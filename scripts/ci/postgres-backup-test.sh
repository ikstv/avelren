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
    'diagnostic-validation|intentional failure and secret redaction diagnostics are validated'
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
    'tmpfs-mountinfo-regression|exact-path mountinfo stacking and malformed records fail closed'
    'historical-nonempty|historical non-empty-only check remains proven unsafe'
    'host-redirection-classification|Bash host redirection behavior is classified'
    'host-open-status-classification|Bash dynamic FD status capture and persistence are classified'
    'host-dump-mode|host dump is root-owned mode 0600'
    'harness-ownership-isolation|root-owned production runtime stays inside dedicated leaves'
    'host-existing-symlink|pre-existing dump symlink is rejected'
    'host-existing-symlink-regular|pre-existing symlink to a regular file is rejected'
    'host-existing-dangling-symlink|pre-existing dangling symlink is rejected'
    'host-existing-symlink-fifo|pre-existing symlink to a FIFO is rejected without blocking'
    'host-existing-fifo|pre-existing dump FIFO is rejected'
    'host-existing-directory|pre-existing dump directory is rejected'
    'host-existing-regular|pre-existing dump regular file is rejected'
    'host-dump-create-failure|host dump create failure is isolated'
    'host-dump-not-directory-failure|host dump not-a-directory failure is isolated'
    'host-tmpdir-chmod-failure|temporary directory chmod failure is isolated'
    'host-dump-stat-failure|host dump stat failure is isolated'
    'host-dump-identity-mismatch|host dump path and FD identity mismatch is rejected'
    'host-partial-stream|partial dump stream is cleaned up'
    'repository-below-warning|repository below warning threshold succeeds'
    'runtime-stale-state|stale runtime state is rejected'
    'operation-collision-retry|operation collision preserves existing state'
    'setup-evidence-classification|root-owned setup evidence is classified without exposing content'
    'operation-setup-before-creation-signals|setup ownership is safe before operation creation'
    'operation-setup-window-signals|setup-window signals clean the owned operation'
    'operation-setup-after-return-signal|signal after setup return cleans the active operation'
    'operation-setup-failure-cleanup|setup failures clean only partial owned state'
    'operation-setup-collision-signal|setup collision state survives signal cleanup'
    'operation-setup-cleanup-unavailable|unavailable cleanup preserves signal status and reports risk'
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
# This is a literal source-code assertion.
# shellcheck disable=SC2016
assert_not_contains "$root/scripts/backup/postgres-backup.sh" 'if ! { :; } {dump_fd}>"$dump"' dump-open-negated-form-absent
assert_contains "$root/scripts/backup/postgres-backup.sh" 'dump_fd=' dump-fd-initialized
# This is a literal source-code assertion.
# shellcheck disable=SC2016
assert_contains "$root/scripts/backup/postgres-backup.sh" 'if { :; } {dump_fd}>"$dump"; then' dump-open-positive-condition
assert_contains "$root/scripts/backup/postgres-backup.sh" 'dump_create_status=$?' dump-open-status-captured
# This is a literal source-code assertion.
# shellcheck disable=SC2016
assert_contains "$root/scripts/backup/postgres-backup.sh" '[ "$dump_create_status" -ne 0 ] || [ -z "${dump_fd:-}" ]' dump-fd-guarded-after-open
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

begin_case diagnostic-validation
assert_command_succeeds diagnostic-intentional-failure-and-redaction \
  diagnostics_self_test "$root/scripts/ci/postgres-backup-test.sh"
pass_case diagnostic-validation

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
production_lock=
state_root=
fixture_root=
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
backup_tmp="$test_root/production-tmp"
production_lock="$test_root/production-lock"
state_root="$log_root/state"
fixture_root="$log_root/fixtures"
mkdir -p "$fake_bin" "$backup_tmp" "$production_lock" "$state_root" "$fixture_root"
chmod 700 "$test_root" "$log_root" "$backup_tmp" "$production_lock" "$state_root" "$fixture_root"
runner=()
[ "$(id -u)" -eq 0 ] || runner=(sudo)
harness_uid="$(id -u)"
harness_gid="$(id -g)"
production_uid="$("${runner[@]}" id -u)"
test_root_initial_metadata="$(stat -c '%u:%g:%a' "$test_root")"
log_root_initial_metadata="$(stat -c '%u:%g:%a' "$log_root")"
production_tmp_initial_metadata="$(stat -c '%u:%g:%a' "$backup_tmp")"
production_lock_initial_metadata="$(stat -c '%u:%g:%a' "$production_lock")"

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -eu
args="$*"
arguments=("$@")

operation_path() {
  local control="$1" operation_name
  operation_name="${control##*/}"
  case "$operation_name" in operation.*) ;; *) exit 64 ;; esac
  printf '%s/%s\n' "$FAKE_OPERATION_ROOT" "$operation_name"
}

control_argument() {
  local action="$1" offset="$2" index
  for index in "${!arguments[@]}"; do
    if [ "${arguments[$index]}" = "$action" ]; then
      printf '%s\n' "${arguments[$((index + offset))]}"
      return 0
    fi
  done
  return 64
}

wait_setup_barrier() {
  local phase="$1"
  [ "${FAKE_SETUP_BARRIER_PHASE:-}" = "$phase" ] || return 0
  printf '%s\n' "$phase" >"$FAKE_SETUP_READY"
  read -r release <"$FAKE_SETUP_RELEASE"
  [ "$release" = release ]
}

