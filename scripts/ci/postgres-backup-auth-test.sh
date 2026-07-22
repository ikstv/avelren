#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'PostgreSQL auth regression test must run as root.' >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root/scripts/backup/postgres-tcp-dump.sh"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/avelren-pgpass-test.XXXXXX")"
fake_bin="$test_root/bin"
capture="$test_root/capture"
secret_file="$test_root/postgres_password"
expected_pgpass="$test_root/expected-pgpass"
runtime_root=/run/avelren-backup
runtime_created=0
mkdir -p "$fake_bin" "$capture"
chmod 700 "$test_root" "$capture"
[ ! -e "$runtime_root" ] || [ -z "$(find "$runtime_root" -mindepth 1 -print -quit)" ] || {
  printf '%s\n' 'PostgreSQL backup runtime is already in use.' >&2
  exit 1
}
if [ ! -e "$runtime_root" ]; then
  install -d -o root -g root -m 700 "$runtime_root"
  runtime_created=1
fi

cleanup() {
  case "$test_root" in
    "${RUNNER_TEMP:-/tmp}"/avelren-pgpass-test.*) rm -rf -- "$test_root" ;;
    *) printf '%s\n' 'Refusing cleanup outside disposable test scope.' >&2; exit 90 ;;
  esac
  [ -z "$(find "$runtime_root" -mindepth 1 -print -quit)" ]
  [ "$runtime_created" -eq 0 ] || rmdir -- "$runtime_root"
}
trap cleanup EXIT

cat >"$fake_bin/pg_dump" <<'FAKE_PG_DUMP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$FAKE_CAPTURE/argv"
printf '%s\n' "$PGPASSFILE" >"$FAKE_CAPTURE/pgpass-path"
stat -c '%u:%a' "$PGPASSFILE" >"$FAKE_CAPTURE/pgpass-mode"
cp "$PGPASSFILE" "$FAKE_CAPTURE/pgpass-content"
chmod 600 "$FAKE_CAPTURE/pgpass-content"
cmp -s "$PGPASSFILE" "$FAKE_EXPECTED_PGPASS" || exit 81
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  : >"$FAKE_CAPTURE/ready"
  trap 'exit 143' TERM
  trap 'exit 130' INT
  while :; do sleep 1; done
fi
printf '%s\n' 'fake-custom-format-dump'
FAKE_PG_DUMP
chmod 755 "$fake_bin/pg_dump"

cat >"$fake_bin/mktemp" <<'FAKE_MKTEMP'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${FAKE_MKTEMP_FAIL:-0}" = 1 ]; then exit 70; fi
exec /usr/bin/mktemp "$@"
FAKE_MKTEMP
cat >"$fake_bin/chmod" <<'FAKE_CHMOD'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${!#}"
if [ "${FAKE_CHMOD_FAIL:-0}" = 1 ] && [[ "$target" == */pgpass.* ]]; then exit 71; fi
exec /usr/bin/chmod "$@"
FAKE_CHMOD
cat >"$fake_bin/stat" <<'FAKE_STAT'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${!#}"
if [ "${FAKE_STAT_FAIL:-0}" = 1 ] && [[ "$target" == */pgpass.* ]]; then exit 72; fi
exec /usr/bin/stat "$@"
FAKE_STAT
chmod 755 "$fake_bin/mktemp" "$fake_bin/chmod" "$fake_bin/stat"

new_operation() {
  operation_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  control_dir="/run/avelren-backup/operation.$operation_id"
  mkdir -m 700 "$control_dir"
  date +%s >"$control_dir/heartbeat"
}

remove_operation() {
  case "$control_dir" in /run/avelren-backup/operation.[a-f0-9]*) rm -rf -- "$control_dir" ;; *) exit 90 ;; esac
}

run_helper() {
  env \
    PATH="$fake_bin:$PATH" \
    AVELREN_POSTGRES_PASSWORD_FILE="$secret_file" \
    AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 \
    AVELREN_BACKUP_TERMINATION_TIMEOUT=10 \
    FAKE_MKTEMP_FAIL="${FAKE_MKTEMP_FAIL:-0}" \
    FAKE_CHMOD_FAIL="${FAKE_CHMOD_FAIL:-0}" \
    FAKE_STAT_FAIL="${FAKE_STAT_FAIL:-0}" \
    FAKE_CAPTURE="$capture" \
    FAKE_EXPECTED_PGPASS="$expected_pgpass" \
    "$helper" avelren avelren "$control_dir" "$operation_id"
}

run_password_case() {
  password="$1"
  expected="$2"
  printf '%s' "$password" >"$secret_file"
  chmod 600 "$secret_file"
  printf '%s\n' "$expected" >"$expected_pgpass"
  chmod 600 "$expected_pgpass"
  rm -f "$capture/argv" "$capture/pgpass-path" "$capture/pgpass-content"
  new_operation
  run_helper >/dev/null 2>"$test_root/password-case.log"
  [ "$(cat "$control_dir/status")" = 0 ]
  test -s "$control_dir/postgres.dump"
  grep -Fq -- '--host 127.0.0.1' "$capture/argv"
  grep -Fq -- '--port 5432' "$capture/argv"
  [ "$(cat "$capture/pgpass-mode")" = "$(id -u):600" ]
  pgpass_path="$(cat "$capture/pgpass-path")"
  [ ! -e "$pgpass_path" ]
  cmp -s "$capture/pgpass-content" "$expected_pgpass"
  if grep -Fq -- "$password" "$test_root/password-case.log" "$capture/argv"; then
    printf '%s\n' 'PostgreSQL password leaked into logs or process arguments.' >&2
    exit 1
  fi
  remove_operation
}

