#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image_tag="avelren-caddy-capability-test:${GITHUB_RUN_ID:-local}-${RANDOM}"

cleanup() {
  docker image rm --force "$image_tag" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --pull --tag "$image_tag" "$repository_root/deploy/caddy"

if ! MSYS_NO_PATHCONV=1 docker run --rm --network none --entrypoint sh "$image_tag" -ec 'test -z "$(getcap /usr/bin/caddy)"'; then
  printf '%s\n' 'Unexpected Caddy file capabilities.' >&2
  exit 1
fi

version_output="$(MSYS_NO_PATHCONV=1 docker run --rm --network none --read-only --user 10001:10001 --security-opt no-new-privileges:true --cap-drop ALL --entrypoint caddy "$image_tag" version)"
if [ -z "$version_output" ]; then
  printf '%s\n' 'Caddy version command returned no output.' >&2
  exit 1
fi

printf '%s\n' 'Caddy capability regression test passed.'
