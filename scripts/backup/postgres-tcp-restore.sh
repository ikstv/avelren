#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This restore helper must run as root.' >&2; exit 1; }

container="${1:-}"
pg_user="${2:-}"
production_db="${3:-}"
temporary_db="${4:-}"
restore_token="${5:-}"
status_file="${6:-}"
runtime_root=/run/avelren-backup
docker_command_timeout="${AVELREN_BACKUP_DOCKER_TIMEOUT:-5}"
cleanup_armed=0
cleanup_warning_emitted=0
cleanup_status_reported=0
status_fd=
status_file_identity=
expected_cluster=
expected_oid=

case "$container" in ''|*[!a-f0-9]*) printf '%s\n' 'PostgreSQL container identity is invalid.' >&2; exit 1 ;; esac
[ "${#container}" -eq 64 ] || { printf '%s\n' 'PostgreSQL container identity is invalid.' >&2; exit 1; }
case "$pg_user" in ''|*[!A-Za-z0-9_]*) printf '%s\n' 'PostgreSQL restore user is invalid.' >&2; exit 1 ;; esac
[ "$production_db" = avelren ] || { printf '%s\n' 'Production database name must remain avelren.' >&2; exit 1; }
case "$restore_token" in ''|*[!a-f0-9]*) printf '%s\n' 'Restore operation identity is invalid.' >&2; exit 1 ;; esac
[ "${#restore_token}" -eq 32 ] || { printf '%s\n' 'Restore operation identity is invalid.' >&2; exit 1; }
[ "$temporary_db" = "avelren_restore_$restore_token" ] || {
  printf '%s\n' 'Temporary restore database identity is invalid.' >&2
  exit 1
}
[ "$temporary_db" != "$production_db" ] || exit 1
case "$docker_command_timeout" in ''|*[!0-9]*) exit 1 ;; esac
[ "$docker_command_timeout" -ge 1 ] && [ "$docker_command_timeout" -le 30 ] || exit 1

status_parent="${status_file%/*}"
if [ "$status_parent" = "$status_file" ] || [ "$status_file" != "$status_parent/.route-status" ]; then
  printf '%s\n' 'Restore route status path is invalid.' >&2
  exit 1
fi
[ "${status_parent##*/}" = "avelren-restore.$restore_token" ] || {
  printf '%s\n' 'Restore route status path is invalid.' >&2
  exit 1
}
if [ ! -d "$status_parent" ] || [ -L "$status_parent" ] || \
   [ "$(stat -c '%u:%g:%a' "$status_parent" 2>/dev/null)" != 0:0:700 ] || \
   [ ! -f "$status_file" ] || [ -L "$status_file" ] || \
   [ "$(stat -c '%h:%u:%g:%a' "$status_file" 2>/dev/null)" != 1:0:0:600 ] || \
   [ "$(tail -n 1 "$status_file" 2>/dev/null)" != operation-owned ]; then
  printf '%s\n' 'Restore route status file is unsafe.' >&2
  exit 1
fi
exec {status_fd}>>"$status_file"
status_file_identity="$(stat -c '%d:%i:%h:%u:%g:%a' "$status_file")"
status_fd_identity="$(stat -Lc '%d:%i:%h:%u:%g:%a' "/proc/$$/fd/$status_fd")"
if [ "$status_file_identity" != "$status_fd_identity" ] || \
   ! [[ "$status_file_identity" =~ ^[0-9]+:[0-9]+:1:0:0:600$ ]]; then
  printf '%s\n' 'Restore route status file identity is unsafe.' >&2
  exit 1
fi

host_status_file_is_secure() {
  [ -f "$status_file" ] && [ ! -L "$status_file" ] && \
    [ "$(stat -c '%d:%i:%h:%u:%g:%a' "$status_file" 2>/dev/null)" = "$status_file_identity" ] && \
    [ "$(stat -Lc '%d:%i:%h:%u:%g:%a' "/proc/$$/fd/$status_fd" 2>/dev/null)" = "$status_file_identity" ]
}

write_host_status() {
  local marker="$1"
  host_status_file_is_secure || return 1
  printf '%s\n' "$marker" >&"$status_fd"
  [ "$(tail -n 1 "$status_file")" = "$marker" ]
}

