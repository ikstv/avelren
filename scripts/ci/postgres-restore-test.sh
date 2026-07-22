#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
drill="$root/scripts/backup/postgres-restore-drill.sh"
helper="$root/scripts/backup/postgres-tcp-restore.sh"
disposable_base="${RUNNER_TEMP:-/tmp}"
test_root=
capture_root=
root_runner=()
active_launch_pid=
active_outer_pid=
outer_pid_file=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_status() {
  local expected="$1" actual="$2" assertion="$3"
  [ "$actual" -eq "$expected" ] || fail "$assertion (expected status $expected, got $actual)"
}

assert_nonzero_not_timeout() {
  local actual="$1" assertion="$2"
  [ "$actual" -ne 0 ] || fail "$assertion (unexpected success)"
  if [ "$actual" -eq 124 ] || [ "$actual" -eq 137 ]; then
    fail "$assertion (bounded timeout expired)"
  fi
}

assert_contains() {
  local path="$1" marker="$2" assertion="$3"
  grep -Fq -- "$marker" "$path" || fail "$assertion (marker absent)"
}

assert_not_contains() {
  local path="$1" marker="$2" assertion="$3"
  if grep -Fq -- "$marker" "$path" 2>/dev/null; then
    fail "$assertion (forbidden marker present)"
  fi
}

safe_disposable_directory() {
  local path="$1"
  case "$path" in
    "$disposable_base"/avelren-restore-test.*|"$disposable_base"/avelren-restore-capture.*)
      [ -n "$path" ] && [ "$path" != / ] && [ "$path" != "$HOME" ] &&
        [ -d "$path" ] && [ ! -L "$path" ]
      ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if ! [[ "$active_outer_pid" =~ ^[0-9]+$ ]] && [ -n "$outer_pid_file" ] && [ -s "$outer_pid_file" ]; then
    active_outer_pid="$(cat "$outer_pid_file" 2>/dev/null || true)"
  fi
  if [[ "$active_outer_pid" =~ ^[0-9]+$ ]]; then
    "${root_runner[@]}" kill -TERM -- "-$active_outer_pid" >/dev/null 2>&1 || true
    "${root_runner[@]}" kill -KILL -- "-$active_outer_pid" >/dev/null 2>&1 || true
  elif [[ "$active_launch_pid" =~ ^[0-9]+$ ]]; then
    kill -TERM "$active_launch_pid" >/dev/null 2>&1 || true
    kill -KILL "$active_launch_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$active_launch_pid" =~ ^[0-9]+$ ]]; then
    wait "$active_launch_pid" 2>/dev/null || true
  fi
  if [ -n "$test_root" ] && safe_disposable_directory "$test_root"; then
    "${root_runner[@]}" rm -rf -- "$test_root"
  fi
  if [ -n "$capture_root" ] && safe_disposable_directory "$capture_root"; then
    "${root_runner[@]}" rm -rf -- "$capture_root"
  fi
  exit "$status"
}
trap cleanup EXIT

[ "$(uname -s)" = Linux ] || fail 'restore safety tests require Linux'
[ -x "$drill" ] || fail 'restore drill is not executable'
[ -x "$helper" ] || fail 'restore TCP helper is not executable'
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || fail 'sudo is required for root restore tests'
  sudo -n true >/dev/null 2>&1 || fail 'passwordless sudo is required for root restore tests'
  root_runner=(sudo -n)
fi

test_root="$(mktemp -d "$disposable_base/avelren-restore-test.XXXXXX")"
capture_root="$(mktemp -d "$disposable_base/avelren-restore-capture.XXXXXX")"
chmod 700 "$test_root" "$capture_root"
fake_bin="$test_root/bin"
production_tmp="$test_root/production-tmp"
production_lock="$test_root/production-lock"
state_root="$capture_root/state"
fixture_root="$capture_root/fixtures"
log_root="$capture_root/logs"
production_log_root="$test_root/production-log"
mkdir -m 700 "$fake_bin" "$production_tmp" "$production_lock" "$state_root" "$fixture_root" "$log_root" "$production_log_root"
"${root_runner[@]}" chown root:root "$production_log_root"

compose_file="$test_root/compose.yml"
env_file="$test_root/environment"
rclone_config="$test_root/rclone.conf"
password_file="$test_root/restic-password"
printf '%s\n' 'services: {}' >"$compose_file"
: >"$env_file"
: >"$rclone_config"
printf '%s' 'restore-fixture-password' >"$password_file"
chmod 600 "$compose_file" "$env_file" "$rclone_config"
chmod 400 "$password_file"
"${root_runner[@]}" chown root:root "$rclone_config" "$password_file"

docker_calls="$state_root/docker-calls"
route_identity="$state_root/route-identity"
database_state="$state_root/database-state"
restored_state="$state_root/restored-state"
restic_proof="$state_root/restic-proof"
restore_target="$state_root/restore-target"
host_pg_restore_marker="$state_root/host-pg-restore"
restic_ready="$state_root/restic-ready"
setup_directory_ready="$state_root/setup-directory-ready"
setup_directory_release="$state_root/setup-directory-release"
create_action_ready="$state_root/create-action-ready"
create_action_release="$state_root/create-action-release"
outer_pid_file="$state_root/outer-pid"
route_status_capture="$state_root/route-status-final"
sentinel="$fixture_root/sentinel"
for capture in "$docker_calls" "$route_identity" "$database_state" "$restored_state" \
  "$restic_proof" "$restore_target" "$host_pg_restore_marker" "$restic_ready" "$create_action_ready" "$outer_pid_file" \
  "$setup_directory_ready" "$route_status_capture"; do
  : >"$capture"
  chmod 600 "$capture"
done
printf '%s\n' 'sentinel-unchanged' >"$sentinel"
chmod 600 "$sentinel"

cat >"$fake_bin/date" <<'FAKE_DATE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$*" = '-u +%Y%m%dT%H%M%SZ' ]; then
  printf '%s\n' 20000101T000000Z
else
  exec /bin/date "$@"
fi
FAKE_DATE

cat >"$fake_bin/pg_restore" <<'FAKE_HOST_PG_RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' invoked >"$FAKE_HOST_PG_RESTORE_MARKER"
printf '%s\n' 'Host pg_restore invocation is forbidden.' >&2
exit 97
FAKE_HOST_PG_RESTORE

