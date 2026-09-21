#!/usr/bin/env bash
#
# infra/create-docker-secrets.sh
#
# Reads infra/secrets.txt (KEY=value per line) and creates a `docker
# secret` named KEY for each non-blank value. Run on a Swarm manager,
# after filling in the values you need in secrets.txt.
#
# NOTE: this only creates the secret objects in the Swarm's raft store.
# It does NOT wire them into any service — see secrets.txt's header
# comment for why (Swarm secrets mount as files under /run/secrets/*,
# never as env vars, and no service here reads from files yet).
#
# Usage:
#   ./create-docker-secrets.sh            # create secrets that don't exist yet;
#                                         # ones that already exist are skipped
#   ./create-docker-secrets.sh --force    # create all secrets, including those that already exist
#                                         # (removes + creates a new version; fails
#                                         # if a service is still using the old one)
#
# Updating a secret already attached to a running service (Swarm secrets
# are immutable — there's no in-place edit):
#   1. run `docker service scale <service-name>=0`      # detach it by stopping the service
#   2. ./create-docker-secrets.sh --force    # removes + recreates the secret
#   3. run `docker service scale <service-name>=1`    # or `docker stack deploy` again —
#                                            # either restores it and picks up
#                                            # the new value

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.txt"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }
docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active \
  || { echo "This node isn't part of an active Swarm (run 'docker swarm init' first)." >&2; exit 1; }

[[ -f "$SECRETS_FILE" ]] || { echo "$SECRETS_FILE not found." >&2; exit 1; }

created=0
skipped_existing=0
skipped_blank=()

while IFS='=' read -r key value; do
  # Skip comments and blank lines.
  [[ -z "$key" || "$key" == \#* ]] && continue
  key="$(echo "$key" | xargs)" # trim whitespace

  if [[ -z "$value" ]]; then
    skipped_blank+=("$key")
    continue
  fi

  if docker secret inspect "$key" >/dev/null 2>&1; then
    if [[ "$FORCE" -eq 1 ]]; then
      echo "==> $key already exists — removing to create a new version (--force)"
      if ! docker secret rm "$key" >/dev/null 2>&1; then
        # Swarm secrets are immutable and can't be removed while a
        # service still references them (docker secret rm fails outright).
        echo "    Could not remove $key — it's attached to a running service. Detach it first with either:" >&2
        echo "      docker service update --secret-rm $key <service-name>" >&2
        echo "      docker service scale <service-name>=0   # then scale back up after re-running this script" >&2
        skipped_existing=$((skipped_existing + 1))
        continue
      fi
      echo "==> Recreating secret: $key"
    else
      echo "==> $key created earlier, skipping..."
      skipped_existing=$((skipped_existing + 1))
      continue
    fi
  else
    echo "==> Creating secret: $key"
  fi

  printf '%s' "$value" | docker secret create "$key" - >/dev/null
  created=$((created + 1))
done < "$SECRETS_FILE"

echo
echo "Done. Created: $created, already existed (skipped): $skipped_existing, blank (skipped): ${#skipped_blank[@]}"
if [[ "${#skipped_blank[@]}" -gt 0 ]]; then
  echo "Blank in secrets.txt (fill these in if you need them): ${skipped_blank[*]}"
fi
