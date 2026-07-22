#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/avelren-compose-smoke.XXXXXX")"
project_name="avelren-smoke-${GITHUB_RUN_ID:-local}-${RANDOM}"
project_name="$(printf '%s' "$project_name" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
environment_file="$temporary_root/.env.production"
secret_directory="$temporary_root/secrets"
is_msys=false
active_restore_launch_pid=
active_restore_group_pid=
active_restore_pid_file=
case "${OSTYPE:-}" in
  msys* | cygwin*) is_msys=true ;;
esac

cleanup() {
  local exit_code=$?
  trap - EXIT
  if ! [[ "$active_restore_group_pid" =~ ^[0-9]+$ ]] && \
     [ -n "$active_restore_pid_file" ] && [ -s "$active_restore_pid_file" ]; then
    active_restore_group_pid="$(cat "$active_restore_pid_file" 2>/dev/null || true)"
  fi
  if [[ "$active_restore_group_pid" =~ ^[0-9]+$ ]]; then
    sudo kill -TERM -- "-$active_restore_group_pid" >/dev/null 2>&1 || true
    sudo kill -KILL -- "-$active_restore_group_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$active_restore_launch_pid" =~ ^[0-9]+$ ]]; then
    kill -TERM "$active_restore_launch_pid" >/dev/null 2>&1 || true
    wait "$active_restore_launch_pid" 2>/dev/null || true
  fi
  if [[ "$project_name" != avelren-smoke-* ]] || [[ "$temporary_root" != */avelren-compose-smoke.* ]]; then
    printf '%s\n' 'Refusing cleanup outside disposable smoke-test scope.' >&2
    exit 90
  fi
  if [ "$exit_code" -ne 0 ] && [ -f "$environment_file" ]; then
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" ps --all || true
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" logs --no-color --tail=100 postgres api 2>&1 \
      | sed -E 's#postgres(ql)?://[^[:space:]]+#[REDACTED_DATABASE_URL]#g' || true
  fi
  if [ -f "$environment_file" ]; then
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ "$is_msys" = true ]; then
    :
  elif [ "$(id -u)" -eq 0 ]; then
    chown -R "$(id -u):$(id -g)" "$temporary_root" 2>/dev/null || true
  else
    docker run --rm --user 0 --volume "$temporary_root:/cleanup" \
      --entrypoint chown postgres:17-alpine -R "$(id -u):$(id -g)" /cleanup \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temporary_root"
  exit "$exit_code"
}
trap cleanup EXIT

umask 077
mkdir -p "$secret_directory"
chmod 700 "$secret_directory" || [ "$is_msys" = true ]
postgres_password="$(openssl rand -hex 32)"
printf '%s' "$postgres_password" > "$secret_directory/postgres_password"
printf 'postgresql://avelren:%s@postgres:5432/avelren' "$postgres_password" \
  > "$secret_directory/database_url"
unset postgres_password
chmod 600 "$secret_directory/postgres_password"
chmod 0400 "$secret_directory/database_url"
if [ "$is_msys" = true ]; then
  :
elif [ "$(id -u)" -eq 0 ]; then
  chown 10001:10001 "$secret_directory/database_url"
else
  docker run --rm --user 0 --volume "$secret_directory:/secrets" \
    --entrypoint chown postgres:17-alpine 10001:10001 /secrets/database_url \
    >/dev/null
fi

if [ "$is_msys" = false ]; then
  [ "$(stat -c '%a' "$secret_directory")" = '700' ]
  [ "$(stat -c '%a' "$secret_directory/postgres_password")" = '600' ]
  [ "$(stat -c '%u:%g %a' "$secret_directory/database_url")" = '10001:10001 400' ]
fi

compose_postgres_password="$secret_directory/postgres_password"
compose_database_url="$secret_directory/database_url"
if [ "$is_msys" = true ]; then
  compose_postgres_password="$(cygpath -m "$compose_postgres_password")"
  compose_database_url="$(cygpath -m "$compose_database_url")"
fi

printf '%s\n' \
  'AVELREN_DOMAIN=smoke.example.invalid' \
  'ACME_EMAIL=smoke@example.invalid' \
  'AVELREN_INSTANCE_ID=avelren-smoke' \
  'POSTGRES_DB=avelren' \
  'POSTGRES_USER=avelren' \
  "POSTGRES_PASSWORD_FILE=$compose_postgres_password" \
  "DATABASE_URL_FILE=$compose_database_url" \
  > "$environment_file"
