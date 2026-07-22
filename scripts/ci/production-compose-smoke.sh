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
postgres_container="$("${compose[@]}" ps -q postgres)"
runtime_root=/run/avelren-backup
[ -n "$(docker inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$postgres_container")" ]
[ "$("${compose[@]}" exec -T -u 0 postgres stat -c '%u:%g:%a' "$runtime_root")" = '0:0:700' ]
# Verify the effective kernel mount as well as the Docker declaration. The
# target is canonical and unescaped, so exact mountinfo field matching cannot
# accept a nested or similarly named mount point.
"${compose[@]}" exec -T -u 0 postgres sh -s -- "$runtime_root" <<'EOF'
set -eu
target="$1"
if ! awk -v target="$target" '
  function has(options, expected,  count, item) {
    count = split(options, item, ",")
    for (i = 1; i <= count; i++) if (item[i] == expected) return 1
    return 0
  }
  $5 == target {
    dash = 0
    for (i = 7; i <= NF; i++) if ($i == "-") { dash = i; break }
    if (!dash || $(dash + 1) != "tmpfs") exit 1
    if (!has($6, "rw") || !has($6, "noexec") || !has($6, "nosuid") || !has($6, "nodev")) exit 1
    found++
  }
  END { exit found == 1 ? 0 : 1 }
' /proc/self/mountinfo
then
  printf '%s\n' 'Effective PostgreSQL backup tmpfs mount validation failed.' >&2
  awk -v target="$target" '$5 == target { print }' /proc/self/mountinfo >&2
  exit 1
fi
[ "$(stat -c '%u:%g:%a' "$target")" = '0:0:700' ]
EOF

# A real disposable copy of the mounted credential and its operation state must
# disappear on container restart because the runtime is a dedicated tmpfs.
# Expansion belongs to the isolated shell inside the disposable container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c '
  mkdir -m 700 "$1/restart-proof"
  cp /run/secrets/postgres_password "$1/restart-proof/pgpass.fixture"
  chmod 600 "$1/restart-proof/pgpass.fixture"
  [ "$(stat -c "%u:%g:%a" "$1/restart-proof/pgpass.fixture")" = "0:0:600" ]
' sh "$runtime_root"
"${compose[@]}" restart postgres >/dev/null
"${compose[@]}" up -d --wait --wait-timeout 120 postgres
"${compose[@]}" exec -T -u 0 postgres test ! -e "$runtime_root/restart-proof"
[ "$("${compose[@]}" exec -T -u 0 postgres stat -c '%u:%g:%a' "$runtime_root")" = '0:0:700' ]

postgres_query() {
  # Expansion belongs to the isolated shell inside the PostgreSQL container.
  # shellcheck disable=SC2016
  "${compose[@]}" exec -T -u 0 postgres sh -ec '
    export PGPASSWORD="$(cat /run/secrets/postgres_password)"
    exec psql --host 127.0.0.1 --username "$POSTGRES_USER" \
      --dbname "$POSTGRES_DB" --no-psqlrc --tuples-only --no-align \
      --set ON_ERROR_STOP=1 --command "$1"
  ' sh "$1"
}

backup_helper="$repository_root/scripts/backup/postgres-tcp-dump.sh"
backup_dump="$temporary_root/postgres.dump"
backup_log="$temporary_root/postgres-backup-auth.log"
schema_before="$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
operation_id="$(openssl rand -hex 16)"
control_dir="$runtime_root/operation.$operation_id"
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c \
  'umask 077; mkdir -m 700 -- "$1"; cat >"$1/runner.sh"; chmod 700 "$1/runner.sh"; date +%s >"$1/heartbeat"' \
  sh "$control_dir" <"$backup_helper"
"${compose[@]}" exec -T -u 0 \
  -e "AVELREN_BACKUP_OPERATION_ID=$operation_id" \
  -e AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 \
  postgres sh "$control_dir/runner.sh" avelren avelren "$control_dir" "$operation_id" \
  >"$backup_log" 2>&1
