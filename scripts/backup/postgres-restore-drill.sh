#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-password-file.sh"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-repository.sh"

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This drill must run as root.' >&2; exit 1; }
compose_file="${AVELREN_COMPOSE_FILE:-/opt/avelren/docker-compose.yml}"
env_file="${AVELREN_ENV_FILE:-/opt/avelren/.env.production}"
tmp_root="${AVELREN_BACKUP_TMP_ROOT:-/var/lib/avelren-backup/tmp}"
lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/lock/avelren-postgres-restore.lock}"
log_root="${AVELREN_RESTORE_LOG_ROOT:-/var/log}"
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
pg_user="${AVELREN_PG_USER:-avelren}"
production_db="${AVELREN_PG_DATABASE:-avelren}"
docker_command_timeout="${AVELREN_BACKUP_DOCKER_TIMEOUT:-5}"
restore_helper="$script_dir/postgres-tcp-restore.sh"
container_runtime_root=/run/avelren-backup
compose=(docker compose --env-file "$env_file" --file "$compose_file")
repo="rclone:${remote}:Avelren Backups/restic"
container=
restore_token=
directory_token=
tmpdb=
restore_dir=
payload_dir=
restore_dir_identity=
cleanup_armed=0
cleanup_warning_emitted=0
log_file=
dump_fd=
route_status_file=
route_status_identity=
route_started=0
route_cleanup_verified=0
route_preservation_warning_emitted=0

case "$docker_command_timeout" in ''|*[!0-9]*) exit 1 ;; esac
[ "$docker_command_timeout" -ge 1 ] && [ "$docker_command_timeout" -le 30 ] || exit 1
[ "$production_db" = avelren ] || { printf '%s\n' 'Production database name must remain avelren.' >&2; exit 1; }
case "$pg_user" in ''|*[!A-Za-z0-9_]*) printf '%s\n' 'PostgreSQL restore user is invalid.' >&2; exit 1 ;; esac

docker_timed() {
  timeout --signal=KILL "$docker_command_timeout" docker "$@"
}

declared_tmpfs_is_secure() {
  local options option mode_count=0 uid_count=0 gid_count=0
  local rw=0 noexec=0 nosuid=0 nodev=0
  local -a declared_options
  options="$(docker_timed inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$container")" || return 1
  [ -n "$options" ] || return 1
  local IFS=,
  read -r -a declared_options <<<"$options"
  for option in "${declared_options[@]}"; do
    case "$option" in
      rw) rw=1 ;;
      noexec) noexec=1 ;;
      nosuid) nosuid=1 ;;
      nodev) nodev=1 ;;
      mode=0700|mode=700) ((mode_count += 1)) ;;
      uid=0) ((uid_count += 1)) ;;
      gid=0) ((gid_count += 1)) ;;
      ro|exec|suid|dev|rw=*|noexec=*|nosuid=*|nodev=*|mode|uid|gid|mode=*|uid=*|gid=*|'') return 1 ;;
      *) : ;;
    esac
  done
  [ "$rw" -eq 1 ] && [ "$noexec" -eq 1 ] && [ "$nosuid" -eq 1 ] && [ "$nodev" -eq 1 ] && \
    [ "$mode_count" -ge 1 ] && [ "$uid_count" -ge 1 ] && [ "$gid_count" -ge 1 ]
}

effective_tmpfs_is_secure() {
  docker_timed exec --interactive --user 0 "$container" sh -s -- "$container_runtime_root" <<'EFFECTIVE_TMPFS'
set -eu
target="$1"
awk -v target="$target" '
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
' /proc/self/mountinfo
[ -d "$target" ] && [ ! -L "$target" ]
[ "$(stat -c '%u:%g:%a' "$target")" = '0:0:700' ]
EFFECTIVE_TMPFS
}

emit_cleanup_warning() {
  [ "$cleanup_warning_emitted" -eq 0 ] || return 0
  printf '%s\n' 'Restore payload cleanup could not verify ownership; temporary state was preserved.' >&2
  if [ -n "$log_file" ] && [ -f "$log_file" ] && [ ! -L "$log_file" ]; then
    printf '%s\n' 'Restore payload cleanup could not verify ownership; temporary state was preserved.' >>"$log_file"
  fi
  cleanup_warning_emitted=1
}

