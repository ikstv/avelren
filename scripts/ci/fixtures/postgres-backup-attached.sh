#!/usr/bin/env bash
set -Eeuo pipefail

# Deterministic negative mutation of the historical attached transfer. It is
# test-only: terminating this outer shell does not own the inner exec process.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compose_file="${AVELREN_COMPOSE_FILE:?}"
env_file="${AVELREN_ENV_FILE:?}"
pg_database="${AVELREN_PG_DATABASE:-avelren}"
pg_user="${AVELREN_PG_USER:-avelren}"
compose=(docker compose --env-file "$env_file" --file "$compose_file")

"${compose[@]}" exec -T -u 0 postgres sh -s -- "$pg_database" "$pg_user" \
  <"$script_dir/postgres-tcp-dump-attached.sh"