chmod 600 "$environment_file"

compose=(
  docker compose
  --project-name "$project_name"
  --env-file "$environment_file"
  --project-directory "$repository_root"
)

if docker volume ls --quiet --filter "label=com.docker.compose.project=$project_name" | grep -q .; then
  printf '%s\n' 'Disposable Compose project already has resources.' >&2
  exit 91
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d --build postgres
"${compose[@]}" up -d --wait --wait-timeout 120 postgres
postgres_container="$("${compose[@]}" ps -q postgres)"
runtime_root=/run/avelren-backup
[ -n "$(docker inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$postgres_container")" ]
[ "$("${compose[@]}" exec -T -u 0 postgres stat -c '%u:%g:%a' "$runtime_root")" = '0:0:700' ]
# Verify the effective kernel mount as well as the Docker declaration. The
# target is canonical and unescaped, so exact mountinfo field matching cannot
# accept a nested or similarly named mount point.
"${compose[@]}" exec -T -u 0 postgres sh -s -- "$runtime_root" <<'EOF'
set -eu
target="$1"
if ! awk -v target="$target" '
  # AVELREN_TMPFS_MOUNTINFO_AWK_BEGIN
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
  # AVELREN_TMPFS_MOUNTINFO_AWK_END
' /proc/self/mountinfo
then
  printf '%s\n' 'Effective PostgreSQL backup tmpfs mount validation failed.' >&2
  awk -v target="$target" '$5 == target { print }' /proc/self/mountinfo >&2
  exit 1
fi
[ "$(stat -c '%u:%g:%a' "$target")" = '0:0:700' ]
EOF

# A real disposable copy of the mounted credential and its operation state must
# disappear on container restart because the runtime is a dedicated tmpfs.
# Expansion belongs to the isolated shell inside the disposable container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c '
  mkdir -m 700 "$1/restart-proof"
  cp /run/secrets/postgres_password "$1/restart-proof/pgpass.fixture"
  chmod 600 "$1/restart-proof/pgpass.fixture"
  [ "$(stat -c "%u:%g:%a" "$1/restart-proof/pgpass.fixture")" = "0:0:600" ]
' sh "$runtime_root"
"${compose[@]}" restart postgres >/dev/null
"${compose[@]}" up -d --wait --wait-timeout 120 postgres
"${compose[@]}" exec -T -u 0 postgres test ! -e "$runtime_root/restart-proof"
[ "$("${compose[@]}" exec -T -u 0 postgres stat -c '%u:%g:%a' "$runtime_root")" = '0:0:700' ]

postgres_query() {
  # Expansion belongs to the isolated shell inside the PostgreSQL container.
  # shellcheck disable=SC2016
  "${compose[@]}" exec -T -u 0 postgres sh -ec '
    export PGPASSWORD="$(cat /run/secrets/postgres_password)"
    exec psql --host 127.0.0.1 --username "$POSTGRES_USER" \
      --dbname "$POSTGRES_DB" --no-psqlrc --tuples-only --no-align \
      --set ON_ERROR_STOP=1 --command "$1"
  ' sh "$1"
}

wait_for_query_value() {
  local query="$1" expected="$2" label="$3" value= deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    value="$(postgres_query "$query" 2>/dev/null || true)"
    [ "$value" = "$expected" ] && return 0
    sleep 0.1
  done
  printf '%s\n' "$label did not reach its expected PostgreSQL state." >&2
  return 1
}

