#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
diagnostics_helper="$root/scripts/ci/postgres-backup-diagnostics.sh"
# Resolved relative to the repository root.
# shellcheck disable=SC1090
. "$diagnostics_helper"

if [ "${AVELREN_DIAGNOSTICS_SELF_TEST:-0}" = 1 ]; then
  diagnostics_self_test "$root/scripts/ci/postgres-backup-test.sh"
  exit 0
fi

if [ -n "${AVELREN_DIAGNOSTICS_SELF_TEST_CHILD:-}" ]; then
  case_specs=('diagnostics-self-test|intentional sanitized diagnostic failure')
else
  case_specs=(
    'static-contract|backup script contracts and retention policy'
    'runtime-nonroot-guard|non-root backup execution is rejected'
    'runtime-root-runner|root runner dependency is available'
    'harness-setup|isolated fake command and fixture setup'
    'password-validator|Restic password file validation matrix'
    'repository-validator|Restic repository validation matrix'
    'helper-entrypoints|backup helper entrypoints and routing'
    'tmpfs-reordered|reordered secure tmpfs options are accepted'
    'tmpfs-canonical-mode|Docker canonical mode 700 is accepted'
    'tmpfs-missing-noexec|missing noexec is rejected'
    'tmpfs-missing-nosuid|missing nosuid is rejected'
    'tmpfs-missing-nodev|missing nodev is rejected'
    'tmpfs-wrong-mode|unsafe tmpfs mode is rejected'
    'tmpfs-wrong-uid|unsafe tmpfs uid is rejected'
    'tmpfs-wrong-gid|unsafe tmpfs gid is rejected'
    'tmpfs-deceptive-substring|deceptive tmpfs values are rejected'
    'tmpfs-contradictory-exec|contradictory exec option is rejected'
    'tmpfs-malformed-boolean|malformed tmpfs boolean is rejected'
    'tmpfs-effective-not-tmpfs|unsafe effective mount is rejected'
    'historical-nonempty|historical non-empty-only check remains proven unsafe'
    'host-redirection-classification|Bash host redirection behavior is classified'
    'host-dump-mode|host dump is root-owned mode 0600'
    'host-existing-symlink|pre-existing dump symlink is rejected'
    'host-existing-symlink-regular|pre-existing symlink to a regular file is rejected'
    'host-existing-dangling-symlink|pre-existing dangling symlink is rejected'
    'host-existing-symlink-fifo|pre-existing symlink to a FIFO is rejected without blocking'
    'host-existing-fifo|pre-existing dump FIFO is rejected'
    'host-existing-directory|pre-existing dump directory is rejected'
    'host-existing-regular|pre-existing dump regular file is rejected'
    'host-dump-create-failure|host dump create failure is isolated'
    'host-tmpdir-chmod-failure|temporary directory chmod failure is isolated'
    'host-dump-stat-failure|host dump stat failure is isolated'
    'host-dump-identity-mismatch|host dump path and FD identity mismatch is rejected'
    'host-partial-stream|partial dump stream is cleaned up'
    'repository-below-warning|repository below warning threshold succeeds'
    'runtime-stale-state|stale runtime state is rejected'
    'operation-collision-retry|operation collision preserves existing state'
    'repository-warning|repository warning threshold emits warning'
    'repository-hard-stop|repository hard limit stops backup'
    'restic-failure|Restic failure preserves cleanup and status'
    'restore-database-guard|restore drill rejects production database name change'
    'harness-cleanup|root-owned harness fixtures are removed'
  )
fi
diagnostics_init "${case_specs[@]}"

if [ "${AVELREN_DIAGNOSTICS_SELF_TEST_CHILD:-}" = fail ]; then
  diagnostics_set_test_id diagnostics-self-test
  begin_case diagnostics-self-test
  diagnostics_set_assertion intentional-self-test
  intentional_diagnostic_failure() { return 86; }
  intentional_diagnostic_failure
elif [ "${AVELREN_DIAGNOSTICS_SELF_TEST_CHILD:-}" = redact ]; then
  diagnostics_set_test_id diagnostics-self-test
  begin_case diagnostics-self-test
  fail_case intentional-self-test-redaction rejected "${AVELREN_DIAGNOSTICS_SELF_TEST_SECRET:-missing}"
elif [ "${AVELREN_DIAGNOSTICS_SELF_TEST_CHILD:-}" = timeout ]; then
  diagnostics_set_test_id diagnostics-self-test
  begin_case diagnostics-self-test
  kill -TERM "$$"
  fail_case timeout-signal-delivery pass failed
elif [ "${AVELREN_DIAGNOSTICS_SELF_TEST_CHILD:-}" = pass ]; then
  diagnostics_set_test_id diagnostics-self-test
  begin_case diagnostics-self-test
  pass_case diagnostics-self-test
  exit 0
fi

begin_case static-contract
for script in scripts/backup/postgres-backup.sh scripts/backup/postgres-restore-drill.sh scripts/backup/postgres-backup-init.sh scripts/backup/postgres-backup-repo-check.sh scripts/backup/postgres-backup-prune.sh; do
  script_id="${script##*/}"
  script_id="${script_id%.sh}"
  assert_command_succeeds "${script_id}-executable" test -x "$root/$script"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  assert_contains "$root/$script" '. "$script_dir/restic-password-file.sh"' "${script_id}-password-validator-sourced"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  assert_contains "$root/$script" 'validate_restic_password_file "$password_file"' "${script_id}-password-validator-called"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  assert_contains "$root/$script" '. "$script_dir/restic-repository.sh"' "${script_id}-repository-validator-sourced"
  # These are literal source-code assertions.
  # shellcheck disable=SC2016
  assert_contains "$root/$script" 'configure_restic_repository "$repo"' "${script_id}-repository-validator-called"
done
for support_file in restic-password-file.sh restic-repository.sh postgres-tcp-dump.sh postgres-backup-control.sh; do
  support_id="${support_file%.sh}"
  assert_command_succeeds "${support_id}-readable" test -r "$root/scripts/backup/$support_file"
