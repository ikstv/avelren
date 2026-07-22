#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-password-file.sh"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-repository.sh"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/secure-lock-file.sh"

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This backup must run as root.' >&2; exit 1; }
compose_file="${AVELREN_COMPOSE_FILE:-/opt/avelren/docker-compose.yml}"
env_file="${AVELREN_ENV_FILE:-/opt/avelren/.env.production}"
tmp_root="${AVELREN_BACKUP_TMP_ROOT:-/var/lib/avelren-backup/tmp}"
lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/avelren/postgres-backup.lock}"
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
pg_database="${AVELREN_PG_DATABASE:-avelren}"
pg_user="${AVELREN_PG_USER:-avelren}"
heartbeat_timeout="${AVELREN_BACKUP_HEARTBEAT_TIMEOUT:-30}"
docker_command_timeout="${AVELREN_BACKUP_DOCKER_TIMEOUT:-5}"
transfer_timeout="${AVELREN_BACKUP_TRANSFER_TIMEOUT:-900}"
termination_timeout="${AVELREN_BACKUP_TERMINATION_TIMEOUT:-10}"
postgres_dump_helper="$script_dir/postgres-tcp-dump.sh"
postgres_control_helper="$script_dir/postgres-backup-control.sh"
container_runtime_root=/run/avelren-backup
compose=(docker compose --env-file "$env_file" --file "$compose_file")
repo="rclone:${remote}:Avelren Backups/restic"
container=
control_dir=
operation_id=
operation_active=0
operation_setup_cleanup_armed=0
operation_setup_token=
operation_cleanup_warning_emitted=0
tmpdir=

case "$heartbeat_timeout:$docker_command_timeout:$transfer_timeout:$termination_timeout" in *[!0-9:]*) exit 1 ;; esac
[ "$heartbeat_timeout" -ge 5 ] && [ "$heartbeat_timeout" -le 300 ] || exit 1
[ "$docker_command_timeout" -ge 1 ] && [ "$docker_command_timeout" -le 30 ] || exit 1
[ "$transfer_timeout" -ge 30 ] && [ "$transfer_timeout" -le 7200 ] || exit 1
[ "$termination_timeout" -ge 2 ] && [ "$termination_timeout" -le 60 ] || exit 1

control() {
  timeout --signal=KILL "$docker_command_timeout" \
    docker exec --interactive --user 0 "$container" sh -s -- "$@" <"$postgres_control_helper"
}

docker_timed() {
  timeout --signal=KILL "$docker_command_timeout" docker "$@"
}

docker_transfer_timed() {
  timeout --signal=TERM --kill-after="${termination_timeout}s" "$transfer_timeout" docker "$@"
}

declared_tmpfs_is_secure() {
  local options option mode_count=0 uid_count=0 gid_count=0
  local rw=0 noexec=0 nosuid=0 nodev=0
  local -a declared_options
  options="$(docker_timed inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$container")" || return 1
  [ -n "$options" ] || return 1
  local IFS=,
  # Docker serializes tmpfs options as comma-separated exact tokens. Accept
  # additional non-conflicting options, but reject a missing or contradictory
  # required property rather than using substring matching.
  read -r -a declared_options <<<"$options"
  for option in "${declared_options[@]}"; do
    case "$option" in
      rw) rw=1 ;;
      noexec) noexec=1 ;;
      nosuid) nosuid=1 ;;
      nodev) nodev=1 ;;
      # Docker may canonicalize the Compose spelling mode=0700 to mode=700.
      mode=0700|mode=700) ((mode_count += 1)) ;;
      uid=0) ((uid_count += 1)) ;;
      gid=0) ((gid_count += 1)) ;;
      ro|exec|suid|dev|rw=*|noexec=*|nosuid=*|nodev=*|mode|uid|gid|mode=*|uid=*|gid=*) return 1 ;;
      '') return 1 ;;
      *) : ;;
    esac
  done
  [ "$rw" -eq 1 ] && [ "$noexec" -eq 1 ] && [ "$nosuid" -eq 1 ] && [ "$nodev" -eq 1 ] && \
    [ "$mode_count" -ge 1 ] && [ "$uid_count" -ge 1 ] && [ "$gid_count" -ge 1 ]
}

effective_tmpfs_is_secure() {
  # /proc/self/mountinfo is kernel-backed. The canonical target contains no
  # mountinfo escapes, so exact field equality rejects nested/similar mounts.
  docker_timed exec --interactive --user 0 "$container" sh -s -- "$container_runtime_root" <<'EOF'
set -eu
target="$1"
awk -v target="$target" '
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
[ -d "$target" ] && [ ! -L "$target" ]
[ "$(stat -c '%u:%g:%a' "$target")" = '0:0:700' ]
EOF
}