record_setup_phase() {
  local phase="$1"
  [ -n "${FAKE_SETUP_PHASE_TRACE:-}" ] || return 0
  printf '%s\n' "$phase" >>"$FAKE_SETUP_PHASE_TRACE"
}

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
    for operation in "$FAKE_OPERATION_ROOT"/operation.*; do [ ! -e "$operation" ] || exit 74; done
    ;;
  *'exec --interactive --user 0 fake-postgres sh -eu -c'*)
    cat >/dev/null
    argument_count="${#arguments[@]}"
    setup_token="${arguments[$((argument_count - 1))]}"
    control_dir="${arguments[$((argument_count - 2))]}"
    if ! [[ "$setup_token" =~ ^[a-f0-9]{32}$ && "${control_dir##*/}" == operation.* ]]; then
      # Historical fixtures intentionally exercise the pre-token setup
      # protocol; keep that negative proof independent from current hooks.
      printf '%s\n' starting >"$FAKE_DOCKER_STATE"
      exit 0
    fi
    record_setup_phase setup-entered
    operation="$(operation_path "$control_dir")"
    printf '%s\n' "${control_dir##*/}" >"${FAKE_SETUP_CONTROL_FILE:-/dev/null}"
    if [ "${FAKE_SETUP_FAIL:-}" = before ]; then exit 75; fi
    if [ "${FAKE_COLLISION_SIGNAL:-0}" = 1 ]; then
      mkdir -m 700 -- "$operation"
      record_setup_phase operation-directory-created
      if [ "${setup_token:0:1}" = 0 ]; then foreign_token="1${setup_token:1}"; else foreign_token="0${setup_token:1}"; fi
      printf '%s\n' "$foreign_token" >"$operation/.setup-owner"
      chmod 600 "$operation/.setup-owner"
      record_setup_phase setup-owner-written
      printf '%s\n' 'existing-operation-preserved' >"$FAKE_COLLISION_PROOF"
      wait_setup_barrier collision
      exit 73
    fi
    if [ "${FAKE_COLLISION_ONCE:-0}" = 1 ] && [ ! -e "$FAKE_COLLISION_PROOF" ]; then
      printf '%s\n' 'existing-operation-preserved' >"$FAKE_COLLISION_PROOF"
      exit 73
    fi
    wait_setup_barrier before-creation
    [ "${FAKE_SETUP_BARRIER_PHASE:-}" != before-creation ] || exit 75
    mkdir -m 700 -- "$operation"
    record_setup_phase operation-directory-created
    printf '%s\n' "$setup_token" >"$operation/.setup-owner"
    chmod 600 "$operation/.setup-owner"
    record_setup_phase setup-owner-written
    printf '%s\n' runner >"$operation/runner.sh"
    printf '%s\n' heartbeat >"$operation/heartbeat"
    wait_setup_barrier after-creation
    [ "${FAKE_SETUP_FAIL:-}" != after ] || exit 76
    printf '%s\n' starting >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --detach --user 0 '*'-env AVELREN_BACKUP_OPERATION_ID='*)
    printf '%s\n' reached >"${FAKE_DETACHED_REACHED:-/dev/null}"
    wait_setup_barrier before-detached
    printf '%s\n' done:0 >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- heartbeat '*) cat >/dev/null ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- state '*)
    cat >/dev/null
    cat "$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- cleanup '*)
    cat >/dev/null
    control_dir="$(control_argument cleanup 1)"
    operation="$(operation_path "$control_dir")"
    rm -rf -- "$operation"
    printf '%s\n' missing >"$FAKE_DOCKER_STATE"
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- cleanup-owned '*)
    cat >/dev/null
    record_setup_phase cleanup-owned-entered
    [ "${FAKE_CLEANUP_UNAVAILABLE:-0}" = 0 ] || exit 69
    control_dir="$(control_argument cleanup-owned 1)"
    setup_token="$(control_argument cleanup-owned 3)"
    operation="$(operation_path "$control_dir")"
    if [ ! -e "$operation" ]; then
      record_setup_phase cleanup-owned-success
      exit 0
    fi
    if [ -f "$operation/.setup-owner" ] && [ "$(cat "$operation/.setup-owner")" = "$setup_token" ]; then
      rm -rf -- "$operation"
      printf '%s\n' cleaned >>"$FAKE_SETUP_CLEANUP_TRACE"
      record_setup_phase cleanup-owned-success
      exit 0
    fi
    printf '%s\n' preserved >>"$FAKE_SETUP_CLEANUP_TRACE"
    exit 67
    ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- signal '*) cat >/dev/null ;;
  *'exec --interactive --user 0 fake-postgres sh -s -- role-state '*) cat >/dev/null; printf '%s\n' stopped ;;
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
if [ -n "${FAKE_DUMP_FD_STAT_PROOF:-}" ] && [[ "$target" == /proc/*/fd/* ]]; then
  printf '%s\n' reached >"$FAKE_DUMP_FD_STAT_PROOF"
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
rclone_calls="$state_root/rclone-calls"
restic_repositories="$state_root/restic-repositories"
restic_calls="$state_root/restic-calls"
docker_state="$state_root/docker-state"
dump_mode="$state_root/dump-mode"
operation_root="$state_root/operations"
setup_control_file="$state_root/setup-control"
setup_cleanup_trace="$state_root/setup-cleanup-trace"
setup_phase_trace="$state_root/setup-phase-trace"
detached_reached="$state_root/detached-reached"
mkdir -m 700 "$operation_root"
touch "$rclone_calls" "$restic_repositories" "$restic_calls"
root_env=("PATH=$fake_bin:$PATH" "AVELREN_ENV_FILE=$test_root/env" "AVELREN_COMPOSE_FILE=$test_root/compose.yml" "AVELREN_BACKUP_TMP_ROOT=$backup_tmp" "AVELREN_BACKUP_LOCK_FILE=$production_lock/backup.lock" "AVELREN_RCLONE_REMOTE=test-remote" "AVELREN_RESTIC_PASSWORD_FILE=$password" "AVELREN_RCLONE_CONFIG=$config" "FAKE_DB_CREATED=$state_root/db-created" "FAKE_DB_DROPPED=$state_root/db-dropped" "FAKE_RCLONE_CALLS=$rclone_calls" "FAKE_RESTIC_REPOSITORIES=$restic_repositories" "FAKE_RESTIC_CALLS=$restic_calls" "FAKE_COLLISION_PROOF=$state_root/collision-proof")
root_env+=("FAKE_DOCKER_STATE=$docker_state")
root_env+=("FAKE_DUMP_MODE=$dump_mode")
root_env+=("FAKE_OPERATION_ROOT=$operation_root" "FAKE_SETUP_CONTROL_FILE=$setup_control_file" "FAKE_SETUP_CLEANUP_TRACE=$setup_cleanup_trace" "FAKE_DETACHED_REACHED=$detached_reached")
signal_launcher="$test_root/signal-launch.py"
cat >"$signal_launcher" <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys

pid_file = os.environ["AVELREN_TEST_OUTER_PID_FILE"]
descriptor = os.open(pid_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
PY
chmod 755 "$signal_launcher"
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
remove_runner_or_root_fixture() {
  local path="$1" assertion="$2" status=0
  diagnostics_set_assertion "$assertion"
  if "${runner[@]}" rm -f -- "$path"; then
    status=0
  else
    status=$?
  fi
  assert_status 0 "$status" "$assertion"
  assert_runner_file_absent "$path" "$assertion-absent"
}
reset_docker_state() {
  remove_runner_or_root_fixture "$docker_state" hostile-docker-state-reset
}
remove_test_operation_directory() {
  local path="$1" assertion="$2" operation_name operation_identifier status=0
  operation_name="${path##*/}"
  operation_identifier="${operation_name#operation.}"
  diagnostics_set_assertion "$assertion"
  [ "${path%/*}" = "$operation_root" ] || fail_case "$assertion-scope" exact-path outside-root
  case "$operation_name" in operation.*) ;; *) fail_case "$assertion-name" valid invalid ;; esac
  case "$operation_identifier" in ''|*[!a-f0-9]*) fail_case "$assertion-identifier" valid invalid ;; esac
  [ "${#operation_identifier}" -eq 32 ] || fail_case "$assertion-length" 32 "${#operation_identifier}"
  if "${runner[@]}" rm -rf -- "$path"; then status=0; else status=$?; fi
  assert_status 0 "$status" "$assertion"
  assert_runner_file_absent "$path" "$assertion-absent"
}
assert_operation_root_empty() {
  local assertion="$1" output status=0
  diagnostics_set_assertion "$assertion-find"
  if output="$("${runner[@]}" find "$operation_root" -mindepth 1 -maxdepth 1 -print -quit)"; then status=0; else status=$?; fi
  assert_status 0 "$status" "$assertion-find-status"
  [ -z "$output" ] || fail_case "$assertion" empty entries-present
}
wait_for_root_file() {
  local path="$1" process_id="$2"
  for _ in $(seq 1 200); do
    "${runner[@]}" test -e "$path" && return 0
    kill -0 "$process_id" 2>/dev/null || return 1
    sleep 0.025
  done
  return 1
}
wait_for_wrapper_exit() {
  local process_id="$1" deadline=$((SECONDS + 15))
  while kill -0 "$process_id" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}