route_status_file_is_secure() {
  [ -n "$route_status_file" ] && [ -f "$route_status_file" ] && [ ! -L "$route_status_file" ] && \
    [ "$(stat -c '%d:%i:%h:%u:%g:%a' "$route_status_file" 2>/dev/null)" = "$route_status_identity" ]
}

refresh_route_cleanup_status() {
  route_cleanup_verified=0
  [ "$route_started" -eq 1 ] || return 0
  if route_status_file_is_secure && [ "$(tail -n 1 "$route_status_file" 2>/dev/null)" = cleanup-verified ]; then
    route_cleanup_verified=1
  fi
}

emit_route_preservation_warning() {
  [ "$route_preservation_warning_emitted" -eq 0 ] || return 0
  printf '%s\n' 'Restore payload was preserved because database cleanup was not verified.' >&2
  if [ -n "$log_file" ] && [ -f "$log_file" ] && [ ! -L "$log_file" ]; then
    printf '%s\n' 'Restore payload was preserved because database cleanup was not verified.' >>"$log_file"
  fi
  route_preservation_warning_emitted=1
}

cleanup_restore_directory() {
  [ "$cleanup_armed" -eq 1 ] || return 0
  if [ ! -e "$restore_dir" ] && [ ! -L "$restore_dir" ]; then
    cleanup_armed=0
    return 0
  fi
  if [ -z "$restore_token" ] || [ -z "$directory_token" ] || \
     [ "$restore_dir" != "$tmp_root/avelren-restore.$restore_token" ] || \
     [ ! -d "$restore_dir" ] || [ -L "$restore_dir" ] || \
     [ "$(stat -c '%u:%g:%a' "$restore_dir" 2>/dev/null)" != 0:0:700 ] || \
     [ ! -f "$restore_dir/.restore-owner" ] || [ -L "$restore_dir/.restore-owner" ] || \
     [ "$(stat -c '%h:%u:%g:%a' "$restore_dir/.restore-owner" 2>/dev/null)" != 1:0:0:600 ] || \
     [ "$(cat "$restore_dir/.restore-owner" 2>/dev/null)" != "$directory_token" ]; then
    emit_cleanup_warning
    return 1
  fi
  current_identity="$(stat -c '%d:%i' "$restore_dir" 2>/dev/null)"
  if [ -n "$restore_dir_identity" ] && [ "$current_identity" != "$restore_dir_identity" ]; then
    emit_cleanup_warning
    return 1
  fi
  if ! rm -rf -- "$restore_dir" || [ -e "$restore_dir" ] || [ -L "$restore_dir" ]; then
    emit_cleanup_warning
    return 1
  fi
  cleanup_armed=0
  return 0
}

