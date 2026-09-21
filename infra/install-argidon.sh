#!/usr/bin/env bash
# infra/install.sh — single entrypoint that takes a fresh Docker host to:
# single-manager Swarm initialized, overlay network created, core images
# pulled from GHCR, core services + all importer Jobs + the swarm-cronjob
# scheduler deployed. Idempotent — safe to re-run.
#
# Usage: ./install.sh [--advertise-addr <ip>]
#
# Does NOT deploy the Supabase node, backups, or monitoring stack — those
# are separate, independently-runnable pieces with their own setup steps.
# See supabase/README.md, backups/README.md, monitoring/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWARM_DIR="$SCRIPT_DIR"
STACK_NAME="mhews"
NETWORK_NAME="mhews"

ADVERTISE_ADDR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --advertise-addr)
      ADVERTISE_ADDR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  echo "Docker is not installed." >&2
  exit 1
}

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 0.0.0)"
DOCKER_MAJOR="$(echo "$DOCKER_VERSION" | cut -d. -f1)"
if [[ "$DOCKER_MAJOR" -lt 20 ]]; then
  echo "Docker Engine 20.10+ is required for Swarm Jobs (--mode" \
       "replicated-job); detected $DOCKER_VERSION." >&2
  exit 1
fi

echo "==> Checking Swarm status"
SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"
if [[ "$SWARM_STATE" == "active" ]]; then
  echo "    Already in a swarm — skipping 'docker swarm init'."
else
  echo "==> Initializing single-manager Swarm"
  if [[ -n "$ADVERTISE_ADDR" ]]; then
    docker swarm init --advertise-addr "$ADVERTISE_ADDR"
  else
    docker swarm init
  fi
fi

echo "==> Creating overlay network '$NETWORK_NAME' (if missing)"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || \
  docker network create --driver overlay --attachable "$NETWORK_NAME"


export REPO_ROOT

echo "==> Pulling images from GHCR..."
# Built and pushed by .github/workflows/docker-build-*.yml — if the GHCR
# packages are private, run `docker login ghcr.io` first.
GHCR_OWNER="argidon"
for image in mhews-frontend mhews-aggregator mhews-netcdf-service \
             mhews-wind-importer mhews-raster-importer; do
  docker pull "ghcr.io/$GHCR_OWNER/$image:latest"
  echo "==> pulled $image"
done

echo "==> Deploying stacks"
docker stack deploy -c "$SWARM_DIR/stacks/core-services.yml" "$STACK_NAME"
docker stack deploy -c "$SWARM_DIR/stacks/raster-importer-jobs.yml" "$STACK_NAME"
docker stack deploy -c "$SWARM_DIR/stacks/wind-importer-jobs.yml" "$STACK_NAME"
docker stack deploy -c "$SWARM_DIR/stacks/scheduler.yml" "$STACK_NAME"
docker stack deploy -c "$SWARM_DIR/stacks/backup-jobs.yml" "$STACK_NAME"


cat <<EOF

==> Done.
    Check services:     docker service ls
    Check stack tasks:  docker stack ps $STACK_NAME
    Frontend:            http://<this-host>/
    Aggregator health:   http://<this-host>:8765/health

Next steps (not run by this script — see their own READMEs):
  - infra/supabase/    self-hosted Supabase, same machine, shares mhews
  - infra/backups/     nightly Postgres + Storage backups
  - infra/monitoring/  Prometheus/Grafana/Alertmanager/Loki stack
EOF
