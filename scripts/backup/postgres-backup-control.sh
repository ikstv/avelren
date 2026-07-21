#!/bin/sh
set -eu

action="${1:-}"
control_dir="${2:-}"
operation_id="${3:-}"
argument="${4:-}"

case "$operation_id" in ''|*[!a-f0-9]*) exit 64 ;; esac
[ "${#operation_id}" -eq 32 ] || exit 64
[ "$control_dir" = "/tmp/avelren-pg-backup.$operation_id" ] || exit 64

if [ -e "$control_dir" ]; then
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || exit 65
  [ "$(stat -c '%u:%a' "$control_dir")" = '0:700' ] || exit 65
fi

process_matches() {
  role="$1"
  identity_file="$control_dir/$role.identity"
  [ -r "$identity_file" ] || return 1
  identity="$(cat "$identity_file")"
  pid="${identity%%:*}"
  start_time="${identity#*:}"
  case "$pid:$start_time" in *[!0-9:]*) return 1 ;; esac
  [ -n "$pid" ] && [ -n "$start_time" ] || return 1
  [ -r "/proc/$pid/stat" ] || return 1
  [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start_time" ] || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  tr '\000' '\n' <"/proc/$pid/environ" | grep -Fqx "AVELREN_BACKUP_OPERATION_ID=$operation_id"
}

signal_role() {
  role="$1"
  signal="$2"
  process_matches "$role" || return 0
  identity="$(cat "$control_dir/$role.identity")"
  pid="${identity%%:*}"
  kill -"$signal" "$pid" 2>/dev/null || true
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
    elif process_matches supervisor; then
      printf '%s\n' running
    elif [ -r "$control_dir/supervisor.identity" ]; then
      printf '%s\n' stopped
    elif [ -d "$control_dir" ]; then
      printf '%s\n' starting
    else
      printf '%s\n' missing
    fi
    ;;
  signal)
    case "$argument" in
      TERM) signal_role supervisor TERM ;;
      KILL)
        signal_role dump KILL
        signal_role watchdog KILL
        signal_role supervisor KILL
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
      if process_matches "$role"; then exit 66; fi
    done
    [ ! -e "$control_dir" ] || rm -rf -- "$control_dir"
    ;;
  *) exit 64 ;;
esac
