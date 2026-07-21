#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for script in scripts/backup/postgres-backup.sh scripts/backup/postgres-restore-drill.sh scripts/backup/postgres-backup-init.sh scripts/backup/postgres-backup-repo-check.sh scripts/backup/postgres-backup-prune.sh; do
  test -x "$root/$script"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  grep -Fq '. "$script_dir/restic-password-file.sh"' "$root/$script"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  grep -Fq 'validate_restic_password_file "$password_file"' "$root/$script"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  grep -Fq '. "$script_dir/restic-repository.sh"' "$root/$script"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  grep -Fq 'configure_restic_repository "$repo"' "$root/$script"
done
test -r "$root/scripts/backup/restic-password-file.sh"
test -r "$root/scripts/backup/restic-repository.sh"
test -r "$root/scripts/backup/postgres-tcp-dump.sh"
test -r "$root/scripts/backup/postgres-backup-control.sh"
grep -Fq '14 * 1024 * 1024 * 1024' "$root/scripts/backup/postgres-backup.sh"
grep -Fq 'keep-daily 7' "$root/scripts/backup/postgres-backup-prune.sh"
grep -Fq 'keep-weekly 4' "$root/scripts/backup/postgres-backup-prune.sh"
grep -Fq 'keep-monthly 3' "$root/scripts/backup/postgres-backup-prune.sh"
if grep -Eq 'dbname[ =]+avelren.*(dropdb|DROP DATABASE)' "$root/scripts/backup/postgres-restore-drill.sh"; then
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  nonroot_log="$(mktemp "${RUNNER_TEMP:-/tmp}/avelren-backup-nonroot.XXXXXX")"
  nonroot_status=0
  env AVELREN_RCLONE_REMOTE=test "$root/scripts/backup/postgres-backup.sh" >"$nonroot_log" 2>&1 || nonroot_status=$?
  [ "$nonroot_status" -ne 0 ]
  grep -Fq 'This backup must run as root.' "$nonroot_log"
  rm -f -- "$nonroot_log"
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
  *State.Health.Status*) printf '%s\n' healthy ;;
  *HostConfig.Tmpfs*) printf '%s\n' 'rw,mode=0700' ;;
  *'exec --user 0 fake-postgres sh -eu -c'*)
    [ "${FAKE_STALE_RUNTIME:-0}" = 0 ] || exit 74
    ;;
  *'exec --interactive --user 0 fake-postgres sh -eu -c'*)
    cat >/dev/null
    if [ "${FAKE_COLLISION_ONCE:-0}" = 1 ] && [ ! -e "$FAKE_COLLISION_PROOF" ]; then
      printf '%s\n' 'existing-operation-preserved' >"$FAKE_COLLISION_PROOF"
      exit 73
    fi
    printf '%s\n' starting >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --detach --user 0 '*'-env AVELREN_BACKUP_OPERATION_ID='*)
    printf '%s\n' done:0 >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- heartbeat '*) cat >/dev/null ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- state '*)
    cat >/dev/null
    cat "$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- cleanup '*)
    cat >/dev/null
    printf '%s\n' missing >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- signal '*) cat >/dev/null ;;
  *'cp fake-postgres:'*)
    destination="${!#}"
    printf '%s\n' fake-custom-format-dump >"$destination"
    ;;
  *createdb*) : >"$FAKE_DB_CREATED" ;;
  *dropdb*) : >"$FAKE_DB_DROPPED" ;;
  *psql*) case "$args" in *string_agg*) printf '%s\n' '001,002,003' ;; *) printf '%s\n' t ;; esac ;;
  *) exit 0 ;;
esac
FAKE_DOCKER

cat >"$fake_bin/rclone" <<'FAKE_RCLONE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_RCLONE_CALLS"
case "$*" in
  *'size --json'*) printf '{"bytes":%s}\n' "${FAKE_REPOSITORY_BYTES:-0}" ;;
  *) exit 0 ;;
esac
FAKE_RCLONE