reset_setup_signal_fixtures() {
  local suffix="$1"
  remove_runner_or_root_fixture "$setup_control_file" "$suffix-control-reset"
  remove_runner_or_root_fixture "$setup_cleanup_trace" "$suffix-cleanup-trace-reset"
  remove_runner_or_root_fixture "$setup_phase_trace" "$suffix-phase-trace-reset"
  remove_runner_or_root_fixture "$detached_reached" "$suffix-detached-reset"
}
initialize_setup_evidence() {
  local label="$1"
  diagnostics_set_assertion "$label-evidence-create"
  : >"$setup_cleanup_trace"
  : >"$setup_phase_trace"
  chmod 600 "$setup_cleanup_trace" "$setup_phase_trace"
  setup_evidence_identity_before="$(stat -c '%d:%i' -- "$setup_cleanup_trace")"
}
inspect_marker_evidence() {
  local path="$1" marker="$2" label="$3" created_before_signal="$4"
  local identity_before="$5" primary_status="$6" cleanup_result="$7" operation_final="$8"
  local parent="${path%/*}" path_exists=no path_type=missing parent_exists=no
  local parent_traversal_user=no parent_traversal_root=no file_readable_user=no file_readable_root=no
  local file_metadata='unavailable:unavailable:unavailable:unavailable'
  local parent_metadata='unavailable:unavailable:unavailable' identity_after=unavailable replaced=unknown
  local user_grep_status=2 root_grep_status=2 classification=unknown marker_root=no

  if "${runner[@]}" test -e "$parent" && ! "${runner[@]}" test -L "$parent"; then parent_exists=yes; fi
  [ -x "$parent" ] && parent_traversal_user=yes
  if "${runner[@]}" test -x "$parent"; then parent_traversal_root=yes; fi
  if parent_metadata="$("${runner[@]}" stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)"; then :; else parent_metadata='unavailable:unavailable:unavailable'; fi

  if "${runner[@]}" test -L "$path"; then
    path_exists=yes
    path_type=symlink
  elif "${runner[@]}" test -f "$path"; then
    path_exists=yes
    path_type=regular
  elif "${runner[@]}" test -d "$path"; then
    path_exists=yes
    path_type=directory
  elif "${runner[@]}" test -e "$path"; then
    path_exists=yes
    path_type=other
  fi

  if [ "$path_exists" = yes ]; then
    if file_metadata="$("${runner[@]}" stat -c '%u:%g:%a:%s' -- "$path" 2>/dev/null)"; then :; else file_metadata='unavailable:unavailable:unavailable:unavailable'; fi
    if identity_after="$("${runner[@]}" stat -c '%d:%i' -- "$path" 2>/dev/null)"; then
      if [ "$identity_after" = "$identity_before" ]; then replaced=no; else replaced=yes; fi
    fi
    [ -r "$path" ] && file_readable_user=yes
    if "${runner[@]}" test -r "$path"; then file_readable_root=yes; fi
  fi

  if [ "$path_type" = regular ]; then
    if grep -Fxq -- "$marker" "$path" 2>/dev/null; then user_grep_status=0; else user_grep_status=$?; fi
    if "${runner[@]}" grep -Fxq -- "$marker" "$path" 2>/dev/null; then root_grep_status=0; else root_grep_status=$?; fi
  fi
  [ "$root_grep_status" -eq 0 ] && marker_root=yes

  if [ "$path_exists" = no ]; then
    if [ "$identity_before" = unavailable ]; then
      classification='evidence-file-missing'
    else
      classification='evidence-removed-before-assertion'
    fi
  elif [ "$parent_traversal_user" = no ]; then
    classification='evidence-parent-not-traversable'
  elif [ "$path_type" != regular ]; then
    classification='grep-error'
  elif [ "$root_grep_status" -eq 0 ] && [ "$user_grep_status" -eq 2 ] && [ "${file_metadata%%:*}" = 0 ]; then
    classification='marker-present-root-only'
  elif [ "$user_grep_status" -eq 2 ] && [ "${file_metadata%%:*}" = 0 ]; then
    classification='evidence-root-owned'
  elif [ "$user_grep_status" -eq 2 ]; then
    classification='evidence-file-not-readable'
  elif [ "$root_grep_status" -eq 1 ]; then
    classification='marker-absent'
  elif [ "$root_grep_status" -gt 1 ]; then
    classification='grep-error'
  fi

  marker_evidence_classification="$classification"
  marker_evidence_user_grep_status="$user_grep_status"
  marker_evidence_root_grep_status="$root_grep_status"
  marker_evidence_file_metadata="$file_metadata"
  marker_evidence_parent_metadata="$parent_metadata"
  printf 'evidence case=%s classification=%s exists=%s type=%s parent-exists=%s parent-traversal-user=%s parent-traversal-root=%s file-readable-user=%s file-readable-root=%s file-metadata=%s parent-metadata=%s size=%s grep-user=%s grep-root=%s created-before-signal=%s replaced=%s marker-root=%s primary-status=%s cleanup-owned=%s operation-final=%s\n' \
    "$label" "$classification" "$path_exists" "$path_type" "$parent_exists" "$parent_traversal_user" \
    "$parent_traversal_root" "$file_readable_user" "$file_readable_root" "$file_metadata" "$parent_metadata" \
    "${file_metadata##*:}" "$user_grep_status" "$root_grep_status" "$created_before_signal" "$replaced" \
    "$marker_root" "$primary_status" "$cleanup_result" "$operation_final"
}
assert_marker_evidence() {
  local path="$1" marker="$2" label="$3" expected="$4" created_before_signal="$5"
  local identity_before="$6" primary_status="$7" cleanup_result="$8" operation_final="$9"
  inspect_marker_evidence "$path" "$marker" "$label" "$created_before_signal" "$identity_before" \
    "$primary_status" "$cleanup_result" "$operation_final"
  case "$expected:$marker_evidence_root_grep_status" in
    present:0|absent:1) return 0 ;;
    present:1) fail_case "$label" marker-present marker-absent ;;
    absent:0) fail_case "$label" marker-absent marker-present ;;
    *) fail_case "$label" marker-status "$marker_evidence_classification" ;;
  esac
}
assert_setup_phase_sequence() {
  local label="$1" actual expected
  shift
  diagnostics_set_assertion "$label"
  actual="$(<"$setup_phase_trace")"
  expected="$(printf '%s\n' "$@")"
  [ "$actual" = "$expected" ] || fail_case "$label" exact-sequence mismatch
}
assert_harness_root_ownership() {
  local suffix="$1" test_metadata log_metadata
  diagnostics_set_assertion "harness-test-root-stat-$suffix"
  test_metadata="$(stat -c '%u:%g:%a' "$test_root")"
  diagnostics_set_assertion "harness-log-root-stat-$suffix"
  log_metadata="$(stat -c '%u:%g:%a' "$log_root")"
  assert_owner_mode "$harness_uid:$harness_gid:700" "$test_metadata" "harness-test-root-ownership-$suffix"
  assert_owner_mode "$harness_uid:$harness_gid:700" "$log_metadata" "harness-log-root-ownership-$suffix"
}
assert_production_directory_ownership() {
  local suffix="$1" tmp_metadata lock_metadata
  diagnostics_set_assertion "production-tmp-stat-$suffix"
  tmp_metadata="$("${runner[@]}" stat -c '%u:%g:%a' "$backup_tmp")"
  diagnostics_set_assertion "production-lock-stat-$suffix"
  lock_metadata="$("${runner[@]}" stat -c '%u:%g:%a' "$production_lock")"
  assert_owner_mode '0:0:700' "$tmp_metadata" "production-tmp-ownership-$suffix"
  assert_owner_mode '0:0:700' "$lock_metadata" "production-lock-ownership-$suffix"
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
  reset_docker_state
  local status=0
  if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" "$@" \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/tmpfs-$case_name.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_nonzero_status "$status" tmpfs-rejection-status
  assert_contains "$log_root/tmpfs-$case_name.log" "$expected_message" tmpfs-rejection-diagnostic
  assert_runner_file_absent "$docker_state" operation-not-created
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

begin_case tmpfs-mountinfo-regression
mountinfo_target=/run/avelren-backup
mountinfo_root="$fixture_root/mountinfo-parser"
assert_command_succeeds mountinfo-fixture-root-create mkdir -m 700 "$mountinfo_root"

valid_mount='101 1 0:42 / /run/avelren-backup rw,noexec,nosuid,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0'
second_valid_mount='104 1 0:44 / /run/avelren-backup rw,noexec,nosuid,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0'
ext4_mount='102 1 8:1 / /run/avelren-backup rw,noexec,nosuid,nodev - ext4 /dev/sda1 rw'
missing_noexec_mount='103 1 0:43 / /run/avelren-backup rw,nosuid,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0'

write_mountinfo_fixture() {
  case "$1" in
    single-valid) printf '%s\n' "$valid_mount" ;;
    single-ext4) printf '%s\n' "$ext4_mount" ;;
    valid-then-ext4) printf '%s\n%s\n' "$valid_mount" "$ext4_mount" ;;
    ext4-then-valid) printf '%s\n%s\n' "$ext4_mount" "$valid_mount" ;;
    duplicate-valid) printf '%s\n%s\n' "$valid_mount" "$second_valid_mount" ;;
    valid-then-missing-noexec) printf '%s\n%s\n' "$valid_mount" "$missing_noexec_mount" ;;
    similar-path) printf '%s\n' '105 1 0:45 / /run/avelren-backup-extra rw,noexec,nosuid,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0' ;;
    nested-path) printf '%s\n' '106 1 0:46 / /run/avelren-backup/nested rw,noexec,nosuid,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0' ;;
    missing-rw) printf '%s\n' '107 1 0:47 / /run/avelren-backup ro,noexec,nosuid,nodev - tmpfs tmpfs ro,size=16777216,mode=700,uid=0,gid=0' ;;
    missing-noexec) printf '%s\n' "$missing_noexec_mount" ;;
    missing-nosuid) printf '%s\n' '109 1 0:49 / /run/avelren-backup rw,noexec,nodev - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0' ;;
    missing-nodev) printf '%s\n' '110 1 0:50 / /run/avelren-backup rw,noexec,nosuid - tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0' ;;
    malformed-separator) printf '%s\n' '111 1 0:51 / /run/avelren-backup rw,noexec,nosuid,nodev -- tmpfs tmpfs rw,size=16777216,mode=700,uid=0,gid=0' ;;
    malformed-filesystem) printf '%s\n' '112 1 0:52 / /run/avelren-backup rw,noexec,nosuid,nodev -' ;;
    *) return 64 ;;
  esac
}

