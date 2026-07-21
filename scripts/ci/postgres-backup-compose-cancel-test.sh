#!/usr/bin/env bash
# The single-quoted programs below expand only in isolated container shells.
# shellcheck disable=SC2016
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'Compose cancellation test must run as root.' >&2; exit 1; }

repository_root="${AVELREN_TEST_REPOSITORY_ROOT:?}"
compose_file="${AVELREN_TEST_COMPOSE_FILE:?}"
environment_file="${AVELREN_TEST_ENV_FILE:?}"
project_name="${COMPOSE_PROJECT_NAME:?}"
test_root="${AVELREN_TEST_ROOT:?}/backup-cancel"
container="$(docker compose --project-name "$project_name" --env-file "$environment_file" \
  --file "$compose_file" ps -q postgres)"
[ -n "$container" ]

case "$test_root" in /tmp/avelren-compose-smoke.*/backup-cancel) ;; *) exit 90 ;; esac
rm -rf -- "$test_root"
install -d -o root -g root -m 700 "$test_root" "$test_root/bin" "$test_root/backup-tmp"

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM
  if [ -n "${sentinel_pid:-}" ]; then
    docker exec --user 0 "$container" sh -c 'kill -TERM "$1" 2>/dev/null || true' sh "$sentinel_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "${locker_pid:-}" ]; then
    docker exec --user 0 "$container" sh -c 'kill -TERM "$1" 2>/dev/null || true' sh "$locker_pid" >/dev/null 2>&1 || true
  fi
  [ -z "${sentinel_exec_pid:-}" ] || wait "$sentinel_exec_pid" 2>/dev/null || true
  [ -z "${locker_exec_pid:-}" ] || wait "$locker_exec_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
  exit "$exit_code"
}
trap cleanup EXIT

cat >"$test_root/bin/rclone" <<'EOF'
#!/bin/sh
case "$*" in *'size --json'*) printf '%s\n' '{"bytes":0}' ;; *) exit 0 ;; esac
EOF
cat >"$test_root/bin/restic" <<'EOF'
#!/bin/sh
case "$*" in *snapshots*) exit 0 ;; *) printf '%s\n' 'Unexpected Restic call during cancellation test.' >&2; exit 93 ;; esac
EOF
cat >"$test_root/bin/pg_restore" <<'EOF'
#!/bin/sh
exit 94
EOF
chmod 755 "$test_root/bin/"*

cat >"$test_root/signal-launch.py" <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
PY
chmod 755 "$test_root/signal-launch.py"

: >"$test_root/rclone.conf"
printf '%s' 'disposable-restic-password' >"$test_root/restic_password"
chmod 600 "$test_root/rclone.conf"
chmod 400 "$test_root/restic_password"
printf '%s\n' 'test' >"$test_root/backup.env"

compose=(docker compose --project-name "$project_name" --env-file "$environment_file" --file "$compose_file")
container_exec() { docker exec --user 0 "$container" "$@"; }
runtime_root=/run/avelren-backup
[ -n "$(docker inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$container")" ]
[ "$(container_exec stat -c '%u:%g:%a' "$runtime_root")" = '0:0:700' ]

# A lock keeps the real pg_dump child alive without changing the production helper.
"${compose[@]}" exec -T postgres psql --username avelren --dbname avelren --no-psqlrc \
  --set ON_ERROR_STOP=1 --command 'CREATE TABLE IF NOT EXISTS public.backup_cancel_fixture (id integer)' >/dev/null
docker exec --user postgres "$container" sh -c 'echo $$ > /tmp/avelren-backup-locker.pid; exec psql --username avelren --dbname avelren --no-psqlrc --set ON_ERROR_STOP=1 --command "BEGIN; LOCK TABLE public.backup_cancel_fixture IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120)"' &
locker_exec_pid=$!
for _ in $(seq 1 100); do
  locker_pid="$(container_exec sh -c 'cat /tmp/avelren-backup-locker.pid 2>/dev/null || true')"
  [ -n "$locker_pid" ] && break
  sleep 0.05
done
[ -n "${locker_pid:-}" ]
locker_start="$(container_exec awk '{print $22}' "/proc/$locker_pid/stat")"
sleep 1