load_create_handoff() {
  local handoff payload cluster oid
  host_status_file_is_secure || return 1
  handoff="$(grep -E '^database-owned:[0-9]+:[0-9]+$' "$status_file" | tail -n 1)" || handoff=
  [ -n "$handoff" ] || return 1
  payload="${handoff#database-owned:}"
  cluster="${payload%%:*}"
  oid="${payload#*:}"
  case "$cluster" in ''|*[!0-9]*) return 1 ;; esac
  case "$oid" in ''|*[!0-9]*) return 1 ;; esac
  expected_cluster="$cluster"
  expected_oid="$oid"
}

clean_host_environment=(
  env
  -u PGHOST
  -u PGHOSTADDR
  -u PGPORT
  -u PGUSER
  -u PGDATABASE
  -u PGSERVICE
  -u PGSERVICEFILE
  -u PGPASSFILE
  -u PGPASSWORD
  -u PGOPTIONS
)

docker_timed() {
  timeout --signal=KILL "$docker_command_timeout" "${clean_host_environment[@]}" docker "$@"
}

declared_tmpfs_is_secure() {
  local options option mode_count=0 uid_count=0 gid_count=0
  local rw=0 noexec=0 nosuid=0 nodev=0
  local -a declared_options
  options="$(docker_timed inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$container")" || return 1
  [ -n "$options" ] || return 1
  local IFS=,
  read -r -a declared_options <<<"$options"
  for option in "${declared_options[@]}"; do
    case "$option" in
      rw) rw=1 ;;
      noexec) noexec=1 ;;
      nosuid) nosuid=1 ;;
      nodev) nodev=1 ;;
      mode=0700|mode=700) ((mode_count += 1)) ;;
      uid=0) ((uid_count += 1)) ;;
      gid=0) ((gid_count += 1)) ;;
      ro|exec|suid|dev|rw=*|noexec=*|nosuid=*|nodev=*|mode|uid|gid|mode=*|uid=*|gid=*|'') return 1 ;;
      *) : ;;
    esac
  done
  [ "$rw" -eq 1 ] && [ "$noexec" -eq 1 ] && [ "$nosuid" -eq 1 ] && [ "$nodev" -eq 1 ] && \
    [ "$mode_count" -ge 1 ] && [ "$uid_count" -ge 1 ] && [ "$gid_count" -ge 1 ]
}

effective_tmpfs_is_secure() {
  docker_timed exec --interactive --user 0 "$container" sh -s -- "$runtime_root" <<'EFFECTIVE_TMPFS'
set -eu
target="$1"
awk -v target="$target" '
  function has(options, expected,  count, item) {
    count = split(options, item, ",")
    for (i = 1; i <= count; i++) if (item[i] == expected) return 1
    return 0
  }
  $5 == target {
    found++
    dash = 0
    for (i = 7; i <= NF; i++) if ($i == "-") { dash = i; break }
    if (!dash || dash == NF || $(dash + 1) != "tmpfs") { invalid = 1; next }
    if (!has($6, "rw") || !has($6, "noexec") || !has($6, "nosuid") || !has($6, "nodev")) { invalid = 1; next }
  }
  END { exit found == 1 && invalid == 0 ? 0 : 1 }
' /proc/self/mountinfo
[ -d "$target" ] && [ ! -L "$target" ]
[ "$(stat -c '%u:%g:%a' "$target")" = '0:0:700' ]
EFFECTIVE_TMPFS
}

IFS= read -r -d '' container_program <<'CONTAINER_PROGRAM' || :
set -eu
action="${1:-}"
pg_user="${2:-}"
production_db="${3:-}"
temporary_db="${4:-}"
restore_token="${5:-}"
expected_cluster="${6:-}"
expected_oid="${7:-}"
runtime_root=/run/avelren-backup
state_dir="$runtime_root/restore.$restore_token"
owner_file="$state_dir/.owner"
database_file="$state_dir/database"
cluster_file="$state_dir/cluster-system-id"
phase_file="$state_dir/phase"
oid_file="$state_dir/database-oid"
creator_file="$state_dir/creator.identity"
create_client_file="$state_dir/create-client.identity"
password_file=/run/secrets/postgres_password
pgpass_file=
credential_dir="$state_dir"
create_application_name="avelren_restore_create_$restore_token"
state_created=0
creation_intent=0
create_client_pid=
create_client_launching=0
create_client_identity_published=0
pending_signal_status=
termination_timeout=10