run_password_case 'fixture-database-credential' '127.0.0.1:5432:avelren:avelren:fixture-database-credential'
run_password_case 'back\slash' '127.0.0.1:5432:avelren:avelren:back\\slash'
run_password_case 'colon:value' '127.0.0.1:5432:avelren:avelren:colon\:value'
run_password_case 'star*value' '127.0.0.1:5432:avelren:avelren:star*value'
# These metacharacters are intentional literal password and pgpass fixtures.
# shellcheck disable=SC2016
run_password_case 'space \:* $()[]{};&value' '127.0.0.1:5432:avelren:avelren:space \\\:* $()[]{};&value'

new_operation
: >"$secret_file"
chmod 600 "$secret_file"
if run_helper >"$test_root/empty.log" 2>&1; then exit 1; fi
[ "$(cat "$control_dir/status")" -ne 0 ]
[ -z "$(find "$control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
remove_operation

printf '%s' 'fixture-database-credential' >"$secret_file"
printf '%s\n' '127.0.0.1:5432:avelren:avelren:fixture-database-credential' >"$expected_pgpass"
run_injected_failure() {
  failure_variable="$1"
  new_operation
  export "$failure_variable=1"
  failure_status=0
  run_helper >"$test_root/$failure_variable.log" 2>&1 || failure_status=$?
  unset "$failure_variable"
  [ "$failure_status" -ne 0 ]
  [ "$(cat "$control_dir/status")" -ne 0 ]
  [ -z "$(find "$control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
  remove_operation
}

run_injected_failure FAKE_MKTEMP_FAIL
run_injected_failure FAKE_CHMOD_FAIL
run_injected_failure FAKE_STAT_FAIL

new_operation
printf 'trailing-newline\n' >"$secret_file"
if run_helper >"$test_root/trailing-newline.log" 2>&1; then exit 1; fi
[ "$(cat "$control_dir/status")" -ne 0 ]
[ -z "$(find "$control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
if grep -Fq -- 'trailing-newline' "$test_root/trailing-newline.log"; then exit 1; fi
remove_operation

printf '%s' 'fixture-database-credential' >"$secret_file"
printf '%s\n' '127.0.0.1:5432:avelren:avelren:incorrect-representation' >"$expected_pgpass"
new_operation
if run_helper >"$test_root/incorrect-escape.log" 2>&1; then exit 1; fi
[ "$(cat "$control_dir/status")" = 81 ]
[ -z "$(find "$control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
if grep -Fq -- 'fixture-database-credential' "$test_root/incorrect-escape.log" "$capture/argv"; then exit 1; fi
remove_operation

printf '%s\n' '127.0.0.1:5432:avelren:avelren:fixture-database-credential' >"$expected_pgpass"
run_signal_test() {
  signal="$1"
  expected_status="$2"
  rm -f "$capture/ready" "$capture/pgpass-path"
  new_operation
  signal_log="$test_root/${signal}.log"
  (
    trap - INT TERM
    exec env PATH="$fake_bin:$PATH" AVELREN_POSTGRES_PASSWORD_FILE="$secret_file" \
      AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 FAKE_CAPTURE="$capture" \
      FAKE_EXPECTED_PGPASS="$expected_pgpass" FAKE_HOLD=1 \
      "$helper" avelren avelren "$control_dir" "$operation_id"
  ) >"$signal_log" 2>&1 &
  helper_pid=$!
  for _ in $(seq 1 100); do [ -f "$capture/ready" ] && break; sleep 0.05; done
  [ -f "$capture/ready" ]
  signal_pgpass="$(cat "$capture/pgpass-path")"
  kill -s "$signal" "$helper_pid"
  signal_status=0
  wait "$helper_pid" || signal_status=$?
  [ "$signal_status" -eq "$expected_status" ]
  [ "$(cat "$control_dir/status")" -eq "$expected_status" ]
  [ ! -e "$signal_pgpass" ]
  if grep -Fq -- 'fixture-database-credential' "$signal_log" "$capture/argv"; then exit 1; fi
  remove_operation
}

run_signal_test INT 130
run_signal_test TERM 143

rm -f "$capture/ready" "$capture/pgpass-path"
new_operation
printf '%s\n' 0 >"$control_dir/heartbeat"
lease_log="$test_root/lease-expired.log"
lease_status=0
(
  trap - INT TERM
  exec env PATH="$fake_bin:$PATH" AVELREN_POSTGRES_PASSWORD_FILE="$secret_file" \
    AVELREN_BACKUP_HEARTBEAT_TIMEOUT=5 AVELREN_BACKUP_TERMINATION_TIMEOUT=2 \
    FAKE_CAPTURE="$capture" FAKE_EXPECTED_PGPASS="$expected_pgpass" FAKE_HOLD=1 \
    "$helper" avelren avelren "$control_dir" "$operation_id"
) >"$lease_log" 2>&1 || lease_status=$?
[ "$lease_status" -eq 143 ]
[ ! -e "$control_dir" ]
lease_pgpass="$(cat "$capture/pgpass-path")"
[ ! -e "$lease_pgpass" ]
if grep -Fq -- 'fixture-database-credential' "$lease_log" "$capture/argv"; then exit 1; fi

if grep -Eq 'createdb|dropdb|psql|INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP' "$capture/argv"; then
  printf '%s\n' 'Backup helper attempted a database-modifying command.' >&2
  exit 1
fi
printf '%s\n' 'PostgreSQL TCP/PGPASS authentication regression tests passed.'
