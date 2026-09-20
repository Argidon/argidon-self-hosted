#!/bin/sh
# infra/supabase/setup.sh — runs Supabase's own officially maintained
# install script (https://supabase.link/setup.sh, the shortlink for
# supabase/supabase's docker/setup.sh) to bootstrap self-hosted Supabase
# with suggested defaults and prompts.
#
# Linux only (Debian/Ubuntu or RHEL/CentOS/Fedora)
# See https://supabase.com/docs/guides/self-hosting/docker for other OSes.
#
# What the official script does:
#   1. Installs prerequisites: git, openssl, jq, ca-certificates
#   2. Installs Docker Engine + Compose plugin (if missing)
#   3. Optionally installs the AWS CLI v2 (--with-aws) (Added) 
#   4. Sparse-clones the repo to extract the contents of ./docker
#   5. Creates a project directory in CWD and copies docker/* into it
#   6. Records the base version the deployment was set up from (.supabase-version)
#   7. Prompts for the main URLs and writes them to .env
#   8. Generates secrets and asymmetric API keys via utils/*.sh
#
# Usage:
#   sh setup.sh                            # interactive
#   sh setup.sh -y                         # accept defaults, no prompts
#   sh setup.sh --project-dir my-supabase  # name the project directory
#   sh setup.sh --skip-deps                # skip system-package installation
#   sh setup.sh --with-aws                 # also install the AWS CLI v2
#   sh setup.sh --ref self-hosted/v0.7.0   # clone docker/ from a specific git ref
#   sh setup.sh --head                     # clone docker/ from HEAD (skip tags)
#
# Run this from inside an existing checkout of this repo (see README.md's
# "cd ./infra/supabase" step) — it does not clone the repo itself.
# By default the docker/ sources are cloned from the latest self-hosted release
# tag (self-hosted/v*), falling back to the default branch (HEAD) if none exist.
#
# Pinned to self-hosted/v0.8.0 by default
# this project tests against one specific version at a time.
#
# If you want to customise your installation, use the options documented above.
# If you want to use suggested installation defaults, simply run the script 
#without any additional options.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

curl -fsSL https://supabase.link/setup.sh | sh -s -- --project-dir docker --with-aws  --ref self-hosted/v0.8.0 "$@"

echo "==> Starting the Supabase stack"
cd "$SCRIPT_DIR"/docker
sh run.sh start

echo "==> Adding the nginx HTTPS proxy override (docker-compose.nginx.yml)"
sh run.sh config add nginx

echo "==> Attaching api-gw/db to the mhews Swarm overlay network"
cd "$SCRIPT_DIR"
cp docker-compose.override.yml.example docker/docker-compose.override.yml

echo "==> Recreating the stack to pick up the overrides"
cd "$SCRIPT_DIR"/docker
sh run.sh recreate

echo "==> Generated secrets (keep this output private, see docker/.env)"
sh run.sh secrets

echo "==> Supabase is up. See README.md's remaining steps (DB roles, secrets.txt, HTTPS domain)."