case "$action" in create|restore|validate|cleanup|recover) ;; *) exit 64 ;; esac
case "$pg_user" in ""|*[!A-Za-z0-9_]*) exit 64 ;; esac
[ "$production_db" = avelren ] || exit 64
case "$restore_token" in ""|*[!a-f0-9]*) exit 64 ;; esac
[ "${#restore_token}" -eq 32 ] || exit 64
[ "$temporary_db" = "avelren_restore_$restore_token" ] || exit 64
[ "$temporary_db" != "$production_db" ] || exit 64
case "$expected_cluster:$expected_oid" in *[!0-9:]*) exit 64 ;; esac
if [ "$action" = recover ]; then
  if [ -n "$expected_cluster" ] || [ -n "$expected_oid" ]; then
    [ -n "$expected_cluster" ] && [ -n "$expected_oid" ] || exit 64
  fi
elif [ -n "$expected_cluster" ] || [ -n "$expected_oid" ]; then
  exit 64
fi

trusted_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
AVELREN_RESTORE_OPERATION_ID="$restore_token"
export AVELREN_RESTORE_OPERATION_ID

run_pg() {
  env -i PATH="$trusted_path" PGPASSFILE="$pgpass_file" \
    AVELREN_RESTORE_OPERATION_ID="$restore_token" "$@"
}

state_file_is_secure() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%h:%u:%g:%a' "$1")" = 1:0:0:600 ]
}

write_state_file() {
  destination="$1"
  value="$2"
  temporary="$destination.tmp"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ]
  printf '%s\n' "$value" >"$temporary"
  chmod 600 "$temporary"
  state_file_is_secure "$temporary"
  mv -f -- "$temporary" "$destination"
  state_file_is_secure "$destination"
  [ "$(cat "$destination")" = "$value" ]
}

process_start_time() {
  awk '{print $22}' "/proc/$1/stat"
}

write_process_identity() {
  identity_file="$1"
  identity_pid="$2"
  identity_start="$(process_start_time "$identity_pid")"
  case "$identity_pid:$identity_start" in *[!0-9:]*) return 1 ;; esac
  write_state_file "$identity_file" "$identity_pid:$identity_start"
}

identity_state() {
  identity_file="$1"
  if [ ! -e "$identity_file" ] && [ ! -L "$identity_file" ]; then printf '%s\n' missing; return 0; fi
  if ! state_file_is_secure "$identity_file"; then printf '%s\n' unsafe; return 0; fi
  identity="$(cat "$identity_file")"
  identity_pid="${identity%%:*}"
  identity_start="${identity#*:}"
  case "$identity_pid:$identity_start" in *[!0-9:]*) printf '%s\n' unsafe; return 0 ;; esac
  if [ ! -r "/proc/$identity_pid/stat" ]; then printf '%s\n' stopped; return 0; fi
  process_identity="$(awk '{print $3 ":" $22}' "/proc/$identity_pid/stat" 2>/dev/null)" || {
    printf '%s\n' stopped
    return 0
  }
  process_state="${process_identity%%:*}"
  actual_start="${process_identity#*:}"
  if [ "$actual_start" != "$identity_start" ]; then printf '%s\n' stopped; return 0; fi
  if [ "$process_state" = Z ]; then printf '%s\n' stopped; return 0; fi
  if [ ! -r "/proc/$identity_pid/environ" ]; then printf '%s\n' unsafe; return 0; fi
  if tr '\000' '\n' <"/proc/$identity_pid/environ" | grep -Fqx "AVELREN_RESTORE_OPERATION_ID=$restore_token"; then
    printf '%s\n' running
  else
    printf '%s\n' unsafe
  fi
}

signal_identity() {
  identity_file="$1"
  requested_signal="$2"
  state="$(identity_state "$identity_file")"
  case "$state" in
    stopped) return 0 ;;
    running) : ;;
    *) return 1 ;;
  esac
  identity="$(cat "$identity_file")"
  kill -s "$requested_signal" "${identity%%:*}" 2>/dev/null || [ "$(identity_state "$identity_file")" = stopped ]
}

wait_identity_stop() {
  identity_file="$1"
  allow_missing="${2:-0}"
  deadline=$(($(date +%s) + termination_timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(identity_state "$identity_file")"
    case "$state" in
      stopped) return 0 ;;
      missing) [ "$allow_missing" -eq 1 ] && return 0; return 1 ;;
      running) sleep 1 ;;
      *) return 1 ;;
    esac
  done
  state="$(identity_state "$identity_file")"
  [ "$state" = stopped ] || { [ "$allow_missing" -eq 1 ] && [ "$state" = missing ]; }
}

