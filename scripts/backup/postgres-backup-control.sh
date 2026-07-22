#!/bin/sh
set -eu

action="${1:-}"
control_dir="${2:-}"
operation_id="${3:-}"
role="${4:-}"
requested_signal="${5:-}"

case "$operation_id" in ''|*[!a-f0-9]*) exit 64 ;; esac
[ "${#operation_id}" -eq 32 ] || exit 64
[ "$control_dir" = "/run/avelren-backup/operation.$operation_id" ] || exit 64

if [ -e "$control_dir" ]; then
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 65
  [ "$(stat -c '%u:%a' "$control_dir")" = '0:700' ] || exit 65
fi

process_matches_identity() {
  role="$1"
  identity="$2"
  identity_file="$control_dir/$role.identity"
  pid="${identity%%:*}"
  start_time="${identity#*:}"
  case "$pid:$start_time" in *[!0-9:]*) return 1 ;; esac
  [ -n "$pid" ] && [ -n "$start_time" ] || return 1
  [ -r "/proc/$pid/stat" ] || return 1
  [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start_time" ] || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  tr '\000' '\n' <"/proc/$pid/environ" | grep -Fqx "AVELREN_BACKUP_OPERATION_ID=$operation_id"
}

process_matches() {
  role="$1"
  identity_file="$control_dir/$role.identity"
  [ -r "$identity_file" ] || return 1
  identity="$(cat "$identity_file")"
  process_matches_identity "$role" "$identity"
}

identity_exists() {
  role="$1"
  identity_file="$control_dir/$role.identity"
  [ -r "$identity_file" ] || return 1
  identity="$(cat "$identity_file")"
  pid="${identity%%:*}"
  start_time="${identity#*:}"
  case "$pid:$start_time" in *[!0-9:]*) return 1 ;; esac
  [ -n "$pid" ] && [ -n "$start_time" ] || return 1
  [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start_time" ]
}

cleanup_owned_setup() {
  setup_token="$1"
  case "$setup_token" in ''|*[!a-f0-9]*) exit 64 ;; esac
  [ "${#setup_token}" -eq 32 ] || exit 64
  if [ ! -e "$control_dir" ] && [ ! -L "$control_dir" ]; then return 0; fi
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 67
  [ "$(stat -c '%u:%g:%a' "$control_dir")" = '0:0:700' ] || exit 67
  setup_owner="$control_dir/.setup-owner"
  [ -f "$setup_owner" ] && [ ! -L "$setup_owner" ] || exit 67
  [ "$(stat -c '%h:%u:%g:%a' "$setup_owner")" = '1:0:0:600' ] || exit 67
  [ "$(cat "$setup_owner")" = "$setup_token" ] || exit 67
  for setup_role in supervisor dump watchdog; do
    if identity_exists "$setup_role"; then exit 66; fi
  done
  # Revalidate the exact ownership marker immediately before the scoped remove.
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 67
  [ "$(stat -c '%u:%g:%a' "$control_dir")" = '0:0:700' ] || exit 67
  [ -f "$setup_owner" ] && [ ! -L "$setup_owner" ] || exit 67
  [ "$(stat -c '%h:%u:%g:%a' "$setup_owner")" = '1:0:0:600' ] || exit 67
  [ "$(cat "$setup_owner")" = "$setup_token" ] || exit 67
  for setup_role in supervisor dump watchdog; do
    if identity_exists "$setup_role"; then exit 66; fi
  done
  rm -rf -- "$control_dir"
}

signal_role() {
  role="$1"
  signal="$2"
  identity_file="$control_dir/$role.identity"
  [ -r "$identity_file" ] || return 0
  identity="$(cat "$identity_file")"
  process_matches_identity "$role" "$identity" || return 0
  # Re-read and validate immediately before kill. Any changed or stale identity
  # fails closed; this narrows but cannot make the OS PID check-and-signal atomic.
  [ "$(cat "$identity_file")" = "$identity" ] || return 0
  process_matches_identity "$role" "$identity" || return 0
  pid="${identity%%:*}"
  kill -"$signal" "$pid" 2>/dev/null || true
  if process_matches_identity "$role" "$identity"; then printf '%s\n' running; else printf '%s\n' stopped; fi
}

case "$action" in
  heartbeat)
    [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 1
    now="$(date +%s)"
    printf '%s\n' "$now" >"$control_dir/heartbeat.tmp"
    mv -f -- "$control_dir/heartbeat.tmp" "$control_dir/heartbeat"
    ;;
  state)
    if [ -r "$control_dir/status" ]; then
      status="$(cat "$control_dir/status")"
      case "$status" in ''|*[!0-9]*) exit 65 ;; esac
      printf 'done:%s\n' "$status"
    elif identity_exists supervisor; then
      printf '%s\n' running
    elif [ -r "$control_dir/supervisor.identity" ]; then
      printf '%s\n' stopped
    elif [ -d "$control_dir" ]; then
      printf '%s\n' starting
    else
      printf '%s\n' missing
    fi
    ;;
  role-state)
    case "$role" in supervisor|dump|watchdog) ;; *) exit 64 ;; esac
    if identity_exists "$role"; then printf '%s\n' running; else printf '%s\n' stopped; fi
    ;;
  signal)
    case "$role:$requested_signal" in
      supervisor:TERM|supervisor:KILL|dump:TERM|dump:KILL|watchdog:TERM|watchdog:KILL)
        signal_role "$role" "$requested_signal"
        ;;
      *) exit 64 ;;
    esac
    ;;
  identities)
    for role in supervisor dump watchdog; do
      if process_matches "$role"; then printf '%s:%s\n' "$role" "$(cat "$control_dir/$role.identity")"; fi
    done
    ;;
  cleanup)
    for role in supervisor dump watchdog; do
      if identity_exists "$role"; then exit 66; fi
    done
    [ ! -e "$control_dir" ] || rm -rf -- "$control_dir"
    ;;
  cleanup-owned)
    cleanup_owned_setup "$role"
    ;;
  *) exit 64 ;;
esac