wait_for_local_process_exit() {
  local process_id="$1" deadline=$((SECONDS + 30))
  while kill -0 "$process_id" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

backup_helper="$repository_root/scripts/backup/postgres-tcp-dump.sh"
backup_dump="$temporary_root/postgres.dump"
backup_log="$temporary_root/postgres-backup-auth.log"
"${compose[@]}" up -d --build api
"${compose[@]}" up -d --wait --wait-timeout 180 api
schema_before="$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
operation_id="$(openssl rand -hex 16)"
control_dir="$runtime_root/operation.$operation_id"
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c \
  'umask 077; mkdir -m 700 -- "$1"; cat >"$1/runner.sh"; chmod 700 "$1/runner.sh"; date +%s >"$1/heartbeat"' \
  sh "$control_dir" <"$backup_helper"
"${compose[@]}" exec -T -u 0 \
  -e "AVELREN_BACKUP_OPERATION_ID=$operation_id" \
  -e AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 \
  postgres sh "$control_dir/runner.sh" avelren avelren "$control_dir" "$operation_id" \
  >"$backup_log" 2>&1
[ "$("${compose[@]}" exec -T postgres cat "$control_dir/status")" = 0 ]
# The Docker archive API does not reliably traverse tmpfs mounts; stream the
# already successful custom dump without printing it to the Actions log.
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c '
  file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ]
  [ "$(stat -c "%u:%g:%a" "$file")" = "0:0:600" ]
  cat -- "$file"
' sh "$control_dir/postgres.dump" >"$backup_dump"
"${compose[@]}" exec -T -u 0 postgres rm -rf -- "$control_dir"
[ -s "$backup_dump" ]
"${compose[@]}" exec -T postgres pg_restore --list <"$backup_dump" >/dev/null
schema_after="$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
[ "$schema_before" = "$schema_after" ]
[ -z "$("${compose[@]}" exec -T postgres find "$runtime_root" -maxdepth 2 -name 'pgpass.*' -print -quit)" ]
if grep -Fq -f "$secret_directory/postgres_password" "$backup_log"; then
  printf '%s\n' 'PostgreSQL password leaked into backup output.' >&2
  exit 1
fi

# Exercise the production restore helper against the same disposable container
# without publishing PostgreSQL on the host. Hostile libpq variables must not
# alter the helper's exact container/TCP/pgpass route.
restore_helper="$repository_root/scripts/backup/postgres-tcp-restore.sh"
restore_token="$(openssl rand -hex 16)"
restore_database="avelren_restore_$restore_token"
restore_log="$temporary_root/postgres-restore-auth.log"
restore_state_dir="$temporary_root/avelren-restore.$restore_token"
restore_status_file="$restore_state_dir/.route-status"
sudo install -d -o root -g root -m 0700 "$restore_state_dir"
sudo install -o root -g root -m 0600 /dev/null "$restore_status_file"
printf '%s\n' operation-owned | sudo tee "$restore_status_file" >/dev/null
sudo env \
  "PATH=$PATH" \
  PGHOST=hostile.example.invalid \
  PGHOSTADDR=192.0.2.10 \
  PGPORT=1 \
  PGUSER=hostile-user \
  PGDATABASE=hostile-database \
  PGSERVICE=hostile-service \
  "PGSERVICEFILE=$temporary_root/hostile-service.conf" \
  "PGPASSFILE=$temporary_root/hostile-pgpass" \
  PGPASSWORD=hostile-password-marker \
  PGOPTIONS='-c statement_timeout=1' \
  "$restore_helper" "$postgres_container" avelren avelren "$restore_database" "$restore_token" "$restore_status_file" \
  <"$backup_dump" >"$restore_log" 2>&1
sudo test "$(sudo tail -n 1 "$restore_status_file")" = cleanup-verified
[ "$(postgres_query "SELECT count(*) FROM pg_database WHERE datname = '$restore_database'")" = 0 ]
[ -z "$("${compose[@]}" exec -T -u 0 postgres find "$runtime_root" -maxdepth 1 -name "restore.$restore_token" -print -quit)" ]
[ -z "$("${compose[@]}" exec -T -u 0 postgres find "$runtime_root" -maxdepth 2 -name 'pgpass.*' -print -quit)" ]
if grep -Fq -f "$secret_directory/postgres_password" "$restore_log" || \
   grep -Fq 'hostile-password-marker' "$restore_log"; then
  printf '%s\n' 'PostgreSQL password leaked into restore output.' >&2
  exit 1
fi
sudo rm -rf -- "$restore_state_dir"
printf '%s\n' 'PASS: production-restore-controlled-route'

