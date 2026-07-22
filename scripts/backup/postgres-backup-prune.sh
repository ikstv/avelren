#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-password-file.sh"
# Resolved relative to the installed script directory.
# shellcheck disable=SC1091
. "$script_dir/restic-repository.sh"
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This command must run as root.' >&2; exit 1; }
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
validate_restic_password_file "$password_file" || exit 1
repo="rclone:${remote}:Avelren Backups/restic"
configure_restic_repository "$repo" || exit 1
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic check --password-file "$password_file" >/dev/null
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$RESTIC_REPOSITORY_URL" restic forget --password-file "$password_file" --tag "$RESTIC_POSTGRES_TAG" --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune >/dev/null
printf '%s\n' 'Controlled PostgreSQL retention completed.'