cat >"$fake_bin/restic" <<'FAKE_RESTIC'
#!/usr/bin/env bash
set -eu
printf '%s\n' "${RESTIC_REPOSITORY:-missing}" >>"$FAKE_RESTIC_REPOSITORIES"
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
touch "$config"
printf '%s' 'fixture-password' >"$password"
chmod 600 "$config"
chmod 400 "$password"
if [ "$(id -u)" -ne 0 ]; then
  sudo chown root:root "$config" "$password"
fi
rclone_calls="$test_root/rclone-calls"
restic_repositories="$test_root/restic-repositories"
touch "$rclone_calls" "$restic_repositories"
root_env=("PATH=$fake_bin:$PATH" "AVELREN_ENV_FILE=$test_root/env" "AVELREN_COMPOSE_FILE=$test_root/compose.yml" "AVELREN_BACKUP_TMP_ROOT=$backup_tmp" "AVELREN_BACKUP_LOCK_FILE=$test_root/backup.lock" "AVELREN_RCLONE_REMOTE=test-remote" "AVELREN_RESTIC_PASSWORD_FILE=$password" "AVELREN_RCLONE_CONFIG=$config" "FAKE_DB_CREATED=$log_root/db-created" "FAKE_DB_DROPPED=$log_root/db-dropped" "FAKE_RCLONE_CALLS=$rclone_calls" "FAKE_RESTIC_REPOSITORIES=$restic_repositories" "FAKE_COLLISION_PROOF=$log_root/collision-proof")
root_env+=("FAKE_DOCKER_STATE=$test_root/docker-state")
runner=()
[ "$(id -u)" -eq 0 ] || runner=(sudo)
validator="$root/scripts/backup/restic-password-file.sh"
validator_fixture="$test_root/validator-password"
printf '%s' 'validator-fixture' >"$validator_fixture"
"${runner[@]}" chown root:root "$validator_fixture"
run_validator() {
  # Expansion belongs to the isolated bash process.
  # shellcheck disable=SC2016
  "${runner[@]}" env VALIDATOR="$validator" PASSWORD_FILE="$1" bash -c '. "$VALIDATOR"; validate_restic_password_file "$PASSWORD_FILE"'
}
expect_validator_pass() {
  "${runner[@]}" chmod "$1" "$validator_fixture"
  run_validator "$validator_fixture"
}
expect_validator_fail() {
  "${runner[@]}" chmod "$1" "$validator_fixture"
  if run_validator "$validator_fixture" >/dev/null 2>&1; then
    exit 1
  fi
}
expect_validator_pass 400
expect_validator_pass 600
for rejected_mode in 0000 0440 0640 0644 0500; do
  expect_validator_fail "$rejected_mode"
done
"${runner[@]}" chmod 400 "$validator_fixture"
if [ "$(id -u)" -eq 0 ]; then
  chown 65534:65534 "$validator_fixture"
else
  sudo chown "$(id -u):$(id -g)" "$validator_fixture"
fi
if run_validator "$validator_fixture" >/dev/null 2>&1; then
  exit 1
fi
"${runner[@]}" chown root:root "$validator_fixture"
empty_fixture="$test_root/empty-password"
"${runner[@]}" touch "$empty_fixture"
"${runner[@]}" chown root:root "$empty_fixture"
"${runner[@]}" chmod 400 "$empty_fixture"
if run_validator "$empty_fixture" >/dev/null 2>&1; then
  exit 1
fi
symlink_fixture="$test_root/symlink-password"
"${runner[@]}" ln -s "$validator_fixture" "$symlink_fixture"
if run_validator "$symlink_fixture" >/dev/null 2>&1; then
  exit 1