mountinfo_cases=(
  'single-valid:0'
  'single-ext4:1'
  'valid-then-ext4:1'
  'ext4-then-valid:1'
  'duplicate-valid:1'
  'valid-then-missing-noexec:1'
  'similar-path:1'
  'nested-path:1'
  'missing-rw:1'
  'missing-noexec:1'
  'missing-nosuid:1'
  'missing-nodev:1'
  'malformed-separator:1'
  'malformed-filesystem:1'
)

for mountinfo_spec in "${mountinfo_cases[@]}"; do
  mountinfo_case="${mountinfo_spec%%:*}"
  diagnostics_set_assertion "mountinfo-$mountinfo_case-fixture-create"
  write_mountinfo_fixture "$mountinfo_case" >"$mountinfo_root/$mountinfo_case.mountinfo"
done

legacy_mountinfo_status=0
if awk -v target="$mountinfo_target" '
    function has(options, expected,  count, item) {
      count = split(options, item, ",")
      for (i = 1; i <= count; i++) if (item[i] == expected) return 1
      return 0
    }
    $5 == target {
      dash = 0
      for (i = 7; i <= NF; i++) if ($i == "-") { dash = i; break }
      if (!dash || dash == NF || $(dash + 1) != "tmpfs") exit 1
      if (!has($6, "rw") || !has($6, "noexec") || !has($6, "nosuid") || !has($6, "nodev")) exit 1
      found++
    }
    END { exit found == 1 ? 0 : 1 }
  ' "$mountinfo_root/valid-then-ext4.mountinfo"; then
  legacy_mountinfo_status=0
else
  legacy_mountinfo_status=$?
fi
printf 'mountinfo-parser implementation=historical case=valid-then-ext4 contract-status=1 actual-status=%s result=DEFECT-REPRODUCED\n' \
  "$legacy_mountinfo_status"
assert_status 0 "$legacy_mountinfo_status" historical-stacked-mount-fail-open

extract_mountinfo_parser() {
  local source="$1" destination="$2"
  awk '
    /^[[:space:]]*# AVELREN_TMPFS_MOUNTINFO_AWK_BEGIN$/ {
      if (capture || begin_count) exit 2
      capture = 1
      begin_count++
      next
    }
    /^[[:space:]]*# AVELREN_TMPFS_MOUNTINFO_AWK_END$/ {
      if (!capture || end_count) exit 3
      capture = 0
      end_count++
      next
    }
    capture { print }
    END { if (capture || begin_count != 1 || end_count != 1) exit 4 }
  ' "$source" >"$destination"
}

for mountinfo_implementation in \
    "production:$root/scripts/backup/postgres-backup.sh" \
    "smoke:$root/scripts/ci/production-compose-smoke.sh"; do
  implementation_name="${mountinfo_implementation%%:*}"
  implementation_source="${mountinfo_implementation#*:}"
  implementation_parser="$mountinfo_root/$implementation_name.awk"
  assert_command_succeeds "mountinfo-$implementation_name-parser-extract" \
    extract_mountinfo_parser "$implementation_source" "$implementation_parser"
  assert_command_succeeds "mountinfo-$implementation_name-parser-nonempty" test -s "$implementation_parser"
  assert_not_contains "$implementation_parser" 'exit 1' "mountinfo-$implementation_name-no-early-exit"
  assert_contains "$implementation_parser" \
    'END { exit found == 1 && invalid == 0 ? 0 : 1 }' \
    "mountinfo-$implementation_name-found-invalid-contract"

  for mountinfo_spec in "${mountinfo_cases[@]}"; do
    mountinfo_case="${mountinfo_spec%%:*}"
    expected_mountinfo_status="${mountinfo_spec#*:}"
    actual_mountinfo_status=0
    if awk -v target="$mountinfo_target" -f "$implementation_parser" \
        "$mountinfo_root/$mountinfo_case.mountinfo"; then
      actual_mountinfo_status=0
    else
      actual_mountinfo_status=$?
    fi
    if [ "$actual_mountinfo_status" -eq "$expected_mountinfo_status" ]; then
      mountinfo_result=PASS
    else
      mountinfo_result=FAIL
    fi
    printf 'mountinfo-parser implementation=%s case=%s expected-status=%s actual-status=%s result=%s\n' \
      "$implementation_name" "$mountinfo_case" "$expected_mountinfo_status" "$actual_mountinfo_status" "$mountinfo_result"
    assert_status "$expected_mountinfo_status" "$actual_mountinfo_status" \
      "mountinfo-$implementation_name-$mountinfo_case-status"
  done
done

diagnostics_set_assertion mountinfo-fixture-cleanup
rm -rf -- "$mountinfo_root"
assert_file_absent "$mountinfo_root" mountinfo-fixture-removed
pass_case tmpfs-mountinfo-regression

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
probe_root="$log_root/redirection-probe"
probe_stderr="$probe_root/probe.stderr"
probe_trace="$probe_root/probe.strace"
mkdir -m 700 "$probe_root"
assert_command_succeeds strace-available command -v strace

ln -s /dev/null "$probe_root/probe-symlink"
mapfile -t trace_result < <(trace_open_line "$probe_root/probe-symlink" "$probe_trace" "$probe_stderr")
assert_status 0 "${trace_result[0]}" symlink-dev-null-status
symlink_trace_line="${trace_result[1]:-}"
assert_nonempty "$symlink_trace_line" symlink-dev-null-openat
[[ "$symlink_trace_line" == *O_CREAT* ]] || fail_case symlink-used-o-creat accepted rejected
[[ "$symlink_trace_line" != *O_EXCL* ]] || fail_case symlink-used-o-excl rejected accepted
[[ "$symlink_trace_line" != *O_NOFOLLOW* ]] || fail_case symlink-used-o-nofollow rejected accepted
[[ "$symlink_trace_line" != *O_TRUNC* ]] || fail_case symlink-used-o-trunc rejected accepted
if [[ "$symlink_trace_line" =~ =[[:space:]]+[0-9]+([[:space:]]|$) ]]; then
  target_opened=yes
else
  target_opened=no
fi
[ "$target_opened" = yes ] || fail_case symlink-target-opened accepted rejected
assert_command_succeeds symlink-fixture-preserved test -L "$probe_root/probe-symlink"
assert_command_succeeds symlink-target-character-device test -c /dev/null
rm -f -- "$probe_root/probe-symlink" "$probe_trace" "$probe_stderr"

mapfile -t trace_result < <(trace_open_line "$probe_root/probe-absent" "$probe_trace" "$probe_stderr")
assert_status 0 "${trace_result[0]}" absent-path-status
absent_trace_line="${trace_result[1]:-}"
assert_nonempty "$absent_trace_line" absent-path-openat
[[ "$absent_trace_line" == *O_CREAT* ]] || fail_case absent-path-used-o-creat accepted rejected
[[ "$absent_trace_line" == *O_EXCL* ]] || fail_case absent-path-used-o-excl accepted rejected
[[ "$absent_trace_line" != *O_NOFOLLOW* ]] || fail_case absent-path-used-o-nofollow rejected accepted
[[ "$absent_trace_line" != *O_TRUNC* ]] || fail_case absent-path-used-o-trunc rejected accepted
[[ "$absent_trace_line" =~ =[[:space:]]+[0-9]+([[:space:]]|$) ]] || fail_case absent-path-target-opened accepted rejected
assert_file_exists "$probe_root/probe-absent" absent-path-regular-file-created
rm -f -- "$probe_root/probe-absent" "$probe_trace" "$probe_stderr"
rmdir "$probe_root"
assert_file_absent "$probe_root" redirection-probe-cleanup
printf '%s\n' 'classification case=host-existing-symlink exit-status=0 marker-id=fd-opened-before-path-rejection path-before=symlink symlink-target=character-device path-after=symlink fd-opened-before-validation=yes target-mutated=no used-o-creat=yes used-o-excl=no used-o-nofollow=no used-o-trunc=no cleanup-status=pass'
printf '%s\n' 'classification case=host-redirection-classification absent-exit-status=0 absent-path-type=regular used-o-creat=yes used-o-excl=yes used-o-nofollow=no used-o-trunc=no cleanup-status=pass'
pass_case host-redirection-classification

begin_case host-open-status-classification
open_probe_root="$fixture_root/open-status-probe"
open_probe_failure="$open_probe_root/missing/file"
open_probe_success="$open_probe_root/success.dump"
negated_output="$log_root/open-status-negated.out"
negated_stderr="$log_root/open-status-negated.stderr"
positive_failure_output="$log_root/open-status-positive-failure.out"
positive_failure_stderr="$log_root/open-status-positive-failure.stderr"
positive_success_output="$log_root/open-status-positive-success.out"
positive_success_stderr="$log_root/open-status-positive-success.stderr"
assert_runner_file_absent "$open_probe_root" open-status-probe-absent
assert_command_succeeds open-status-probe-create mkdir -m 700 "$open_probe_root"