done
assert_contains "$root/scripts/backup/postgres-backup.sh" '14 * 1024 * 1024 * 1024' hard-limit-contract
assert_contains "$root/scripts/backup/postgres-backup-prune.sh" 'keep-daily 7' daily-retention-contract
assert_contains "$root/scripts/backup/postgres-backup-prune.sh" 'keep-weekly 4' weekly-retention-contract
assert_contains "$root/scripts/backup/postgres-backup-prune.sh" 'keep-monthly 3' monthly-retention-contract
restore_drop_status=0
if grep -Eq 'dbname[ =]+avelren.*(dropdb|DROP DATABASE)' "$root/scripts/backup/postgres-restore-drill.sh" 2>/dev/null; then
  restore_drop_status=0
else
  restore_drop_status=$?
fi
assert_status 1 "$restore_drop_status" restore-drop-guard
pass_case static-contract

if [ "$(id -u)" -ne 0 ]; then
  begin_case runtime-nonroot-guard
  nonroot_log="$(mktemp "${RUNNER_TEMP:-/tmp}/avelren-backup-nonroot.XXXXXX")"
  nonroot_status=0
  if env AVELREN_RCLONE_REMOTE=test "$root/scripts/backup/postgres-backup.sh" >"$nonroot_log" 2>&1; then
    nonroot_status=0
  else
    nonroot_status=$?
  fi
  nonroot_marker_status=0
  if grep -Fq 'This backup must run as root.' "$nonroot_log" 2>/dev/null; then
    nonroot_marker_status=0
  else
    nonroot_marker_status=$?
  fi
  diagnostics_set_assertion nonroot-log-cleanup
  rm -f -- "$nonroot_log"
  assert_nonzero_status "$nonroot_status" nonroot-status
  assert_status 0 "$nonroot_marker_status" nonroot-diagnostic
  pass_case runtime-nonroot-guard
else
  skip_case runtime-nonroot-guard already-root
fi

if [ "$(id -u)" -ne 0 ] && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; }; then
  skip_case runtime-root-runner root-runner-unavailable
  skip_remaining_cases root-runner-unavailable
  printf '%s\n' 'Runtime failure-path tests skipped: root runner is unavailable.'
  exit 0
fi

begin_case runtime-root-runner
pass_case runtime-root-runner

disposable_base="${RUNNER_TEMP:-/tmp}"
test_root=
log_root=
fake_bin=
backup_tmp=
safe_disposable_path() {
  case "$1" in
    "$disposable_base"/avelren-backup-test.*|"$disposable_base"/avelren-backup-capture.*)
      [ -n "$1" ] && [ "$1" != / ] && [ "$1" != "$HOME" ] && [ ! -L "$1" ] && [ -d "$1" ]
      ;;
    *) return 1 ;;
  esac
}
cleanup() {
  local primary_status=$? cleanup_failed=0 cleanup_state=pass final_status finish_status=0
  trap - EXIT ERR TERM
  set +e
  if [ "$primary_status" -ne 0 ] && ! diagnostics_has_failure; then
    diagnostics_record_failure "$primary_status" "$LINENO" untrapped-exit status 0 "$primary_status"
  fi
  begin_case harness-cleanup
  if [ -n "$test_root" ]; then
    if safe_disposable_path "$test_root"; then
      if [ "$(id -u)" -eq 0 ]; then rm -rf -- "$test_root"; else sudo -n rm -rf -- "$test_root"; fi
      [ ! -e "$test_root" ] && [ ! -L "$test_root" ] || cleanup_failed=1
    else
      cleanup_failed=1
    fi
  fi
  if [ -n "$log_root" ]; then
    if safe_disposable_path "$log_root"; then
      if [ "$(id -u)" -eq 0 ]; then rm -rf -- "$log_root"; else sudo -n rm -rf -- "$log_root"; fi
      [ ! -e "$log_root" ] && [ ! -L "$log_root" ] || cleanup_failed=1
    else
      cleanup_failed=1
    fi
  fi
  if [ "$cleanup_failed" -eq 0 ]; then
    pass_case harness-cleanup
  else
    cleanup_state=fail
    if ! diagnostics_has_failure; then
      diagnostics_set_assertion cleanup-state
      diagnostics_record_failure 1 "$LINENO" cleanup-state assertion pass failed
    else
      diagnostics_close_failed_cleanup
    fi
  fi
  diagnostics_finish "$primary_status" "$cleanup_state" || finish_status=$?
  final_status="$primary_status"
  if [ "$final_status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then final_status=1; fi
  if [ "$final_status" -eq 0 ] && [ "$finish_status" -ne 0 ]; then final_status="$finish_status"; fi
  exit "$final_status"
}
trap cleanup EXIT

begin_case harness-setup
test_root="$(mktemp -d "$disposable_base/avelren-backup-test.XXXXXX")"
log_root="$(mktemp -d "$disposable_base/avelren-backup-capture.XXXXXX")"
diagnostics_set_test_id "$test_root"
fake_bin="$test_root/bin"
backup_tmp="$test_root/backup-tmp"
mkdir -p "$fake_bin" "$backup_tmp"
chmod 700 "$test_root" "$log_root" "$backup_tmp"

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -eu
args="$*"
case "$args" in
  *'ps -q postgres'*) printf '%s\n' fake-postgres ;;
  *State.Health.Status*) printf '%s\n' healthy ;;
  *HostConfig.Tmpfs*) printf '%s\n' "${FAKE_TMPFS_OPTIONS:-rw,noexec,nosuid,nodev,mode=0700,uid=0,gid=0}" ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- /run/avelren-backup'*)
    cat >/dev/null
    exit "${FAKE_EFFECTIVE_TMPFS_STATUS:-0}"
    ;;
  *'exec --user 0 fake-postgres sh -eu -c'*postgres.dump*)
    if [ "${FAKE_STREAM_FAIL:-0}" = 1 ]; then
      printf '%s\n' partial-dump
      printf '%s\n' 'Injected PostgreSQL dump stream failure.' >&2
      exit 79
    fi
    printf '%s\n' fake-custom-format-dump
    ;;
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
printf '%s\n' "${1:-missing}" >>"$FAKE_RESTIC_CALLS"
case "${1:-}" in
  snapshots) exit 0 ;;
  backup)
    dump="${!#}"
    stat -c '%u:%g:%a' "$dump" >"$FAKE_DUMP_MODE"
    if [ "${FAKE_RESTIC_FAIL:-0}" = 1 ]; then
      printf '%s\n' 'Injected Restic backup failure.' >&2
      exit 42
    fi
    exit 0
    ;;
  restore) target=''; previous=''; for arg in "$@"; do [ "$previous" = --target ] && target="$arg"; previous="$arg"; done; printf '%s\n' fake-dump >"$target/restored.dump" ;;
  *) exit 0 ;;