# Exercise the production intent-cleanup fence with a real PostgreSQL backend.
# The disposable createdb wrapper keeps the token-scoped maintenance connection
# active until cleanup terminates it; a differently tagged backend must survive.
intent_wrapper=/usr/local/sbin/createdb
"${compose[@]}" exec -T -u 0 postgres test ! -e "$intent_wrapper"
"${compose[@]}" exec -T -u 0 postgres sh -eu -c 'cat >"$1"; chmod 755 "$1"' sh "$intent_wrapper" <<'INTENT_CREATEDB_WRAPPER'
#!/bin/sh
set -eu
exec psql --host 127.0.0.1 --port 5432 --username avelren --no-password \
  --dbname avelren --no-psqlrc --set ON_ERROR_STOP=1 --command 'SELECT pg_sleep(120)'
INTENT_CREATEDB_WRAPPER
intent_token="$(openssl rand -hex 16)"
intent_database="avelren_restore_$intent_token"
intent_application="avelren_restore_create_$intent_token"
unrelated_application="avelren_restore_unrelated_$intent_token"
intent_log="$temporary_root/postgres-restore-intent-signal.log"
intent_state_dir="$temporary_root/avelren-restore.$intent_token"
intent_status_file="$intent_state_dir/.route-status"
intent_pid_file="$temporary_root/postgres-restore-intent.pid"
intent_launcher="$temporary_root/postgres-restore-intent-launch.py"
sudo install -d -o root -g root -m 0700 "$intent_state_dir"
sudo install -o root -g root -m 0600 /dev/null "$intent_status_file"
printf '%s\n' operation-owned | sudo tee "$intent_status_file" >/dev/null
: >"$intent_pid_file"
chmod 600 "$intent_pid_file"
cat >"$intent_launcher" <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_TRUNC)
with os.fdopen(descriptor, "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
os.execv(sys.argv[2], sys.argv[2:])
PY
chmod 755 "$intent_launcher"

docker exec --detach --user 0 --env "PGAPPNAME=$unrelated_application" "$postgres_container" \
  psql --username avelren --dbname avelren --no-psqlrc --set ON_ERROR_STOP=1 \
    --command 'SELECT pg_sleep(120)'
wait_for_query_value \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$unrelated_application'" 1 \
  unrelated-restore-backend

sudo env \
  "PATH=$PATH" \
  PGHOST=hostile.example.invalid \
  PGHOSTADDR=192.0.2.10 \
  PGPORT=1 \
  PGUSER=hostile-user \
  PGDATABASE=hostile-database \
  PGSERVICE=hostile-service \
  "PGSERVICEFILE=$temporary_root/hostile-service.conf" \
  "PGPASSFILE=$temporary_root/hostile-pgpass" \
  PGPASSWORD=hostile-password-marker \
  PGOPTIONS='-c statement_timeout=1' \
  setsid --wait python3 "$intent_launcher" "$intent_pid_file" \
    "$restore_helper" "$postgres_container" avelren avelren "$intent_database" "$intent_token" "$intent_status_file" \
    <"$backup_dump" >"$intent_log" 2>&1 &
intent_launch_pid=$!
active_restore_launch_pid="$intent_launch_pid"
active_restore_pid_file="$intent_pid_file"
intent_pid_deadline=$((SECONDS + 15))
while [ ! -s "$intent_pid_file" ] && kill -0 "$intent_launch_pid" 2>/dev/null; do
  [ "$SECONDS" -lt "$intent_pid_deadline" ] || break
  sleep 0.1
done
intent_group_pid="$(cat "$intent_pid_file")"
case "$intent_group_pid" in ''|*[!0-9]*) printf '%s\n' 'Restore intent helper identity was not published.' >&2; exit 1 ;; esac
active_restore_group_pid="$intent_group_pid"
wait_for_query_value \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$intent_application' AND datname = 'avelren'" 1 \
  token-scoped-restore-backend
sudo kill -TERM -- "-$intent_group_pid"
wait_for_local_process_exit "$intent_launch_pid" || {
  printf '%s\n' 'Restore intent helper did not exit after TERM.' >&2
  exit 1
}
intent_status=0
if wait "$intent_launch_pid"; then intent_status=0; else intent_status=$?; fi
active_restore_launch_pid=
active_restore_group_pid=
active_restore_pid_file=
[ "$intent_status" -eq 143 ]
sudo test "$(sudo tail -n 1 "$intent_status_file")" = cleanup-verified
wait_for_query_value \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$intent_application'" 0 \
  cleaned-token-scoped-restore-backend