# The negated form is retained only as a regression proof of the historical
# status-masking behavior. Positional expansion belongs to the isolated shell.
# shellcheck disable=SC2016
assert_command_succeeds negated-open-probe "${runner[@]}" bash -Eeuo pipefail -c '
  path="$1"
  fd=
  marker=no
  set -o noclobber
  if ! { :; } {fd}>"$path"; then
    marker=yes
    set +o noclobber
  fi
  status=$?
  assigned=no
  [ -n "${fd:-}" ] && assigned=yes
  created=no
  [ -e "$path" ] && created=yes
  restored=yes
  shopt -qo noclobber && restored=no
  printf "semantics form=negated status=%s marker-reached=%s fd-assigned=%s file-created=%s noclobber-restored=%s\n" \
    "$status" "$marker" "$assigned" "$created" "$restored"
' sh "$open_probe_failure" >"$negated_output" 2>"$negated_stderr"
assert_contains_exact_line "$negated_output" \
  'semantics form=negated status=0 marker-reached=no fd-assigned=no file-created=no noclobber-restored=no' \
  negated-open-classification

# Positive status capture keeps errexit from preempting the custom branch.
# shellcheck disable=SC2016
assert_command_succeeds positive-failure-open-probe "${runner[@]}" bash -Eeuo pipefail -c '
  path="$1"
  fd=
  marker=no
  status=0
  set -o noclobber
  if { :; } {fd}>"$path"; then
    status=0
  else
    status=$?
    marker=yes
  fi
  set +o noclobber
  assigned=no
  [ -n "${fd:-}" ] && assigned=yes
  created=no
  [ -e "$path" ] && created=yes
  restored=yes
  shopt -qo noclobber && restored=no
  printf "semantics form=positive-failure status=%s marker-reached=%s fd-assigned=%s file-created=%s noclobber-restored=%s\n" \
    "$status" "$marker" "$assigned" "$created" "$restored"
' sh "$open_probe_failure" >"$positive_failure_output" 2>"$positive_failure_stderr"
assert_contains_exact_line "$positive_failure_output" \
  'semantics form=positive-failure status=1 marker-reached=yes fd-assigned=no file-created=no noclobber-restored=yes' \
  positive-failure-open-classification

# The successful probe verifies that the allocated FD remains in the same
# root shell, matches its path, streams bytes, and closes explicitly.
# shellcheck disable=SC2016
assert_command_succeeds positive-success-open-probe "${runner[@]}" bash -Eeuo pipefail -c '
  path="$1"
  fd=
  marker=no
  status=0
  umask 077
  set -o noclobber
  if { :; } {fd}>"$path"; then
    status=0
    marker=yes
  else
    status=$?
  fi
  set +o noclobber
  assigned=no
  [ -n "${fd:-}" ] && assigned=yes
  created=no
  [ -f "$path" ] && created=yes
  restored=yes
  shopt -qo noclobber && restored=no
  persisted=no
  [ -n "${fd:-}" ] && [ -e "/proc/$$/fd/$fd" ] && persisted=yes
  identity=no
  [ "$(stat -c "%d:%i" "$path")" = "$(stat -Lc "%d:%i" "/proc/$$/fd/$fd")" ] && identity=yes
  owner_mode="$(stat -c "%u:%g:%a" "$path")"
  printf %s stream-marker >&"$fd"
  fd_number="$fd"
  exec {fd}>&-
  closed=no
  [ ! -e "/proc/$$/fd/$fd_number" ] && closed=yes
  streamed=no
  grep -Fxq stream-marker "$path" && streamed=yes
  printf "semantics form=positive-success status=%s marker-reached=%s fd-assigned=%s file-created=%s noclobber-restored=%s fd-persisted=%s identity-match=%s owner-mode=%s stream-through-fd=%s fd-closed=%s\n" \
    "$status" "$marker" "$assigned" "$created" "$restored" "$persisted" "$identity" "$owner_mode" "$streamed" "$closed"
' sh "$open_probe_success" >"$positive_success_output" 2>"$positive_success_stderr"
assert_contains_exact_line "$positive_success_output" \
  'semantics form=positive-success status=0 marker-reached=yes fd-assigned=yes file-created=yes noclobber-restored=yes fd-persisted=yes identity-match=yes owner-mode=0:0:600 stream-through-fd=yes fd-closed=yes' \
  positive-success-open-classification
assert_command_succeeds positive-success-stream-preserved "${runner[@]}" grep -Fxq stream-marker "$open_probe_success"

remove_runner_or_root_fixture "$open_probe_success" open-status-success-fixture-cleanup
for probe_capture in "$negated_output" "$negated_stderr" "$positive_failure_output" "$positive_failure_stderr" "$positive_success_output" "$positive_success_stderr"; do
  remove_runner_or_root_fixture "$probe_capture" open-status-capture-cleanup
done
assert_command_succeeds open-status-probe-cleanup rmdir "$open_probe_root"
assert_runner_file_absent "$open_probe_root" open-status-probe-removed
printf '%s\n' 'classification case=host-open-status-classification negated-status=0 negated-marker=no positive-failure-status=1 positive-failure-marker=yes positive-success-status=0 positive-success-fd-persisted=yes positive-success-identity-match=yes positive-success-stream=yes positive-success-fd-closed=yes cleanup-status=pass'
pass_case host-open-status-classification

assert_host_dump_rejected() {
  local case_name="$1" case_id status=0 path_before target_type=other target_mutated=no
  local fixed_tmp="$backup_tmp/fixed-$case_name"
  local target="$fixed_tmp/avelren-20000101T000000Z.dump"
  local external_target="$fixture_root/host-target-$case_name"
  local trace_file="$fixture_root/host-$case_name.strace"
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
  assert_runner_file_absent "$fixed_tmp" host-fixture-fixed-tmp-absent
  remove_runner_or_root_fixture "$external_target" host-fixture-external-target-reset
  remove_runner_or_root_fixture "$trace_file" hostile-trace-reset
  assert_command_succeeds host-fixture-fixed-tmp-create "${runner[@]}" mkdir -m 700 "$fixed_tmp"
  case "$case_name" in
    symlink)
      assert_command_succeeds host-fixture-symlink-create "${runner[@]}" ln -s /dev/null "$target"
      path_before=symlink
      target_type=character-device
      ;;
    symlink-regular)
      # Positional expansion belongs to the isolated Bash fixture writer.
      # shellcheck disable=SC2016
      assert_command_succeeds host-fixture-sentinel-create bash -c 'printf %s sentinel-content >"$1"' _ "$external_target"
      diagnostics_set_assertion host-fixture-sentinel-checksum-before
      sentinel_before="$(sha256sum "$external_target" | awk '{print $1}')"
      assert_command_succeeds host-fixture-symlink-create "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=regular
      ;;
    dangling-symlink)
      assert_command_succeeds host-fixture-dangling-symlink-create "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=missing
      ;;
    symlink-fifo)
      assert_command_succeeds host-fixture-external-fifo-create mkfifo "$external_target"
      assert_command_succeeds host-fixture-symlink-create "${runner[@]}" ln -s "$external_target" "$target"
      path_before=symlink
      target_type=fifo
      ;;
    fifo)
      assert_command_succeeds host-fixture-fifo-create "${runner[@]}" mkfifo "$target"
      path_before=fifo
      ;;
    directory)
      assert_command_succeeds host-fixture-directory-create "${runner[@]}" mkdir "$target"
      path_before=directory
      ;;
    regular)
      assert_command_succeeds host-fixture-regular-create "${runner[@]}" touch "$target"
      assert_command_succeeds host-fixture-regular-mode "${runner[@]}" chmod 600 "$target"
      path_before=regular
      ;;
  esac
  if [ "$path_before" = symlink ]; then
    assert_command_succeeds host-fixture-symlink "${runner[@]}" test -L "$target"
  fi
  backup_calls_before="$(grep -c '^backup$' "$restic_calls" || :)"
  reset_docker_state
  assert_command_succeeds hostile-trace-create "${runner[@]}" touch "$trace_file"
  assert_command_succeeds hostile-trace-owner "${runner[@]}" chown root:root "$trace_file"
  assert_command_succeeds hostile-trace-mode "${runner[@]}" chmod 600 "$trace_file"
  umask 0022
  diagnostics_set_assertion existing-host-dump-production-command
  if "${runner[@]}" timeout --signal=TERM --kill-after=1s 5s strace -qq -f -e trace=openat,openat2 -o "$trace_file" \
      env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" FAKE_FIXED_TMPDIR="$fixed_tmp" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_root/host-$case_name.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_command_succeeds hostile-trace-runner-owner "${runner[@]}" chown "$harness_uid:$harness_gid" "$trace_file"
  assert_command_succeeds hostile-trace-runner-mode chmod 600 "$trace_file"
  assert_status 1 "$status" existing-host-dump-status
  assert_contains "$log_root/host-$case_name.log" 'Could not create secure host dump file.' existing-host-dump-diagnostic
  assert_not_contains "$log_root/host-$case_name.log" 'Host dump file permissions are unsafe.' existing-host-dump-branch
  assert_not_contains "$trace_file" "$target" existing-host-dump-not-opened
  backup_calls_after="$(grep -c '^backup$' "$restic_calls" || :)"
  [ "$backup_calls_before" = "$backup_calls_after" ] || fail_case existing-host-dump-restic accepted rejected
  assert_file_absent "$docker_state" existing-host-dump-operation-not-created
  assert_not_contains "$log_root/host-$case_name.log" fixture-password existing-host-dump-secret-absent
  case "$case_name" in
    symlink-regular)
      diagnostics_set_assertion host-fixture-sentinel-checksum-after
      sentinel_after="$(sha256sum "$external_target" | awk '{print $1}')"
      [ "$sentinel_before" = "$sentinel_after" ] || target_mutated=yes
      ;;
    dangling-symlink) [ ! -e "$external_target" ] || target_mutated=yes ;;
    symlink-fifo) [ -p "$external_target" ] || target_mutated=yes ;;
  esac
  [ "$target_mutated" = no ] || fail_case existing-host-dump-target-mutation accepted rejected
  assert_runner_file_absent "$fixed_tmp" existing-host-dump-removed
  assert_backup_tmp_empty existing-host-dump-cleanup
  remove_runner_or_root_fixture "$external_target" host-fixture-external-target-cleanup
  remove_runner_or_root_fixture "$trace_file" hostile-trace-cleanup
  printf 'classification case=%s exit-status=1 marker-id=create-secure-host-dump-failed path-before=%s symlink-target=%s path-after=missing fd-opened-before-validation=no target-mutated=no cleanup-status=pass\n' \
    "$case_id" "$path_before" "$target_type"
  pass_case "$case_id"
}

