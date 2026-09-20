#!/usr/bin/env bash
# Installs Docker Engine when absent, then initializes this node as a Swarm manager.
# Usage: ./install-docker.sh [--advertise-addr <ip-or-interface>]
# You may need to run this script with sudo if not executed as root.
set -euo pipefail

ADVERTISE_ADDR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --advertise-addr)
      [[ $# -ge 2 ]] || { echo "Missing value for --advertise-addr." >&2; exit 1; }
      ADVERTISE_ADDR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script supports Linux hosts only. Install Docker Desktop, enable"
  echo "Docker Swarm, then run 'docker swarm init' on macOS or Windows." >&2
  exit 1
fi

run_as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_docker() {
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y docker
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y docker
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm docker
  else
    echo "Unsupported Linux package manager. Install Docker Engine manually," >&2
    echo "then rerun this script." >&2
    exit 1
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker Engine"
  install_docker
fi

if ! docker info >/dev/null 2>&1; then
  echo "==> Starting Docker"
  run_as_root systemctl enable --now docker
fi

docker info >/dev/null 2>&1 || {
  echo "Docker is installed but its daemon is unavailable." >&2
  exit 1
}

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}')"
DOCKER_MAJOR="$(echo "$DOCKER_VERSION" | cut -d. -f1)"
if [[ "$DOCKER_MAJOR" -lt 20 ]]; then
  echo "Docker Engine 20.10+ is required; detected $DOCKER_VERSION." >&2
  exit 1
fi

if [[ $EUID -ne 0 && -n "${SUDO_USER:-}" ]]; then
  run_as_root usermod -aG docker "$SUDO_USER"
  echo "Added $SUDO_USER to the docker group; log out and back in for passwordless Docker access."
fi

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}')"
if [[ "$SWARM_STATE" == "active" ]]; then
  echo "==> Docker Swarm is already active."
  exit 0
fi

echo "==> Initializing Docker Swarm manager"
if [[ -n "$ADVERTISE_ADDR" ]]; then
  docker swarm init --advertise-addr "$ADVERTISE_ADDR"
else
  docker swarm init
fi

echo "==> Docker Engine and Swarm are ready."