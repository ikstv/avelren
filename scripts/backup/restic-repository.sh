#!/usr/bin/env bash

configure_restic_repository() {
  local repository="${1:-}"
  local rclone_path
  local remote
  local path

  if [ -z "$repository" ] || printf '%s' "$repository" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    printf '%s\n' 'Restic repository configuration is invalid.' >&2
    return 1
  fi

  case "$repository" in
    rclone:rclone:*|rclone:|rclone::*|rclone:*:)
      printf '%s\n' 'Restic repository configuration is invalid.' >&2
      return 1
      ;;
    rclone:*) ;;
    *)
      printf '%s\n' 'Restic repository configuration is invalid.' >&2
      return 1
      ;;
  esac

  rclone_path="${repository#rclone:}"
  remote="${rclone_path%%:*}"
  path="${rclone_path#*:}"
  if [ "$path" = "$rclone_path" ] || [ -z "$remote" ] || [ -z "$path" ]; then
    printf '%s\n' 'Restic repository configuration is invalid.' >&2
    return 1
  fi
  case "$remote" in
    *[!A-Za-z0-9_-]*)
      printf '%s\n' 'Restic repository configuration is invalid.' >&2
      return 1
      ;;
  esac

  # Outputs are consumed by scripts that source this helper.
  # shellcheck disable=SC2034
  RESTIC_REPOSITORY_URL="$repository"
  # shellcheck disable=SC2034
  RCLONE_REPOSITORY_PATH="$rclone_path"
  RCLONE_REMOTE_ROOT="${remote}:"
  case "$path" in
    # shellcheck disable=SC2034
    */*) RCLONE_REPOSITORY_PARENT="${remote}:${path%/*}" ;;
    # shellcheck disable=SC2034
    *) RCLONE_REPOSITORY_PARENT="$RCLONE_REMOTE_ROOT" ;;
  esac
}
