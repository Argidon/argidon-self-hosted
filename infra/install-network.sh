#!/usr/bin/env bash
# Creates the attachable overlay network shared by Swarm and Compose workloads.
# Usage: ./install-network.sh
set -euo pipefail

NETWORK_NAME="mhews"

command -v docker >/dev/null 2>&1 || {
  echo "Docker Engine is not installed. Run ./install-docker.sh first." >&2
  exit 1
}

docker info >/dev/null 2>&1 || {
  echo "Docker is installed but its daemon is unavailable." >&2
  exit 1
}

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}')"
if [[ "$SWARM_STATE" != "active" ]]; then
  echo "Docker Swarm is not active. Run ./install-docker.sh first." >&2
  exit 1
fi

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  DRIVER="$(docker network inspect --format '{{.Driver}}' "$NETWORK_NAME")"
  SCOPE="$(docker network inspect --format '{{.Scope}}' "$NETWORK_NAME")"
  ATTACHABLE="$(docker network inspect --format '{{.Attachable}}' "$NETWORK_NAME")"

  if [[ "$DRIVER" != "overlay" || "$SCOPE" != "swarm" || "$ATTACHABLE" != "true" ]]; then
    echo "Existing '$NETWORK_NAME' network is incompatible:" >&2
    echo "  driver=$DRIVER scope=$SCOPE attachable=$ATTACHABLE" >&2
    echo "It must be an attachable Swarm overlay network. Remove or rename it," >&2
    echo "then rerun this script." >&2
    exit 1
  fi

  echo "==> '$NETWORK_NAME' is already an attachable Swarm overlay network."
  exit 0
fi

echo "==> Creating attachable Swarm overlay network '$NETWORK_NAME'"
docker network create --driver overlay --attachable "$NETWORK_NAME"
echo "==> '$NETWORK_NAME' is ready for Swarm services and Compose containers."