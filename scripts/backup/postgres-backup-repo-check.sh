#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'This command must run as root.' >&2; exit 1; }
remote="${AVELREN_RCLONE_REMOTE:?AVELREN_RCLONE_REMOTE is required}"
password_file="${AVELREN_RESTIC_PASSWORD_FILE:-/etc/avelren/backup/restic_password}"
rclone_config="${AVELREN_RCLONE_CONFIG:-/etc/avelren/backup/rclone.conf}"
case "$remote" in (''|*[!A-Za-z0-9_-]*) printf '%s\n' 'Invalid rclone remote name.' >&2; exit 1;; esac
repo="rclone:${remote}:Avelren Backups/restic"
RCLONE_CONFIG="$rclone_config" rclone lsd "rclone:${remote}:" >/dev/null
RCLONE_CONFIG="$rclone_config" rclone lsf "rclone:${remote}:Avelren Backups" >/dev/null
RCLONE_CONFIG="$rclone_config" RESTIC_REPOSITORY="$repo" restic check --password-file "$password_file" >/dev/null
RCLONE_CONFIG="$rclone_config" rclone size --json "$repo" | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/repository_bytes=\1/p'