cat >"$fake_bin/rm" <<'FAKE_RM'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${!#}"
case "$target" in
  "$FAKE_EXPECTED_TMP_ROOT"/avelren-restore.*)
    if [ "${target%/*}" = "$FAKE_EXPECTED_TMP_ROOT" ] &&
       [ -f "$target/.route-status" ] && [ ! -L "$target/.route-status" ]; then
      tail -n 1 -- "$target/.route-status" >"$FAKE_ROUTE_STATUS_CAPTURE"
    fi
    ;;
esac
exec /usr/bin/rm "$@"
FAKE_RM

cat >"$fake_bin/mkdir" <<'FAKE_MKDIR'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${!#}"
if [ "${FAKE_MKDIR_SETUP_BARRIER:-0}" = 1 ] && \
   [ "${target%/*}" = "$FAKE_EXPECTED_TMP_ROOT" ]; then
  case "${target##*/}" in
    avelren-restore.*) ;;
    *) exec /usr/bin/mkdir "$@" ;;
  esac
  /usr/bin/mkdir "$@"
  printf '%s\n' ready >"$FAKE_SETUP_DIRECTORY_READY"
  IFS= read -r release <"$FAKE_SETUP_DIRECTORY_RELEASE"
  [ "$release" = release ] || exit 76
  exit 0
fi
exec /usr/bin/mkdir "$@"
FAKE_MKDIR

cat >"$fake_bin/restic" <<'FAKE_RESTIC'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "${RESTIC_REPOSITORY:-}" = 'rclone:test-remote:Avelren Backups/restic' ] || exit 61
[ "${RCLONE_CONFIG:-}" = "$FAKE_EXPECTED_RCLONE_CONFIG" ] || exit 61
[ "${1:-}" = restore ] || exit 62
[ "${2:-}" = latest ] || exit 62
shift 2

target=
tag=
password_file=
tag_count=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || exit 62
      tag="$2"
      tag_count=$((tag_count + 1))
      shift 2
      ;;
    --password-file)
      [ "$#" -ge 2 ] || exit 62
      password_file="$2"
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || exit 62
      target="$2"
      shift 2
      ;;
    *) exit 62 ;;
  esac
