#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repository_root/scripts/backup/secure-lock-file.sh"
backup_script="$repository_root/scripts/backup/postgres-backup.sh"
restore_script="$repository_root/scripts/backup/postgres-restore-drill.sh"
backup_unit="$repository_root/deploy/systemd/avelren-postgres-backup.service"
repo_check_unit="$repository_root/deploy/systemd/avelren-postgres-repo-check.service"
documentation="$repository_root/docs/postgres-backup.md"
test_root=
active_pid=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

cleanup() {
  local status=$? cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  if [[ "${active_pid:-}" =~ ^[0-9]+$ ]]; then
    kill -TERM "$active_pid" >/dev/null 2>&1 || true
    wait "$active_pid" >/dev/null 2>&1 || true
  fi
  case "${test_root:-}" in
    /var/tmp/avelren-secure-lock-test.*)
      if [ ! -L "$test_root" ]; then
        rm -rf -- "$test_root" || cleanup_failed=1
        [ ! -e "$test_root" ] && [ ! -L "$test_root" ] || cleanup_failed=1
      else
        cleanup_failed=1
      fi
      ;;
    '') ;;
    *) cleanup_failed=1 ;;
  esac
  if [ "$cleanup_failed" -ne 0 ]; then
    printf '%s\n' 'FAIL: secure lock fixture cleanup was incomplete.' >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

[ "$(uname -s)" = Linux ] || fail 'secure lock tests require Linux'
[ "$(id -u)" -eq 0 ] || fail 'secure lock tests require root'
for command_name in bash flock realpath stat strace timeout python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
[ -r "$helper" ] || fail 'secure lock helper is unavailable'

umask 077
test_root="$(mktemp -d /var/tmp/avelren-secure-lock-test.XXXXXX)"
shared_parent="$test_root/shared-parent"
lock_directory="$shared_parent/avelren"
backup_lock="$lock_directory/postgres-backup.lock"
restore_lock="$lock_directory/postgres-restore.lock"
log_root="$test_root/logs"
fake_bin="$test_root/fake-bin"
probe="$test_root/lock-probe.sh"
mkdir -m 0755 -- "$shared_parent"
mkdir -m 0700 -- "$log_root" "$fake_bin"
chown root:root "$test_root" "$shared_parent" "$log_root" "$fake_bin"

cat >"$probe" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
. "${AVELREN_TEST_LOCK_HELPER:?}"
kind="$1"
lock_path="$2"
status=0
if avelren_secure_lock_acquire "$lock_path"; then
  status=0
else
  status=$?
fi
if [ "$status" -ne 0 ]; then
  case "$kind:$status" in
    backup:73) printf '%s\n' 'PostgreSQL backup lock directory is unsafe.' >&2 ;;
    backup:75) printf '%s\n' 'Another PostgreSQL backup is running.' >&2 ;;
    backup:*) printf '%s\n' 'PostgreSQL backup lock file is unsafe.' >&2 ;;
    restore:73) printf '%s\n' 'PostgreSQL restore lock directory is unsafe.' >&2 ;;
    restore:75) printf '%s\n' 'Another PostgreSQL restore drill is running.' >&2 ;;
    restore:*) printf '%s\n' 'PostgreSQL restore lock file is unsafe.' >&2 ;;
    *) exit 90 ;;
  esac
  exit 1
