#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-password-file.sh"

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This drill must run as root.' >&2; exit 1; }
compose_file="${AVELREN_COMPOSE_FILE:-/opt/avelren/docker-compose.yml}"
env_file="${AVELREN_ENV_FILE:-/opt/avelren/.env.production}"
tmp_root="${AVELREN_BACKUP_TMP_ROOT:-/var/lib/avelren-backup/tmp}"
lock_file="${AVELREN_BACKUP_LOCK_FILE:-/run/lock/avelren-postgres-restore.lock}"
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
pg_user="${AVELREN_PG_USER:-avelren}"
production_db="${AVELREN_PG_DATABASE:-avelren}"
compose=(docker compose --env-file "$env_file" --file "$compose_file")
repo="rclone:${remote}:Avelren Backups/restic"
case "$remote" in (''|*[!A-Za-z0-9_-]*) exit 1;; esac
[ "$production_db" = avelren ] || { printf '%s\n' 'Production database name must remain avelren.' >&2; exit 1; }
validate_restic_password_file "$password_file" || exit 1
install -d -o root -g root -m 700 "$tmp_root" "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { printf '%s\n' 'Another backup operation is running.' >&2; exit 1; }
suffix="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
tmpdb="avelren_restore_${suffix}"
case "$tmpdb" in avelren_restore_[a-f0-9][a-f0-9]*) ;; *) printf '%s\n' 'Temporary database name generation failed.' >&2; exit 1;; esac
[ "$tmpdb" != "$production_db" ] || exit 1
restore_dir="$(mktemp -d -p "$tmp_root" avelren-restore.XXXXXX)"
chmod 700 "$restore_dir"
cleanup_allowed=0
log_file="/var/log/avelren-restore-drill-$(date -u +%Y%m%dT%H%M%SZ).log"
umask 077
cleanup() {
  if [ "$cleanup_allowed" -eq 1 ]; then
    rm -rf -- "$restore_dir"
  else
    printf '%s\n' 'Restore drill stopped with uncertain state; temporary database and files were preserved.' >>"$log_file"
  fi
}
trap cleanup EXIT
printf '%s\n' 'Restore drill started; secrets and payloads omitted.' >"$log_file"
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$repo" restic restore latest --password-file "$password_file" --target "$restore_dir" >/dev/null
dump="$(find "$restore_dir" -type f -name '*.dump' -print -quit)"
[ -n "$dump" ] || { printf '%s\n' 'No custom-format dump found.' >>"$log_file"; exit 1; }
"${compose[@]}" exec -T postgres createdb --username "$pg_user" "$tmpdb" >/dev/null
pg_restore --no-owner --no-acl --dbname "$tmpdb" "$dump" >/dev/null 2>>"$log_file"
[ "$("${compose[@]}" exec -T postgres psql --username "$pg_user" --dbname "$tmpdb" -Atqc "SELECT string_agg(version, ',' ORDER BY version) FROM avelren_schema_migrations")" = '001,002,003' ] || exit 1
for table in collector_observations collector_snapshots threshold_events collector_leases push_devices notification_outbox external_source_poll_state; do
  [ "$("${compose[@]}" exec -T postgres psql --username "$pg_user" --dbname "$tmpdb" -Atqc "SELECT to_regclass('public.${table}') IS NOT NULL")" = t ] || exit 1
done
if ! "${compose[@]}" exec -T postgres dropdb --username "$pg_user" "$tmpdb" >/dev/null 2>>"$log_file"; then
  printf '%s\n' 'Temporary database cleanup failed; state was preserved.' >>"$log_file"
  exit 1
fi
cleanup_allowed=1
rm -rf -- "$restore_dir"
cleanup_allowed=0
trap - EXIT
printf '%s\n' 'Restore drill passed for temporary database; production database was not used.'