[ "$(postgres_query "SELECT count(*) FROM pg_database WHERE datname = '$intent_database'")" = 0 ]
[ -z "$("${compose[@]}" exec -T -u 0 postgres find "$runtime_root" -maxdepth 1 -name "restore.$intent_token" -print -quit)" ]
[ -z "$("${compose[@]}" exec -T -u 0 postgres find "$runtime_root" -maxdepth 2 -name 'pgpass.*' -print -quit)" ]
[ "$(postgres_query "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$unrelated_application'")" = 1 ]
postgres_query "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$unrelated_application'" >/dev/null
wait_for_query_value \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$unrelated_application'" 0 \
  unrelated-restore-backend-cleanup
if grep -Fq -f "$secret_directory/postgres_password" "$intent_log" || \
   grep -Fq 'hostile-password-marker' "$intent_log"; then
  printf '%s\n' 'PostgreSQL password leaked into interrupted restore output.' >&2
  exit 1
fi
"${compose[@]}" exec -T -u 0 postgres rm -f -- "$intent_wrapper"
"${compose[@]}" exec -T -u 0 postgres test ! -e "$intent_wrapper"
sudo rm -rf -- "$intent_state_dir"
rm -f -- "$intent_pid_file" "$intent_launcher"
printf '%s\n' 'PASS: production-restore-intent-cleanup'

wrong_password_file="$runtime_root/avelren-wrong-password"
# Expansion belongs to the isolated shell inside the disposable PostgreSQL container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -ec \
  'umask 077; od -An -N32 -tx1 /dev/urandom | tr -d " \n" >"$1"' sh "$wrong_password_file"
wrong_password_status=0
wrong_operation_id="$(openssl rand -hex 16)"
wrong_control_dir="$runtime_root/operation.$wrong_operation_id"
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c \
  'umask 077; mkdir -m 700 -- "$1"; cat >"$1/runner.sh"; chmod 700 "$1/runner.sh"; date +%s >"$1/heartbeat"' \
  sh "$wrong_control_dir" <"$backup_helper"
"${compose[@]}" exec -T -u 0 \
  -e "AVELREN_BACKUP_OPERATION_ID=$wrong_operation_id" \
  -e AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 \
  -e AVELREN_POSTGRES_PASSWORD_FILE="$wrong_password_file" \
  postgres sh "$wrong_control_dir/runner.sh" avelren avelren "$wrong_control_dir" "$wrong_operation_id" \
  >/dev/null 2>>"$backup_log" || wrong_password_status=$?
"${compose[@]}" exec -T -u 0 postgres rm -f -- "$wrong_password_file"
[ "$wrong_password_status" -ne 0 ]
[ "$("${compose[@]}" exec -T postgres cat "$wrong_control_dir/status")" -ne 0 ]
[ -z "$("${compose[@]}" exec -T postgres find "$wrong_control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
"${compose[@]}" exec -T -u 0 postgres rm -rf -- "$wrong_control_dir"

[ "$(postgres_query 'SELECT current_database()')" = 'avelren' ]
[ "$(postgres_query 'SELECT current_user')" = 'avelren' ]

sudo env \
  "PATH=$PATH" \
  "COMPOSE_PROJECT_NAME=$project_name" \
  "AVELREN_TEST_REPOSITORY_ROOT=$repository_root" \
  "AVELREN_TEST_COMPOSE_FILE=$repository_root/docker-compose.yml" \
  "AVELREN_TEST_ENV_FILE=$environment_file" \
  "AVELREN_TEST_ROOT=$temporary_root" \
  "$repository_root/scripts/ci/postgres-backup-compose-cancel-test.sh"

[ "$(postgres_query "SELECT string_agg(version, ',' ORDER BY version) FROM avelren_schema_migrations")" = '001,002,003' ]
[ "$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'avelren_schema_migrations'")" = '1' ]
[ -z "$("${compose[@]}" ps -q caddy)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q postgres)" | grep -E 'HostIp|HostPort' || true)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q api)" | grep -E 'HostIp|HostPort' || true)" ]

printf '%s\n' 'Production Compose smoke test passed: clean PostgreSQL initialization, API health, and migrations 001-003.'
