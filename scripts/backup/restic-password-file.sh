#!/usr/bin/env bash

validate_restic_password_file() {
  local password_file_path="${1:-}"
  local owner_uid
  local file_mode

  if [ -z "$password_file_path" ] || [ -L "$password_file_path" ] || [ ! -f "$password_file_path" ] || [ ! -s "$password_file_path" ]; then
    printf '%s\n' 'Restic password file metadata is invalid.' >&2
    return 1
  fi

  owner_uid="$(stat -c '%u' -- "$password_file_path")" || return 1
  file_mode="$(stat -c '%a' -- "$password_file_path")" || return 1
  if [ "$owner_uid" != 0 ]; then
    printf '%s\n' 'Restic password file metadata is invalid.' >&2
    return 1
  fi

  case "$file_mode" in
    400|600) return 0 ;;
    *)
      printf '%s\n' 'Restic password file metadata is invalid.' >&2
      return 1
      ;;
  esac
}