operation_state() {
  control state "$control_dir" "$operation_id" 2>/dev/null || printf '%s\n' unavailable
}

wait_for_operation_stop() {
  deadline=$((SECONDS + termination_timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(operation_state)"
    case "$state" in running|starting|unavailable) sleep 1 ;; *) return 0 ;; esac
  done
  return 1
}

wait_for_role_stop() {
  role="$1"
  deadline=$((SECONDS + termination_timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(control role-state "$control_dir" "$operation_id" "$role" 2>/dev/null || printf '%s\n' unavailable)"
    case "$state" in running|unavailable) sleep 1 ;; *) return 0 ;; esac
  done
  return 1
}

cleanup_setup_operation() {
  [ "$operation_setup_cleanup_armed" -eq 1 ] || return 0
  if control cleanup-owned "$control_dir" "$operation_id" "$operation_setup_token" >/dev/null 2>&1; then
    operation_setup_cleanup_armed=0
    operation_setup_token=
  elif [ "$operation_cleanup_warning_emitted" -eq 0 ]; then
    printf '%s\n' 'Could not verify cleanup of PostgreSQL backup setup state.' >&2
    operation_cleanup_warning_emitted=1
  fi
  return 0
}

cancel_operation() {
  if [ "$operation_active" -ne 1 ]; then
    cleanup_setup_operation
    return 0
  fi
  children_stopped=1
  control signal "$control_dir" "$operation_id" supervisor TERM >/dev/null 2>&1 || true
  if ! wait_for_operation_stop; then
    # The supervisor owns and reaps both children. Escalate its dump child
    # first, then its watchdog, and terminate the supervisor only after both
    # child identities are gone.
    control signal "$control_dir" "$operation_id" dump KILL >/dev/null 2>&1 || true
    wait_for_role_stop dump || children_stopped=0
    wait_for_operation_stop || true
  fi
  dump_state="$(control role-state "$control_dir" "$operation_id" dump 2>/dev/null || printf '%s\n' unavailable)"
  if [ "$dump_state" = running ]; then
    control signal "$control_dir" "$operation_id" dump KILL >/dev/null 2>&1 || true
    wait_for_role_stop dump || children_stopped=0
  elif [ "$dump_state" = unavailable ]; then
    children_stopped=0
  fi
  watchdog_state="$(control role-state "$control_dir" "$operation_id" watchdog 2>/dev/null || printf '%s\n' unavailable)"
  if [ "$watchdog_state" = running ]; then
    control signal "$control_dir" "$operation_id" watchdog TERM >/dev/null 2>&1 || true
    if ! wait_for_role_stop watchdog; then
      control signal "$control_dir" "$operation_id" watchdog KILL >/dev/null 2>&1 || true
      wait_for_role_stop watchdog || children_stopped=0
    fi
  elif [ "$watchdog_state" = unavailable ]; then
    children_stopped=0
  fi
  if [ "$children_stopped" -eq 1 ]; then
    if ! wait_for_operation_stop; then
      control signal "$control_dir" "$operation_id" supervisor KILL >/dev/null 2>&1 || true
      wait_for_operation_stop || true
    fi
  fi
  if control cleanup "$control_dir" "$operation_id" >/dev/null 2>&1; then
    operation_active=0
  fi
}

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM
  cancel_operation
  [ -z "$tmpdir" ] || rm -rf -- "$tmpdir"
  exit "$exit_code"
}

terminate() {
  exit_code="$1"
  trap '' INT TERM
  cancel_operation
  exit "$exit_code"
}

trap cleanup EXIT
trap 'terminate 130' INT
trap 'terminate 143' TERM

configure_restic_repository "$repo" || exit 1
if [ ! -f "$env_file" ] || [ ! -f "$password_file" ] || [ ! -f "$rclone_config" ] || \
   [ ! -f "$postgres_dump_helper" ] || [ ! -f "$postgres_control_helper" ]; then
  printf '%s\n' 'Backup configuration is incomplete.' >&2
  exit 1
fi
validate_restic_password_file "$password_file" || exit 1
[ "$(stat -c '%u:%a' "$rclone_config")" = '0:600' ] || { printf '%s\n' 'rclone config must be root:root mode 0600.' >&2; exit 1; }
install -d -o root -g root -m 700 "$tmp_root"
lock_status=0
if avelren_secure_lock_acquire "$lock_file"; then
  lock_status=0
else
  lock_status=$?
fi
case "$lock_status" in
  0) ;;
  73) printf '%s\n' 'PostgreSQL backup lock directory is unsafe.' >&2; exit 1 ;;
  75) printf '%s\n' 'Another PostgreSQL backup is running.' >&2; exit 1 ;;
  *) printf '%s\n' 'PostgreSQL backup lock file is unsafe.' >&2; exit 1 ;;