stop_identity() {
  identity_file="$1"
  allow_missing="${2:-0}"
  state="$(identity_state "$identity_file")"
  case "$state" in
    stopped) return 0 ;;
    missing) [ "$allow_missing" -eq 1 ] && return 0; return 1 ;;
    running) : ;;
    *) return 1 ;;
  esac
  signal_identity "$identity_file" TERM || return 1
  if wait_identity_stop "$identity_file" "$allow_missing"; then return 0; fi
  [ "$(identity_state "$identity_file")" = running ] || return 1
  signal_identity "$identity_file" KILL || return 1
  wait_identity_stop "$identity_file" "$allow_missing"
}

stop_and_reap_local_client() {
  identity_pid=
  identity_start=
  [ -n "$create_client_pid" ] || return 0
  if [ "$create_client_identity_published" -eq 1 ]; then
    state_file_is_secure "$create_client_file" || return 1
    identity="$(cat "$create_client_file")"
    identity_pid="${identity%%:*}"
    identity_start="${identity#*:}"
    case "$identity_pid:$identity_start" in *[!0-9:]*) return 1 ;; esac
    [ "$identity_pid" = "$create_client_pid" ] || return 1
    # A reaped PID may already have been reused at a deferred trap boundary;
    # the persisted start time and operation token must match before signalling.
    stop_identity "$create_client_file" || return 1
  else
    # Before identity publication this is still an unreaped direct child, so
    # its PID cannot be reused. This path closes the async-launch handoff.
    kill -TERM "$create_client_pid" 2>/dev/null || :
    deadline=$(($(date +%s) + termination_timeout))
    while kill -0 "$create_client_pid" 2>/dev/null; do
      [ "$(awk '{print $3}' "/proc/$create_client_pid/stat" 2>/dev/null)" != Z ] || break
      [ "$(date +%s)" -lt "$deadline" ] || break
      sleep 1
    done
    if kill -0 "$create_client_pid" 2>/dev/null && \
       [ "$(awk '{print $3}' "/proc/$create_client_pid/stat" 2>/dev/null)" != Z ]; then
      kill -KILL "$create_client_pid" 2>/dev/null || :
    fi
  fi
  wait "$create_client_pid" 2>/dev/null || :
  create_client_pid=
  create_client_identity_published=0
}

verify_owner() {
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ]
  [ "$(stat -c '%u:%g:%a' "$state_dir")" = 0:0:700 ]
  state_file_is_secure "$owner_file"
  [ "$(cat "$owner_file")" = "$restore_token" ]
  state_file_is_secure "$database_file"
  [ "$(cat "$database_file")" = "$temporary_db" ]
}

create_pgpass() {
  [ -d "$runtime_root" ] && [ ! -L "$runtime_root" ]
  [ "$(stat -c '%u:%g:%a' "$runtime_root")" = 0:0:700 ]
  [ -f "$password_file" ] && [ ! -L "$password_file" ] && [ -s "$password_file" ]
  [ "$(wc -l <"$password_file")" -eq 0 ]
  pgpass_file="$(mktemp "$credential_dir/pgpass.$restore_token.XXXXXX")"
  chmod 600 "$pgpass_file"
  [ "$(stat -c '%h:%u:%g:%a' "$pgpass_file")" = 1:0:0:600 ]
  {
    printf '127.0.0.1:5432:%s:%s:' "$production_db" "$pg_user"
    sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' "$password_file"
    printf '\n'
    printf '127.0.0.1:5432:%s:%s:' "$temporary_db" "$pg_user"
    sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' "$password_file"
    printf '\n'
  } >"$pgpass_file"
}

query_production() {
  run_pg psql --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
    --dbname "$production_db" --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 "$@"
}

verify_route() {
  identity="$(query_production --command "SELECT current_database() || '|' || current_user || '|' || host(inet_server_addr()) || '|' || inet_server_port()" 2>/dev/null)"
  [ "$identity" = "$production_db|$pg_user|127.0.0.1|5432" ]
}

current_cluster_id() {
  query_production --command 'SELECT system_identifier FROM pg_control_system()' 2>/dev/null
}