esac
FAKE_RESTIC

cat >"$fake_bin/pg_restore" <<'FAKE_PG_RESTORE'
#!/usr/bin/env bash
exit 0
FAKE_PG_RESTORE
cat >"$fake_bin/date" <<'FAKE_DATE'
#!/usr/bin/env bash
set -eu
if [ "$*" = '-u +%Y%m%dT%H%M%SZ' ]; then
  printf '%s\n' "${FAKE_DATE_VALUE:-20000101T000000Z}"
else
  exec /bin/date "$@"
fi
FAKE_DATE
cat >"$fake_bin/mktemp" <<'FAKE_MKTEMP'
#!/usr/bin/env bash
set -eu
if [ -n "${FAKE_FIXED_TMPDIR:-}" ] && [ "${1:-}" = -d ]; then
  printf '%s\n' "$FAKE_FIXED_TMPDIR"
else
  exec /usr/bin/mktemp "$@"
fi
FAKE_MKTEMP
cat >"$fake_bin/chmod" <<'FAKE_CHMOD'
#!/usr/bin/env bash
set -eu
target="${!#}"
if [ "${FAKE_TMPDIR_CHMOD_FAIL:-0}" = 1 ] && [ -n "${FAKE_FIXED_TMPDIR:-}" ] && [ "$target" = "$FAKE_FIXED_TMPDIR" ]; then
  printf '%s\n' 'Injected temporary directory chmod failure.' >&2
  exit 71
fi
exec /usr/bin/chmod "$@"
FAKE_CHMOD
cat >"$fake_bin/stat" <<'FAKE_STAT'
#!/usr/bin/env bash
set -eu
target="${!#}"
if [ "${FAKE_DUMP_STAT_FAIL:-0}" = 1 ] && [[ "$target" == *avelren-20000101T000000Z.dump ]]; then
  printf '%s\n' 'Injected host dump stat failure.' >&2
  exit 72
