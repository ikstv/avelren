#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for script in scripts/backup/postgres-backup.sh scripts/backup/postgres-restore-drill.sh scripts/backup/postgres-backup-init.sh scripts/backup/postgres-backup-repo-check.sh scripts/backup/postgres-backup-prune.sh; do
  test -x "$root/$script"
done
grep -Fq '14 * 1024 * 1024 * 1024' "$root/scripts/backup/postgres-backup.sh"
grep -Fq 'keep-daily 7' "$root/scripts/backup/postgres-backup-prune.sh"
grep -Fq 'keep-weekly 4' "$root/scripts/backup/postgres-backup-prune.sh"
grep -Fq 'keep-monthly 3' "$root/scripts/backup/postgres-backup-prune.sh"
if grep -Eq 'dbname[ =]+avelren.*(dropdb|DROP DATABASE)' "$root/scripts/backup/postgres-restore-drill.sh"; then
  exit 1
fi

if [ "$(id -u)" -ne 0 ] && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; }; then
  printf '%s\n' 'Runtime failure-path tests skipped: root runner is unavailable.'
  exit 0
fi

disposable_base="${RUNNER_TEMP:-/tmp}"
test_root="$(mktemp -d "$disposable_base/avelren-backup-test.XXXXXX")"
log_root="$(mktemp -d "$disposable_base/avelren-backup-capture.XXXXXX")"
fake_bin="$test_root/bin"
backup_tmp="$test_root/backup-tmp"
mkdir -p "$fake_bin" "$backup_tmp"
chmod 700 "$test_root" "$log_root" "$backup_tmp"
safe_disposable_path() {
  case "$1" in
    "$disposable_base"/avelren-backup-test.*|"$disposable_base"/avelren-backup-capture.*)
      [ -n "$1" ] && [ "$1" != / ] && [ "$1" != "$HOME" ] && [ ! -L "$1" ] && [ -d "$1" ]
      ;;
    *) return 1 ;;
  esac
}
cleanup() {
  safe_disposable_path "$test_root" || exit 1
  safe_disposable_path "$log_root" || exit 1
  if [ "$(id -u)" -eq 0 ]; then
    rm -rf -- "$test_root" "$log_root"
  else
    sudo rm -rf -- "$test_root" "$log_root"
  fi
}
trap cleanup EXIT

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -eu
args="$*"
case "$args" in
  *'ps -q postgres'*) printf '%s\n' fake-postgres ;;
  *inspect*) printf '%s\n' healthy ;;
  *'pg_dump'*) printf '%s\n' fake-custom-format-dump ;;
  *createdb*) : >"$FAKE_DB_CREATED" ;;
  *dropdb*) : >"$FAKE_DB_DROPPED" ;;
  *psql*) case "$args" in *string_agg*) printf '%s\n' '001,002,003' ;; *) printf '%s\n' t ;; esac ;;
  *) exit 0 ;;
esac
FAKE_DOCKER

cat >"$fake_bin/rclone" <<'FAKE_RCLONE'
#!/usr/bin/env bash
set -eu
case "$*" in
  *'size --json'*) printf '{"bytes":%s}\n' "${FAKE_REPOSITORY_BYTES:-0}" ;;
  *) exit 0 ;;
esac
FAKE_RCLONE

cat >"$fake_bin/restic" <<'FAKE_RESTIC'
#!/usr/bin/env bash
set -eu
case "$*" in
  *snapshots*) exit 0 ;;
  *backup*) [ "${FAKE_RESTIC_FAIL:-0}" = 1 ] && exit 42 || exit 0 ;;
  *restore*) target=''; previous=''; for arg in "$@"; do [ "$previous" = --target ] && target="$arg"; previous="$arg"; done; printf '%s\n' fake-dump >"$target/restored.dump" ;;
  *) exit 0 ;;
esac
FAKE_RESTIC