current_database_oid() {
  query_production --command "SELECT oid FROM pg_database WHERE datname = '$temporary_db'" 2>/dev/null
}

create_backend_count() {
  count="$(query_production --command "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = '$create_application_name' AND usename = '$pg_user' AND datname = '$production_db' AND pid <> pg_backend_pid()" 2>/dev/null)" || return 1
  case "$count" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$count"
}

stop_create_backends() {
  count="$(create_backend_count)" || return 1
  if [ "$count" -gt 0 ]; then
    query_production --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = '$create_application_name' AND usename = '$pg_user' AND datname = '$production_db' AND pid <> pg_backend_pid()" \
      >/dev/null 2>&1 || return 1
  fi
  deadline=$(($(date +%s) + termination_timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    count="$(create_backend_count)" || return 1
    [ "$count" -ne 0 ] || return 0
    sleep 1
  done
  [ "$(create_backend_count)" -eq 0 ]
}

verify_cluster() {
  state_file_is_secure "$cluster_file"
  expected_cluster="$(cat "$cluster_file")"
  case "$expected_cluster" in ""|*[!0-9]*) return 1 ;; esac
  [ "$(current_cluster_id)" = "$expected_cluster" ]
}

verify_ready_database() {
  verify_owner
  state_file_is_secure "$phase_file"
  [ "$(cat "$phase_file")" = ready ]
  state_file_is_secure "$oid_file"
  expected_oid="$(cat "$oid_file")"
  case "$expected_oid" in ""|*[!0-9]*) return 1 ;; esac
  create_pgpass
  verify_route
  verify_cluster
  [ "$(current_database_oid)" = "$expected_oid" ]
}

