#!/bin/sh
set -eu

pg_database="${1:-}"
pg_user="${2:-}"
control_dir="${3:-}"
operation_id="${4:-}"
password_file="${AVELREN_POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password}"
heartbeat_timeout="${AVELREN_BACKUP_HEARTBEAT_TIMEOUT:-30}"
termination_timeout="${AVELREN_BACKUP_TERMINATION_TIMEOUT:-10}"
runner_uid="$(id -u)"
pgpass_file=
dump_pid=
watchdog_pid=
lease_expired=0

case "$pg_database:$pg_user" in
  *[!A-Za-z0-9_:]*|:*|*:) printf '%s\n' 'PostgreSQL backup identity is invalid.' >&2; exit 1 ;;
esac
case "$operation_id" in ''|*[!a-f0-9]*) printf '%s\n' 'Backup operation identity is invalid.' >&2; exit 1 ;; esac
[ "${#operation_id}" -eq 32 ] || { printf '%s\n' 'Backup operation identity is invalid.' >&2; exit 1; }
[ "$control_dir" = "/run/avelren-backup/operation.$operation_id" ] || { printf '%s\n' 'Backup control path is invalid.' >&2; exit 1; }
case "$heartbeat_timeout" in ''|*[!0-9]*) exit 1 ;; esac
[ "$heartbeat_timeout" -ge 5 ] && [ "$heartbeat_timeout" -le 300 ] || exit 1
case "$termination_timeout" in ''|*[!0-9]*) exit 1 ;; esac
[ "$termination_timeout" -ge 2 ] && [ "$termination_timeout" -le 60 ] || exit 1

AVELREN_BACKUP_OPERATION_ID="$operation_id"
export AVELREN_BACKUP_OPERATION_ID

process_start_time() {
  awk '{print $22}' "/proc/$1/stat"
}

identity_is_live() {
  identity_file="$1"
  [ -r "$identity_file" ] || return 1
  identity="$(cat "$identity_file")"
  pid="${identity%%:*}"
  start_time="${identity#*:}"
  case "$pid:$start_time" in *[!0-9:]*) return 1 ;; esac
  if [ ! -r "/proc/$pid/stat" ] || [ "$(process_start_time "$pid")" != "$start_time" ]; then return 1; fi
  [ -r "/proc/$pid/environ" ] || return 1
  tr '\000' '\n' <"/proc/$pid/environ" | grep -Fqx "AVELREN_BACKUP_OPERATION_ID=$operation_id"
}

write_identity() {
  role="$1"
  pid="$2"
  start_time="$(process_start_time "$pid")"
  printf '%s:%s\n' "$pid" "$start_time" >"$control_dir/$role.identity.tmp"
  mv -f -- "$control_dir/$role.identity.tmp" "$control_dir/$role.identity"
}

# Invoked through the EXIT trap.
# shellcheck disable=SC2317,SC2329
write_status() {
  status="$1"
  printf '%s\n' "$status" >"$control_dir/status.tmp"
  mv -f -- "$control_dir/status.tmp" "$control_dir/status"
}

stop_and_reap() {
  pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  deadline=$(($(date +%s) + termination_timeout))
  while kill -0 "$pid" 2>/dev/null; do
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    [ "$state" != Z ] || break
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" != Z ]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  # This wait is performed by the direct parent and is the actual reap point.
  wait "$pid" 2>/dev/null || true
}

# Invoked through the EXIT trap.
# shellcheck disable=SC2317,SC2329
cleanup() {
  exit_code=$?
  trap - EXIT INT TERM HUP
  stop_and_reap "$dump_pid"
  stop_and_reap "$watchdog_pid"
  dump_pid=
  watchdog_pid=
  [ -n "$pgpass_file" ] && rm -f -- "$pgpass_file"
  if [ "$exit_code" -ne 0 ]; then
    rm -f -- "$control_dir/postgres.dump"
  fi
  if [ "$lease_expired" -eq 1 ]; then
    rm -rf -- "$control_dir"
  else
    write_status "$exit_code"
  fi
  exit "$exit_code"
}