container_exec sh -c 'echo $$ > /tmp/avelren-backup-sentinel.pid; exec sleep 120' &
sentinel_exec_pid=$!
for _ in $(seq 1 100); do
  sentinel_pid="$(container_exec sh -c 'cat /tmp/avelren-backup-sentinel.pid 2>/dev/null || true')"
  [ -n "$sentinel_pid" ] && break
  sleep 0.05
done
[ -n "${sentinel_pid:-}" ]
sentinel_start="$(container_exec awk '{print $22}' "/proc/$sentinel_pid/stat")"

identity_is_live() {
  identity="$1"
  pid="${identity%%:*}"
  start="${identity#*:}"
  current="$(container_exec sh -c 'if test -r "/proc/$1/stat"; then set -- $(cat "/proc/$1/stat"); printf "%s\n" "${22}"; fi' sh "$pid")"
  [ "$current" = "$start" ]
}

unrelated_is_live() {
  pid="$1"
  start="$2"
  current="$(container_exec sh -c 'if test -r "/proc/$1/stat"; then set -- $(cat "/proc/$1/stat"); printf "%s\n" "${22}"; fi' sh "$pid")"
  [ "$current" = "$start" ]
}

# A replaced/stale identity must fail closed even when its numeric PID and
# recorded start time point at a live unrelated process.
stale_operation_id=00000000000000000000000000000001
stale_control_dir="$runtime_root/operation.$stale_operation_id"
container_exec mkdir -m 700 -- "$stale_control_dir"
container_exec sh -c 'printf "%s:%s\n" "$1" "$2" >"$3/supervisor.identity"' \
  sh "$sentinel_pid" "$sentinel_start" "$stale_control_dir"
docker exec --interactive --user 0 "$container" sh -s -- \
  signal "$stale_control_dir" "$stale_operation_id" supervisor TERM \
  <"$repository_root/scripts/backup/postgres-backup-control.sh" >/dev/null
unrelated_is_live "$sentinel_pid" "$sentinel_start"
container_exec rm -rf -- "$stale_control_dir"