cleanup() {
  primary_status=$?
  cleanup_status=0
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  if [ -n "$dump_fd" ]; then
    exec {dump_fd}<&-
    dump_fd=
  fi
  refresh_route_cleanup_status
  if [ "$route_started" -eq 1 ] && [ "$route_cleanup_verified" -ne 1 ]; then
    cleanup_armed=0
    emit_route_preservation_warning
  fi
  cleanup_restore_directory || cleanup_status=$?
  if [ "$primary_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then primary_status=1; fi
  exit "$primary_status"
}

terminate() {
  trap '' HUP INT TERM
  exit "$1"
}

create_restore_directory() (
  set -Eeuo pipefail
  created=0
  setup_cleanup() {
    setup_status=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$setup_status" -ne 0 ] && [ "$created" -eq 1 ] && \
       [ -d "$restore_dir" ] && [ ! -L "$restore_dir" ]; then
      if ! rm -rf -- "$restore_dir" || [ -e "$restore_dir" ] || [ -L "$restore_dir" ]; then
        printf '%s\n' 'Restore payload cleanup failed during setup; temporary state was preserved.' >&2
        if [ -n "$log_file" ] && [ -f "$log_file" ] && [ ! -L "$log_file" ]; then
          printf '%s\n' 'Restore payload cleanup failed during setup; temporary state was preserved.' >>"$log_file"
        fi
      fi
    fi
    exit "$setup_status"
  }
  trap setup_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  [ ! -e "$restore_dir" ] && [ ! -L "$restore_dir" ]
  mkdir -m 700 -- "$restore_dir"
  created=1
  printf '%s\n' "$directory_token" >"$restore_dir/.restore-owner"
  chmod 600 "$restore_dir/.restore-owner"
  mkdir -m 700 -- "$payload_dir"
  [ "$(stat -c '%u:%g:%a' "$restore_dir")" = 0:0:700 ]
  [ -f "$restore_dir/.restore-owner" ] && [ ! -L "$restore_dir/.restore-owner" ]
  [ "$(stat -c '%h:%u:%g:%a' "$restore_dir/.restore-owner")" = 1:0:0:600 ]
  [ "$(cat "$restore_dir/.restore-owner")" = "$directory_token" ]
  [ -d "$payload_dir" ] && [ ! -L "$payload_dir" ]
  [ "$(stat -c '%u:%g:%a' "$payload_dir")" = 0:0:700 ]
)

trap cleanup EXIT
trap 'terminate 129' HUP
trap 'terminate 130' INT
trap 'terminate 143' TERM

configure_restic_repository "$repo" || exit 1
if [ ! -f "$env_file" ] || [ ! -f "$password_file" ] || [ ! -f "$rclone_config" ] || \
   [ ! -f "$restore_helper" ] || [ -L "$restore_helper" ] || [ ! -x "$restore_helper" ]; then
  printf '%s\n' 'Restore drill configuration is incomplete.' >&2
  exit 1
fi
validate_restic_password_file "$password_file" || exit 1
[ "$(stat -c '%u:%a' "$rclone_config")" = 0:600 ] || {
  printf '%s\n' 'rclone config must be root:root mode 0600.' >&2
  exit 1
}
install -d -o root -g root -m 700 "$tmp_root" "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { printf '%s\n' 'Another PostgreSQL restore drill is running.' >&2; exit 1; }

container="$("${compose[@]}" ps -q postgres)"
case "$container" in ''|*[!a-f0-9]*) printf '%s\n' 'PostgreSQL container is unavailable.' >&2; exit 1 ;; esac
[ "${#container}" -eq 64 ] || { printf '%s\n' 'PostgreSQL container identity is invalid.' >&2; exit 1; }
[ "$(docker_timed inspect -f '{{.Id}}' "$container")" = "$container" ] || {
  printf '%s\n' 'PostgreSQL container identity changed.' >&2
  exit 1
}
[ "$(docker_timed inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] || {
  printf '%s\n' 'PostgreSQL is not healthy.' >&2
  exit 1
}
declared_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL restore runtime tmpfs configuration is unsafe.' >&2
  exit 1
}
effective_tmpfs_is_secure || {
  printf '%s\n' 'PostgreSQL restore runtime effective tmpfs mount is unsafe.' >&2
  exit 1
}

restore_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
directory_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
case "$restore_token:$directory_token" in ''|*[!a-f0-9:]*) exit 1 ;; esac
[ "${#restore_token}" -eq 32 ] && [ "${#directory_token}" -eq 32 ] || exit 1
tmpdb="avelren_restore_$restore_token"
restore_dir="$tmp_root/avelren-restore.$restore_token"
payload_dir="$restore_dir/payload"
cleanup_armed=1