[ "$("${compose[@]}" exec -T postgres cat "$control_dir/status")" = 0 ]
# The Docker archive API does not reliably traverse tmpfs mounts; stream the
# already successful custom dump without printing it to the Actions log.
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c '
  file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ]
  [ "$(stat -c "%u:%g:%a" "$file")" = "0:0:600" ]
  cat -- "$file"
' sh "$control_dir/postgres.dump" >"$backup_dump"
"${compose[@]}" exec -T -u 0 postgres rm -rf -- "$control_dir"
[ -s "$backup_dump" ]
"${compose[@]}" exec -T postgres pg_restore --list <"$backup_dump" >/dev/null
schema_after="$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
[ "$schema_before" = "$schema_after" ]
[ -z "$("${compose[@]}" exec -T postgres find "$runtime_root" -maxdepth 2 -name 'pgpass.*' -print -quit)" ]
if grep -Fq -f "$secret_directory/postgres_password" "$backup_log"; then
  printf '%s\n' 'PostgreSQL password leaked into backup output.' >&2
  exit 1
fi

wrong_password_file="$runtime_root/avelren-wrong-password"
# Expansion belongs to the isolated shell inside the disposable PostgreSQL container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -ec \
  'umask 077; od -An -N32 -tx1 /dev/urandom | tr -d " \n" >"$1"' sh "$wrong_password_file"
wrong_password_status=0
wrong_operation_id="$(openssl rand -hex 16)"
wrong_control_dir="$runtime_root/operation.$wrong_operation_id"
# Expansion belongs to the isolated container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T -u 0 postgres sh -eu -c \
  'umask 077; mkdir -m 700 -- "$1"; cat >"$1/runner.sh"; chmod 700 "$1/runner.sh"; date +%s >"$1/heartbeat"' \
  sh "$wrong_control_dir" <"$backup_helper"
"${compose[@]}" exec -T -u 0 \
  -e "AVELREN_BACKUP_OPERATION_ID=$wrong_operation_id" \
  -e AVELREN_BACKUP_HEARTBEAT_TIMEOUT=30 \
  -e AVELREN_POSTGRES_PASSWORD_FILE="$wrong_password_file" \
  postgres sh "$wrong_control_dir/runner.sh" avelren avelren "$wrong_control_dir" "$wrong_operation_id" \
  >/dev/null 2>>"$backup_log" || wrong_password_status=$?
"${compose[@]}" exec -T -u 0 postgres rm -f -- "$wrong_password_file"
[ "$wrong_password_status" -ne 0 ]
[ "$("${compose[@]}" exec -T postgres cat "$wrong_control_dir/status")" -ne 0 ]
[ -z "$("${compose[@]}" exec -T postgres find "$wrong_control_dir" -maxdepth 1 -name 'pgpass.*' -print -quit)" ]
"${compose[@]}" exec -T -u 0 postgres rm -rf -- "$wrong_control_dir"

[ "$(postgres_query 'SELECT current_database()')" = 'avelren' ]
[ "$(postgres_query 'SELECT current_user')" = 'avelren' ]

sudo env \
  "PATH=$PATH" \
  "COMPOSE_PROJECT_NAME=$project_name" \
  "AVELREN_TEST_REPOSITORY_ROOT=$repository_root" \
  "AVELREN_TEST_COMPOSE_FILE=$repository_root/docker-compose.yml" \
  "AVELREN_TEST_ENV_FILE=$environment_file" \
  "AVELREN_TEST_ROOT=$temporary_root" \
  "$repository_root/scripts/ci/postgres-backup-compose-cancel-test.sh"

"${compose[@]}" up -d --build api
"${compose[@]}" up -d --wait --wait-timeout 180 api

[ "$(postgres_query "SELECT string_agg(version, ',' ORDER BY version) FROM avelren_schema_migrations")" = '001,002,003' ]
[ "$(postgres_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'avelren_schema_migrations'")" = '1' ]
[ -z "$("${compose[@]}" ps -q caddy)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q postgres)" | grep -E 'HostIp|HostPort' || true)" ]
[ -z "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$("${compose[@]}" ps -q api)" | grep -E 'HostIp|HostPort' || true)" ]

printf '%s\n' 'Production Compose smoke test passed: clean PostgreSQL initialization, API health, and migrations 001-003.'