fi
if [ "${FAKE_DUMP_IDENTITY_MISMATCH:-0}" = 1 ] && [[ "$target" == /proc/*/fd/* ]]; then
  printf '%s\n' 'Injected host dump identity mismatch.' >&2
  printf '%s\n' '0:0:1:0:0:600'
  exit 0
fi
exec /usr/bin/stat "$@"
FAKE_STAT
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
restic_calls="$test_root/restic-calls"
touch "$rclone_calls" "$restic_repositories" "$restic_calls"
root_env=("PATH=$fake_bin:$PATH" "AVELREN_ENV_FILE=$test_root/env" "AVELREN_COMPOSE_FILE=$test_root/compose.yml" "AVELREN_BACKUP_TMP_ROOT=$backup_tmp" "AVELREN_BACKUP_LOCK_FILE=$test_root/backup.lock" "AVELREN_RCLONE_REMOTE=test-remote" "AVELREN_RESTIC_PASSWORD_FILE=$password" "AVELREN_RCLONE_CONFIG=$config" "FAKE_DB_CREATED=$log_root/db-created" "FAKE_DB_DROPPED=$log_root/db-dropped" "FAKE_RCLONE_CALLS=$rclone_calls" "FAKE_RESTIC_REPOSITORIES=$restic_repositories" "FAKE_RESTIC_CALLS=$restic_calls" "FAKE_COLLISION_PROOF=$log_root/collision-proof")
root_env+=("FAKE_DOCKER_STATE=$test_root/docker-state")
root_env+=("FAKE_DUMP_MODE=$log_root/dump-mode")
runner=()
[ "$(id -u)" -eq 0 ] || runner=(sudo)
pass_case harness-setup

begin_case password-validator
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
  diagnostics_set_assertion "password-mode-$1-fixture"
  "${runner[@]}" chmod "$1" "$validator_fixture"
  diagnostics_set_assertion "password-mode-$1-accepted"
  run_validator "$validator_fixture"
}
expect_validator_fail() {
  diagnostics_set_assertion "password-mode-$1-fixture"
  "${runner[@]}" chmod "$1" "$validator_fixture"
  if run_validator "$validator_fixture" >/dev/null 2>&1; then
    fail_case "password-mode-$1-rejected" rejected accepted
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
  fail_case password-owner-rejected rejected accepted
fi
"${runner[@]}" chown root:root "$validator_fixture"
empty_fixture="$test_root/empty-password"
"${runner[@]}" touch "$empty_fixture"
"${runner[@]}" chown root:root "$empty_fixture"
"${runner[@]}" chmod 400 "$empty_fixture"
if run_validator "$empty_fixture" >/dev/null 2>&1; then
  fail_case empty-password-rejected rejected accepted
fi
symlink_fixture="$test_root/symlink-password"
"${runner[@]}" ln -s "$validator_fixture" "$symlink_fixture"
if run_validator "$symlink_fixture" >/dev/null 2>&1; then
  fail_case symlink-password-rejected rejected accepted
fi
pass_case password-validator

begin_case repository-validator
repository_validator="$root/scripts/backup/restic-repository.sh"
run_repository_validator() {
  # Expansion belongs to the isolated bash process.
  # shellcheck disable=SC2016
  env VALIDATOR="$repository_validator" REPOSITORY="$1" bash -c '. "$VALIDATOR"; configure_restic_repository "$REPOSITORY"; test "$RESTIC_REPOSITORY_URL" = "rclone:test-remote:Avelren Backups/restic"; test "$RCLONE_REPOSITORY_PATH" = "test-remote:Avelren Backups/restic"'
}
diagnostics_set_assertion valid-repository-accepted
run_repository_validator 'rclone:test-remote:Avelren Backups/restic'
invalid_repository_specs=(
  'scheme|s3:test-remote:Avelren Backups/restic'
  'double-prefix|rclone:rclone:test-remote:Avelren Backups/restic'
  'missing-remote|rclone::Avelren Backups/restic'
  'missing-path|rclone:test-remote:'
)
for invalid_repository_spec in "${invalid_repository_specs[@]}"; do
  invalid_repository_id="${invalid_repository_spec%%|*}"
  invalid_repository="${invalid_repository_spec#*|}"
  if run_repository_validator "$invalid_repository" >/dev/null 2>&1; then fail_case "repository-$invalid_repository_id-rejected" rejected accepted; fi
done
if run_repository_validator $'rclone:test-remote:Avelren Backups/restic\ninvalid' >/dev/null 2>&1; then fail_case newline-repository-rejected rejected accepted; fi
if run_repository_validator $'rclone:test-remote:Avelren Backups/restic\tinvalid' >/dev/null 2>&1; then fail_case tab-repository-rejected rejected accepted; fi
pass_case repository-validator

assert_backup_tmp_empty() {
  local output='' status=0
  diagnostics_set_assertion "$1"
  if output="$("${runner[@]}" find "$backup_tmp" -mindepth 1 -print -quit)"; then
    status=0
  else
    status=$?
  fi
  assert_status 0 "$status" "$1-find-status"
  if [ -n "$output" ]; then fail_case "$1" empty entries-present; fi
}
assert_runner_file_absent() {
  local path="$1" assertion="$2" status=0
  # Positional expansion belongs to the isolated root-capable bash process.
  # shellcheck disable=SC2016
  if "${runner[@]}" bash -c 'if [ -e "$1" ] || [ -L "$1" ]; then exit 1; fi' _ "$path"; then
    status=0
  else
    status=$?
  fi
  assert_status 0 "$status" "$assertion"
}
capture_is_runner_readable() { [ -r "$log_root" ] && [ -x "$log_root" ] && [ -f "$1" ] && [ -r "$1" ]; }

begin_case helper-entrypoints
printf '%s\n' 'test' >"$test_root/env"
printf '%s\n' 'test' >"$test_root/compose.yml"

diagnostics_set_assertion backup-init-success
"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-init.sh" >/dev/null
diagnostics_set_assertion repository-check-success
"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-repo-check.sh" >/dev/null
diagnostics_set_assertion prune-success
"${runner[@]}" env "${root_env[@]}" "$root/scripts/backup/postgres-backup-prune.sh" >/dev/null
assert_contains_exact_line "$rclone_calls" 'lsd test-remote:' init-routing
assert_contains_exact_line "$rclone_calls" 'lsf test-remote:Avelren Backups' repository-routing
assert_contains_exact_line "$rclone_calls" 'size --json test-remote:Avelren Backups/restic' size-routing
assert_not_contains "$rclone_calls" 'rclone:test-remote:' rclone-url-not-forwarded
unexpected_repository_status=0
if grep -Fvxq 'rclone:test-remote:Avelren Backups/restic' "$restic_repositories" 2>/dev/null; then
  unexpected_repository_status=0
else
  unexpected_repository_status=$?
fi
assert_status 1 "$unexpected_repository_status" restic-repository-routing
pass_case helper-entrypoints

below_warning=$((12 * 1024 * 1024 * 1024 - 1))
at_warning=$((12 * 1024 * 1024 * 1024))
at_hard_stop=$((14 * 1024 * 1024 * 1024))

assert_tmpfs_rejected() {
  local case_id="$1" case_name="$2" expected_message="$3"
  shift 3
  begin_case "$case_id"
  "${runner[@]}" rm -f "$test_root/docker-state"
  local status=0
  if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" "$@" \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/tmpfs-$case_name.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_nonzero_status "$status" tmpfs-rejection-status
  assert_contains "$log_root/tmpfs-$case_name.log" "$expected_message" tmpfs-rejection-diagnostic
  assert_runner_file_absent "$test_root/docker-state" operation-not-created
  assert_backup_tmp_empty tmpfs-rejection-cleanup
  assert_not_contains "$log_root/tmpfs-$case_name.log" fixture-password secret-absent
  pass_case "$case_id"
}

# Required declared tokens are order-independent and harmless additions remain
# compatible, but each missing, deceptive, malformed, or contradictory value
# must fail before operation creation.
begin_case tmpfs-reordered
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
  FAKE_TMPFS_OPTIONS='gid=0,size=16m,nodev,rw,mode=0700,noexec,uid=0,nosuid' \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/tmpfs-reordered.log" 2>&1
assert_backup_tmp_empty tmpfs-reordered-cleanup
pass_case tmpfs-reordered

begin_case tmpfs-canonical-mode
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
  FAKE_TMPFS_OPTIONS='rw,noexec,nosuid,nodev,mode=700,uid=0,gid=0,size=16m' \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/tmpfs-canonical-mode.log" 2>&1
assert_backup_tmp_empty tmpfs-canonical-cleanup
pass_case tmpfs-canonical-mode

for missing_option in noexec nosuid nodev; do
  options='rw,noexec,nosuid,nodev,mode=0700,uid=0,gid=0'
  options="${options//$missing_option,/}"
  assert_tmpfs_rejected "tmpfs-missing-$missing_option" "missing-$missing_option" 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
    "FAKE_TMPFS_OPTIONS=$options"
done
assert_tmpfs_rejected tmpfs-wrong-mode wrong-mode 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec,nosuid,nodev,mode=07000,uid=0,gid=0'
assert_tmpfs_rejected tmpfs-wrong-uid wrong-uid 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec,nosuid,nodev,mode=0700,uid=1,gid=0'
assert_tmpfs_rejected tmpfs-wrong-gid wrong-gid 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec,nosuid,nodev,mode=0700,uid=0,gid=1'
assert_tmpfs_rejected tmpfs-deceptive-substring deceptive-substring 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec,nosuid,nodev,mode=07000,uid=00,gid=00'
assert_tmpfs_rejected tmpfs-contradictory-exec contradictory-exec 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec,exec,nosuid,nodev,mode=0700,uid=0,gid=0'
assert_tmpfs_rejected tmpfs-malformed-boolean malformed-boolean 'PostgreSQL backup runtime tmpfs configuration is unsafe.' \
  'FAKE_TMPFS_OPTIONS=rw,noexec=1,nosuid,nodev,mode=0700,uid=0,gid=0'
assert_tmpfs_rejected tmpfs-effective-not-tmpfs effective-not-tmpfs 'PostgreSQL backup runtime effective tmpfs mount is unsafe.' \
  'FAKE_EFFECTIVE_TMPFS_STATUS=1'

# The historical non-empty HostConfig check accepts the missing-noexec case;
# retain this proof so the negative matrix cannot silently regress to it.
begin_case historical-nonempty
legacy_backup="$test_root/legacy-postgres-backup.sh"
history_file="$log_root/history-list"
legacy_probe="$log_root/legacy-probe"
legacy_ref=
history_status=0
if git -C "$root" rev-list HEAD >"$history_file"; then
  history_status=0
else
  history_status=$?
fi
assert_status 0 "$history_status" history-list
while read -r candidate; do
  if git -C "$root" show "$candidate:scripts/backup/postgres-backup.sh" >"$legacy_probe" 2>/dev/null \
      && grep -Fq 'PostgreSQL backup runtime is not tmpfs-backed.' "$legacy_probe" 2>/dev/null; then
    legacy_ref="$candidate"
    break
  fi
done <"$history_file"
assert_nonempty "$legacy_ref" legacy-fixture-found
legacy_materialize_status=0
if git -C "$root" show "$legacy_ref:scripts/backup/postgres-backup.sh" >"$legacy_probe"; then
  legacy_materialize_status=0
else
  legacy_materialize_status=$?
fi
assert_status 0 "$legacy_materialize_status" legacy-fixture-materialized
assert_command_succeeds legacy-fixture-copied "${runner[@]}" cp "$legacy_probe" "$legacy_backup"
"${runner[@]}" cp "$root/scripts/backup/restic-password-file.sh" "$root/scripts/backup/restic-repository.sh" \
  "$root/scripts/backup/postgres-tcp-dump.sh" "$root/scripts/backup/postgres-backup-control.sh" "$test_root/"
"${runner[@]}" chmod 700 "$legacy_backup"
diagnostics_set_assertion legacy-backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
  FAKE_TMPFS_OPTIONS='rw,nosuid,nodev,mode=0700,uid=0,gid=0' \
  "$legacy_backup" >"$log_root/legacy-nonempty-only.log" 2>&1
assert_contains "$log_root/legacy-nonempty-only.log" 'PostgreSQL backup completed.' legacy-backup-completed
assert_backup_tmp_empty legacy-backup-cleanup
pass_case historical-nonempty

run_noclobber_probe() {
  local target="$1" stderr_file="$2" status=0
  # Expansion belongs to the isolated probe shell.
  # shellcheck disable=SC2016
  if timeout --signal=TERM --kill-after=1s 2s bash -c \
      'set -o noclobber; exec {probe_fd}>"$1"' sh "$target" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  printf '%s' "$status"
}

trace_open_line() {
  local target="$1" trace_file="$2" stderr_file="$3" status=0
  # Expansion belongs to the isolated probe shell.
  # shellcheck disable=SC2016
  if timeout --signal=TERM --kill-after=1s 2s strace -qq -f -e trace=openat,openat2 -o "$trace_file" \
      bash -c 'set -o noclobber; exec {probe_fd}>"$1"' sh "$target" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$status"
  grep -E 'openat2?\([^,]+, ".*probe-(symlink|absent)"' "$trace_file" | tail -n 1
}

begin_case host-redirection-classification
probe_root="$test_root/redirection-probe"
probe_stderr="$log_root/redirection-probe.stderr"
probe_trace="$test_root/redirection-probe.strace"
mkdir -m 700 "$probe_root"
assert_command_succeeds strace-available command -v strace

ln -s /dev/null "$probe_root/probe-symlink"
mapfile -t trace_result < <(trace_open_line "$probe_root/probe-symlink" "$probe_trace" "$probe_stderr")
assert_status 1 "${trace_result[0]}" symlink-dev-null-status
assert_nonempty "${trace_result[1]:-}" symlink-dev-null-openat
assert_contains "$probe_trace" 'O_CREAT' symlink-used-o-creat
assert_not_contains "$probe_trace" 'O_EXCL' symlink-used-o-excl
assert_not_contains "$probe_trace" 'O_NOFOLLOW' symlink-used-o-nofollow
assert_not_contains "$probe_trace" 'O_TRUNC' symlink-used-o-trunc
if [[ "${trace_result[1]}" =~ =[[:space:]]+[0-9]+([[:space:]]|$) ]]; then
  target_opened=yes
else
  target_opened=no
fi
[ "$target_opened" = yes ] || fail_case symlink-target-opened accepted rejected
printf '%s\n' 'classification case=host-existing-symlink exit-status=1 marker-id=fd-opened-before-path-rejection path-before=symlink symlink-target=character-device path-after=symlink fd-opened-before-validation=yes target-mutated=no cleanup-status=pending'
rm -f -- "$probe_root/probe-symlink" "$probe_trace" "$probe_stderr"

printf '%s' sentinel-content >"$probe_root/sentinel"
sentinel_before="$(sha256sum "$probe_root/sentinel" | awk '{print $1}')"
ln -s "$probe_root/sentinel" "$probe_root/probe-symlink"
probe_status="$(run_noclobber_probe "$probe_root/probe-symlink" "$probe_stderr")"
assert_status 1 "$probe_status" symlink-regular-status
sentinel_after="$(sha256sum "$probe_root/sentinel" | awk '{print $1}')"
[ "$sentinel_before" = "$sentinel_after" ] || fail_case symlink-regular-sentinel accepted rejected
rm -f -- "$probe_root/probe-symlink" "$probe_root/sentinel" "$probe_stderr"

ln -s "$probe_root/dangling-target" "$probe_root/probe-symlink"
probe_status="$(run_noclobber_probe "$probe_root/probe-symlink" "$probe_stderr")"
assert_status 1 "$probe_status" dangling-symlink-status
assert_file_exists "$probe_root/dangling-target" dangling-symlink-target-created
rm -f -- "$probe_root/probe-symlink" "$probe_root/dangling-target" "$probe_stderr"

mkfifo "$probe_root/probe-fifo"
ln -s "$probe_root/probe-fifo" "$probe_root/probe-symlink"
probe_status="$(run_noclobber_probe "$probe_root/probe-symlink" "$probe_stderr")"
assert_status 124 "$probe_status" symlink-fifo-bounded-timeout
rm -f -- "$probe_root/probe-symlink" "$probe_root/probe-fifo" "$probe_stderr"

printf '%s' regular-content >"$probe_root/probe-regular"
regular_before="$(sha256sum "$probe_root/probe-regular" | awk '{print $1}')"
probe_status="$(run_noclobber_probe "$probe_root/probe-regular" "$probe_stderr")"
assert_status 1 "$probe_status" existing-regular-status
regular_after="$(sha256sum "$probe_root/probe-regular" | awk '{print $1}')"
[ "$regular_before" = "$regular_after" ] || fail_case existing-regular-sentinel accepted rejected
rm -f -- "$probe_root/probe-regular" "$probe_stderr"

mkdir "$probe_root/probe-directory"
probe_status="$(run_noclobber_probe "$probe_root/probe-directory" "$probe_stderr")"
assert_status 1 "$probe_status" existing-directory-status
rmdir "$probe_root/probe-directory"
rm -f -- "$probe_stderr"

mapfile -t trace_result < <(trace_open_line "$probe_root/probe-absent" "$probe_trace" "$probe_stderr")
assert_status 0 "${trace_result[0]}" absent-path-status
assert_nonempty "${trace_result[1]:-}" absent-path-openat
assert_contains "$probe_trace" 'O_CREAT' absent-path-used-o-creat
assert_contains "$probe_trace" 'O_EXCL' absent-path-used-o-excl
assert_not_contains "$probe_trace" 'O_NOFOLLOW' absent-path-used-o-nofollow
assert_not_contains "$probe_trace" 'O_TRUNC' absent-path-used-o-trunc
rm -f -- "$probe_root/probe-absent" "$probe_trace" "$probe_stderr"
rmdir "$probe_root"
printf '%s\n' 'classification case=host-redirection-classification used-o-creat=yes used-o-excl-existing-symlink=no used-o-excl-absent-path=yes used-o-nofollow=no used-o-trunc=no followed-symlink=yes target-opened=yes cleanup-status=pass'
pass_case host-redirection-classification

assert_host_dump_rejected() {
  local case_name="$1" case_id status=0 path_before target_type=other target_mutated=no
  local fixed_tmp="$backup_tmp/fixed-$case_name"
  local target="$fixed_tmp/avelren-20000101T000000Z.dump"
  local external_target="$test_root/host-target-$case_name"
  local trace_file="$test_root/host-$case_name.strace"
  local backup_calls_before backup_calls_after sentinel_before='' sentinel_after=''
  case "$case_name" in
    symlink) case_id=host-existing-symlink ;;
    symlink-regular) case_id=host-existing-symlink-regular ;;
    dangling-symlink) case_id=host-existing-dangling-symlink ;;
    symlink-fifo) case_id=host-existing-symlink-fifo ;;
    fifo|directory|regular) case_id="host-existing-$case_name" ;;
    *) fail_case host-fixture-kind known unknown ;;
  esac
  begin_case "$case_id"
  "${runner[@]}" mkdir -m 700 "$fixed_tmp"
  case "$case_name" in
    symlink)
      "${runner[@]}" ln -s /dev/null "$target"
      path_before=symlink
      target_type=character-device
      ;;
    symlink-regular)
      printf '%s' sentinel-content >"$external_target"
      sentinel_before="$(sha256sum "$external_target" | awk '{print $1}')"
      "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=regular
      ;;
    dangling-symlink)
      "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=missing
      ;;
    symlink-fifo)
      mkfifo "$external_target"
      "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=fifo
      ;;
    fifo)
      "${runner[@]}" mkfifo "$target"
      path_before=fifo
      ;;
    directory)
      "${runner[@]}" mkdir "$target"
      path_before=directory
      ;;
    regular)
      "${runner[@]}" touch "$target"
      "${runner[@]}" chmod 600 "$target"
      path_before=regular
      ;;
  esac
  if [ "$path_before" = symlink ]; then
    assert_command_succeeds host-fixture-symlink "${runner[@]}" test -L "$target"
  fi
  backup_calls_before="$(grep -c '^backup$' "$restic_calls" || :)"
  rm -f -- "$test_root/docker-state"
  umask 0022
  if "${runner[@]}" timeout --signal=TERM --kill-after=1s 5s strace -qq -f -e trace=openat,openat2 -o "$trace_file" \
      env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" FAKE_FIXED_TMPDIR="$fixed_tmp" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_root/host-$case_name.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  "${runner[@]}" chown "$(id -u):$(id -g)" "$trace_file"
  chmod 600 "$trace_file"
  assert_status 1 "$status" existing-host-dump-status
  assert_contains "$log_root/host-$case_name.log" 'Could not create secure host dump file.' existing-host-dump-diagnostic
  assert_not_contains "$log_root/host-$case_name.log" 'Host dump file permissions are unsafe.' existing-host-dump-branch
  assert_not_contains "$trace_file" "$target" existing-host-dump-not-opened
  backup_calls_after="$(grep -c '^backup$' "$restic_calls" || :)"
  [ "$backup_calls_before" = "$backup_calls_after" ] || fail_case existing-host-dump-restic accepted rejected
  assert_file_absent "$test_root/docker-state" existing-host-dump-operation-not-created
  assert_not_contains "$log_root/host-$case_name.log" fixture-password existing-host-dump-secret-absent
  case "$case_name" in
    symlink-regular)
      sentinel_after="$(sha256sum "$external_target" | awk '{print $1}')"
      [ "$sentinel_before" = "$sentinel_after" ] || target_mutated=yes
      ;;
    dangling-symlink) [ ! -e "$external_target" ] || target_mutated=yes ;;
    symlink-fifo) [ -p "$external_target" ] || target_mutated=yes ;;
  esac
  [ "$target_mutated" = no ] || fail_case existing-host-dump-target-mutation accepted rejected
  assert_runner_file_absent "$fixed_tmp" existing-host-dump-removed
  assert_backup_tmp_empty existing-host-dump-cleanup
  rm -f -- "$external_target" "$trace_file"
  printf 'classification case=%s exit-status=1 marker-id=create-secure-host-dump-failed path-before=%s symlink-target=%s path-after=missing fd-opened-before-validation=no target-mutated=no cleanup-status=pass\n' \
    "$case_id" "$path_before" "$target_type"
  pass_case "$case_id"
}

begin_case host-dump-mode
rm -f "$log_root/dump-mode"
umask 0022
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/explicit-dump-mode.log" 2>&1
assert_owner_mode '0:0:600' "$("${runner[@]}" cat "$log_root/dump-mode")" host-dump-owner-mode
assert_backup_tmp_empty host-dump-mode-cleanup
pass_case host-dump-mode

assert_host_dump_rejected symlink
assert_host_dump_rejected symlink-regular
assert_host_dump_rejected dangling-symlink
assert_host_dump_rejected symlink-fifo
assert_host_dump_rejected fifo
assert_host_dump_rejected directory
assert_host_dump_rejected regular

begin_case host-dump-create-failure
fixed_tmp="$backup_tmp/fixed-create-failure"
"${runner[@]}" mkdir -m 700 "$fixed_tmp"
backup_calls_before="$(grep -c '^backup$' "$restic_calls" || :)"
rm -f -- "$test_root/docker-state"
if "${runner[@]}" timeout --signal=TERM --kill-after=1s 5s env "${root_env[@]}" \
    FAKE_REPOSITORY_BYTES="$below_warning" FAKE_FIXED_TMPDIR="$fixed_tmp" \
    FAKE_DATE_VALUE='missing/20000101T000000Z' "$root/scripts/backup/postgres-backup.sh" \
    >"$log_root/host-create-failure.log" 2>&1; then
  status=0
else
  status=$?
fi
assert_status 1 "$status" host-dump-create-failure-status
assert_contains "$log_root/host-create-failure.log" 'Could not create secure host dump file.' host-dump-create-failure-marker
assert_not_contains "$log_root/host-create-failure.log" 'Host dump file permissions are unsafe.' host-dump-create-failure-branch
backup_calls_after="$(grep -c '^backup$' "$restic_calls" || :)"
[ "$backup_calls_before" = "$backup_calls_after" ] || fail_case host-dump-create-failure-restic accepted rejected
assert_file_absent "$test_root/docker-state" host-dump-create-failure-operation-not-created
assert_not_contains "$log_root/host-create-failure.log" fixture-password host-dump-create-failure-secret-absent
assert_runner_file_absent "$fixed_tmp" host-dump-create-failure-removed
assert_backup_tmp_empty host-dump-create-failure-cleanup
printf '%s\n' 'classification case=host-dump-create-failure exit-status=1 marker-id=create-secure-host-dump-failed path-before=missing symlink-target=missing path-after=missing fd-opened-before-validation=no target-mutated=no cleanup-status=pass'
pass_case host-dump-create-failure

# The atomic dump mode comes from umask plus the single noclobber open; there
# is deliberately no path-based dump chmod. Exercise tmpdir chmod, path stat,
# and path/FD identity failures, and prove that each injector was reached.
for injected_failure in FAKE_TMPDIR_CHMOD_FAIL FAKE_DUMP_STAT_FAIL FAKE_DUMP_IDENTITY_MISMATCH; do
  fixed_tmp="$backup_tmp/fixed-$injected_failure"
  case "$injected_failure" in
    FAKE_TMPDIR_CHMOD_FAIL)
      injected_case=host-tmpdir-chmod-failure
      expected_status=71
      expected_marker='Injected temporary directory chmod failure.'
      ;;
    FAKE_DUMP_STAT_FAIL)
      injected_case=host-dump-stat-failure
      expected_status=1
      expected_marker='Injected host dump stat failure.'
      ;;
    FAKE_DUMP_IDENTITY_MISMATCH)
      injected_case=host-dump-identity-mismatch
      expected_status=1
      expected_marker='Injected host dump identity mismatch.'
      ;;
    *) fail_case injected-failure-kind known unknown ;;
  esac
  begin_case "$injected_case"
  "${runner[@]}" mkdir -m 700 "$fixed_tmp"
  if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" FAKE_FIXED_TMPDIR="$fixed_tmp" "$injected_failure=1" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_root/host-$injected_failure.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_status "$expected_status" "$status" injected-failure-status
  assert_contains "$log_root/host-$injected_failure.log" "$expected_marker" injected-failure-marker
  if [ "$injected_failure" = FAKE_DUMP_STAT_FAIL ] || [ "$injected_failure" = FAKE_DUMP_IDENTITY_MISMATCH ]; then
    assert_contains "$log_root/host-$injected_failure.log" 'Host dump file permissions are unsafe.' dump-stat-diagnostic
  fi
  assert_runner_file_absent "$fixed_tmp" injected-fixture-removed
  assert_backup_tmp_empty injected-failure-cleanup
  pass_case "$injected_case"
done

begin_case host-partial-stream
partial_stream_status=0
if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" FAKE_STREAM_FAIL=1 \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/host-partial-stream.log" 2>&1; then
  partial_stream_status=0
else
  partial_stream_status=$?
fi
assert_status 79 "$partial_stream_status" partial-stream-status
assert_contains "$log_root/host-partial-stream.log" 'Injected PostgreSQL dump stream failure.' partial-stream-marker
assert_backup_tmp_empty partial-stream-cleanup
pass_case host-partial-stream

begin_case repository-below-warning
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" "$root/scripts/backup/postgres-backup.sh" >"$log_root/below-warning.log" 2>&1
assert_command_succeeds log-readable capture_is_runner_readable "$log_root/below-warning.log"
assert_not_contains "$log_root/below-warning.log" 'Warning: repository reached 12 GiB.' warning-absent
assert_backup_tmp_empty below-warning-cleanup
pass_case repository-below-warning

begin_case runtime-stale-state
stale_runtime_status=0
if "${runner[@]}" env "${root_env[@]}" FAKE_STALE_RUNTIME=1 FAKE_REPOSITORY_BYTES="$below_warning" \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/stale-runtime.log" 2>&1; then
  stale_runtime_status=0
else
  stale_runtime_status=$?
fi
assert_nonzero_status "$stale_runtime_status" stale-runtime-status
assert_contains "$log_root/stale-runtime.log" 'PostgreSQL backup runtime is unsafe or contains operation state.' stale-runtime-diagnostic
assert_backup_tmp_empty stale-runtime-cleanup
pass_case runtime-stale-state

begin_case operation-collision-retry
rm -f "$log_root/collision-proof"
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_COLLISION_ONCE=1 FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/collision.log" 2>&1
assert_command_succeeds collision-state-preserved "${runner[@]}" grep -Fxq 'existing-operation-preserved' "$log_root/collision-proof"
assert_contains "$log_root/collision.log" 'PostgreSQL backup completed.' collision-backup-completed
assert_backup_tmp_empty collision-cleanup
pass_case operation-collision-retry

begin_case repository-warning
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$at_warning" "$root/scripts/backup/postgres-backup.sh" >"$log_root/at-warning.log" 2>&1
assert_command_succeeds log-readable capture_is_runner_readable "$log_root/at-warning.log"
assert_contains "$log_root/at-warning.log" 'Warning: repository reached 12 GiB.' warning-present
assert_not_contains "$log_root/at-warning.log" 'Backup stopped: repository reached the 14 GiB hard limit.' hard-stop-absent
assert_backup_tmp_empty warning-cleanup
pass_case repository-warning

begin_case repository-hard-stop
hard_stop_status=0
if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$at_hard_stop" "$root/scripts/backup/postgres-backup.sh" >"$log_root/at-hard-stop.log" 2>&1; then
  hard_stop_status=0
else
  hard_stop_status=$?
fi
assert_nonzero_status "$hard_stop_status" hard-stop-status
assert_command_succeeds log-readable capture_is_runner_readable "$log_root/at-hard-stop.log"
assert_contains "$log_root/at-hard-stop.log" 'Backup stopped: repository reached the 14 GiB hard limit.' hard-stop-diagnostic
assert_backup_tmp_empty hard-stop-cleanup
pass_case repository-hard-stop

begin_case restic-failure
failure_status=0
if "${runner[@]}" env "${root_env[@]}" FAKE_RESTIC_FAIL=1 "$root/scripts/backup/postgres-backup.sh" >"$log_root/failure.log" 2>&1; then
  failure_status=0
else
  failure_status=$?
fi
assert_status 42 "$failure_status" restic-failure-status
assert_backup_tmp_empty restic-failure-cleanup
assert_command_succeeds log-readable capture_is_runner_readable "$log_root/failure.log"
assert_contains "$log_root/failure.log" 'Injected Restic backup failure.' restic-failure-marker
secret_scan_status=0
if grep -Eq 'fake-secret|password|token' "$log_root/below-warning.log" "$log_root/at-warning.log" "$log_root/at-hard-stop.log" "$log_root/failure.log" 2>/dev/null; then
  secret_scan_status=0
else
  secret_scan_status=$?
fi
assert_status 1 "$secret_scan_status" captured-log-secret-scan
pass_case restic-failure

begin_case restore-database-guard
restore_guard_log="$log_root/restore-guard.log"
restore_log_status=0
if : >"$restore_guard_log"; then
  restore_log_status=0
else
  restore_log_status=$?
fi
assert_status 0 "$restore_log_status" restore-log-created
assert_command_succeeds restore-log-writable test -w "$restore_guard_log"
restore_status=0
if "${runner[@]}" env "${root_env[@]}" AVELREN_PG_DATABASE=not_avelren "$root/scripts/backup/postgres-restore-drill.sh" >"$restore_guard_log" 2>&1; then
  restore_status=0
else
  restore_status=$?
fi
assert_nonzero_status "$restore_status" restore-guard-status
assert_contains "$restore_guard_log" 'Production database name must remain avelren.' restore-guard-diagnostic
assert_not_contains_ci "$restore_guard_log" 'permission denied' restore-guard-reached
assert_file_absent "$log_root/db-created" restore-database-not-created
pass_case restore-database-guard

printf '%s\n' 'PostgreSQL backup failure-path and cleanup tests passed.'
