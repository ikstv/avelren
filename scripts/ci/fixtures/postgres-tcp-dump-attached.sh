#!/bin/sh
set -eu

# Deterministic test-only fixture for the historical attached cancellation
# defect. Production uses the supervised detached helper instead.
pg_database="${1:-}"
pg_user="${2:-}"
password_file="${AVELREN_POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password}"
pgpass_tmpdir="${AVELREN_PGPASS_TMPDIR:-/tmp}"
pgpass_file=
dump_pid=

case "$pg_database:$pg_user" in
  *[!A-Za-z0-9_:]*|:*|*:)
    exit 64
    ;;
esac

# Invoked through the EXIT trap.
# shellcheck disable=SC2317,SC2329
cleanup() {
  exit_code=$?
  trap - EXIT
  if [ -n "$dump_pid" ]; then
    kill -TERM "$dump_pid" 2>/dev/null || true
    wait "$dump_pid" 2>/dev/null || true
  fi
  if [ -n "$pgpass_file" ]; then
    rm -f -- "$pgpass_file"
  fi
  exit "$exit_code"
}

# Invoked through signal traps.
# shellcheck disable=SC2317,SC2329
terminate() {
  exit_code="$1"
  trap - INT TERM HUP
  if [ -n "$dump_pid" ]; then
    kill -TERM "$dump_pid" 2>/dev/null || true
    wait "$dump_pid" 2>/dev/null || true
    dump_pid=
  fi
  exit "$exit_code"
}

trap cleanup EXIT
trap 'terminate 130' INT
trap 'terminate 143' TERM
trap 'terminate 129' HUP

[ -f "$password_file" ] && [ ! -L "$password_file" ] && [ -s "$password_file" ]
[ "$(wc -l <"$password_file")" -eq 0 ]

umask 077
pgpass_file="$(mktemp "$pgpass_tmpdir/avelren-pgpass.XXXXXX")"
chmod 600 "$pgpass_file"
[ "$(stat -c '%a' "$pgpass_file")" = 600 ]

{
  printf '127.0.0.1:5432:%s:%s:' "$pg_database" "$pg_user"
  sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' "$password_file"
  printf '\n'
} >"$pgpass_file"

PGPASSFILE="$pgpass_file"
export PGPASSFILE
pg_dump \
  --host 127.0.0.1 \
  --port 5432 \
  --username "$pg_user" \
  --dbname "$pg_database" \
  --format=custom \
  --no-owner \
  --no-acl \
  </dev/null &
dump_pid=$!
dump_status=0
wait "$dump_pid" || dump_status=$?
dump_pid=
exit "$dump_status"
