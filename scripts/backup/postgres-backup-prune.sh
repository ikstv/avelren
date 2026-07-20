#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This command must run as root.' >&2; exit 1; }
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
case "$remote" in (''|*[!A-Za-z0-9_-]*) printf '%s\n' 'Invalid rclone remote name.' >&2; exit 1;; esac
repo="rclone:${remote}:Avelren Backups/restic"
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$repo" restic check --password-file "$password_file" >/dev/null
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$repo" restic forget --password-file "$password_file" --tag postgres --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune >/dev/null
printf '%s\n' 'Controlled PostgreSQL retention completed.'