finish_action() {
  primary_status=$?
  cleanup_status=0
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  stop_and_reap_local_client || cleanup_status=1
  if [ "$action" = create ] && [ "$primary_status" -ne 0 ] && \
     [ "$state_created" -eq 1 ] && [ "$creation_intent" -eq 0 ]; then
    if [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; then
      rm -rf -- "$state_dir" || cleanup_status=1
    fi
    if [ -e "$state_dir" ] || [ -L "$state_dir" ]; then cleanup_status=1; fi
  fi
  if [ -n "$pgpass_file" ]; then
    rm -f -- "$pgpass_file" || cleanup_status=1
    if [ -e "$pgpass_file" ] || [ -L "$pgpass_file" ]; then cleanup_status=1; fi
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' 'Temporary PostgreSQL credential cleanup failed; verified state was preserved.' >&2
  fi
  if [ "$primary_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then primary_status=1; fi
  exit "$primary_status"
}

terminate_action() {
  signal_status="$1"
  trap '' HUP INT TERM
  # EXIT cleanup reports an unverifiable child identity without replacing the
  # primary signal-derived status.
  stop_and_reap_local_client || :
  exit "$signal_status"
}

handle_action_signal() {
  signal_status="$1"
  if [ "$create_client_launching" -eq 1 ]; then
    if [ -z "$pending_signal_status" ]; then pending_signal_status="$signal_status"; fi
    return 0
  fi
  terminate_action "$signal_status"
}

trap finish_action EXIT
trap 'handle_action_signal 129' HUP
trap 'handle_action_signal 130' INT
trap 'handle_action_signal 143' TERM

case "$action" in
  create)
    if [ -e "$state_dir" ] || [ -L "$state_dir" ]; then exit 73; fi
    mkdir -m 700 -- "$state_dir"
    state_created=1
    write_state_file "$owner_file" "$restore_token"
    write_state_file "$database_file" "$temporary_db"
    verify_owner
    create_pgpass
    verify_route
    cluster_id="$(current_cluster_id)"
    case "$cluster_id" in ""|*[!0-9]*) exit 1 ;; esac
    existing_oid="$(current_database_oid)"
    [ -z "$existing_oid" ] || exit 73
    write_state_file "$cluster_file" "$cluster_id"
    write_process_identity "$creator_file" "$$"
    write_state_file "$phase_file" intent
    creation_intent=1
    # Queue a signal across the one-command launch handoff so the direct child
    # is always recorded before TERM/KILL/reap begins.
    create_client_launching=1
    env -i PATH="$trusted_path" PGPASSFILE="$pgpass_file" PGAPPNAME="$create_application_name" \
      AVELREN_RESTORE_OPERATION_ID="$restore_token" \
      createdb --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
        --maintenance-db "$production_db" --template template0 "$temporary_db" >/dev/null 2>&1 &
    create_client_pid=$!
    create_client_launching=0
    if [ -n "$pending_signal_status" ]; then
      terminate_action "$pending_signal_status"
    fi
    write_process_identity "$create_client_file" "$create_client_pid"
    create_client_identity_published=1
    create_status=0
    if wait "$create_client_pid"; then create_status=0; else create_status=$?; fi
    create_client_pid=
    create_client_identity_published=0
    rm -f -- "$create_client_file"
    if [ "$create_status" -ne 0 ]; then
      printf '%s\n' 'Temporary restore database creation failed.' >&2
      exit 1
    fi
    database_oid="$(current_database_oid)"
    case "$database_oid" in ""|*[!0-9]*) exit 1 ;; esac
    write_state_file "$oid_file" "$database_oid"
    write_state_file "$phase_file" ready
    printf 'database-owned:%s:%s\n' "$cluster_id" "$database_oid"
    ;;
  restore)
    verify_ready_database
    if ! run_pg pg_restore --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
      --dbname "$temporary_db" --exit-on-error --single-transaction --no-owner --no-acl 2>/dev/null; then
      printf '%s\n' 'PostgreSQL restore into the temporary database failed.' >&2
      exit 1
    fi
    [ "$(current_database_oid)" = "$(cat "$oid_file")" ]
    ;;
  validate)
    verify_ready_database
    identity="$(run_pg psql --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
      --dbname "$temporary_db" --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --command "SELECT current_database() || '|' || current_user || '|' || host(inet_server_addr()) || '|' || inet_server_port()" 2>/dev/null)"
    [ "$identity" = "$temporary_db|$pg_user|127.0.0.1|5432" ]
    migrations="$(run_pg psql --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
      --dbname "$temporary_db" --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --command "SELECT string_agg(version, ',' ORDER BY version) FROM public.avelren_schema_migrations" 2>/dev/null)"
    [ "$migrations" = 001,002,003 ]
    for table in collector_observations collector_snapshots threshold_events collector_leases push_devices notification_outbox external_source_poll_state; do
      present="$(run_pg psql --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
        --dbname "$temporary_db" --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --command "SELECT to_regclass('public.$table') IS NOT NULL" 2>/dev/null)"
      [ "$present" = t ]
    done
    ;;
  cleanup)
    if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then exit 76; fi
    verify_owner
    create_pgpass
    verify_route
    phase=
    if [ -e "$phase_file" ] || [ -L "$phase_file" ]; then
      state_file_is_secure "$phase_file"
      phase="$(cat "$phase_file")"
    fi
    current_oid="$(current_database_oid)"
    case "$phase" in
      '')
        [ -z "$current_oid" ] || exit 1
        ;;
      intent)
        verify_cluster
        if [ -e "$create_client_file" ] || [ -L "$create_client_file" ]; then
          stop_identity "$create_client_file" 1
        fi
        stop_identity "$creator_file"
        # The client can disconnect while PostgreSQL is still processing
        # CREATE DATABASE. Fence the exact token-scoped server backend before
        # deciding that an absent OID means no database can appear later.
        stop_create_backends
        state_file_is_secure "$phase_file"
        phase="$(cat "$phase_file")"
        current_oid="$(current_database_oid)"
        case "$phase" in
          intent) : ;;
          ready)
            state_file_is_secure "$oid_file"
            expected_state_oid="$(cat "$oid_file")"
            case "$expected_state_oid" in ""|*[!0-9]*) exit 1 ;; esac
            [ "$current_oid" = "$expected_state_oid" ]
            ;;
          *) exit 1 ;;
        esac
        ;;
      ready)
        verify_cluster
        state_file_is_secure "$oid_file"
        expected_oid="$(cat "$oid_file")"
        case "$expected_oid" in ""|*[!0-9]*) exit 1 ;; esac
        if [ -n "$current_oid" ] && [ "$current_oid" != "$expected_oid" ]; then exit 1; fi
        ;;
      *) exit 1 ;;
    esac
    if [ -n "$current_oid" ]; then
      if ! run_pg dropdb --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
        --maintenance-db "$production_db" --if-exists --force "$temporary_db" >/dev/null 2>&1; then
        printf '%s\n' 'Temporary restore database cleanup failed; verified state was preserved.' >&2
        exit 1
      fi
    fi
    remaining_oid="$(current_database_oid)"
    [ -z "$remaining_oid" ]
    rm -f -- "$pgpass_file"
    pgpass_file=
    rm -rf -- "$state_dir"
    [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]
    ;;
  recover)
    [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ] || exit 1
    credential_dir="$runtime_root"
    create_pgpass
    verify_route
    recovery_cluster="$(current_cluster_id)"
    case "$recovery_cluster" in ""|*[!0-9]*) exit 1 ;; esac
    recovery_oid="$(current_database_oid)"
    if [ -n "$expected_cluster" ]; then
      [ "$recovery_cluster" = "$expected_cluster" ] || exit 1
      if [ -n "$recovery_oid" ] && [ "$recovery_oid" != "$expected_oid" ]; then exit 1; fi
    fi
    if [ -n "$recovery_oid" ]; then
      if ! run_pg dropdb --host 127.0.0.1 --port 5432 --username "$pg_user" --no-password \
        --maintenance-db "$production_db" --if-exists --force "$temporary_db" >/dev/null 2>&1; then
        printf '%s\n' 'Temporary restore database recovery cleanup failed.' >&2
        exit 1
      fi
    fi
    remaining_oid="$(current_database_oid)"
    [ -z "$remaining_oid" ]
    ;;