esac
container="$("${compose[@]}" ps -q postgres)"
[ -n "$container" ] || { printf '%s\n' 'PostgreSQL container is unavailable.' >&2; exit 1; }
[ "$(docker_timed inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] || { printf '%s\n' 'PostgreSQL is not healthy.' >&2; exit 1; }
declared_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL backup runtime tmpfs configuration is unsafe.' >&2
  exit 1
}
effective_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL backup runtime effective tmpfs mount is unsafe.' >&2
  exit 1
}
# Fail closed on any operation state left in this container boot. It may belong
# to an active controller and is never removed by a later operation.
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
docker_timed exec --user 0 "$container" sh -eu -c '
  root="$1"
  [ -d "$root" ] && [ ! -L "$root" ]
  [ "$(stat -c "%u:%g:%a" "$root")" = "0:0:700" ]
  for item in "$root"/operation.*; do [ ! -e "$item" ] || exit 74; done
' sh "$container_runtime_root" || { printf '%s\n' 'PostgreSQL backup runtime is unsafe or contains operation state.' >&2; exit 1; }
repo_bytes() { RCLONE_CONFIG="$rclone_config" rclone size --json "$RCLONE_REPOSITORY_PATH" | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'; }
bytes="$(repo_bytes)"
case "$bytes" in (''|*[!0-9]*) printf '%s\n' 'Repository size is unavailable.' >&2; exit 1;; esac
[ "$bytes" -lt $((14 * 1024 * 1024 * 1024)) ] || { printf '%s\n' 'Backup stopped: repository reached the 14 GiB hard limit.' >&2; exit 1; }
[ "$bytes" -lt $((12 * 1024 * 1024 * 1024)) ] || printf '%s\n' 'Warning: repository reached 12 GiB.' >&2
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic snapshots --password-file "$password_file" >/dev/null

tmpdir="$(mktemp -d -p "$tmp_root" avelren-pg-backup.XXXXXX)"
chmod 700 "$tmpdir"
if [ ! -d "$tmpdir" ] || [ -L "$tmpdir" ] || [ "$(stat -c '%u:%g:%a' "$tmpdir")" != '0:0:700' ]; then
  printf '%s\n' 'Host dump temporary directory is unsafe.' >&2
  exit 1
fi
dump="$tmpdir/avelren-$(date -u +%Y%m%dT%H%M%SZ).dump"
umask 077
# Bash noclobber is not O_NOFOLLOW: for an existing non-regular path it may
# open a symlink target before rejecting the path/FD identity mismatch. The
# directory above is freshly created and root-only; reject every existing
# entry before asking noclobber for an atomic O_CREAT|O_EXCL absent-path open.
if [ -e "$dump" ] || [ -L "$dump" ]; then
  printf '%s\n' 'Could not create secure host dump file.' >&2
  exit 1
fi
dump_fd=
dump_create_status=0
set -o noclobber
if { :; } {dump_fd}>"$dump"; then
  dump_create_status=0
else
  dump_create_status=$?
fi
set +o noclobber
if [ "$dump_create_status" -ne 0 ] || [ -z "${dump_fd:-}" ]; then
  printf '%s\n' 'Could not create secure host dump file.' >&2
  exit 1
fi
dump_path_identity="$(stat -c '%d:%i:%h:%u:%g:%a' "$dump")" || dump_path_identity=
dump_fd_identity="$(stat -Lc '%d:%i:%h:%u:%g:%a' "/proc/$$/fd/$dump_fd")" || dump_fd_identity=
if ! { [ -f "$dump" ] && [ ! -L "$dump" ] && [ -f "/proc/$$/fd/$dump_fd" ] && \
    [ -n "$dump_path_identity" ] && [ "$dump_path_identity" = "$dump_fd_identity" ]; }; then
  printf '%s\n' 'Host dump file permissions are unsafe.' >&2
  exit 1
fi
if ! [[ "$dump_path_identity" =~ ^[0-9]+:[0-9]+:1:0:0:600$ ]]; then
  printf '%s\n' 'Host dump file permissions are unsafe.' >&2
  exit 1
fi
create_status=1
for _ in 1 2 3 4 5; do
  operation_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  case "$operation_id" in ''|*[!a-f0-9]*) exit 1 ;; esac
  [ "${#operation_id}" -eq 32 ] || exit 1
  operation_setup_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  case "$operation_setup_token" in ''|*[!a-f0-9]*) exit 1 ;; esac
  [ "${#operation_setup_token}" -eq 32 ] || exit 1
  control_dir="$container_runtime_root/operation.$operation_id"
  operation_setup_cleanup_armed=1
  create_status=0
  # mkdir is atomic and deliberately does not accept an existing operation.
  # The independent marker hands cleanup ownership to the host before this
  # foreground command can defer an INT/TERM trap.
  # Expansion belongs to the isolated container shell.
  # shellcheck disable=SC2016
  docker_timed exec --interactive --user 0 "$container" sh -eu -c '
    umask 077
    root="$1"; directory="$2"; setup_token="$3"; created=0
    cleanup() { status=$?; trap - EXIT HUP INT TERM; [ "$status" -eq 0 ] || [ "$created" -eq 0 ] || rm -rf -- "$directory"; exit "$status"; }
    trap cleanup EXIT
    trap "exit 129" HUP
    trap "exit 130" INT
    trap "exit 143" TERM
    [ -d "$root" ] && [ ! -L "$root" ] && [ "$(stat -c "%u:%g:%a" "$root")" = "0:0:700" ]
    case "$setup_token" in ""|*[!a-f0-9]*) exit 64 ;; esac
    [ "${#setup_token}" -eq 32 ]
    if ! mkdir -m 700 -- "$directory"; then [ ! -e "$directory" ] || exit 73; exit 1; fi
    created=1
    [ "$(stat -c "%u:%g:%a" "$directory")" = "0:0:700" ]
    printf "%s\n" "$setup_token" >"$directory/.setup-owner"
    [ -f "$directory/.setup-owner" ] && [ ! -L "$directory/.setup-owner" ]
    [ "$(stat -c "%h:%u:%g:%a" "$directory/.setup-owner")" = "1:0:0:600" ]
    cat >"$directory/runner.sh"
    chmod 700 "$directory/runner.sh"
    date +%s >"$directory/heartbeat"
  ' sh "$container_runtime_root" "$control_dir" "$operation_setup_token" <"$postgres_dump_helper" || create_status=$?
  if [ "$create_status" -eq 73 ]; then
    operation_setup_cleanup_armed=0
    operation_setup_token=
    continue
  fi
  break