begin_case host-dump-mode
reset_docker_state
remove_runner_or_root_fixture "$dump_mode" host-dump-mode-capture-reset
diagnostics_set_assertion host-dump-mode-test-root-before-stat
test_root_before_mode="$(stat -c '%u:%g:%a' "$test_root")"
diagnostics_set_assertion host-dump-mode-log-root-before-stat
log_root_before_mode="$(stat -c '%u:%g:%a' "$log_root")"
umask 0022
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/explicit-dump-mode.log" 2>&1
assert_owner_mode '0:0:600' "$("${runner[@]}" cat "$dump_mode")" host-dump-owner-mode
assert_backup_tmp_empty host-dump-mode-cleanup
pass_case host-dump-mode

begin_case harness-ownership-isolation
assert_owner_mode "$harness_uid:$harness_gid:700" "$test_root_initial_metadata" harness-test-root-initial-ownership
assert_owner_mode "$harness_uid:$harness_gid:700" "$log_root_initial_metadata" harness-log-root-initial-ownership
assert_owner_mode "$harness_uid:$harness_gid:700" "$test_root_before_mode" harness-test-root-before-backup-ownership
assert_owner_mode "$harness_uid:$harness_gid:700" "$log_root_before_mode" harness-log-root-before-backup-ownership
assert_owner_mode '0' "$production_uid" production-invocation-euid
assert_harness_root_ownership after-backup
assert_production_directory_ownership after-backup
diagnostics_set_assertion harness-docker-state-stat-after-backup
docker_state_after_mode="$("${runner[@]}" stat -c '%u:%g:%a' "$docker_state")"
assert_command_succeeds harness-state-marker-create touch "$state_root/runner-marker"
assert_command_succeeds harness-state-marker-remove rm -f -- "$state_root/runner-marker"
assert_file_absent "$state_root/runner-marker" harness-state-marker-removed
reset_docker_state
assert_command_succeeds harness-root-state-create "${runner[@]}" install -o root -g root -m 600 /dev/null "$docker_state"
assert_owner_mode '0:0:600' "$("${runner[@]}" stat -c '%u:%g:%a' "$docker_state")" harness-root-state-ownership
reset_docker_state
diagnostics_set_assertion harness-test-root-stat-after-backup
test_root_after_mode="$(stat -c '%u:%g:%a' "$test_root")"
diagnostics_set_assertion harness-log-root-stat-after-backup
log_root_after_mode="$(stat -c '%u:%g:%a' "$log_root")"
diagnostics_set_assertion production-tmp-stat-report
production_tmp_metadata="$("${runner[@]}" stat -c '%u:%g:%a' "$backup_tmp")"
diagnostics_set_assertion production-lock-stat-report
production_lock_metadata="$("${runner[@]}" stat -c '%u:%g:%a' "$production_lock")"
printf 'ownership case=harness-ownership-isolation harness-euid=%s production-euid=%s test-root-before=%s test-root-after=%s log-root-before=%s log-root-after=%s production-tmp-before=%s production-tmp-after=%s production-lock-before=%s production-lock-after=%s docker-state-before=missing docker-state-after=%s state-reset=pass\n' \
  "$harness_uid" "$production_uid" "$test_root_before_mode" "$test_root_after_mode" "$log_root_before_mode" "$log_root_after_mode" \
  "$production_tmp_initial_metadata" "$production_tmp_metadata" "$production_lock_initial_metadata" "$production_lock_metadata" "$docker_state_after_mode"
pass_case harness-ownership-isolation

assert_host_dump_rejected symlink
assert_host_dump_rejected symlink-regular
assert_host_dump_rejected dangling-symlink
assert_host_dump_rejected symlink-fifo
assert_host_dump_rejected fifo
assert_host_dump_rejected directory
assert_host_dump_rejected regular

assert_host_dump_create_failure() {
  local case_id="$1" failure_kind="$2" fake_date fixed_tmp log_file fd_stat_proof
  local status=0 backup_calls_before backup_calls_after marker_count
  case "$failure_kind" in
    missing-parent)
      fake_date='missing/20000101T000000Z'
      ;;
    not-directory)
      fake_date='not-a-directory/20000101T000000Z'
      ;;
    *) fail_case host-dump-create-failure-kind known unknown ;;
  esac
  fixed_tmp="$backup_tmp/fixed-$case_id"
  log_file="$log_root/$case_id.log"
  fd_stat_proof="$state_root/$case_id-fd-stat"
  begin_case "$case_id"
  assert_runner_file_absent "$fixed_tmp" "$case_id-fixture-absent"
  assert_command_succeeds "$case_id-fixture-create" "${runner[@]}" mkdir -m 700 "$fixed_tmp"
  if [ "$failure_kind" = not-directory ]; then
    assert_command_succeeds "$case_id-intermediate-create" "${runner[@]}" \
      install -o root -g root -m 600 /dev/null "$fixed_tmp/avelren-not-a-directory"
    assert_command_succeeds "$case_id-intermediate-regular" "${runner[@]}" \
      test -f "$fixed_tmp/avelren-not-a-directory"
  fi
  backup_calls_before="$(grep -c '^backup$' "$restic_calls" || :)"
  reset_docker_state
  remove_runner_or_root_fixture "$fd_stat_proof" "$case_id-fd-stat-reset"
  diagnostics_set_assertion "$case_id-production-command"
  if "${runner[@]}" timeout --signal=TERM --kill-after=1s 5s env "${root_env[@]}" \
      FAKE_REPOSITORY_BYTES="$below_warning" FAKE_FIXED_TMPDIR="$fixed_tmp" \
      FAKE_DATE_VALUE="$fake_date" FAKE_DUMP_FD_STAT_PROOF="$fd_stat_proof" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_status 1 "$status" "$case_id-status"
  assert_contains "$log_file" 'Could not create secure host dump file.' "$case_id-marker"
  marker_count="$(grep -Fc 'Could not create secure host dump file.' "$log_file" || :)"
  [ "$marker_count" = 1 ] || fail_case "$case_id-marker-count" one "$marker_count"
  assert_not_contains "$log_file" 'Host dump file permissions are unsafe.' "$case_id-unsafe-branch"
  assert_not_contains "$log_file" 'unbound variable' "$case_id-unbound-variable-absent"
  assert_runner_file_absent "$fd_stat_proof" "$case_id-fd-not-used-after-failure"
  backup_calls_after="$(grep -c '^backup$' "$restic_calls" || :)"
  [ "$backup_calls_before" = "$backup_calls_after" ] || fail_case "$case_id-restic" not-started started
  assert_file_absent "$docker_state" "$case_id-operation-not-created"
  assert_not_contains "$log_file" fixture-password "$case_id-secret-absent"
  assert_runner_file_absent "$fixed_tmp" "$case_id-fixture-removed"
  assert_backup_tmp_empty "$case_id-cleanup"
  printf 'classification case=%s failure-kind=%s exit-status=1 marker-id=create-secure-host-dump-failed marker-count=1 dump-fd-used-after-failure=no operation-created=no restic-started=no cleanup-status=pass\n' \
    "$case_id" "$failure_kind"
  pass_case "$case_id"
}