done
[ "$tag_count" -eq 1 ] && [ "$tag" = postgres ] || exit 63
[ "$password_file" = "$FAKE_EXPECTED_PASSWORD_FILE" ] || exit 63
[ -n "$target" ] && [ -d "$target" ] && [ ! -L "$target" ] || exit 63
case "$target" in "$FAKE_EXPECTED_TMP_ROOT"/*) ;; *) exit 63 ;; esac

printf '%s\n' 'selector=latest tag=postgres target=present' >"$FAKE_RESTIC_PROOF"
printf '%s\n' "$target" >"$FAKE_RESTORE_TARGET"
if [ "${FAKE_RESTIC_BARRIER:-0}" = 1 ]; then
  printf '%s\n' ready >"$FAKE_RESTIC_READY"
  IFS= read -r release <"$FAKE_RESTIC_RELEASE"
  [ "$release" = release ] || exit 64
fi
if [ "${FAKE_RESTIC_FAIL:-0}" = 1 ]; then exit 65; fi

payload="$target/var/lib/avelren-backup/tmp"
mkdir -p -- "$payload"
umask 077
case "${FAKE_RESTORE_LAYOUT:-one}" in
  one)
    printf '%s\n' fake-custom-format-dump >"$payload/avelren-20000101T000000Z.dump"
    chmod 600 "$payload/avelren-20000101T000000Z.dump"
    ;;
  zero) ;;
  multiple)
    printf '%s\n' fake-custom-format-dump >"$payload/avelren-20000101T000000Z.dump"
    printf '%s\n' second-custom-format-dump >"$payload/avelren-20000101T000001Z.dump"
    chmod 600 "$payload/avelren-20000101T000000Z.dump" "$payload/avelren-20000101T000001Z.dump"
    ;;
  symlink)
    ln -s -- "$FAKE_RESTORE_SENTINEL" "$payload/avelren-20000101T000000Z.dump"
    ;;
  fifo)
    mkfifo -- "$payload/avelren-20000101T000000Z.dump"
    ;;
  directory)
    mkdir -- "$payload/avelren-20000101T000000Z.dump"
    ;;
  wrong-name)
    printf '%s\n' fake-custom-format-dump >"$payload/unscoped.dump"
    chmod 600 "$payload/unscoped.dump"
    ;;
  hardlink)
    ln -- "$FAKE_RESTORE_SENTINEL" "$payload/avelren-20000101T000000Z.dump"
    ;;
  *) exit 66 ;;
esac
FAKE_RESTIC

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

container_id="${FAKE_CONTAINER_ID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
if [ "${1:-}" = compose ]; then
  shift
  while [ "$#" -gt 0 ] && [ "$1" != ps ]; do shift; done
  [ "$#" -eq 3 ] && [ "$1" = ps ] && [ "$2" = -q ] && [ "$3" = postgres ] || exit 67
  printf '%s\n' "$container_id"
  exit 0
fi

if [ "${1:-}" = inspect ]; then
  [ "$#" -eq 4 ] && [ "$2" = -f ] || exit 67
  case "$3" in
    '{{.Id}}') printf '%s\n' "$container_id" ;;
    '{{.State.Health.Status}}') printf '%s\n' healthy ;;
    '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}')
      printf '%s\n' 'rw,noexec,nosuid,nodev,mode=0700,uid=0,gid=0'
      ;;
    *) exit 67 ;;
  esac
  [ "$4" = "$container_id" ] || exit 67
  exit 0
fi

[ "${1:-}" = exec ] || exit 67
shift
[ "${1:-}" = --interactive ] || exit 67
shift
[ "${1:-}" = --user ] && [ "${2:-}" = 0 ] || exit 67
shift 2
[ "${1:-}" = "$container_id" ] || exit 67
case "$1" in ''|*[!a-f0-9]*) exit 67 ;; esac
[ "${#1}" -eq 64 ] || exit 67
shift

if [ "$#" -eq 4 ] && [ "$1" = sh ] && [ "$2" = -s ] && [ "$3" = -- ] &&
   [ "$4" = /run/avelren-backup ]; then
  cat >/dev/null
  exit 0
fi

[ "$#" -eq 16 ] || exit 68
[ "$1" = env ] && [ "$2" = -i ] || exit 68
case "$3" in PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin) ;; *) exit 68 ;; esac
case "$4" in AVELREN_RESTORE_OPERATION_ID=*) operation_id="${4#*=}" ;; *) exit 68 ;; esac
[ "$5" = sh ] && [ "$6" = -eu ] && [ "$7" = -c ] || exit 68
program="$8"
[ "$9" = sh ] || exit 68
action="${10}"
pg_user="${11}"
production_db="${12}"
temporary_db="${13}"
restore_token="${14}"
expected_cluster="${15}"
expected_oid="${16}"

for variable in PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGSERVICE PGSERVICEFILE PGPASSFILE PGPASSWORD PGOPTIONS; do
  if [ -n "${!variable+x}" ]; then exit 69; fi
done
case "$action" in create|restore|validate|cleanup|recover) ;; *) exit 69 ;; esac
[ "$pg_user" = avelren ] && [ "$production_db" = avelren ] || exit 69
case "$restore_token" in ''|*[!a-f0-9]*) exit 69 ;; esac
[ "${#restore_token}" -eq 32 ] || exit 69
[ "$operation_id" = "$restore_token" ] || exit 69
[ "$temporary_db" = "avelren_restore_$restore_token" ] || exit 69
if [ "$action" = recover ]; then
  case "$expected_cluster:$expected_oid" in *[!0-9:]*) exit 69 ;; esac
  [ -n "$expected_cluster" ] && [ -n "$expected_oid" ] || {
    [ -z "$expected_cluster" ] && [ -z "$expected_oid" ] || exit 69
  }
else
  [ -z "$expected_cluster" ] && [ -z "$expected_oid" ] || exit 69
fi
case "$program" in
  *'env -i PATH='*'PGPASSFILE='*'--host 127.0.0.1'*'--port 5432'*'--no-password'*) ;;
  *) exit 69 ;;
esac
case "$program" in
  *'create_client_launching=1'*'create_client_pid=$!'*'create_client_launching=0'*'pending_signal_status'*'create_client_identity_published=1'*) ;;
  *) exit 69 ;;
esac
case "$program" in *'PGAPPNAME="$create_application_name"'*) ;; *) exit 69 ;; esac
case "$program" in *'pg_stat_activity'*) ;; *) exit 69 ;; esac
case "$program" in *'pg_terminate_backend'*) ;; *) exit 69 ;; esac
case "$program" in *'stop_create_backends'*) ;; *) exit 69 ;; esac

printf '%s\n' "$action" >>"$FAKE_DOCKER_CALLS"
current="$(cat "$FAKE_DATABASE_STATE")"
cluster_id=7543210987654321
database_oid=16384
expected="$temporary_db|$restore_token|$cluster_id|$database_oid"
case "$action" in
  create)
    [ -z "$current" ] || exit 70
    if [ "${FAKE_DOCKER_FAIL_ACTION:-}" = create-before ]; then exit 70; fi
    printf '%s\n' "$expected" >"$FAKE_DATABASE_STATE"
    printf 'database=%s token-length=32 container-length=64 cluster-id=%s database-oid=%s\n' \
      "$temporary_db" "$cluster_id" "$database_oid" >"$FAKE_ROUTE_IDENTITY"
    if [ "${FAKE_DOCKER_CREATE_BARRIER:-0}" = 1 ]; then
      printf '%s\n' ready >"$FAKE_DOCKER_CREATE_READY"
      IFS= read -r release <"$FAKE_DOCKER_CREATE_RELEASE"
      [ "$release" = release ] || exit 71
    fi
    if [ "${FAKE_DOCKER_FAIL_ACTION:-}" = create-after ]; then
      exit 71
    fi
    printf 'database-owned:%s:%s\n' "$cluster_id" "$database_oid"
    ;;
  restore)
    [ "$current" = "$expected" ] || exit 71
    payload="$(cat)"
    [ "$payload" = fake-custom-format-dump ] || exit 71
    if [ "${FAKE_DOCKER_FAIL_ACTION:-}" = restore ]; then exit 72; fi
    printf '%s\n' "$expected" >"$FAKE_RESTORED_STATE"
    ;;
  validate)
    [ "$current" = "$expected" ] || exit 72
    [ "$(cat "$FAKE_RESTORED_STATE")" = "$expected" ] || exit 72
    if [ "${FAKE_DOCKER_FAIL_ACTION:-}" = validate ]; then exit 73; fi
    ;;
  cleanup|recover)
    if [ -z "$current" ]; then exit 0; fi
    [ "$current" = "$expected" ] || exit 75
    if [ "$action" = recover ] && [ -n "$expected_cluster" ]; then
      [ "$expected_cluster:$expected_oid" = "$cluster_id:$database_oid" ] || exit 75
    fi
    if [ "$action" = cleanup ] && [ "${FAKE_DOCKER_CLEANUP_STATE_LOSS:-0}" = 1 ]; then exit 76; fi
    if [ "$action" = recover ] && [ "${FAKE_DOCKER_RECOVER_OID_MISMATCH:-0}" = 1 ]; then exit 75; fi
    if [ "${FAKE_DOCKER_FAIL_ACTION:-}" = cleanup ]; then exit 74; fi
    if [ "${FAKE_DOCKER_IDENTITY_MISMATCH:-0}" = 1 ]; then exit 75; fi
    : >"$FAKE_DATABASE_STATE"
    : >"$FAKE_RESTORED_STATE"
    ;;
esac
FAKE_DOCKER

cat >"$test_root/signal-launch.py" <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys

pid_file = os.environ["AVELREN_TEST_OUTER_PID_FILE"]
descriptor = os.open(pid_file, os.O_WRONLY | os.O_TRUNC)
with os.fdopen(descriptor, "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
PY
chmod 755 "$fake_bin"/* "$test_root/signal-launch.py"

common_env=(
  "PATH=$fake_bin:$PATH"
  "AVELREN_ENV_FILE=$env_file"
  "AVELREN_COMPOSE_FILE=$compose_file"
  "AVELREN_BACKUP_TMP_ROOT=$production_tmp"
  "AVELREN_BACKUP_LOCK_FILE=$production_lock/restore.lock"
  'AVELREN_RCLONE_REMOTE=test-remote'
  "AVELREN_RESTIC_PASSWORD_FILE=$password_file"
  "AVELREN_RCLONE_CONFIG=$rclone_config"
  "AVELREN_RESTORE_LOG_ROOT=$production_log_root"
  "FAKE_EXPECTED_RCLONE_CONFIG=$rclone_config"
  "FAKE_EXPECTED_PASSWORD_FILE=$password_file"
  "FAKE_EXPECTED_TMP_ROOT=$production_tmp"
  "FAKE_RESTIC_PROOF=$restic_proof"
  "FAKE_RESTORE_TARGET=$restore_target"
  "FAKE_RESTORE_SENTINEL=$sentinel"
  "FAKE_RESTIC_READY=$restic_ready"
  "FAKE_SETUP_DIRECTORY_READY=$setup_directory_ready"
  "FAKE_SETUP_DIRECTORY_RELEASE=$setup_directory_release"
  "FAKE_DOCKER_CREATE_READY=$create_action_ready"
  "FAKE_DOCKER_CREATE_RELEASE=$create_action_release"
  "FAKE_HOST_PG_RESTORE_MARKER=$host_pg_restore_marker"
  "FAKE_DOCKER_CALLS=$docker_calls"
  "FAKE_ROUTE_IDENTITY=$route_identity"
  "FAKE_DATABASE_STATE=$database_state"
  "FAKE_RESTORED_STATE=$restored_state"
  "FAKE_ROUTE_STATUS_CAPTURE=$route_status_capture"
)
hostile_pg_env=(
  'PGHOST=hostile.example.invalid'
  'PGHOSTADDR=192.0.2.10'
  'PGPORT=1'
  'PGUSER=hostile-user'
  'PGDATABASE=hostile-database'
  'PGSERVICE=hostile-service'
  "PGSERVICEFILE=$fixture_root/hostile-service.conf"
  "PGPASSFILE=$fixture_root/hostile-pgpass"
  'PGPASSWORD=hostile-password-marker'
  'PGOPTIONS=-c statement_timeout=1'
)

reset_case() {
  local path output
  for path in "$docker_calls" "$route_identity" "$database_state" "$restored_state" \
    "$restic_proof" "$restore_target" "$host_pg_restore_marker" "$restic_ready" "$create_action_ready" "$outer_pid_file" \
    "$setup_directory_ready" "$route_status_capture"; do
    : >"$path"
  done
  rm -f -- "$create_action_release" "$setup_directory_release"
  printf '%s\n' 'sentinel-unchanged' >"$sentinel"
  output="$("${root_runner[@]}" find "$production_tmp" -mindepth 1 -print -quit)"
  [ -z "$output" ] || fail 'previous restore case left temporary state'
  case "$production_log_root" in "$test_root"/production-log) ;; *) fail 'unsafe production log test path' ;; esac
  "${root_runner[@]}" rm -rf -- "$production_log_root"
  "${root_runner[@]}" install -d -o root -g root -m 700 "$production_log_root"
}

run_restore() {
  local layout="$1" log="$2" status=0
  shift 2
  if "${root_runner[@]}" env "${common_env[@]}" "${hostile_pg_env[@]}" \
      "FAKE_RESTORE_LAYOUT=$layout" "$@" \
      timeout --signal=TERM --kill-after=3s 15s "$drill" >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$status"
}

assert_no_secret() {
  local log="$1" assertion="$2" status=0
  assert_not_contains "$log" 'restore-fixture-password' "$assertion-restic-secret"
  assert_not_contains "$log" 'hostile-password-marker' "$assertion-hostile-secret"
  if "${root_runner[@]}" grep -R -Fq -- 'restore-fixture-password' "$production_log_root"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "$assertion-restic-secret-internal"
  if "${root_runner[@]}" grep -R -Fq -- 'hostile-password-marker' "$production_log_root"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "$assertion-hostile-secret-internal"
}

assert_internal_log_contains() {
  local marker="$1" assertion="$2" status=0
  if "${root_runner[@]}" grep -R -Fq -- "$marker" "$production_log_root"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || fail "$assertion (marker absent from internal log)"
}

assert_runtime_empty() {
  local assertion="$1" output
  output="$("${root_runner[@]}" find "$production_tmp" -mindepth 1 -print -quit)"
  [ -z "$output" ] || fail "$assertion (temporary restore state remains)"
  [ ! -s "$database_state" ] || fail "$assertion (fake database remains)"
}

assert_host_restore_absent() {
  [ ! -s "$host_pg_restore_marker" ] || fail "$1 (host pg_restore was invoked)"
}

assert_action_sequence() {
  local expected="$1" assertion="$2" actual
  actual="$(paste -sd, "$docker_calls")"
  [ "$actual" = "$expected" ] || fail "$assertion (expected $expected, got ${actual:-none})"
}

read_restore_root() {
  local target
  target="$(cat "$restore_target")"
  case "$target" in "$production_tmp"/*) ;; *) return 1 ;; esac
  case "${target##*/}" in payload) printf '%s\n' "${target%/*}" ;; *) printf '%s\n' "$target" ;; esac
}

remove_preserved_restore_root() {
  local assertion="$1" path
  path="$(read_restore_root)" || fail "$assertion (unsafe captured restore path)"
  case "$path" in "$production_tmp"/avelren-restore.*) ;; *) fail "$assertion (unexpected restore path)" ;; esac
  "${root_runner[@]}" rm -rf -- "$path"
}

reset_case
success_log="$log_root/restore-success.log"
success_status="$(run_restore one "$success_log")"
assert_status 0 "$success_status" restore-success-status
assert_contains "$success_log" 'Restore drill passed for a controlled temporary database; production database was not used.' restore-success-diagnostic
assert_contains "$restic_proof" 'selector=latest tag=postgres target=present' restore-tagged-snapshot
assert_action_sequence 'create,restore,validate,cleanup' restore-success-actions
assert_contains "$route_identity" 'token-length=32 container-length=64' restore-immutable-identities
assert_contains "$route_status_capture" 'cleanup-verified' restore-success-route-status
assert_host_restore_absent restore-success-host-route
assert_runtime_empty restore-success-cleanup
assert_no_secret "$success_log" restore-success-redaction
assert_not_contains "$success_log" 'Temporary restore database cleanup failed' restore-success-cleanup-diagnostic
pass restore-route-success

reset_case
mutable_log="$log_root/restore-mutable-container.log"
mutable_status="$(run_restore one "$mutable_log" FAKE_CONTAINER_ID=fake-postgres)"
assert_nonzero_not_timeout "$mutable_status" restore-mutable-container-status
[ ! -s "$docker_calls" ] || fail 'mutable container identity reached a restore action'
assert_host_restore_absent restore-mutable-container-host-route
assert_runtime_empty restore-mutable-container-cleanup
assert_no_secret "$mutable_log" restore-mutable-container-redaction
pass restore-mutable-container-rejected

for layout in zero multiple symlink fifo directory wrong-name hardlink; do
  reset_case
  layout_log="$log_root/restore-$layout.log"
  layout_status="$(run_restore "$layout" "$layout_log")"
  assert_nonzero_not_timeout "$layout_status" "restore-$layout-status"
  [ ! -s "$docker_calls" ] || fail "restore-$layout reached a database action"
  assert_host_restore_absent "restore-$layout-host-route"
  assert_runtime_empty "restore-$layout-cleanup"
  assert_no_secret "$layout_log" "restore-$layout-redaction"
  case "$layout" in
    zero) assert_contains "$layout_log" 'No PostgreSQL dump found in selected snapshot.' restore-zero-diagnostic ;;
    multiple) assert_contains "$layout_log" 'Selected PostgreSQL snapshot contains ambiguous dump artifacts.' restore-multiple-diagnostic ;;
    symlink|fifo|directory)
      assert_contains "$layout_log" 'Selected PostgreSQL dump artifact is unsafe.' "restore-$layout-diagnostic"
      ;;
    wrong-name) assert_contains "$layout_log" 'Selected PostgreSQL dump name is invalid.' restore-wrong-name-diagnostic ;;
    hardlink) assert_contains "$layout_log" 'Selected PostgreSQL dump artifact is unsafe.' restore-hardlink-diagnostic ;;
  esac
  [ "$(cat "$sentinel")" = sentinel-unchanged ] || fail "restore-$layout mutated the external sentinel"
  pass "restore-artifact-$layout-rejected"
done

reset_case
snapshot_failure_log="$log_root/restore-snapshot-failure.log"
snapshot_failure_status="$(run_restore one "$snapshot_failure_log" FAKE_RESTIC_FAIL=1)"
assert_status 65 "$snapshot_failure_status" restore-snapshot-failure-status
assert_contains "$snapshot_failure_log" 'PostgreSQL-scoped snapshot restore failed.' restore-snapshot-failure-diagnostic
[ ! -s "$docker_calls" ] || fail 'snapshot restore failure reached a database action'
assert_host_restore_absent restore-snapshot-failure-host-route
assert_runtime_empty restore-snapshot-failure-cleanup
assert_no_secret "$snapshot_failure_log" restore-snapshot-failure-redaction
pass restore-snapshot-failure-cleanup

reset_case
restore_failure_log="$log_root/restore-action-failure.log"
restore_failure_status="$(run_restore one "$restore_failure_log" FAKE_DOCKER_FAIL_ACTION=restore)"
assert_status 72 "$restore_failure_status" restore-action-failure-status
assert_contains "$restore_failure_log" 'Controlled PostgreSQL restore route failed.' restore-action-failure-diagnostic
assert_action_sequence 'create,restore,cleanup' restore-action-failure-actions
assert_contains "$route_status_capture" 'cleanup-verified' restore-action-failure-route-status
assert_host_restore_absent restore-action-failure-host-route
assert_runtime_empty restore-action-failure-cleanup
assert_no_secret "$restore_failure_log" restore-action-failure-redaction
pass restore-action-failure-cleanup

reset_case
validation_failure_log="$log_root/restore-validation-failure.log"
validation_failure_status="$(run_restore one "$validation_failure_log" FAKE_DOCKER_FAIL_ACTION=validate)"
assert_status 73 "$validation_failure_status" restore-validation-failure-status
assert_contains "$validation_failure_log" 'Controlled PostgreSQL restore route failed.' restore-validation-failure-diagnostic
assert_action_sequence 'create,restore,validate,cleanup' restore-validation-failure-actions
assert_contains "$route_status_capture" 'cleanup-verified' restore-validation-failure-route-status
assert_host_restore_absent restore-validation-failure-host-route
assert_runtime_empty restore-validation-failure-cleanup
assert_no_secret "$validation_failure_log" restore-validation-failure-redaction
pass restore-validation-failure-cleanup

reset_case
recovery_log="$log_root/restore-state-loss-recovery.log"
recovery_status="$(run_restore one "$recovery_log" FAKE_DOCKER_CLEANUP_STATE_LOSS=1)"
assert_status 0 "$recovery_status" restore-state-loss-recovery-status
assert_action_sequence 'create,restore,validate,cleanup,recover' restore-state-loss-recovery-actions
assert_contains "$route_status_capture" 'cleanup-verified' restore-state-loss-recovery-route-status
assert_host_restore_absent restore-state-loss-recovery-host-route
assert_runtime_empty restore-state-loss-recovery-cleanup
assert_no_secret "$recovery_log" restore-state-loss-recovery-redaction
pass restore-state-loss-recovery

for create_phase in create-before create-after; do
  reset_case
  create_log="$log_root/restore-$create_phase.log"
  create_status="$(run_restore one "$create_log" "FAKE_DOCKER_FAIL_ACTION=$create_phase")"
  assert_nonzero_not_timeout "$create_status" "restore-$create_phase-status"
  assert_action_sequence 'create,cleanup' "restore-$create_phase-actions"
  assert_runtime_empty "restore-$create_phase-cleanup"
  assert_no_secret "$create_log" "restore-$create_phase-redaction"
  pass "restore-$create_phase-cleanup"
done

run_preservation_case() {
  local label="$1" expected_status="$2" expected_actions="$3"
  shift 3
  local log="$log_root/$label.log" status restore_root route_status
  reset_case
  status="$(run_restore one "$log" "$@")"
  assert_status "$expected_status" "$status" "$label-status"
  assert_action_sequence "$expected_actions" "$label-actions"
  assert_internal_log_contains 'Temporary restore database cleanup failed; verified state was preserved.' "$label-diagnostic"
  assert_contains "$log" 'Restore payload was preserved because database cleanup was not verified.' \
    "$label-route-preservation-diagnostic"
  [ -s "$database_state" ] || fail "$label (database identity was not preserved)"
  restore_root="$(read_restore_root)" || fail "$label (unsafe captured restore path)"
  "${root_runner[@]}" test -d "$restore_root" || fail "$label (restore directory was not preserved)"
  route_status="$("${root_runner[@]}" tail -n 1 -- "$restore_root/.route-status")"
  [ "$route_status" = cleanup-unverified ] || fail "$label (route status was not cleanup-unverified)"
  [ ! -s "$route_status_capture" ] || fail "$label (preserved route was reported removed)"
  assert_no_secret "$log" "$label-redaction"
  remove_preserved_restore_root "$label-harness-cleanup"
  : >"$database_state"
  : >"$restored_state"
  assert_runtime_empty "$label-harness-cleanup"
  pass "$label"
}

run_preservation_case restore-cleanup-failure 1 'create,restore,validate,cleanup,cleanup' \
  FAKE_DOCKER_FAIL_ACTION=cleanup
run_preservation_case restore-database-identity-mismatch 1 'create,restore,validate,cleanup,cleanup' \
  FAKE_DOCKER_IDENTITY_MISMATCH=1
run_preservation_case restore-primary-status-preserved 72 'create,restore,cleanup' \
  FAKE_DOCKER_FAIL_ACTION=restore FAKE_DOCKER_IDENTITY_MISMATCH=1
run_preservation_case restore-recovery-identity-mismatch 1 \
  'create,restore,validate,cleanup,recover,cleanup,recover' \
  FAKE_DOCKER_CLEANUP_STATE_LOSS=1 FAKE_DOCKER_RECOVER_OID_MISMATCH=1

wait_for_marker() {
  local path="$1" process_id="$2" deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(cat "$path" 2>/dev/null || true)" = ready ] && return 0
    kill -0 "$process_id" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

wait_for_process_exit() {
  local process_id="$1" deadline=$((SECONDS + 15))
  while kill -0 "$process_id" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

run_setup_directory_signal_case() {
  local signal="$1" expected_status="$2" label="restore-directory-handoff-${1,,}"
  local log="$log_root/$label.log" launch_pid outer_pid restore_root status=0
  reset_case
  mkfifo -- "$setup_directory_release"
  "${root_runner[@]}" env "${common_env[@]}" "${hostile_pg_env[@]}" \
    FAKE_RESTORE_LAYOUT=one FAKE_MKDIR_SETUP_BARRIER=1 \
    AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" \
    setsid --wait "$test_root/signal-launch.py" "$drill" >"$log" 2>&1 &
  launch_pid=$!
  active_launch_pid="$launch_pid"
  wait_for_marker "$setup_directory_ready" "$launch_pid" || \
    fail "$label (directory-creation barrier was not reached)"
  outer_pid="$(cat "$outer_pid_file")"
  case "$outer_pid" in ''|*[!0-9]*) fail "$label (invalid outer pid)" ;; esac
  active_outer_pid="$outer_pid"
  restore_root="$("${root_runner[@]}" find "$production_tmp" -mindepth 1 -maxdepth 1 \
    -type d -name 'avelren-restore.*' -print -quit)"
  case "$restore_root" in "$production_tmp"/avelren-restore.*) ;; *) fail "$label (created directory absent)" ;; esac
  "${root_runner[@]}" test ! -e "$restore_root/.restore-owner" || \
    fail "$label (ownership was published before the barrier)"
  "${root_runner[@]}" kill -s "$signal" -- "-$outer_pid"
  # The wrapper inherits the production creation child's ignored dispositions;
  # without that isolation this group signal kills it after directory creation.
  # shellcheck disable=SC2016
  timeout 3 bash -c 'printf "%s\n" release >"$1"' sh "$setup_directory_release" || \
    fail "$label (directory-creation barrier release failed)"
  wait_for_process_exit "$launch_pid" || fail "$label (process did not exit)"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  active_launch_pid=
  active_outer_pid=
  assert_status "$expected_status" "$status" "$label-status"
  [ ! -s "$docker_calls" ] || fail "$label (database action started after setup signal)"
  assert_host_restore_absent "$label-host-route"
  assert_runtime_empty "$label-cleanup"
  assert_no_secret "$log" "$label-redaction"
  rm -f -- "$setup_directory_release"
  pass "$label"
}

run_setup_directory_signal_case INT 130
run_setup_directory_signal_case TERM 143

cat >"$test_root/create-client-handoff.sh" <<'CREATE_CLIENT_HANDOFF'
#!/bin/sh
set -u
ready_file="$1"
pid_file="$2"
release_file="$3"
result_file="$4"
child_ready_file="$5"
create_client_pid=
create_client_start=
create_client_launching=0
pending_signal_status=

stop_and_reap_child() {
  pid="$1"
  expected_start="$2"
  metadata="$(awk '{print $3 ":" $4 ":" $22}' "/proc/$pid/stat" 2>/dev/null)" || return 1
  [ "${metadata#*:}" = "$$:$expected_start" ] || return 1
  kill -TERM "$pid" 2>/dev/null || :
  attempt=0
  while metadata="$(awk '{print $3 ":" $4 ":" $22}' "/proc/$pid/stat" 2>/dev/null)"; do
    [ "${metadata#*:}" = "$$:$expected_start" ] || return 1
    state="${metadata%%:*}"
    [ "$state" != Z ] || break
    [ "$attempt" -lt 50 ] || break
    attempt=$((attempt + 1))
    sleep 0.02
  done
  metadata="$(awk '{print $3 ":" $4 ":" $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  if [ -n "$metadata" ]; then
    [ "${metadata#*:}" = "$$:$expected_start" ] || return 1
    if [ "${metadata%%:*}" != Z ] && kill -KILL "$pid" 2>/dev/null; then
      printf '%s\n' kill-escalated >>"$result_file"
    fi
  fi
  # A single direct-parent wait is portable; dash may cache the status for a repeated wait.
  child_wait_status=0
  if wait "$pid" 2>/dev/null; then child_wait_status=0; else child_wait_status=$?; fi
  printf 'reaped-status:%s\n' "$child_wait_status" >>"$result_file"
}

terminate_handoff() {
  status="$1"
  trap '' HUP INT TERM
  stop_and_reap_child "$create_client_pid" "$create_client_start"
  exit "$status"
}

handle_handoff_signal() {
  status="$1"
  if [ "$create_client_launching" -eq 1 ]; then
    if [ -z "$pending_signal_status" ]; then pending_signal_status="$status"; fi
    printf 'queued:%s\n' "$pending_signal_status" >>"$result_file"
    return 0
  fi
  terminate_handoff "$status"
}

trap 'handle_handoff_signal 129' HUP
trap 'handle_handoff_signal 130' INT
trap 'handle_handoff_signal 143' TERM

create_client_launching=1
python3 -c 'import pathlib, signal, sys; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text("ready\n", encoding="ascii"); signal.pause()' "$child_ready_file" &
spawned_child_pid=$!
while [ ! -s "$child_ready_file" ]; do sleep 0.02; done
spawned_child_metadata="$(awk '{print $4 ":" $22}' "/proc/$spawned_child_pid/stat")" || exit 98
spawned_child_parent="${spawned_child_metadata%%:*}"
spawned_child_start="${spawned_child_metadata#*:}"
[ "$spawned_child_parent" = "$$" ] || exit 98
case "$spawned_child_start" in ''|*[!0-9]*) exit 98 ;; esac
printf '%s:%s:%s\n' "$$" "$spawned_child_pid" "$spawned_child_start" >"$pid_file"
printf '%s\n' ready >"$ready_file"
while [ ! -e "$release_file" ]; do sleep 0.02; done
create_client_pid="$spawned_child_pid"
create_client_start="$spawned_child_start"
printf 'captured:%s\n' "$create_client_pid" >>"$result_file"
create_client_launching=0
if [ -n "$pending_signal_status" ]; then terminate_handoff "$pending_signal_status"; fi
exit 99
CREATE_CLIENT_HANDOFF
chmod 755 "$test_root/create-client-handoff.sh"

wait_for_content() {
  local path="$1" marker="$2" process_id="$3" deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    grep -Fq -- "$marker" "$path" 2>/dev/null && return 0
    kill -0 "$process_id" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

run_create_client_handoff_case() {
  local signal="$1" expected_status="$2" label="restore-create-client-handoff-${1,,}"
  local ready="$state_root/$label-ready" pids="$state_root/$label-pids"
  local release="$state_root/$label-release" result="$state_root/$label-result"
  local child_ready="$state_root/$label-child-ready" launch_pid creator_pid published_outer child_pid
  local child_identity child_start current_start reap_status status=0
  rm -f -- "$ready" "$pids" "$release" "$result" "$child_ready"
  : >"$result"
  : >"$outer_pid_file"
  AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" \
    setsid --wait python3 "$test_root/signal-launch.py" \
      "$test_root/create-client-handoff.sh" "$ready" "$pids" "$release" "$result" "$child_ready" &
  launch_pid=$!
  active_launch_pid="$launch_pid"
  wait_for_marker "$ready" "$launch_pid" || fail "$label (launch barrier was not reached)"
  IFS=: read -r creator_pid child_pid child_start <"$pids"
  case "$creator_pid" in ''|*[!0-9]*) fail "$label (invalid creator pid)" ;; esac
  published_outer="$(cat "$outer_pid_file")"
  [ "$published_outer" = "$creator_pid" ] || fail "$label (signal-reset identity mismatch)"
  active_outer_pid="$creator_pid"
  case "$child_pid" in ''|*[!0-9]*) fail "$label (invalid child pid)" ;; esac
  case "$child_start" in ''|*[!0-9]*) fail "$label (invalid child start time)" ;; esac
  if ! child_identity="$(awk '{print $4 ":" $22}' "/proc/$child_pid/stat" 2>/dev/null)"; then
    fail "$label (child identity became unavailable before signal delivery)"
  fi
  [ "$child_identity" = "$creator_pid:$child_start" ] || \
    fail "$label (child identity did not match the creator publication)"
  kill -s "$signal" "$creator_pid"
  wait_for_content "$result" "queued:$expected_status" "$launch_pid" || fail "$label (signal was not queued)"
  kill -0 "$child_pid" 2>/dev/null || fail "$label (child exited before queued signal consumption)"
  : >"$release"
  wait_for_process_exit "$launch_pid" || fail "$label (creator did not exit)"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  active_launch_pid=
  active_outer_pid=
  assert_status "$expected_status" "$status" "$label-status"
  assert_contains "$result" "captured:$child_pid" "$label-pid-captured"
  assert_contains "$result" kill-escalated "$label-kill-escalation"
  # Fields belong to awk; no shell expansion is intended.
  # shellcheck disable=SC2016
  reap_status="$(awk -F: '$1 == "reaped-status" { value=$2 } END { print value }' "$result")"
  case "$reap_status" in ''|*[!0-9]*) fail "$label (invalid direct-parent wait status)" ;; esac
  if [ "$reap_status" -le 128 ] || [ "$reap_status" -gt 255 ]; then
    fail "$label (direct-parent wait did not return a signal-derived status)"
  fi
  if [ -r "/proc/$child_pid/stat" ]; then
    if current_start="$(awk '{print $22}' "/proc/$child_pid/stat" 2>/dev/null)"; then
      [ "$current_start" != "$child_start" ] || fail "$label (original child identity survived cleanup)"
    fi
  fi
  rm -f -- "$ready" "$pids" "$release" "$result" "$child_ready"
  pass "$label"
}

run_create_client_handoff_case INT 130
run_create_client_handoff_case TERM 143

run_create_action_signal_case() {
  local signal="$1" expected_status="$2" label="restore-create-action-signal-${1,,}"
  local log="$log_root/$label.log" launch_pid outer_pid status=0
  reset_case
  mkfifo -- "$create_action_release"
  "${root_runner[@]}" env "${common_env[@]}" "${hostile_pg_env[@]}" \
    FAKE_RESTORE_LAYOUT=one FAKE_DOCKER_CREATE_BARRIER=1 \
    AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" \
    setsid --wait "$test_root/signal-launch.py" "$drill" >"$log" 2>&1 &
  launch_pid=$!
  active_launch_pid="$launch_pid"
  wait_for_marker "$create_action_ready" "$launch_pid" || fail "$label (create-action barrier was not reached)"
  outer_pid="$(cat "$outer_pid_file")"
  case "$outer_pid" in ''|*[!0-9]*) fail "$label (invalid outer pid)" ;; esac
  active_outer_pid="$outer_pid"
  "${root_runner[@]}" kill -s "$signal" -- "-$outer_pid"
  # If a shell defers its trap until the foreground fake returns, release it
  # only after the signal has been delivered to the isolated process group.
  # shellcheck disable=SC2016
  timeout 3 bash -c 'printf "%s\n" release >"$1"' sh "$create_action_release" >/dev/null 2>&1 || :
  wait_for_process_exit "$launch_pid" || fail "$label (process did not exit)"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  active_launch_pid=
  active_outer_pid=
  assert_status "$expected_status" "$status" "$label-status"
  assert_action_sequence 'create,cleanup' "$label-actions"
  assert_contains "$route_status_capture" cleanup-verified "$label-route-status"
  assert_host_restore_absent "$label-host-route"
  assert_runtime_empty "$label-cleanup"
  assert_no_secret "$log" "$label-redaction"
  rm -f -- "$create_action_release"
  pass "$label"
}

run_create_action_signal_case INT 130
run_create_action_signal_case TERM 143

run_signal_case() {
  local signal="$1" expected_status="$2" label="restore-signal-${1,,}"
  local release="$state_root/$label-release" log="$log_root/$label.log"
  local launch_pid outer_pid status=0
  reset_case
  rm -f -- "$release"
  mkfifo -- "$release"
  "${root_runner[@]}" env "${common_env[@]}" "${hostile_pg_env[@]}" \
    FAKE_RESTORE_LAYOUT=one FAKE_RESTIC_BARRIER=1 FAKE_RESTIC_RELEASE="$release" \
    AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" \
    setsid --wait "$test_root/signal-launch.py" "$drill" >"$log" 2>&1 &
  launch_pid=$!
  active_launch_pid="$launch_pid"
  wait_for_marker "$restic_ready" "$launch_pid" || fail "$label (barrier was not reached)"
  outer_pid="$(cat "$outer_pid_file")"
  case "$outer_pid" in ''|*[!0-9]*) fail "$label (invalid outer pid)" ;; esac
  active_outer_pid="$outer_pid"
  "${root_runner[@]}" kill -s "$signal" "$outer_pid"
  # Positional expansion belongs to the bounded FIFO release helper.
  # shellcheck disable=SC2016
  timeout 3 bash -c 'printf "%s\n" release >"$1"' sh "$release" || fail "$label (barrier release failed)"
  wait_for_process_exit "$launch_pid" || fail "$label (process did not exit)"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  active_launch_pid=
  active_outer_pid=
  assert_status "$expected_status" "$status" "$label-status"
  [ ! -s "$docker_calls" ] || fail "$label (database action started after signal)"
  assert_host_restore_absent "$label-host-route"
  assert_runtime_empty "$label-cleanup"
  assert_no_secret "$log" "$label-redaction"
  rm -f -- "$release"
  pass "$label"
}

run_signal_case INT 130
run_signal_case TERM 143

run_directory_identity_mismatch_case() {
  local label=restore-directory-identity-mismatch
  local release="$state_root/$label-release" log="$log_root/$label.log"
  local quarantine="$fixture_root/$label-original"
  local launch_pid outer_pid status=0 restore_root owner_token route_status
  reset_case
  rm -f -- "$release"
  "${root_runner[@]}" rm -rf -- "$quarantine"
  mkfifo -- "$release"
  "${root_runner[@]}" env "${common_env[@]}" "${hostile_pg_env[@]}" \
    FAKE_RESTORE_LAYOUT=one FAKE_RESTIC_BARRIER=1 FAKE_RESTIC_RELEASE="$release" \
    AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" \
    setsid --wait "$test_root/signal-launch.py" "$drill" >"$log" 2>&1 &
  launch_pid=$!
  active_launch_pid="$launch_pid"
  wait_for_marker "$restic_ready" "$launch_pid" || fail "$label (barrier was not reached)"
  restore_root="$(read_restore_root)" || fail "$label (unsafe captured restore path)"
  "${root_runner[@]}" test -d "$restore_root" || fail "$label (owned restore directory absent)"
  owner_token="$("${root_runner[@]}" cat "$restore_root/.restore-owner")"
  case "$owner_token" in ''|*[!a-f0-9]*) fail "$label (invalid owner token)" ;; esac
  [ "${#owner_token}" -eq 32 ] || fail "$label (invalid owner token length)"
  route_status="$("${root_runner[@]}" cat "$restore_root/.route-status")"
  [ "$route_status" = operation-owned ] || fail "$label (invalid route status fixture)"
  "${root_runner[@]}" mv -- "$restore_root" "$quarantine"
  "${root_runner[@]}" install -d -o root -g root -m 700 "$restore_root" "$restore_root/payload"
  # Positional expansion belongs to the isolated root-capable fixture writer.
  # shellcheck disable=SC2016
  "${root_runner[@]}" env OWNER_TOKEN="$owner_token" ROUTE_STATUS="$route_status" bash -c \
    'umask 077; printf "%s\n" "$OWNER_TOKEN" >"$1/.restore-owner"; printf "%s\n" "$ROUTE_STATUS" >"$1/.route-status"; chmod 600 "$1/.restore-owner" "$1/.route-status"' \
    sh "$restore_root"
  outer_pid="$(cat "$outer_pid_file")"
  case "$outer_pid" in ''|*[!0-9]*) fail "$label (invalid outer pid)" ;; esac
  active_outer_pid="$outer_pid"
  "${root_runner[@]}" kill -s TERM "$outer_pid"
  # Positional expansion belongs to the bounded FIFO release helper.
  # shellcheck disable=SC2016
  timeout 3 bash -c 'printf "%s\n" release >"$1"' sh "$release" || fail "$label (barrier release failed)"
  wait_for_process_exit "$launch_pid" || fail "$label (process did not exit)"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  active_launch_pid=
  active_outer_pid=
  assert_status 143 "$status" "$label-status"
  [ ! -s "$docker_calls" ] || fail "$label (database action started after signal)"
  "${root_runner[@]}" test -d "$restore_root" || fail "$label (replacement directory was deleted)"
  "${root_runner[@]}" test -d "$quarantine" || fail "$label (original directory was deleted)"
  assert_contains "$log" 'Restore payload cleanup could not verify ownership; temporary state was preserved.' "$label-diagnostic"
  assert_no_secret "$log" "$label-redaction"
  "${root_runner[@]}" rm -rf -- "$restore_root" "$quarantine"
  rm -f -- "$release"
  assert_runtime_empty "$label-harness-cleanup"
  pass "$label"
}

run_directory_identity_mismatch_case

printf '%s\n' 'PostgreSQL restore route, selection, and cleanup tests passed.'