esac
CONTAINER_PROGRAM

run_container_action() {
  local action="$1"
  local action_cluster="${2:-}"
  local action_oid="${3:-}"
  "${clean_host_environment[@]}" docker exec --interactive --user 0 "$container" \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "AVELREN_RESTORE_OPERATION_ID=$restore_token" \
    sh -eu -c "$container_program" sh "$action" "$pg_user" "$production_db" "$temporary_db" "$restore_token" \
      "$action_cluster" "$action_oid"
}

cleanup_database() {
  if [ "$cleanup_armed" -ne 1 ]; then
    if [ "$cleanup_status_reported" -eq 0 ]; then
      write_host_status cleanup-verified || return 1
      cleanup_status_reported=1
    fi
    return 0
  fi
  load_create_handoff || {
    expected_cluster=
    expected_oid=
  }
  action_status=0
  if run_container_action cleanup </dev/null; then
    action_status=0
  else
    action_status=$?
  fi
  if [ "$action_status" -eq 76 ]; then
    if run_container_action recover "$expected_cluster" "$expected_oid" </dev/null; then
      action_status=0
    else
      action_status=$?
    fi
  fi
  if [ "$action_status" -eq 0 ]; then
    cleanup_armed=0
    if write_host_status cleanup-verified; then
      cleanup_status_reported=1
      return 0
    fi
  fi
  write_host_status cleanup-unverified || :
  if [ "$cleanup_warning_emitted" -eq 0 ]; then
    printf '%s\n' 'Temporary restore database cleanup failed; verified state was preserved.' >&2
    cleanup_warning_emitted=1
  fi
  return 1
}

cleanup() {
  primary_status=$?
  cleanup_status=0
  trap - EXIT
  trap '' HUP INT TERM
  cleanup_database || cleanup_status=$?
  if [ "$primary_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then primary_status=1; fi
  exit "$primary_status"
}

terminate() {
  trap '' HUP INT TERM
  exit "$1"
}

trap cleanup EXIT
trap 'terminate 129' HUP
trap 'terminate 130' INT
trap 'terminate 143' TERM

[ "$(docker_timed inspect -f '{{.Id}}' "$container")" = "$container" ] || {
  printf '%s\n' 'PostgreSQL container identity changed.' >&2
  exit 1
}
[ "$(docker_timed inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] || {
  printf '%s\n' 'PostgreSQL is not healthy.' >&2
  exit 1
}
declared_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL restore runtime tmpfs configuration is unsafe.' >&2
  exit 1
}
effective_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL restore runtime effective tmpfs mount is unsafe.' >&2
  exit 1
}

cleanup_armed=1
run_container_action create </dev/null >&"$status_fd"
load_create_handoff || {
  printf '%s\n' 'Temporary restore database ownership handoff failed.' >&2
  exit 1
}
run_container_action restore
run_container_action validate </dev/null
cleanup_database
# Exercise the idempotent no-op path before removing traps.
cleanup_database
trap - EXIT HUP INT TERM
printf '%s\n' 'Controlled PostgreSQL restore route completed.'