fi
[ -z "${AVELREN_TEST_STDERR_MARKER:-}" ] || printf '%s\n' "$AVELREN_TEST_STDERR_MARKER" >&2
[ -z "${AVELREN_TEST_REACHED:-}" ] || : >"$AVELREN_TEST_REACHED"
if [ -n "${AVELREN_TEST_RELEASE:-}" ]; then
  deadline=$((SECONDS + 10))
  while [ ! -e "$AVELREN_TEST_RELEASE" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 76
    sleep 0.025
  done
fi
exit "${AVELREN_TEST_POST_LOCK_STATUS:-0}"
PROBE
chmod 0700 "$probe"

cat >"$fake_bin/stat" <<'FAKE_STAT'
#!/usr/bin/env bash
set -eu
target="${!#}"
if [[ "$*" == *'%d:%i:%h:%u:%g:%a'* ]] && [[ "$target" == /proc/*/fd/* ]] &&
   [ "$(readlink -f -- "$target" 2>/dev/null || true)" = "${AVELREN_TEST_INJECT_LOCK:-}" ]; then
  if [ "${AVELREN_TEST_STAT_MODE:-}" = mismatch ] && [[ "$target" =~ ^/proc/[0-9]+/fd/[0-9]+$ ]]; then
    : >"$AVELREN_TEST_INJECTED"
    printf '%s\n' '9:9:1:0:0:600'
    exit 0
  fi
fi
exec /usr/bin/stat "$@"
FAKE_STAT
chmod 0700 "$fake_bin/stat"

cat >"$fake_bin/flock" <<'FAKE_FLOCK'
#!/usr/bin/env bash
set -eu
status=0
if /usr/bin/flock "$@"; then status=0; else status=$?; fi
if [ "$status" -eq 0 ] && [ "${AVELREN_TEST_FLOCK_REPLACE:-}" = 1 ] &&
   [ ! -e "${AVELREN_TEST_INJECTED:?}" ]; then
  /usr/bin/mv -- "${AVELREN_TEST_INJECT_LOCK:?}" "${AVELREN_TEST_QUARANTINE:?}"
  /usr/bin/install -o root -g root -m 0600 /dev/null "${AVELREN_TEST_INJECT_LOCK:?}"
  : >"$AVELREN_TEST_INJECTED"
fi
exit "$status"
FAKE_FLOCK
chmod 0700 "$fake_bin/flock"

export AVELREN_TEST_LOCK_HELPER="$helper"

run_probe() {
  local kind="$1" lock_path="$2" log="$3" status=0
  shift 3
  if timeout --signal=TERM --kill-after=1s 5s env "$@" "$probe" "$kind" "$lock_path" >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$status"
}

assert_status() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" -eq "$expected" ] || fail "$label expected status $expected, got $actual"
}

assert_exact_diagnostic() {
  local log="$1" expected="$2" label="$3" count
  count="$(grep -Fxc -- "$expected" "$log" || true)"
  [ "$count" -eq 1 ] || fail "$label expected one exact diagnostic, got $count"
}

assert_not_timed_out() {
  local status="$1" label="$2"
  case "$status" in 124|137|143) fail "$label exceeded its bounded runtime" ;; esac
}

reset_namespace() {
  rm -rf -- "$lock_directory"
}

prepare_directory() {
  reset_namespace
  mkdir -m 0700 -- "$lock_directory"
  chown root:root "$lock_directory"
}

prepare_valid_lock() {
  local path="$1" content="${2:-lock-canary}"
  prepare_directory
  printf '%s' "$content" >"$path"
  chmod 0600 "$path"
  chown root:root "$path"
}

expect_unsafe() {
  local kind="$1" path="$2" diagnostic="$3" label="$4" log status
  log="$log_root/$label.log"
  shift 4
  status="$(run_probe "$kind" "$path" "$log" "$@")"
  assert_not_timed_out "$status" "$label"
  assert_status 1 "$status" "$label"
  assert_exact_diagnostic "$log" "$diagnostic" "$label"
  if grep -Fq 'lock-secret-canary' "$log"; then fail "$label exposed fixture content"; fi
}

wait_for_file() {
  local path="$1" process_id="$2" deadline=$((SECONDS + 10))
  while [ ! -e "$path" ]; do
    kill -0 "$process_id" 2>/dev/null || return 1
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.025
  done
}

path_token_present() {
  local file="$1" directive="$2" expected="$3"
  awk -v directive="$directive" -v expected="$expected" '
    index($0, directive "=") == 1 {
      sub("^[^=]*=", "")
      for (i = 1; i <= NF; i++) if ($i == expected) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

path_token_absent() {
  ! path_token_present "$1" "$2" "$3"
}

global_lock_before=absent
if [ -e /run/lock ] && [ ! -L /run/lock ]; then
  global_lock_before="$(stat -c '%d:%i:%u:%g:%a' -- /run/lock)"
fi

grep -Fq 'lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/avelren/postgres-backup.lock}"' "$backup_script" ||
  fail 'backup default lock path is incorrect'
grep -Fq 'lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/avelren/postgres-restore.lock}"' "$restore_script" ||
  fail 'restore default lock path is incorrect'
if grep -Eq ':-/run/lock/[^/]+\.lock' "$backup_script" "$restore_script"; then
  fail 'a production default is still a direct child of /run/lock'
fi
pass lock-01-default-not-global-child

shared_metadata_before="$(stat -c '%u:%g:%a' -- "$shared_parent")"
printf '%s' 'shared-parent-sentinel' >"$shared_parent/sentinel"
chmod 0644 "$shared_parent/sentinel"
sentinel_identity_before="$(stat -c '%d:%i:%u:%g:%a:%s' -- "$shared_parent/sentinel")"
sentinel_hash_before="$(sha256sum "$shared_parent/sentinel" | awk '{print $1}')"

reset_namespace
fresh_trace="$test_root/fresh.trace"
fresh_log="$log_root/fresh.log"
fresh_reached="$test_root/fresh.reached"
fresh_status=0
if strace -f -qq -e trace=openat,openat2,chmod,fchmod,fchmodat,fchmodat2,chown,fchown,fchownat -o "$fresh_trace" env \
    AVELREN_TEST_LOCK_HELPER="$helper" AVELREN_TEST_REACHED="$fresh_reached" \
    "$probe" backup "$backup_lock" >"$fresh_log" 2>&1; then
  fresh_status=0
else
  fresh_status=$?
fi
assert_status 0 "$fresh_status" fresh-lock
[ -e "$fresh_reached" ] || fail 'fresh lock did not reach the protected operation'
[ -d "$lock_directory" ] && [ ! -L "$lock_directory" ] || fail 'fresh namespace is not a directory'
[ "$(stat -c '%u:%g:%a' "$lock_directory")" = '0:0:700' ] || fail 'fresh namespace metadata is unsafe'
[ -f "$backup_lock" ] && [ ! -L "$backup_lock" ] || fail 'fresh lock is not regular'
[ "$(stat -c '%h:%u:%g:%a' "$backup_lock")" = '1:0:0:600' ] || fail 'fresh lock metadata is unsafe'
fresh_open_lines="$(grep -F 'postgres-backup.lock' "$fresh_trace" | grep -F 'O_CREAT' || true)"
fresh_open_count="$(printf '%s\n' "$fresh_open_lines" | grep -c . || true)"
[ "$fresh_open_count" -eq 1 ] || fail 'fresh lock was not created exactly once'
printf '%s\n' "$fresh_open_lines" | grep -Fq 'O_EXCL' || fail 'fresh lock creation omitted O_EXCL'
if printf '%s\n' "$fresh_open_lines" | grep -Fq 'O_TRUNC'; then fail 'fresh lock creation used O_TRUNC'; fi
[ "$(stat -c '%u:%g:%a' "$shared_parent")" = "$shared_metadata_before" ] || fail 'shared parent metadata changed'
[ "$(stat -c '%d:%i:%u:%g:%a:%s' "$shared_parent/sentinel")" = "$sentinel_identity_before" ] || fail 'shared sentinel metadata changed'
[ "$(sha256sum "$shared_parent/sentinel" | awk '{print $1}')" = "$sentinel_hash_before" ] || fail 'shared sentinel content changed'
if grep -Eq '(f?chmod(at2?)?|f?chown(at)?)\(' "$fresh_trace"; then
  fail 'fresh setup issued an unexpected metadata syscall'
fi
global_lock_after_fresh=absent
if [ -e /run/lock ] && [ ! -L /run/lock ]; then
  global_lock_after_fresh="$(stat -c '%d:%i:%u:%g:%a' -- /run/lock)"
fi
[ "$global_lock_after_fresh" = "$global_lock_before" ] || fail 'fresh setup changed real /run/lock metadata'
rm -f -- "$fresh_trace" "$fresh_reached"
pass lock-02-global-parent-not-mutated
pass lock-03-shared-parent-metadata-preserved
pass lock-04-shared-parent-sentinel-preserved
pass lock-05-shared-parent-mode-preserved
pass lock-06-fresh-directory-secure
pass lock-13-fresh-lock-secure

existing_directory_identity="$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")"
status="$(run_probe backup "$backup_lock" "$log_root/existing-directory.log" AVELREN_TEST_STDERR_MARKER=lock-stderr-preserved)"
assert_status 0 "$status" existing-directory
assert_exact_diagnostic "$log_root/existing-directory.log" lock-stderr-preserved existing-directory-stderr
[ "$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")" = "$existing_directory_identity" ] || fail 'existing secure directory was rewritten'
pass lock-07-existing-directory-accepted

reset_namespace
mkdir -m 0700 "$test_root/directory-target"
printf '%s' 'directory-target-sentinel' >"$test_root/directory-target/sentinel"
target_hash="$(sha256sum "$test_root/directory-target/sentinel" | awk '{print $1}')"
ln -s "$test_root/directory-target" "$lock_directory"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock directory is unsafe.' directory-symlink
[ -L "$lock_directory" ] || fail 'directory symlink was replaced'
[ "$(sha256sum "$test_root/directory-target/sentinel" | awk '{print $1}')" = "$target_hash" ] || fail 'directory symlink target changed'
pass lock-08-directory-symlink-rejected

mkdir -m 0755 "$test_root/ancestor-target"
ln -s "$test_root/ancestor-target" "$test_root/ancestor-link"
ancestor_lock="$test_root/ancestor-link/avelren/postgres-backup.lock"
expect_unsafe backup "$ancestor_lock" 'PostgreSQL backup lock directory is unsafe.' directory-ancestor-symlink
[ ! -e "$test_root/ancestor-target/avelren" ] && [ ! -L "$test_root/ancestor-target/avelren" ] ||
  fail 'namespace was created through an intermediate symlink'
pass lock-08b-ancestor-symlink-rejected

reset_namespace
printf '%s' 'foreign-directory-object' >"$lock_directory"
directory_file_hash="$(sha256sum "$lock_directory" | awk '{print $1}')"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock directory is unsafe.' directory-regular
[ "$(sha256sum "$lock_directory" | awk '{print $1}')" = "$directory_file_hash" ] || fail 'directory regular object changed'
pass lock-09-directory-regular-rejected

reset_namespace
mkdir -m 0700 "$lock_directory"
chown 65534:65534 "$lock_directory"
wrong_owner_before="$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock directory is unsafe.' directory-owner
[ "$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")" = "$wrong_owner_before" ] || fail 'wrong-owner directory was repaired'
pass lock-10-directory-owner-rejected

reset_namespace
mkdir -m 0755 "$lock_directory"
chown root:root "$lock_directory"
wrong_mode_before="$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock directory is unsafe.' directory-mode
[ "$(stat -c '%d:%i:%u:%g:%a' "$lock_directory")" = "$wrong_mode_before" ] || fail 'wrong-mode directory was repaired'
pass lock-11-directory-mode-rejected
pass lock-12-directory-failure-preserves-object

prepare_valid_lock "$backup_lock" 'existing-lock-canary'
valid_identity_before="$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$backup_lock")"
valid_hash_before="$(sha256sum "$backup_lock" | awk '{print $1}')"
existing_trace="$test_root/existing.trace"
status=0
if strace -f -qq -e trace=openat,openat2,chmod,fchmod,fchmodat,fchmodat2,chown,fchown,fchownat -o "$existing_trace" \
    env AVELREN_TEST_LOCK_HELPER="$helper" \
    "$probe" backup "$backup_lock" >"$log_root/existing-lock.log" 2>&1; then status=0; else status=$?; fi
assert_status 0 "$status" existing-lock
[ "$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$backup_lock")" = "$valid_identity_before" ] || fail 'existing valid lock metadata changed'
[ "$(sha256sum "$backup_lock" | awk '{print $1}')" = "$valid_hash_before" ] || fail 'existing valid lock was truncated'
if grep -Eq '(f?chmod(at2?)?|f?chown(at)?)\(' "$existing_trace"; then
  fail 'existing secure directory received an unnecessary metadata syscall'
fi
if grep -F 'postgres-backup.lock' "$existing_trace" | grep -Fq 'O_TRUNC'; then fail 'existing valid lock open used O_TRUNC'; fi
rm -f -- "$existing_trace"
pass lock-14-existing-lock-accepted
pass lock-15-existing-lock-not-truncated

prepare_directory
printf '%s' 'lock-secret-canary' >"$test_root/symlink-target"
chmod 0600 "$test_root/symlink-target"
target_identity_before="$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$test_root/symlink-target")"
target_hash="$(sha256sum "$test_root/symlink-target" | awk '{print $1}')"
ln -s "$test_root/symlink-target" "$backup_lock"
symlink_lock_log="$log_root/lock-symlink.log"
symlink_lock_trace="$test_root/lock-symlink.trace"
symlink_lock_status=0
if timeout --signal=TERM --kill-after=1s 5s strace -f -qq -e trace=openat,openat2 \
    -o "$symlink_lock_trace" env AVELREN_TEST_LOCK_HELPER="$helper" \
    "$probe" backup "$backup_lock" >"$symlink_lock_log" 2>&1; then
  symlink_lock_status=0
else
  symlink_lock_status=$?
fi
assert_not_timed_out "$symlink_lock_status" lock-symlink
assert_status 1 "$symlink_lock_status" lock-symlink
assert_exact_diagnostic "$symlink_lock_log" 'PostgreSQL backup lock file is unsafe.' lock-symlink
if grep -Fq 'postgres-backup.lock' "$symlink_lock_trace" || grep -Fq 'symlink-target' "$symlink_lock_trace"; then
  fail 'lock symlink was opened by the production lock helper'
fi
[ -L "$backup_lock" ] || fail 'lock symlink was replaced'
[ "$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$test_root/symlink-target")" = "$target_identity_before" ] || fail 'lock symlink target metadata changed'
[ "$(sha256sum "$test_root/symlink-target" | awk '{print $1}')" = "$target_hash" ] || fail 'lock symlink target content changed'
if grep -Fq 'lock-secret-canary' "$symlink_lock_log"; then fail 'lock symlink diagnostic exposed fixture content'; fi
rm -f -- "$symlink_lock_trace"
pass lock-16-lock-symlink-rejected

prepare_directory
mkfifo -m 0600 "$backup_lock"
fifo_identity="$(stat -c '%d:%i:%F:%a' "$backup_lock")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-fifo
[ "$(stat -c '%d:%i:%F:%a' "$backup_lock")" = "$fifo_identity" ] || fail 'FIFO lock object changed'
pass lock-17-fifo-bounded-rejection

prepare_directory
mkdir -m 0600 "$backup_lock"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-directory
[ -d "$backup_lock" ] || fail 'directory lock object changed'
pass lock-18-lock-directory-rejected

prepare_directory
python3 - "$backup_lock" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY
socket_identity="$(stat -c '%d:%i:%F' "$backup_lock")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-socket
[ "$(stat -c '%d:%i:%F' "$backup_lock")" = "$socket_identity" ] || fail 'socket lock object changed'
pass lock-19-lock-socket-rejected

prepare_directory
printf '%s' 'hardlink-canary' >"$test_root/hardlink-sentinel"
chmod 0600 "$test_root/hardlink-sentinel"
ln "$test_root/hardlink-sentinel" "$backup_lock"
hardlink_identity="$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$backup_lock")"
hardlink_hash="$(sha256sum "$backup_lock" | awk '{print $1}')"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-hardlink
[ "$(stat -c '%d:%i:%h:%u:%g:%a:%s' "$backup_lock")" = "$hardlink_identity" ] || fail 'hardlinked lock metadata changed'
[ "$(sha256sum "$backup_lock" | awk '{print $1}')" = "$hardlink_hash" ] || fail 'hardlinked lock content changed'
pass lock-20-hardlink-rejected

prepare_valid_lock "$backup_lock"
chown 65534:65534 "$backup_lock"
wrong_file_owner="$(stat -c '%d:%i:%h:%u:%g:%a' "$backup_lock")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-owner
[ "$(stat -c '%d:%i:%h:%u:%g:%a' "$backup_lock")" = "$wrong_file_owner" ] || fail 'wrong-owner lock was repaired'
pass lock-21-lock-owner-rejected

prepare_valid_lock "$backup_lock"
chmod 0644 "$backup_lock"
wrong_file_mode="$(stat -c '%d:%i:%h:%u:%g:%a' "$backup_lock")"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-mode
[ "$(stat -c '%d:%i:%h:%u:%g:%a' "$backup_lock")" = "$wrong_file_mode" ] || fail 'wrong-mode lock was repaired'
pass lock-22-lock-mode-rejected

prepare_valid_lock "$backup_lock"
injected="$test_root/mismatch-injected"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-identity-mismatch \
  "PATH=$fake_bin:$PATH" AVELREN_TEST_STAT_MODE=mismatch AVELREN_TEST_INJECT_LOCK="$backup_lock" AVELREN_TEST_INJECTED="$injected"
[ -e "$injected" ] || fail 'identity mismatch injector was not reached'
pass lock-23-path-fd-mismatch-rejected

prepare_valid_lock "$backup_lock" 'replacement-original'
injected="$test_root/replacement-injected"
quarantine="$test_root/replacement-original"
expect_unsafe backup "$backup_lock" 'PostgreSQL backup lock file is unsafe.' lock-replacement \
  "PATH=$fake_bin:$PATH" AVELREN_TEST_FLOCK_REPLACE=1 AVELREN_TEST_INJECT_LOCK="$backup_lock" \
  AVELREN_TEST_INJECTED="$injected" AVELREN_TEST_QUARANTINE="$quarantine"
[ -e "$injected" ] && [ -f "$backup_lock" ] && [ -f "$quarantine" ] || fail 'post-flock replacement injector did not preserve both objects'
[ "$(stat -c '%d:%i' "$backup_lock")" != "$(stat -c '%d:%i' "$quarantine")" ] || fail 'replacement did not change identity'
[ "$(cat "$quarantine")" = replacement-original ] || fail 'replacement changed original content'
pass lock-24-replacement-rejected

if grep -R -Fq 'lock-secret-canary' "$log_root"; then fail 'a lock diagnostic exposed fixture content'; fi
pass lock-25-diagnostic-redaction

run_contention_case() {
  local kind="$1" lock_path="$2" collision_message="$3" prefix="$4"
  local ready="$test_root/$prefix.ready" release="$test_root/$prefix.release"
  local holder_log="$log_root/$prefix-holder.log" contender_log="$log_root/$prefix-contender.log"
  local next_log="$log_root/$prefix-next.log" contender_status holder_status=0 next_status

  prepare_directory
  env AVELREN_TEST_LOCK_HELPER="$helper" AVELREN_TEST_REACHED="$ready" AVELREN_TEST_RELEASE="$release" \
    "$probe" "$kind" "$lock_path" >"$holder_log" 2>&1 &
  active_pid=$!
  wait_for_file "$ready" "$active_pid" || fail "$prefix holder did not acquire the lock"
  contender_status="$(run_probe "$kind" "$lock_path" "$contender_log")"
  assert_status 1 "$contender_status" "$prefix contention"
  assert_exact_diagnostic "$contender_log" "$collision_message" "$prefix contention"
  : >"$release"
  if wait "$active_pid"; then holder_status=0; else holder_status=$?; fi
  active_pid=
  assert_status 0 "$holder_status" "$prefix holder"
  next_status="$(run_probe "$kind" "$lock_path" "$next_log")"
  assert_status 0 "$next_status" "$prefix release"
}

run_contention_case backup "$backup_lock" 'Another PostgreSQL backup is running.' backup
pass lock-26-backup-mutual-exclusion
run_contention_case restore "$restore_lock" 'Another PostgreSQL restore drill is running.' restore
pass lock-27-restore-mutual-exclusion
pass lock-28-normal-release

prepare_directory
failure_status="$(run_probe backup "$backup_lock" "$log_root/handled-failure.log" AVELREN_TEST_POST_LOCK_STATUS=42)"
assert_status 42 "$failure_status" handled-failure
status="$(run_probe backup "$backup_lock" "$log_root/after-handled-failure.log")"
assert_status 0 "$status" handled-failure-release
pass lock-29-handled-failure-release
pass lock-30-collision-contract-preserved

grep -Fxq 'RuntimeDirectory=avelren' "$backup_unit" || fail 'backup unit does not declare the exact runtime namespace'
grep -Fxq 'RuntimeDirectoryMode=0700' "$backup_unit" || fail 'backup unit runtime mode is not 0700'
grep -Fxq 'RuntimeDirectoryPreserve=yes' "$backup_unit" || fail 'backup unit does not preserve the shared namespace'
path_token_absent "$backup_unit" ReadWritePaths /run/lock || fail 'backup unit grants broad /run/lock write access'
path_token_absent "$repo_check_unit" ReadWritePaths /run/lock || fail 'repo-check unit grants broad /run/lock write access'
pass lock-31-systemd-no-global-lock-write

if grep -q '^RuntimeDirectory=' "$repo_check_unit"; then fail 'repo-check unnecessarily manages the lock namespace'; fi
path_token_absent "$repo_check_unit" ReadWritePaths /run/avelren || fail 'repo-check unnecessarily writes the lock namespace'
pass lock-32-repo-check-no-lock-write

grep -Fq '/run/avelren/postgres-backup.lock' "$documentation" || fail 'documentation omits the backup lock path'
grep -Fq '/run/avelren/postgres-restore.lock' "$documentation" || fail 'documentation omits the restore lock path'
grep -Fq 'RuntimeDirectory=avelren' "$documentation" || fail 'documentation omits systemd runtime ownership'
pass lock-33-scripts-units-docs-agree

if grep -E '(^|[[:space:]])(chmod|chown)([[:space:]].*)?[[:space:]]/run/lock([[:space:]]|$)' "$documentation"; then
  fail 'documentation mutates the global /run/lock directory'
fi
pass lock-34-no-global-lock-repair-instructions

for script in "$backup_script" "$restore_script"; do
  grep -Fq '. "$script_dir/secure-lock-file.sh"' "$script" || fail "$(basename "$script") does not source the production lock helper"
  grep -Fq 'avelren_secure_lock_acquire "$lock_file"' "$script" || fail "$(basename "$script") does not call the production lock helper"
done
pass lock-35-production-entrypoints-use-helper

global_lock_after=absent
if [ -e /run/lock ] && [ ! -L /run/lock ]; then
  global_lock_after="$(stat -c '%d:%i:%u:%g:%a' -- /run/lock)"
fi
[ "$global_lock_after" = "$global_lock_before" ] || fail 'the real /run/lock metadata changed'

printf '%s\n' 'Secure lock namespace and object regression matrix passed.'
