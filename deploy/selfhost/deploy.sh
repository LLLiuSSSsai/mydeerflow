#!/usr/bin/env bash
#
# Pull the images built by .github/workflows/deploy.yml and restart DeerFlow.
# Run from anywhere; the script cd's to the repository root.
#
# Required environment:
#   DEER_FLOW_IMAGE_PREFIX  e.g. ghcr.io/owner/deer-flow
# Optional:
#   IMAGE_TAG               defaults to latest; the workflow passes sha-<commit>
#
# The server's .env supplies the runtime paths, secrets and bind address.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed or not on PATH" >&2
    exit 1
fi

if [ ! -f .env ]; then
    echo "Missing $REPO_ROOT/.env (runtime paths and secrets)" >&2
    exit 1
fi

if [ -z "${DEER_FLOW_IMAGE_PREFIX:-}" ]; then
    echo "Set DEER_FLOW_IMAGE_PREFIX, e.g. ghcr.io/owner/deer-flow" >&2
    exit 1
fi

COMPOSE=(
    docker compose
    --env-file .env
    -p deer-flow
    -f docker/docker-compose.yaml
    -f deploy/selfhost/docker-compose.images.yaml
)

echo "Pulling ${DEER_FLOW_IMAGE_PREFIX}-{backend,frontend}:${IMAGE_TAG:-latest}"
"${COMPOSE[@]}" pull gateway frontend

echo "Starting services"
"${COMPOSE[@]}" up -d --no-build --remove-orphans --wait --wait-timeout 300 \
    redis gateway frontend nginx

docker image prune -f
echo "Deployment complete"
