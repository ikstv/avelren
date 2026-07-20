#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-password-file.sh"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-repository.sh"

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This backup must run as root.' >&2; exit 1; }
compose_file="${AVELREN_COMPOSE_FILE:-/opt/avelren/docker-compose.yml}"
env_file="${AVELREN_ENV_FILE:-/opt/avelren/.env.production}"
tmp_root="${AVELREN_BACKUP_TMP_ROOT:-/var/lib/avelren-backup/tmp}"
lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/lock/avelren-postgres-backup.lock}"
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
pg_database="${AVELREN_PG_DATABASE:-avelren}"
pg_user="${AVELREN_PG_USER:-avelren}"
compose=(docker compose --env-file "$env_file" --file "$compose_file")
repo="rclone:${remote}:Avelren Backups/restic"
configure_restic_repository "$repo" || exit 1
if [ ! -f "$env_file" ] || [ ! -f "$password_file" ] || [ ! -f "$rclone_config" ]; then
  printf '%s\n' 'Backup configuration is incomplete.' >&2
  exit 1
fi
validate_restic_password_file "$password_file" || exit 1
[ "$(stat -c '%u:%a' "$rclone_config")" = '0:600' ] || { printf '%s\n' 'rclone config must be root:root mode 0600.' >&2; exit 1; }
install -d -o root -g root -m 700 "$tmp_root" "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { printf '%s\n' 'Another PostgreSQL backup is running.' >&2; exit 1; }
container="$("${compose[@]}" ps -q postgres)"
[ -n "$container" ] || { printf '%s\n' 'PostgreSQL container is unavailable.' >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] || { printf '%s\n' 'PostgreSQL is not healthy.' >&2; exit 1; }
repo_bytes() { RCLONE_CONFIG="$rclone_config" rclone size --json "$RCLONE_REPOSITORY_PATH" | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'; }
bytes="$(repo_bytes)"
case "$bytes" in (''|*[!0-9]*) printf '%s\n' 'Repository size is unavailable.' >&2; exit 1;; esac
[ "$bytes" -lt $((14 * 1024 * 1024 * 1024)) ] || { printf '%s\n' 'Backup stopped: repository reached the 14 GiB hard limit.' >&2; exit 1; }
[ "$bytes" -lt $((12 * 1024 * 1024 * 1024)) ] || printf '%s\n' 'Warning: repository reached 12 GiB.' >&2
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic snapshots --password-file "$password_file" >/dev/null
tmpdir="$(mktemp -d -p "$tmp_root" avelren-pg-backup.XXXXXX)"
chmod 700 "$tmpdir"
dump="$tmpdir/avelren-$(date -u +%Y%m%dT%H%M%SZ).dump"
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT
if ! "${compose[@]}" exec -T postgres pg_dump --username "$pg_user" --dbname "$pg_database" --format=custom --no-owner --no-acl >"$dump" 2>"$tmpdir/pg_dump.stderr"; then
  printf '%s\n' 'PostgreSQL dump failed.' >&2
  exit 1
fi
[ -s "$dump" ] || { printf '%s\n' 'PostgreSQL dump is empty.' >&2; exit 1; }
pg_restore --list "$dump" >/dev/null 2>"$tmpdir/pg_restore.stderr" || { printf '%s\n' 'PostgreSQL dump validation failed.' >&2; exit 1; }
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic backup --password-file "$password_file" --tag postgres "$dump" >/dev/null
printf '%s\n' 'PostgreSQL backup completed.'
