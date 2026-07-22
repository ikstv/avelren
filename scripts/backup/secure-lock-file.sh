#!/usr/bin/env bash

# Shared secure host-lock primitive for the backup and restore entrypoints.
# Bash does not expose O_NOFOLLOW. Safety therefore relies on a canonical path
# below a validated root-controlled parent, an exact root-only directory,
# atomic O_CREAT|O_EXCL creation for an absent file, and post-open identity
# validation. A root-equivalent actor is outside this local threat model.

AVELREN_SECURE_LOCK_FD=
AVELREN_SECURE_LOCK_DIRECTORY_FD=
AVELREN_SECURE_LOCK_DIRECTORY_PATH=
AVELREN_SECURE_LOCK_DIRECTORY_REFERENCE=
AVELREN_SECURE_LOCK_NAME=

avelren_secure_lock_close_fd() {
  local variable_name="$1"
  local descriptor="${!variable_name:-}"
  case "$descriptor" in
    '') ;;
    *[!0-9]*) return 1 ;;
    *) exec {descriptor}<&- ;;
  esac
  printf -v "$variable_name" '%s' ''
}

avelren_secure_lock_close() {
  avelren_secure_lock_close_fd AVELREN_SECURE_LOCK_FD
  avelren_secure_lock_close_fd AVELREN_SECURE_LOCK_DIRECTORY_FD
}