# Invoked through signal traps.
# shellcheck disable=SC2317,SC2329
terminate() {
  exit_code="$1"
  trap - INT TERM HUP
  [ ! -f "$control_dir/lease-expired" ] || lease_expired=1
  stop_and_reap "$dump_pid"
  dump_pid=
  stop_and_reap "$watchdog_pid"
  watchdog_pid=
  exit "$exit_code"
}

watch_heartbeat() {
  supervisor_pid="$1"
  supervisor_start="$2"
  while :; do
    sleep 1
    [ -r "$control_dir/heartbeat" ] || continue
    heartbeat="$(cat "$control_dir/heartbeat" 2>/dev/null || true)"
    case "$heartbeat" in ''|*[!0-9]*) continue ;; esac
    now="$(date +%s)"
    if [ $((now - heartbeat)) -gt "$heartbeat_timeout" ]; then
      if [ -r "/proc/$supervisor_pid/stat" ] && [ "$(process_start_time "$supervisor_pid")" = "$supervisor_start" ]; then
        printf '%s\n' 1 >"$control_dir/lease-expired"
        kill -TERM "$supervisor_pid" 2>/dev/null || true
        deadline=$((now + termination_timeout))
        while identity_is_live "$control_dir/supervisor.identity" && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
        if identity_is_live "$control_dir/supervisor.identity"; then
          if identity_is_live "$control_dir/dump.identity"; then
            dump_identity="$(cat "$control_dir/dump.identity")"
            kill -KILL "${dump_identity%%:*}" 2>/dev/null || true
          fi
          # Give the supervisor a second bounded interval to reap the dump.
          deadline=$(($(date +%s) + termination_timeout))
          while identity_is_live "$control_dir/supervisor.identity" && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
        fi
      fi
      exit 0
    fi
  done
}

trap cleanup EXIT
trap 'terminate 130' INT
trap 'terminate 143' TERM
trap 'terminate 129' HUP

[ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 1
[ "$(stat -c '%u:%a' "$control_dir")" = "$runner_uid:700" ] || exit 1
if [ ! -f "$password_file" ] || [ -L "$password_file" ] || [ ! -s "$password_file" ]; then
  printf '%s\n' 'PostgreSQL password secret is unavailable.' >&2
  exit 1
fi
if [ "$(wc -l <"$password_file")" -ne 0 ]; then
  printf '%s\n' 'PostgreSQL password secret has an invalid format.' >&2
  exit 1
fi

supervisor_pid=$$
supervisor_start="$(process_start_time "$supervisor_pid")"
write_identity supervisor "$supervisor_pid"

umask 077
pgpass_file="$(mktemp "$control_dir/pgpass.XXXXXX")"
chmod 600 "$pgpass_file"
if [ "$(stat -c '%u:%a' "$pgpass_file")" != "$runner_uid:600" ]; then
  printf '%s\n' 'Temporary PostgreSQL credential permissions are invalid.' >&2
  exit 1
fi
{
  printf '127.0.0.1:5432:%s:%s:' "$pg_database" "$pg_user"
  sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' "$password_file"
  printf '\n'
} >"$pgpass_file"

PGPASSFILE="$pgpass_file"
export PGPASSFILE
pg_dump \
  --host 127.0.0.1 \
  --port 5432 \
  --username "$pg_user" \
  --dbname "$pg_database" \
  --format=custom \
  --no-owner \
  --no-acl \
  </dev/null >"$control_dir/postgres.dump" &
dump_pid=$!
write_identity dump "$dump_pid"
watch_heartbeat "$supervisor_pid" "$supervisor_start" &
watchdog_pid=$!
write_identity watchdog "$watchdog_pid"

dump_status=0
wait "$dump_pid" || dump_status=$?
dump_pid=
if [ -f "$control_dir/lease-expired" ]; then
  lease_expired=1
  dump_status=124
fi
stop_and_reap "$watchdog_pid"
watchdog_pid=
exit "$dump_status"