wait_for_outer() {
  pid="$1"
  timeout_seconds="$2"
  deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

find_control_dir() {
  container_exec sh -c 'for item in "$1"/operation.*; do [ -d "$item" ] || continue; printf "%s\n" "$item"; done' sh "$runtime_root" \
    | head -n 1
}

assert_no_secret() {
  log_file="$1"
  argv_file="$2"
  if grep -Fq -f "${environment_file%/*}/secrets/postgres_password" "$log_file" "$argv_file"; then
    printf '%s\n' 'PostgreSQL password leaked into logs or argv.' >&2
    exit 1
  fi
}

run_cancel_case() {
  signal="$1"
  expected_status="$2"
  dump_mode="${3:-normal}"
  case_name="$signal-$dump_mode"
  log_file="$test_root/$case_name.log"
  argv_file="$test_root/$case_name.argv"
  : >"$argv_file"

  env \
    PATH="$test_root/bin:$PATH" \
    COMPOSE_PROJECT_NAME="$project_name" \
    AVELREN_COMPOSE_FILE="$compose_file" \
    AVELREN_ENV_FILE="$environment_file" \
    AVELREN_BACKUP_TMP_ROOT="$test_root/backup-tmp" \
    AVELREN_BACKUP_LOCK_FILE="$test_root/backup.lock" \
    AVELREN_RCLONE_REMOTE=test-remote \
    AVELREN_RESTIC_PASSWORD_FILE="$test_root/restic_password" \
    AVELREN_RCLONE_CONFIG="$test_root/rclone.conf" \
    AVELREN_BACKUP_HEARTBEAT_TIMEOUT=10 \
    AVELREN_BACKUP_DOCKER_TIMEOUT=3 \
    AVELREN_BACKUP_TERMINATION_TIMEOUT=4 \
    "$test_root/signal-launch.py" "$repository_root/scripts/backup/postgres-backup.sh" >"$log_file" 2>&1 &
  outer_pid=$!

  control_dir=
  for _ in $(seq 1 200); do
    control_dir="$(find_control_dir)"
    if [ -n "$control_dir" ] && container_exec test -r "$control_dir/dump.identity" && \
       container_exec sh -c 'find "$1" -maxdepth 1 -name "pgpass.*" -type f | grep -q .' sh "$control_dir"; then
      break
    fi
    kill -0 "$outer_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -n "$control_dir" ]
  supervisor_identity="$(container_exec cat "$control_dir/supervisor.identity")"
  dump_identity="$(container_exec cat "$control_dir/dump.identity")"
  watchdog_identity="$(container_exec cat "$control_dir/watchdog.identity")"
  for identity in "$supervisor_identity" "$dump_identity" "$watchdog_identity"; do
    identity_is_live "$identity"
    pid="${identity%%:*}"
    {
      container_exec sh -c 'tr "\\000" " " <"/proc/$1/cmdline"' sh "$pid"
      printf '\n'
      container_exec sh -c 'tr "\\000" "\n" <"/proc/$1/environ"' sh "$pid"
    } >>"$argv_file"
  done

  if [ "$dump_mode" = stopped ]; then
    dump_pid="${dump_identity%%:*}"
    container_exec kill -STOP "$dump_pid"
    [ "$(container_exec awk '{print $3}' "/proc/$dump_pid/stat")" = T ]
  fi

  kill -s "$signal" "$outer_pid"
  wait_for_outer "$outer_pid" 20 || { printf '%s\n' "Outer backup ignored $signal." >&2; exit 1; }
  actual_status=0
  wait "$outer_pid" || actual_status=$?
  [ "$actual_status" -eq "$expected_status" ]

  for identity in "$supervisor_identity" "$dump_identity" "$watchdog_identity"; do
    if identity_is_live "$identity"; then
      printf '%s\n' "Scoped backup process survived $signal." >&2
      exit 1
    fi
  done
  if container_exec test -e "$control_dir"; then exit 1; fi
  [ -z "$(container_exec find "$runtime_root" -maxdepth 2 -name 'pgpass.*' -print -quit)" ]
  unrelated_is_live "$sentinel_pid" "$sentinel_start"
  unrelated_is_live "$locker_pid" "$locker_start"
  container_exec pg_isready --username avelren --dbname avelren >/dev/null
  assert_no_secret "$log_file" "$argv_file"
  [ -z "$(find "$test_root/backup-tmp" -mindepth 1 -print -quit)" ]
}

run_cancel_case INT 130
run_cancel_case TERM 143
run_cancel_case TERM 143 stopped

# The old attached implementation is retained only as a negative mutation: its
# outer shell can exit while docker compose exec and the inner dump remain alive.
legacy_dir="$test_root/legacy"
install -d -m 700 "$legacy_dir"
legacy_ref=
while read -r candidate; do
  if git -c "safe.directory=$repository_root" -C "$repository_root" show "$candidate:scripts/backup/postgres-backup.sh" 2>/dev/null \
      | grep -F '"${compose[@]}" exec -T -u 0 postgres sh -s --' >/dev/null && \
     git -c "safe.directory=$repository_root" -C "$repository_root" show "$candidate:scripts/backup/postgres-tcp-dump.sh" 2>/dev/null \
      | grep -F 'PGPASSFILE=' >/dev/null; then
    legacy_ref="$candidate"
    break
  fi
done < <(git -c "safe.directory=$repository_root" -C "$repository_root" rev-list HEAD)
[ -n "$legacy_ref" ]
git -c "safe.directory=$repository_root" -C "$repository_root" show "$legacy_ref:scripts/backup/postgres-backup.sh" >"$legacy_dir/postgres-backup.sh"
git -c "safe.directory=$repository_root" -C "$repository_root" show "$legacy_ref:scripts/backup/postgres-tcp-dump.sh" >"$legacy_dir/postgres-tcp-dump.sh"
cp "$repository_root/scripts/backup/restic-password-file.sh" "$repository_root/scripts/backup/restic-repository.sh" "$legacy_dir/"
chmod 700 "$legacy_dir/"*.sh
grep -Fq '"${compose[@]}" exec -T -u 0 postgres sh -s --' "$legacy_dir/postgres-backup.sh"

legacy_log="$test_root/legacy.log"
env \
  PATH="$test_root/bin:$PATH" \
  COMPOSE_PROJECT_NAME="$project_name" \
  AVELREN_COMPOSE_FILE="$compose_file" \
  AVELREN_ENV_FILE="$environment_file" \
  AVELREN_BACKUP_TMP_ROOT="$test_root/backup-tmp" \
  AVELREN_BACKUP_LOCK_FILE="$test_root/legacy.lock" \
  AVELREN_RCLONE_REMOTE=test-remote \
  AVELREN_RESTIC_PASSWORD_FILE="$test_root/restic_password" \
  AVELREN_RCLONE_CONFIG="$test_root/rclone.conf" \
  "$test_root/signal-launch.py" "$legacy_dir/postgres-backup.sh" >"$legacy_log" 2>&1 &
legacy_outer_pid=$!
legacy_pgpass=
for _ in $(seq 1 200); do
  legacy_pgpass="$(container_exec sh -c 'find /tmp -maxdepth 1 -name "avelren-pgpass.*" -type f -print -quit')"
  [ -n "$legacy_pgpass" ] && break
  kill -0 "$legacy_outer_pid" 2>/dev/null || break
  sleep 0.05
done
[ -n "$legacy_pgpass" ]
legacy_dump_pid="$(container_exec sh -c '
  for environment in /proc/[0-9]*/environ; do
    [ -r "$environment" ] || continue
    if tr "\000" "\n" <"$environment" | grep -Fqx "PGPASSFILE=$1"; then
      pid="${environment#/proc/}"; printf "%s\n" "${pid%/environ}"; exit 0
    fi
  done
' sh "$legacy_pgpass")"
[ -n "$legacy_dump_pid" ]
legacy_dump_start="$(container_exec awk '{print $22}' "/proc/$legacy_dump_pid/stat")"
legacy_supervisor_pid="$(container_exec awk '{print $4}' "/proc/$legacy_dump_pid/stat")"
legacy_supervisor_start="$(container_exec awk '{print $22}' "/proc/$legacy_supervisor_pid/stat")"

kill -TERM "$legacy_outer_pid"
legacy_outer_stopped=0
wait_for_outer "$legacy_outer_pid" 5 && legacy_outer_stopped=1
if [ "$legacy_outer_stopped" -eq 1 ]; then wait "$legacy_outer_pid" || true; fi
legacy_reason=
if identity_is_live "$legacy_dump_pid:$legacy_dump_start"; then
  legacy_reason=inner-process-survived
elif container_exec test -e "$legacy_pgpass"; then
  legacy_reason=credential-remained-in-container
fi
[ -n "$legacy_reason" ] || {
  printf '%s\n' 'Legacy attached mutation unexpectedly satisfied the cancellation contract.' >&2
  exit 1
}
printf 'Legacy attached mutation rejected: %s.\n' "$legacy_reason"
assert_no_secret "$legacy_log" /dev/null

# Reap only the exact legacy helper/dump identities captured above.
container_exec sh -c '
  pid="$1"; expected="$2"
  current="$(if test -r "/proc/$pid/stat"; then set -- $(cat "/proc/$pid/stat"); printf "%s\n" "${22}"; fi)"
  [ "$current" != "$expected" ] || kill -TERM "$pid" 2>/dev/null || true
' sh "$legacy_dump_pid" "$legacy_dump_start"
container_exec sh -c '
  pid="$1"; expected="$2"
  current="$(if test -r "/proc/$pid/stat"; then set -- $(cat "/proc/$pid/stat"); printf "%s\n" "${22}"; fi)"
  [ "$current" != "$expected" ] || kill -TERM "$pid" 2>/dev/null || true
' sh "$legacy_supervisor_pid" "$legacy_supervisor_start"
kill -TERM "$legacy_outer_pid" 2>/dev/null || true
wait "$legacy_outer_pid" 2>/dev/null || true
for _ in $(seq 1 100); do container_exec test -e "$legacy_pgpass" || break; sleep 0.05; done
container_exec test ! -e "$legacy_pgpass"

printf '%s\n' 'End-to-end Compose cancellation tests passed for SIGINT, SIGTERM, and TERM-resistant dump KILL escalation; unrelated processes survived.'
printf '%s\n' 'Legacy attached docker compose exec mutation was rejected by the same cancellation contract.'