fi
repository_validator="$root/scripts/backup/restic-repository.sh"
run_repository_validator() {
  # Expansion belongs to the isolated bash process.
  # shellcheck disable=SC2016
  env VALIDATOR="$repository_validator" REPOSITORY="$1" bash -c '. "$VALIDATOR"; configure_restic_repository "$REPOSITORY"; test "$RESTIC_REPOSITORY_URL" = "rclone:test-remote:Avelren Backups/restic"; test "$RCLONE_REPOSITORY_PATH" = "test-remote:Avelren Backups/restic"'
}
run_repository_validator 'rclone:test-remote:Avelren Backups/restic'
for invalid_repository in 's3:test-remote:Avelren Backups/restic' 'rclone:rclone:test-remote:Avelren Backups/restic' 'rclone::Avelren Backups/restic' 'rclone:test-remote:'; do
  if run_repository_validator "$invalid_repository" >/dev/null 2>&1; then exit 1; fi
done
if run_repository_validator $'rclone:test-remote:Avelren Backups/restic\ninvalid' >/dev/null 2>&1; then exit 1; fi
if run_repository_validator $'rclone:test-remote:Avelren Backups/restic\tinvalid' >/dev/null 2>&1; then exit 1; fi
backup_tmp_is_empty() { [ -z "$("${runner[@]}" find "$backup_tmp" -mindepth 1 -print -quit)" ]; }
capture_is_runner_readable() { [ -r "$log_root" ] && [ -x "$log_root" ] && [ -f "$1" ] && [ -r "$1" ]; }
printf '%s\n' 'test' >"$test_root/env"
printf '%s\n' 'test' >"$test_root/compose.yml"

"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-init.sh" >/dev/null
"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-repo-check.sh" >/dev/null
"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-prune.sh" >/dev/null
grep -Fxq 'lsd test-remote:' "$rclone_calls"
grep -Fxq 'lsf test-remote:Avelren Backups' "$rclone_calls"
grep -Fxq 'size --json test-remote:Avelren Backups/restic' "$rclone_calls"
if grep -Fq 'rclone:test-remote:' "$rclone_calls"; then exit 1; fi
if grep -Fvxq 'rclone:test-remote:Avelren Backups/restic' "$restic_repositories"; then exit 1; fi

below_warning=$((12 * 1024 * 1024 * 1024 - 1))
at_warning=$((12 * 1024 * 1024 * 1024))
at_hard_stop=$((14 * 1024 * 1024 * 1024))

"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" "$root/scripts/backup/postgres-backup.sh" >"$log_root/below-warning.log" 2>&1
capture_is_runner_readable "$log_root/below-warning.log"
if grep -Fq 'Warning: repository reached 12 GiB.' "$log_root/below-warning.log"; then
  exit 1
fi
backup_tmp_is_empty

set +e
"${runner[@]}" env "${root_env[@]}" FAKE_STALE_RUNTIME=1 FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/stale-runtime.log" 2>&1
stale_runtime_status=$?
set -e
[ "$stale_runtime_status" -ne 0 ]
grep -Fq 'PostgreSQL backup runtime is unsafe or contains operation state.' "$log_root/stale-runtime.log"
backup_tmp_is_empty

rm -f "$log_root/collision-proof"
"${runner[@]}" env "${root_env[@]}" FAKE_COLLISION_ONCE=1 FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/collision.log" 2>&1
grep -Fxq 'existing-operation-preserved' "$log_root/collision-proof"
grep -Fq 'PostgreSQL backup completed.' "$log_root/collision.log"
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

restore_guard_log="$log_root/restore-guard.log"
: >"$restore_guard_log" || { printf '%s\n' 'Restore guard harness log setup failed.' >&2; exit 1; }
[ -w "$restore_guard_log" ] || { printf '%s\n' 'Restore guard harness log is not writable.' >&2; exit 1; }
set +e
"${runner[@]}" env "${root_env[@]}" AVELREN_PG_DATABASE=not_avelren "$root/scripts/backup/postgres-restore-drill.sh" >"$restore_guard_log" 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ]
grep -Fq 'Production database name must remain avelren.' "$restore_guard_log"
if grep -Fqi 'permission denied' "$restore_guard_log"; then
  printf '%s\n' 'Restore guard harness failed before executing the guard.' >&2
  exit 1
fi
[ ! -e "$log_root/db-created" ]

printf '%s\n' 'PostgreSQL backup failure-path and cleanup tests passed.'