avelren_secure_lock_validate_ancestors() {
  local parent="$1" current=/ component metadata owner group mode mode_value
  local -a components paths

  IFS=/ read -r -a components <<<"${parent#/}"
  paths=(/)
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    if [ "$current" = / ]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    paths+=("$current")
  done
  for current in "${paths[@]}"; do
    [ ! -L "$current" ] && [ -d "$current" ] || return 1
    metadata="$(stat -c '%u:%g:%a' -- "$current" 2>/dev/null)" || return 1
    owner="${metadata%%:*}"
    metadata="${metadata#*:}"
    group="${metadata%%:*}"
    mode="${metadata#*:}"
    case "$owner:$group:$mode" in *[!0-9:]*) return 1 ;; esac
    [ "$owner" -eq 0 ] && [ "$group" -eq 0 ] || return 1
    mode_value=$((8#$mode))
    if (( (mode_value & 0022) != 0 )); then
      # Sticky root-owned parents such as /tmp and /var/tmp are acceptable:
      # an unprivileged pre-creation of our exact leaf is detected and rejected.
      (( (mode_value & 01000) != 0 && (mode_value & 0002) != 0 )) || return 1
    fi
  done
}

avelren_secure_lock_directory_identity() {
  local lock_directory="$1" directory_reference="$2" expected_identity="$3"
  local path_identity reference_identity fd_identity

  [ ! -L "$lock_directory" ] && [ -d "$lock_directory" ] || return 1
  [ -d "$directory_reference" ] || return 1
  path_identity="$(stat -c '%d:%i:%u:%g:%a' -- "$lock_directory" 2>/dev/null)" || return 1
  reference_identity="$(stat -Lc '%d:%i:%u:%g:%a' -- "$directory_reference" 2>/dev/null)" || return 1
  fd_identity="$(stat -Lc '%d:%i:%u:%g:%a' -- "/proc/$$/fd/$AVELREN_SECURE_LOCK_DIRECTORY_FD" 2>/dev/null)" || return 1
  [ "$path_identity" = "$reference_identity" ] && [ "$path_identity" = "$fd_identity" ] || return 1
  [ "${path_identity#*:*:}" = '0:0:700' ] || return 1
  [ -z "$expected_identity" ] || [ "$path_identity" = "$expected_identity" ]
}

avelren_secure_lock_file_identity() {
  local lock_path="$1" lock_reference="$2" directory_path="$3" directory_reference="$4" expected_identity="$5"
  local fd_identity path_identity reference_identity

  [ -f "/proc/$$/fd/$AVELREN_SECURE_LOCK_FD" ] || return 1
  [ ! -L "$lock_path" ] && [ -f "$lock_path" ] || return 1
  [ ! -L "$lock_reference" ] && [ -f "$lock_reference" ] || return 1
  # Read the FD first so a replacement injected between these observations is
  # exposed by the subsequent exact-path comparison.
  fd_identity="$(stat -Lc '%d:%i:%h:%u:%g:%a' -- "/proc/$$/fd/$AVELREN_SECURE_LOCK_FD" 2>/dev/null)" || return 1
  path_identity="$(stat -c '%d:%i:%h:%u:%g:%a' -- "$lock_path" 2>/dev/null)" || return 1
  reference_identity="$(stat -c '%d:%i:%h:%u:%g:%a' -- "$lock_reference" 2>/dev/null)" || return 1
  [ "$fd_identity" = "$path_identity" ] && [ "$fd_identity" = "$reference_identity" ] || return 1
  [ "${fd_identity#*:*:}" = '1:0:0:600' ] || return 1
  [ -z "$expected_identity" ] || [ "$fd_identity" = "$expected_identity" ] || return 1
  avelren_secure_lock_directory_identity "$directory_path" "$directory_reference" ''
}

avelren_secure_lock_prepare_directory() {
  local lock_path="$1" canonical lock_directory lock_name parent directory_name
  local parent_identity parent_fd= directory_reference directory_identity

  [ "$(id -u)" -eq 0 ] || return 73
  case "$lock_path" in /*) ;; *) return 73 ;; esac
  [[ "$lock_path" != *[[:cntrl:]]* ]] || return 73
  lock_name="${lock_path##*/}"
  lock_directory="${lock_path%/*}"
  [ -n "$lock_directory" ] || lock_directory=/
  parent="${lock_directory%/*}"
  [ -n "$parent" ] || parent=/
  directory_name="${lock_directory##*/}"
  [[ "$lock_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 73
  [[ "$directory_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 73
  [ "$lock_directory" != / ] || return 73
  avelren_secure_lock_validate_ancestors "$parent" || return 73
  # Reject the exact leaf before canonicalization so realpath never resolves an
  # attacker-supplied directory symlink. Validated ancestors are root-controlled.
  [ ! -L "$lock_directory" ] || return 73
  canonical="$(realpath -m -- "$lock_directory" 2>/dev/null)" || return 73
  [ "$canonical" = "$lock_directory" ] || return 73

  parent_identity="$(stat -c '%d:%i:%u:%g:%a' -- "$parent" 2>/dev/null)" || return 73
  if { exec {parent_fd}<"$parent"; } 2>/dev/null; then :; else return 73; fi
  if [ ! -d "/proc/$$/fd/$parent_fd" ] ||
     [ "$parent_identity" != "$(stat -Lc '%d:%i:%u:%g:%a' -- "/proc/$$/fd/$parent_fd" 2>/dev/null)" ]; then
    exec {parent_fd}<&-
    return 73
  fi

  directory_reference="/proc/$$/fd/$parent_fd/$directory_name"
  if [ ! -L "$directory_reference" ] && [ ! -e "$directory_reference" ]; then
    if mkdir -m 0700 -- "$directory_reference" 2>/dev/null; then :; else
      if [ ! -L "$directory_reference" ] && [ ! -e "$directory_reference" ]; then
        exec {parent_fd}<&-
        return 73
      fi
    fi
  fi
  if [ -L "$lock_directory" ] || [ ! -d "$lock_directory" ] ||
     [ "$(stat -c '%u:%g:%a' -- "$lock_directory" 2>/dev/null)" != '0:0:700' ]; then
    exec {parent_fd}<&-
    return 73
  fi
  directory_identity="$(stat -c '%d:%i:%u:%g:%a' -- "$lock_directory" 2>/dev/null)" || {
    exec {parent_fd}<&-
    return 73
  }
  if [ "$directory_identity" != "$(stat -c '%d:%i:%u:%g:%a' -- "$directory_reference" 2>/dev/null)" ]; then
    exec {parent_fd}<&-
    return 73
  fi
  if { exec {AVELREN_SECURE_LOCK_DIRECTORY_FD}<"$directory_reference"; } 2>/dev/null; then :; else
    exec {parent_fd}<&-
    return 73
  fi
  if ! avelren_secure_lock_directory_identity "$lock_directory" "$directory_reference" "$directory_identity"; then
    exec {parent_fd}<&-
    avelren_secure_lock_close
    return 73
  fi
  exec {parent_fd}<&-
  AVELREN_SECURE_LOCK_DIRECTORY_PATH="$lock_directory"
  AVELREN_SECURE_LOCK_DIRECTORY_REFERENCE="/proc/$$/fd/$AVELREN_SECURE_LOCK_DIRECTORY_FD"
  AVELREN_SECURE_LOCK_NAME="$lock_name"
}

avelren_secure_lock_acquire() {
  local lock_path="$1" lock_directory lock_name lock_reference
  local file_identity= saved_umask noclobber_was_set=0 create_status=0 flock_status=0

  avelren_secure_lock_close
  # Dynamic descriptors must survive the command that allocates them.
  shopt -u varredir_close
  if avelren_secure_lock_prepare_directory "$lock_path"; then :; else return $?; fi
  lock_directory="$AVELREN_SECURE_LOCK_DIRECTORY_PATH"
  lock_name="$AVELREN_SECURE_LOCK_NAME"
  lock_reference="$AVELREN_SECURE_LOCK_DIRECTORY_REFERENCE/$lock_name"

  if [ -L "$lock_reference" ] || [ -e "$lock_reference" ]; then
    [ ! -L "$lock_reference" ] && [ -f "$lock_reference" ] || { avelren_secure_lock_close; return 74; }
    file_identity="$(stat -c '%d:%i:%h:%u:%g:%a' -- "$lock_reference" 2>/dev/null)" || {
      avelren_secure_lock_close
      return 74
    }
    [ "${file_identity#*:*:}" = '1:0:0:600' ] || { avelren_secure_lock_close; return 74; }
    # A read-only open is sufficient for Linux flock and cannot truncate or
    # recreate the already validated regular file.
    if { exec {AVELREN_SECURE_LOCK_FD}<"$lock_reference"; } 2>/dev/null; then :; else
      avelren_secure_lock_close
      return 74
    fi
  else
    saved_umask="$(umask)"
    case $- in *C*) noclobber_was_set=1 ;; esac
    umask 077
    set -o noclobber
    if { :; } 2>/dev/null {AVELREN_SECURE_LOCK_FD}>"$lock_reference"; then
      create_status=0
    else
      create_status=$?
    fi
    [ "$noclobber_was_set" -eq 1 ] || set +o noclobber
    umask "$saved_umask"
    if [ "$create_status" -ne 0 ] || [ -z "${AVELREN_SECURE_LOCK_FD:-}" ]; then
      AVELREN_SECURE_LOCK_FD=
      # A trusted concurrent invocation may have won atomic creation. Validate
      # the resulting object and continue to flock it so the legacy collision
      # status and diagnostic remain deterministic.
      if [ ! -L "$lock_reference" ] && [ -f "$lock_reference" ]; then
        file_identity="$(stat -c '%d:%i:%h:%u:%g:%a' -- "$lock_reference" 2>/dev/null)" || file_identity=
      else
        file_identity=
      fi
      if [ -z "$file_identity" ] || [ "${file_identity#*:*:}" != '1:0:0:600' ]; then
        avelren_secure_lock_close
        return 74
      fi
      if { exec {AVELREN_SECURE_LOCK_FD}<"$lock_reference"; } 2>/dev/null; then :; else
        avelren_secure_lock_close
        return 74
      fi
    fi
  fi

  if ! avelren_secure_lock_file_identity "$lock_path" "$lock_reference" "$lock_directory" \
      "$AVELREN_SECURE_LOCK_DIRECTORY_REFERENCE" "$file_identity"; then
    avelren_secure_lock_close
    return 74
  fi
  if flock -n -E 75 "$AVELREN_SECURE_LOCK_FD" 2>/dev/null; then
    flock_status=0
  else
    flock_status=$?
  fi
  if [ "$flock_status" -ne 0 ]; then
    avelren_secure_lock_close
    [ "$flock_status" -eq 75 ] && return 75
    return 74
  fi
  if ! avelren_secure_lock_file_identity "$lock_path" "$lock_reference" "$lock_directory" \
      "$AVELREN_SECURE_LOCK_DIRECTORY_REFERENCE" "$file_identity"; then
    avelren_secure_lock_close
    return 74
  fi
}