assert_host_dump_create_failure host-dump-create-failure missing-parent
assert_host_dump_create_failure host-dump-not-directory-failure not-directory

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
  assert_runner_file_absent "$fixed_tmp" injected-fixture-absent
  assert_command_succeeds injected-fixture-create "${runner[@]}" mkdir -m 700 "$fixed_tmp"
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
remove_runner_or_root_fixture "$state_root/collision-proof" collision-proof-reset
diagnostics_set_assertion backup-command-success
"${runner[@]}" env "${root_env[@]}" FAKE_COLLISION_ONCE=1 FAKE_REPOSITORY_BYTES="$below_warning" \
  "$root/scripts/backup/postgres-backup.sh" >"$log_root/collision.log" 2>&1
assert_command_succeeds collision-state-preserved "${runner[@]}" grep -Fxq 'existing-operation-preserved' "$state_root/collision-proof"
assert_contains "$log_root/collision.log" 'PostgreSQL backup completed.' collision-backup-completed
assert_backup_tmp_empty collision-cleanup
pass_case operation-collision-retry

begin_case setup-evidence-classification
reset_setup_signal_fixtures setup-evidence-classification
# Expansion belongs to the isolated root-capable evidence writer.
# shellcheck disable=SC2016
assert_command_succeeds legacy-root-evidence-create "${runner[@]}" env EVIDENCE="$setup_cleanup_trace" \
  bash -c 'umask 077; printf "%s\n" cleaned >"$EVIDENCE"'
legacy_evidence_identity="$("${runner[@]}" stat -c '%d:%i' -- "$setup_cleanup_trace")"
inspect_marker_evidence "$setup_cleanup_trace" cleaned legacy-root-evidence no "$legacy_evidence_identity" \
  130 success absent
[ "$marker_evidence_classification" = marker-present-root-only ] || \
  fail_case legacy-root-evidence-classification marker-present-root-only "$marker_evidence_classification"
assert_status 2 "$marker_evidence_user_grep_status" legacy-root-evidence-user-grep
assert_status 0 "$marker_evidence_root_grep_status" legacy-root-evidence-root-grep
assert_owner_mode '0:0:600' "${marker_evidence_file_metadata%:*}" legacy-root-evidence-owner-mode
assert_owner_mode "$harness_uid:$harness_gid:700" "$marker_evidence_parent_metadata" legacy-root-evidence-parent-owner-mode
remove_runner_or_root_fixture "$setup_cleanup_trace" legacy-root-evidence-cleanup
pass_case setup-evidence-classification

run_setup_signal_case() {
  local label="$1" phase="$2" signal="$3" expected_status="$4" expected_cleanup="$5" expected_marker="$6"
  shift 6
  local ready="$state_root/setup-ready-$label" release="$state_root/setup-release-$label"
  local outer_pid_file="$state_root/setup-outer-pid-$label" log_file="$log_root/setup-signal-$label.log"
  local launch_pid outer_pid status=0 operation_name operation_path cleanup_result operation_final
  local -a expected_phases
  reset_setup_signal_fixtures "$label"
  initialize_setup_evidence "$label"
  remove_runner_or_root_fixture "$ready" "$label-ready-reset"
  remove_runner_or_root_fixture "$release" "$label-release-reset"
  remove_runner_or_root_fixture "$outer_pid_file" "$label-pid-reset"
  diagnostics_set_assertion "$label-release-create"
  mkfifo -- "$release"
  diagnostics_set_assertion "$label-backup-launch"
  "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
    FAKE_SETUP_BARRIER_PHASE="$phase" FAKE_SETUP_READY="$ready" FAKE_SETUP_RELEASE="$release" \
    FAKE_SETUP_PHASE_TRACE="$setup_phase_trace" \
    AVELREN_BACKUP_DOCKER_TIMEOUT=10 AVELREN_TEST_OUTER_PID_FILE="$outer_pid_file" "$@" \
    "$signal_launcher" "$root/scripts/backup/postgres-backup.sh" >"$log_file" 2>&1 &
  launch_pid=$!
  diagnostics_set_assertion "$label-barrier-ready"
  wait_for_root_file "$ready" "$launch_pid"
  diagnostics_set_assertion "$label-outer-pid-ready"
  wait_for_root_file "$outer_pid_file" "$launch_pid"
  operation_name="$("${runner[@]}" cat "$setup_control_file")"
  operation_path="$operation_root/$operation_name"
  last_signal_operation="$operation_path"
  case "$phase" in
    before-creation)
      assert_runner_file_absent "$operation_path" "$label-not-created-before-signal"
      assert_runner_file_absent "$detached_reached" "$label-host-not-active"
      ;;
    after-creation|collision)
      assert_command_succeeds "$label-created-before-signal" "${runner[@]}" test -d "$operation_path"
      assert_runner_file_absent "$detached_reached" "$label-host-not-active"
      ;;
    before-detached)
      assert_command_succeeds "$label-created-before-signal" "${runner[@]}" test -d "$operation_path"
      assert_command_succeeds "$label-host-active" "${runner[@]}" test -e "$detached_reached"
      ;;
    *) fail_case "$label-phase" known unknown ;;
  esac
  outer_pid="$("${runner[@]}" cat "$outer_pid_file")"
  case "$outer_pid" in ''|*[!0-9]*) fail_case "$label-outer-pid" numeric invalid ;; esac
  diagnostics_set_assertion "$label-signal-delivery"
  # Record the deterministic delivery point before the target trap can append
  # cleanup evidence concurrently. The signal-derived exit status proves receipt.
  printf '%s\n' signal-observed >>"$setup_phase_trace"
  "${runner[@]}" kill -s "$signal" "$outer_pid"
  if [ "$phase" = after-creation ] || [ "$phase" = collision ]; then
    assert_command_succeeds "$label-still-blocked-before-release" "${runner[@]}" test -d "$operation_path"
  fi
  # Positional expansion belongs to the isolated bounded Bash writer.
  # shellcheck disable=SC2016
  assert_command_succeeds "$label-barrier-release" timeout 3 bash -c 'printf "%s\n" release >"$1"' sh "$release"
  diagnostics_set_assertion "$label-outer-exit"
  wait_for_wrapper_exit "$launch_pid"
  if wait "$launch_pid"; then status=0; else status=$?; fi
  printf '%s\n' foreground-returned >>"$setup_phase_trace"
  assert_status "$expected_status" "$status" "$label-signal-status"
  case "$expected_cleanup" in
    absent)
      assert_runner_file_absent "$operation_path" "$label-operation-absent"
      cleanup_result=success
      operation_final=absent
      ;;
    cleaned)
      assert_runner_file_absent "$operation_path" "$label-operation-cleaned"
      if [ "$phase" = before-detached ]; then cleanup_result=not-invoked; else cleanup_result=success; fi
      operation_final=absent
      ;;
    preserved)
      assert_command_succeeds "$label-operation-preserved" "${runner[@]}" test -d "$operation_path"
      operation_final=present
      if [ "$expected_marker" = preserved ]; then cleanup_result=rejected; else cleanup_result=unavailable; fi
      ;;
    *) fail_case "$label-cleanup-contract" known unknown ;;
  esac
  printf '%s\n' evidence-finalized >>"$setup_phase_trace"
  printf '%s\n' assertion-started >>"$setup_phase_trace"
  if [ "$expected_marker" = none ]; then
    assert_marker_evidence "$setup_cleanup_trace" cleaned "$label-token-cleanup" absent yes \
      "$setup_evidence_identity_before" "$status" "$cleanup_result" "$operation_final"
  else
    assert_marker_evidence "$setup_cleanup_trace" "$expected_marker" "$label-token-cleanup" present yes \
      "$setup_evidence_identity_before" "$status" "$cleanup_result" "$operation_final"
  fi
  expected_phases=(setup-entered)
  case "$phase" in after-creation|collision|before-detached)
    expected_phases+=(operation-directory-created setup-owner-written)
    ;;
  esac
  expected_phases+=(signal-observed)
  if [ "$phase" != before-detached ]; then
    expected_phases+=(cleanup-owned-entered)
    [ "$cleanup_result" != success ] || expected_phases+=(cleanup-owned-success)
  fi
  expected_phases+=(foreground-returned evidence-finalized assertion-started)
  assert_setup_phase_sequence "$label-phase-sequence" "${expected_phases[@]}"
  assert_not_contains "$log_file" fixture-password "$label-secret-absent"
  remove_runner_or_root_fixture "$release" "$label-release-cleanup"
  remove_runner_or_root_fixture "$ready" "$label-ready-cleanup"
  remove_runner_or_root_fixture "$outer_pid_file" "$label-pid-cleanup"
  remove_runner_or_root_fixture "$setup_cleanup_trace" "$label-cleanup-trace-cleanup"
  remove_runner_or_root_fixture "$setup_phase_trace" "$label-phase-trace-cleanup"
  printf 'signal-setup case=%s phase=%s signal=%s exit-status=%s cleanup=%s barrier=pass\n' \
    "$label" "$phase" "$signal" "$status" "$expected_cleanup"
}

