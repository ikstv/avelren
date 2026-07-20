#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/avelren-compose-smoke.XXXXXX")"
project_name="avelren-smoke-${GITHUB_RUN_ID:-local}-${RANDOM}"
project_name="$(printf '%s' "$project_name" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
environment_file="$temporary_root/.env.production"
secret_directory="$temporary_root/secrets"
is_msys=false
case "${OSTYPE:-}" in
  msys* | cygwin*) is_msys=true ;;
esac

cleanup() {
  local exit_code=$?
  trap - EXIT
  if [[ "$project_name" != avelren-smoke-* ]] || [[ "$temporary_root" != */avelren-compose-smoke.* ]]; then
    printf '%s\n' 'Refusing cleanup outside disposable smoke-test scope.' >&2
    exit 90
  fi
  if [ "$exit_code" -ne 0 ] && [ -f "$environment_file" ]; then
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" ps --all || true
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" logs --no-color --tail=100 postgres api 2>&1 \
      | sed -E 's#postgres(ql)?://[^[:space:]]+#[REDACTED_DATABASE_URL]#g' || true
  fi
  if [ -f "$environment_file" ]; then
    docker compose --project-name "$project_name" --env-file "$environment_file" \
      --project-directory "$repository_root" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ "$is_msys" = true ]; then
    :
  elif [ "$(id -u)" -eq 0 ]; then
    chown -R "$(id -u):$(id -g)" "$temporary_root" 2>/dev/null || true
  else
    docker run --rm --user 0 --volume "$temporary_root:/cleanup" \
      --entrypoint chown postgres:17-alpine -R "$(id -u):$(id -g)" /cleanup \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temporary_root"
  exit "$exit_code"
}
trap cleanup EXIT

umask 077
mkdir -p "$secret_directory"
chmod 700 "$secret_directory" || [ "$is_msys" = true ]
postgres_password="$(openssl rand -hex 32)"
printf '%s' "$postgres_password" > "$secret_directory/postgres_password"
printf 'postgresql://avelren:%s@postgres:5432/avelren' "$postgres_password" \
  > "$secret_directory/database_url"
unset postgres_password
chmod 600 "$secret_directory/postgres_password"
chmod 0400 "$secret_directory/database_url"
if [ "$is_msys" = true ]; then
  :
elif [ "$(id -u)" -eq 0 ]; then
  chown 10001:10001 "$secret_directory/database_url"
else
  docker run --rm --user 0 --volume "$secret_directory:/secrets" \
    --entrypoint chown postgres:17-alpine 10001:10001 /secrets/database_url \
    >/dev/null
fi

if [ "$is_msys" = false ]; then
  [ "$(stat -c '%a' "$secret_directory")" = '700' ]
  [ "$(stat -c '%a' "$secret_directory/postgres_password")" = '600' ]
  [ "$(stat -c '%u:%g %a' "$secret_directory/database_url")" = '10001:10001 400' ]
fi

compose_postgres_password="$secret_directory/postgres_password"
compose_database_url="$secret_directory/database_url"
if [ "$is_msys" = true ]; then
  compose_postgres_password="$(cygpath -m "$compose_postgres_password")"
  compose_database_url="$(cygpath -m "$compose_database_url")"
fi

printf '%s\n' \
  'AVELREN_DOMAIN=smoke.example.invalid' \
  'ACME_EMAIL=smoke@example.invalid' \
  'AVELREN_INSTANCE_ID=avelren-smoke' \
  'POSTGRES_DB=avelren' \
  'POSTGRES_USER=avelren' \
  "POSTGRES_PASSWORD_FILE=$compose_postgres_password" \
  "DATABASE_URL_FILE=$compose_database_url" \
  > "$environment_file"
chmod 600 "$environment_file"

compose=(
  docker compose
  --project-name "$project_name"
  --env-file "$environment_file"
  --project-directory "$repository_root"
)

if docker volume ls --quiet --filter "label=com.docker.compose.project=$project_name" | grep -q .; then
  printf '%s\n' 'Disposable Compose project already has resources.' >&2
  exit 91
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d --build postgres
"${compose[@]}" up -d --wait --wait-timeout 120 postgres

postgres_query() {
  "${compose[@]}" exec -T -u 0 postgres sh -ec '
    export PGPASSWORD="$(cat /run/secrets/postgres_password)"
    exec psql --host 127.0.0.1 --username "$POSTGRES_USER" \
      --dbname "$POSTGRES_DB" --no-psqlrc --tuples-only --no-align \
      --set ON_ERROR_STOP=1 --command "$1"
  ' sh "$1"
}

[ "$(postgres_query 'SELECT current_database()')" = 'avelren' ]
[ "$(postgres_query 'SELECT current_user')" = 'avelren' ]

"${compose[@]}" up -d --build api
"${compose[@]}" up -d --wait --wait-timeout 180 api

[ "$(postgres_query "SELECT string_agg(version, ',' ORDER BY version) FROM avelren_schema_migrations")" = '001,002,003' ]
[ "$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'avelren_schema_migrations'")" = '1' ]
[ -z "$("${compose[@]}" ps -q caddy)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q postgres)" | grep -E 'HostIp|HostPort' || true)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q api)" | grep -E 'HostIp|HostPort' || true)" ]

printf '%s\n' 'Production Compose smoke test passed: clean PostgreSQL initialization, API health, and migrations 001-003.'