cat >"$fake_bin/pg_restore" <<'FAKE_PG_RESTORE'
#!/usr/bin/env bash
exit 0
FAKE_PG_RESTORE
chmod 755 "$fake_bin"/*

config="$test_root/rclone.conf"
password="$test_root/restic_password"
touch "$config" "$password"
chmod 600 "$config" "$password"
if [ "$(id -u)" -ne 0 ]; then
  sudo chown root:root "$config" "$password"
fi
root_env=("PATH=$fake_bin:$PATH" "AVELREN_ENV_FILE=$test_root/env" "AVELREN_COMPOSE_FILE=$test_root/compose.yml" "AVELREN_BACKUP_TMP_ROOT=$backup_tmp" "AVELREN_BACKUP_LOCK_FILE=$test_root/backup.lock" "AVELREN_RCLONE_REMOTE=test-remote" "AVELREN_RESTIC_PASSWORD_FILE=$password" "AVELREN_RCLONE_CONFIG=$config" "FAKE_DB_CREATED=$test_root/db-created" "FAKE_DB_DROPPED=$test_root/db-dropped")
runner=()
[ "$(id -u)" -eq 0 ] || runner=(sudo)
backup_tmp_is_empty() { [ -z "$("${runner[@]}" find "$backup_tmp" -mindepth 1 -print -quit)" ]; }
capture_is_runner_readable() { [ -r "$log_root" ] && [ -x "$log_root" ] && [ -f "$1" ] && [ -r "$1" ]; }
printf '%s\n' 'test' >"$test_root/env"
printf '%s\n' 'test' >"$test_root/compose.yml"

below_warning=$((12 * 1024 * 1024 * 1024 - 1))
at_warning=$((12 * 1024 * 1024 * 1024))
at_hard_stop=$((14 * 1024 * 1024 * 1024))

"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" "$root/scripts/backup/postgres-backup.sh" >"$log_root/below-warning.log" 2>&1
capture_is_runner_readable "$log_root/below-warning.log"
if grep -Fq 'Warning: repository reached 12 GiB.' "$log_root/below-warning.log"; then
  exit 1
fi
backup_tmp_is_empty

"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$at_warning" "$root/scripts/backup/postgres-backup.sh" >"$log_root/at-warning.log" 2>&1
capture_is_runner_readable "$log_root/at-warning.log"
grep -Fq 'Warning: repository reached 12 GiB.' "$log_root/at-warning.log"
if grep -Fq 'Backup stopped: repository reached the 14 GiB hard limit.' "$log_root/at-warning.log"; then
  exit 1
fi
backup_tmp_is_empty

set +e
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$at_hard_stop" "$root/scripts/backup/postgres-backup.sh" >"$log_root/at-hard-stop.log" 2>&1
hard_stop_status=$?
set -e
[ "$hard_stop_status" -ne 0 ]
capture_is_runner_readable "$log_root/at-hard-stop.log"
grep -Fq 'Backup stopped: repository reached the 14 GiB hard limit.' "$log_root/at-hard-stop.log"
backup_tmp_is_empty

set +e
"${runner[@]}" env "${root_env[@]}" FAKE_RESTIC_FAIL=1 "$root/scripts/backup/postgres-backup.sh" >"$log_root/failure.log" 2>&1
failure_status=$?
set -e
[ "$failure_status" -ne 0 ]
backup_tmp_is_empty
capture_is_runner_readable "$log_root/failure.log"
if grep -Eq 'fake-secret|password|token' "$log_root/below-warning.log" "$log_root/at-warning.log" "$log_root/at-hard-stop.log" "$log_root/failure.log"; then
  exit 1
fi

set +e
"${runner[@]}" env "${root_env[@]}" AVELREN_PG_DATABASE=avelren "$root/scripts/backup/postgres-restore-drill.sh" >"$test_root/restore-guard.log" 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ]
[ ! -e "$test_root/db-created" ]

printf '%s\n' 'PostgreSQL backup failure-path and cleanup tests passed.'