[ -d "$log_root" ] && [ ! -L "$log_root" ] || { printf '%s\n' 'Restore log directory is unsafe.' >&2; exit 1; }
log_root_metadata="$(stat -c '%u:%a' "$log_root")"
log_root_uid="${log_root_metadata%%:*}"
log_root_mode="${log_root_metadata#*:}"
case "$log_root_uid:$log_root_mode" in *[!0-9:]*) exit 1 ;; esac
[ "$log_root_uid" -eq 0 ] && [ $((8#$log_root_mode & 0022)) -eq 0 ] || {
  printf '%s\n' 'Restore log directory is unsafe.' >&2
  exit 1
}
umask 077
log_file="$(mktemp -p "$log_root" avelren-restore-drill.XXXXXX.log)"
[ -f "$log_file" ] && [ ! -L "$log_file" ] && [ "$(stat -c '%h:%u:%g:%a' "$log_file")" = 1:0:0:600 ] || exit 1
printf '%s\n' 'Restore drill started; secrets and payloads omitted.' >"$log_file"

create_restore_directory
restore_dir_identity="$(stat -c '%d:%i' "$restore_dir")"
[ -n "$restore_dir_identity" ] || exit 1
route_status_file="$restore_dir/.route-status"
( umask 077; printf '%s\n' operation-owned >"$route_status_file" )
[ -f "$route_status_file" ] && [ ! -L "$route_status_file" ] && \
  [ "$(stat -c '%h:%u:%g:%a' "$route_status_file")" = 1:0:0:600 ] || exit 1
route_status_identity="$(stat -c '%d:%i:%h:%u:%g:%a' "$route_status_file")"

restore_status=0
if RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" \
  restic restore latest --tag "$RESTIC_POSTGRES_TAG" --password-file "$password_file" \
    --target "$payload_dir" >/dev/null 2>>"$log_file"; then
  restore_status=0
else
  restore_status=$?
fi
if [ "$restore_status" -ne 0 ]; then
  printf '%s\n' 'PostgreSQL-scoped snapshot restore failed.' >&2
  exit "$restore_status"
fi
[ -d "$payload_dir" ] && [ ! -L "$payload_dir" ] && [ "$(stat -c '%u:%g:%a' "$payload_dir")" = 0:0:700 ] || {
  printf '%s\n' 'Restored payload directory is unsafe.' >&2
  exit 1
}

candidate_list="$restore_dir/dump-candidates"
( umask 077; : >"$candidate_list" )
if ! find -P "$payload_dir" -xdev -name '*.dump' -print0 >"$candidate_list"; then
  printf '%s\n' 'Could not enumerate PostgreSQL dump artifacts.' >&2
  exit 1
fi
mapfile -d '' -t dump_candidates <"$candidate_list"
rm -f -- "$candidate_list"
case "${#dump_candidates[@]}" in
  0) printf '%s\n' 'No PostgreSQL dump found in selected snapshot.' >&2; exit 1 ;;
  1) : ;;
  *) printf '%s\n' 'Selected PostgreSQL snapshot contains ambiguous dump artifacts.' >&2; exit 1 ;;
esac
dump="${dump_candidates[0]}"
dump_name="${dump##*/}"
if ! [[ "$dump_name" =~ ^avelren-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then
  printf '%s\n' 'Selected PostgreSQL dump name is invalid.' >&2
  exit 1
fi
dump_path_identity="$(stat -c '%d:%i:%h:%u:%g:%a' "$dump" 2>/dev/null)" || dump_path_identity=
if ! { [ -f "$dump" ] && [ ! -L "$dump" ] && [ -s "$dump" ] && \
    [[ "$dump_path_identity" =~ ^[0-9]+:[0-9]+:1:0:0:600$ ]]; }; then
  printf '%s\n' 'Selected PostgreSQL dump artifact is unsafe.' >&2
  exit 1
fi

dump_open_status=0
if exec {dump_fd}<"$dump"; then
  dump_open_status=0
else
  dump_open_status=$?
fi
if [ "$dump_open_status" -ne 0 ] || [ -z "${dump_fd:-}" ]; then
  printf '%s\n' 'Could not open the verified PostgreSQL dump.' >&2
  exit 1
fi
dump_fd_identity="$(stat -Lc '%d:%i:%h:%u:%g:%a' "/proc/$$/fd/$dump_fd" 2>/dev/null)" || dump_fd_identity=
if [ -z "$dump_fd_identity" ] || [ "$dump_fd_identity" != "$dump_path_identity" ]; then
  printf '%s\n' 'PostgreSQL dump path and file descriptor identity differ.' >&2
  exit 1
fi

route_status=0
route_started=1
if "$restore_helper" "$container" "$pg_user" "$production_db" "$tmpdb" "$restore_token" "$route_status_file" \
  <&"$dump_fd" >/dev/null 2>>"$log_file"; then
  route_status=0
else
  route_status=$?
fi
exec {dump_fd}<&-
dump_fd=
refresh_route_cleanup_status
if [ "$route_cleanup_verified" -ne 1 ]; then
  emit_route_preservation_warning
  cleanup_armed=0
  if [ "$route_status" -eq 0 ]; then route_status=1; fi
fi
if [ "$route_status" -ne 0 ]; then
  printf '%s\n' 'Controlled PostgreSQL restore route failed.' >&2
  exit "$route_status"
fi

cleanup_restore_directory
# EXIT repeats the now-idempotent cleanup path and must observe absence.
printf '%s\n' 'Restore drill passed for a controlled temporary database; production database was not used.'
