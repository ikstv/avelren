#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root/scripts/backup/postgres-tcp-dump.sh"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/avelren-pgpass-test.XXXXXX")"
fake_bin="$test_root/bin"
capture="$test_root/capture"
secret_file="$test_root/postgres_password"
expected_file="$test_root/expected_password"
mkdir -p "$fake_bin" "$capture" "$test_root/pgpass"
chmod 700 "$test_root" "$capture" "$test_root/pgpass"

cleanup() {
  case "$test_root" in
    "${RUNNER_TEMP:-/tmp}"/avelren-pgpass-test.*) rm -rf -- "$test_root" ;;
    *) printf '%s\n' 'Refusing cleanup outside disposable test scope.' >&2; exit 90 ;;
  esac
}
trap cleanup EXIT

printf '%s' 'fixture-database-credential' >"$secret_file"
cp "$secret_file" "$expected_file"
chmod 600 "$secret_file" "$expected_file"

cat >"$fake_bin/pg_dump" <<'FAKE_PG_DUMP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$FAKE_CAPTURE/argv"
printf '%s\n' "$PGPASSFILE" >"$FAKE_CAPTURE/pgpass-path"
stat -c '%a' "$PGPASSFILE" >"$FAKE_CAPTURE/pgpass-mode"
expected="$(cat "$FAKE_EXPECTED_PASSWORD_FILE")"
actual="$(sed -n 's/^127\.0\.0\.1:5432:avelren:avelren://p' "$PGPASSFILE")"
[ "$actual" = "$expected" ] || exit 81
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  : >"$FAKE_CAPTURE/ready"
  trap 'exit 143' TERM
  trap 'exit 130' INT
  while :; do sleep 1; done
fi
printf '%s\n' 'fake-custom-format-dump'
FAKE_PG_DUMP
chmod 755 "$fake_bin/pg_dump"

run_helper() {
  env \
    PATH="$fake_bin:$PATH" \
    AVELREN_POSTGRES_PASSWORD_FILE="$secret_file" \
    AVELREN_PGPASS_TMPDIR="$test_root/pgpass" \
    FAKE_CAPTURE="$capture" \
    FAKE_EXPECTED_PASSWORD_FILE="$expected_file" \
    "$helper" avelren avelren
}

success_log="$test_root/success.log"
run_helper >"$success_log" 2>&1
test -s "$success_log"
grep -Fq -- '--host 127.0.0.1' "$capture/argv"
grep -Fq -- '--port 5432' "$capture/argv"
if grep -Eq -- '(^| )(-h|--host)( |$)' "$capture/argv" && ! grep -Fq -- '--host 127.0.0.1' "$capture/argv"; then
  exit 1
fi
[ "$(cat "$capture/pgpass-mode")" = 600 ]
success_pgpass="$(cat "$capture/pgpass-path")"
[ ! -e "$success_pgpass" ]

printf '%s' 'wrong-fixture-credential' >"$secret_file"
failure_log="$test_root/failure.log"
if run_helper >"$failure_log" 2>&1; then
  printf '%s\n' 'Wrong PostgreSQL password unexpectedly succeeded.' >&2
  exit 1
fi
failure_pgpass="$(cat "$capture/pgpass-path")"
[ ! -e "$failure_pgpass" ]
printf '%s' 'fixture-database-credential' >"$secret_file"

run_signal_test() {
  signal="$1"
  expected_status="$2"
  rm -f "$capture/ready" "$capture/pgpass-path"
  signal_log="$test_root/${signal}.log"
  (
    trap - INT TERM
    exec env \
      PATH="$fake_bin:$PATH" \
      AVELREN_POSTGRES_PASSWORD_FILE="$secret_file" \
      AVELREN_PGPASS_TMPDIR="$test_root/pgpass" \
      FAKE_CAPTURE="$capture" \
      FAKE_EXPECTED_PASSWORD_FILE="$expected_file" \
      FAKE_HOLD=1 \
      "$helper" avelren avelren
  ) >"$signal_log" 2>&1 &
  helper_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$capture/ready" ] && break
    sleep 0.05
  done
  [ -f "$capture/ready" ]
  signal_pgpass="$(cat "$capture/pgpass-path")"
  kill -s "$signal" "$helper_pid"
  signal_status=0
  wait "$helper_pid" || signal_status=$?
  [ "$signal_status" -eq "$expected_status" ]
  [ ! -e "$signal_pgpass" ]
}

run_signal_test INT 130
run_signal_test TERM 143

if grep -Fq -f "$expected_file" "$success_log" "$failure_log" "$test_root/INT.log" "$test_root/TERM.log" "$capture/argv"; then
  printf '%s\n' 'PostgreSQL password leaked into logs or process arguments.' >&2
  exit 1
fi
if grep -Eq 'createdb|dropdb|psql|INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP' "$capture/argv"; then
  printf '%s\n' 'Backup helper attempted a database-modifying command.' >&2
  exit 1
fi
[ -z "$(find "$test_root/pgpass" -mindepth 1 -print -quit)" ]

printf '%s\n' 'PostgreSQL TCP/PGPASS authentication regression tests passed.'