done
[ "$create_status" -eq 0 ] || { printf '%s\n' 'Could not create isolated PostgreSQL backup operation.' >&2; exit 1; }
operation_active=1
operation_setup_cleanup_armed=0
operation_setup_token=
docker_timed exec --detach --user 0 \
  --env "AVELREN_BACKUP_OPERATION_ID=$operation_id" \
  --env "AVELREN_BACKUP_HEARTBEAT_TIMEOUT=$heartbeat_timeout" \
  --env "AVELREN_BACKUP_TERMINATION_TIMEOUT=$termination_timeout" \
  "$container" sh "$control_dir/runner.sh" "$pg_database" "$pg_user" "$control_dir" "$operation_id"

startup_deadline=$((SECONDS + docker_command_timeout))
while :; do
  control heartbeat "$control_dir" "$operation_id" >/dev/null
  state="$(operation_state)"
  case "$state" in
    done:*) dump_status="${state#done:}"; break ;;
    running) : ;;
    starting) [ "$SECONDS" -lt "$startup_deadline" ] || { printf '%s\n' 'PostgreSQL dump process did not start.' >&2; exit 1; } ;;
    *) printf '%s\n' 'PostgreSQL dump process state is unavailable.' >&2; exit 1 ;;
  esac
  sleep 1
done

case "$dump_status" in ''|*[!0-9]*) exit 1 ;; esac
if [ "$dump_status" -ne 0 ]; then
  printf '%s\n' 'PostgreSQL dump failed.' >&2
  exit 1
fi
# Docker's archive API cannot reliably read a file from a container tmpfs.
# Stream only the validated dump bytes to the root-only host temporary file.
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
transfer_status=0
docker_transfer_timed exec --user 0 "$container" sh -eu -c '
  file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ]
  [ "$(stat -c "%u:%g:%a" "$file")" = "0:0:600" ]
  cat -- "$file"
' sh "$control_dir/postgres.dump" >&"$dump_fd" || transfer_status=$?
if [ "$transfer_status" -ne 0 ]; then
  printf '%s\n' 'PostgreSQL dump transfer failed.' >&2
  exit "$transfer_status"
fi
exec {dump_fd}>&-
control cleanup "$control_dir" "$operation_id" >/dev/null
operation_active=0
[ -s "$dump" ] || { printf '%s\n' 'PostgreSQL dump is empty.' >&2; exit 1; }
pg_restore --list "$dump" >/dev/null 2>"$tmpdir/pg_restore.stderr" || { printf '%s\n' 'PostgreSQL dump validation failed.' >&2; exit 1; }
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic backup --password-file "$password_file" --tag "$RESTIC_POSTGRES_TAG" "$dump" >/dev/null
printf '%s\n' 'PostgreSQL backup completed.'