assert_next_backup_succeeds() {
  local label="$1"
  reset_docker_state
  diagnostics_set_assertion "$label-next-backup"
  "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/$label-next-backup.log" 2>&1
  assert_operation_root_empty "$label-next-backup-runtime-clean"
  assert_contains "$log_root/$label-next-backup.log" 'PostgreSQL backup completed.' "$label-next-backup-completed"
}
assert_stale_setup_blocks_next_backup() {
  local label="$1" status=0
  if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_root/$label-stale-next.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_status 1 "$status" "$label-stale-next-status"
  assert_contains "$log_root/$label-stale-next.log" \
    'PostgreSQL backup runtime is unsafe or contains operation state.' "$label-stale-next-diagnostic"
}

begin_case operation-setup-before-creation-signals
run_setup_signal_case setup-before-int before-creation INT 130 absent none
assert_next_backup_succeeds setup-before-int
run_setup_signal_case setup-before-term before-creation TERM 143 absent none
assert_next_backup_succeeds setup-before-term
pass_case operation-setup-before-creation-signals

begin_case operation-setup-window-signals
run_setup_signal_case setup-window-int after-creation INT 130 cleaned cleaned
assert_next_backup_succeeds setup-window-int
run_setup_signal_case setup-window-term after-creation TERM 143 cleaned cleaned
assert_next_backup_succeeds setup-window-term
pass_case operation-setup-window-signals

begin_case operation-setup-after-return-signal
run_setup_signal_case setup-before-detached-int before-detached INT 130 cleaned none
assert_next_backup_succeeds setup-before-detached-int
run_setup_signal_case setup-before-detached-term before-detached TERM 143 cleaned none
assert_next_backup_succeeds setup-before-detached-term
pass_case operation-setup-after-return-signal

begin_case operation-setup-failure-cleanup
for setup_failure in before after; do
  reset_setup_signal_fixtures "setup-failure-$setup_failure"
  initialize_setup_evidence "setup-failure-$setup_failure"
  setup_failure_status=0
  if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" FAKE_SETUP_FAIL="$setup_failure" \
      FAKE_SETUP_PHASE_TRACE="$setup_phase_trace" \
      "$root/scripts/backup/postgres-backup.sh" >"$log_root/setup-failure-$setup_failure.log" 2>&1; then
    setup_failure_status=0
  else
    setup_failure_status=$?
  fi
  assert_status 1 "$setup_failure_status" "setup-failure-$setup_failure-status"
  assert_contains "$log_root/setup-failure-$setup_failure.log" 'Could not create isolated PostgreSQL backup operation.' \
    "setup-failure-$setup_failure-diagnostic"
  assert_operation_root_empty "setup-failure-$setup_failure-cleanup"
  printf '%s\n' evidence-finalized >>"$setup_phase_trace"
  printf '%s\n' assertion-started >>"$setup_phase_trace"
  if [ "$setup_failure" = after ]; then
    assert_marker_evidence "$setup_cleanup_trace" cleaned setup-failure-after-token-cleanup present yes \
      "$setup_evidence_identity_before" "$setup_failure_status" success absent
    assert_setup_phase_sequence setup-failure-after-phase-sequence setup-entered operation-directory-created \
      setup-owner-written cleanup-owned-entered cleanup-owned-success evidence-finalized assertion-started
  else
    assert_marker_evidence "$setup_cleanup_trace" cleaned setup-failure-before-token-cleanup absent yes \
      "$setup_evidence_identity_before" "$setup_failure_status" success absent
    assert_setup_phase_sequence setup-failure-before-phase-sequence setup-entered cleanup-owned-entered cleanup-owned-success \
      evidence-finalized assertion-started
  fi
  remove_runner_or_root_fixture "$setup_cleanup_trace" "setup-failure-$setup_failure-cleanup-trace-cleanup"
  remove_runner_or_root_fixture "$setup_phase_trace" "setup-failure-$setup_failure-phase-trace-cleanup"
done
pass_case operation-setup-failure-cleanup

begin_case operation-setup-collision-signal
run_setup_signal_case setup-collision-term collision TERM 143 preserved preserved FAKE_COLLISION_SIGNAL=1
collision_stale_status=0
if "${runner[@]}" env "${root_env[@]}" FAKE_REPOSITORY_BYTES="$below_warning" \
    "$root/scripts/backup/postgres-backup.sh" >"$log_root/setup-collision-stale.log" 2>&1; then
  collision_stale_status=0
else
  collision_stale_status=$?
fi
assert_status 1 "$collision_stale_status" collision-next-backup-status
assert_contains "$log_root/setup-collision-stale.log" 'PostgreSQL backup runtime is unsafe or contains operation state.' collision-next-backup-stale-state
remove_test_operation_directory "$last_signal_operation" collision-operation-cleanup
pass_case operation-setup-collision-signal

begin_case operation-setup-cleanup-unavailable
run_setup_signal_case setup-cleanup-unavailable-int after-creation INT 130 preserved none FAKE_CLEANUP_UNAVAILABLE=1
assert_contains "$log_root/setup-signal-setup-cleanup-unavailable-int.log" \
  'Could not verify cleanup of PostgreSQL backup setup state.' cleanup-unavailable-diagnostic
cleanup_warning_count="$(grep -Fc 'Could not verify cleanup of PostgreSQL backup setup state.' \
  "$log_root/setup-signal-setup-cleanup-unavailable-int.log" || :)"
[ "$cleanup_warning_count" = 1 ] || fail_case cleanup-unavailable-marker-count one "$cleanup_warning_count"
assert_stale_setup_blocks_next_backup setup-cleanup-unavailable-int
remove_test_operation_directory "$last_signal_operation" cleanup-unavailable-operation-cleanup
run_setup_signal_case setup-cleanup-unavailable-term after-creation TERM 143 preserved none FAKE_CLEANUP_UNAVAILABLE=1
assert_contains "$log_root/setup-signal-setup-cleanup-unavailable-term.log" \
  'Could not verify cleanup of PostgreSQL backup setup state.' cleanup-unavailable-term-diagnostic
cleanup_term_warning_count="$(grep -Fc 'Could not verify cleanup of PostgreSQL backup setup state.' \
  "$log_root/setup-signal-setup-cleanup-unavailable-term.log" || :)"
[ "$cleanup_term_warning_count" = 1 ] || fail_case cleanup-unavailable-term-marker-count one "$cleanup_term_warning_count"
assert_stale_setup_blocks_next_backup setup-cleanup-unavailable-term
remove_test_operation_directory "$last_signal_operation" cleanup-unavailable-term-operation-cleanup
pass_case operation-setup-cleanup-unavailable

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
assert_file_absent "$state_root/db-created" restore-database-not-created
pass_case restore-database-guard

printf '%s\n' 'PostgreSQL backup failure-path and cleanup tests passed.'
