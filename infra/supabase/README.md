# infra/supabase/

Self-hosted Supabase, running as plain `docker compose` on the **same
machine as the Swarm manager** — sharing the `mhews` overlay network so
`aggregator` reaches it directly without a public round-trip, while still
publishing a public HTTPS endpoint for the browser/mobile app, which call
Supabase directly for Auth/Realtime/Storage/Edge Functions. Not a Swarm
*service* itself — a separate `docker compose` project running alongside
the Swarm stacks on that one node.

`setup.sh` here is a thin wrapper that pins and calls Supabase's own
official installer (`self-hosted/v0.8.0`), which is what actually clones
`docker/`, generates secrets, and writes `docker/.env`. 

This guide walks through installing this node, start to finish. Steps 1–4
are required for a minimal working instance; steps 5–9 wire this node up
to the rest of the stack (Swarm services, monitoring, backups) and are
needed before deploying those.

## Prerequisites

- Linux host (Debian/Ubuntu or RHEL/CentOS/Fedora) — see [Supabase's
  self-hosting docs](https://supabase.com/docs/guides/self-hosting/docker)
  for other OSes.
- This node runs on the **same machine as the Swarm manager**, and this
  repo is already cloned there — `../install.sh` has already been run
  from it (it creates the `mhews` overlay network step 8 attaches to;
  `install.sh` itself never clones anything, it expects to already be
  running from inside a checkout).

## Step-by-step installation

### 1. Go into this folder

```sh
cd ./infra/supabase
```

### 2. Run `./setup.sh`

```sh
./setup.sh
```

This delegates to Supabase's own official installer
(`https://supabase.link/setup.sh`), pinned to `self-hosted/v0.8.0`. It
will:

1. Install prerequisites (`git`, `openssl`, `jq`, `ca-certificates`) if missing.
2. run setup.sh script
3. **Prompt you interactively** for the four URL/domain variables below,
   and write them straight into `docker/.env`.
4. Generate every secret (`POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`,
   `SERVICE_ROLE_KEY`, `VAULT_ENC_KEY`, ...) into `docker/.env`
   automatically — you never hand-type these.

**What you need to decide and enter when prompted:**

| Variable | What to enter |
|---|---|
| `SUPABASE_PUBLIC_URL` | The public address this node will be reached at. No domain yet? Use `http://<node-ip>:8000` (`8000` is the gateway's default port). Have a domain + plan to do step 7 (HTTPS)? Use `https://supabase.<your-domain>` instead. |
| `API_EXTERNAL_URL` | Same value as `SUPABASE_PUBLIC_URL` — used to construct Auth's OAuth callbacks/email links. |
| `SITE_URL` | Where `frontend` (this app's Vue bundle) is served from, e.g. `https://<your-app-domain>`. Drives Auth email redirect links (password reset, invites). |
| `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` | HTTP basic-auth credentials guarding Supabase Studio. Upstream ships an insecure default — pick your own. |

Other flags `setup.sh` forwards, if you need them (see its own header
comment): `--skip-deps`, `--with-aws`, `--head`, `--ref self-hosted/vX.Y.Z`
(to override the pinned tag), `-y` (accept defaults, no prompts).

If you skipped a value or need to change it later, edit `docker/.env`
directly and re-run `sh run.sh recreate` (step 3).

### 3. Start the stack

```sh
cd docker
sh run.sh start
```

### 4. Get the generated secrets

```sh
sh run.sh secrets
```

Prints the passwords/API keys `setup.sh` generated into `docker/.env`
(`ANON_KEY`, `SERVICE_ROLE_KEY`, etc.) — you'll copy these out in the next
step. Keep this output private; treat it like `docker/.env` itself.

At this point you have a working, standalone Supabase instance. The
remaining steps connect it to the rest of this app's infrastructure.

### 5. Wire this node into the Swarm app services

Copy and paste these values into `./infra/secrets/secrets.txt`:

| Value (from this node) | `./infra/secrets/secrets.txt` var |
|---|---|
| `SUPABASE_PUBLIC_URL` from `docker/.env` | `VITE_SUPABASE_URL` (the browser/mobile app — must be the public URL) |
| `http://api-gw:8000` (only valid after step 8 below) | `SUPABASE_URL` (`aggregator`/importers — private path over the `mhews` network) |
| `ANON_KEY` from `sh run.sh secrets` | `SUPABASE_ANON_KEY` **and** `VITE_SUPABASE_ANON_KEY` |
| `SERVICE_ROLE_KEY` from `sh run.sh secrets` | `SUPABASE_SERVICE_ROLE_KEY` |


### 6. Create the Grafana read-only Postgres role

The monitoring stack's "Supabase Postgres" datasource must **not**
connect as the `postgres` superuser. On this node, create a role scoped
to `SELECT` only:

```sh
docker exec -it supabase-db psql -U postgres
```

(Or paste the same SQL into Supabase Studio's SQL Editor instead.)

```sql
CREATE ROLE grafana_reader WITH LOGIN PASSWORD 'u7du78s0)DDSBDFJLW';
GRANT CONNECT ON DATABASE postgres TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

Then copy these into `./infra/secrets/secrets.txt`:

```
SUPABASE_DB_HOST=<this node's host>
SUPABASE_DB_READONLY_USER=grafana_reader
SUPABASE_DB_READONLY_PASSWORD=<the password you chose above>
DATA_SOURCE_NAME=postgresql://grafana_reader:<password>@<this node's host>:5432/postgres?sslmode=disable
```

`DATA_SOURCE_NAME` (used by `postgres_exporter`, not Grafana itself) needs
a role with `pg_monitor` instead of table `SELECT` — either reuse
`grafana_reader` and additionally `GRANT pg_monitor TO grafana_reader;`,
or create a second role for it. See `../monitoring/README.md`.

### 7. Set up HTTPS

Skip this step if you're still on `http://<node-ip>:8000` for early
bring-up — come back to it before any production use.

This is a **separate proxy from the app's own `frontend` service**
(`../swarm/stacks/core-services.yml`) — the browser/mobile app needs a
public HTTPS endpoint for Auth/Realtime/Storage/Edge Functions regardless.

Don't hand-install Nginx/Certbot on the host — the vendored `docker/`
checkout ships a ready-made override for exactly this:

```sh
sh run.sh config add nginx   # or: config add caddy — see below
```

Fill these into `docker/.env` before starting:

```
PROXY_DOMAIN=supabase.<your-domain>
CERTBOT_EMAIL=<you>@<your-domain>          # Let's Encrypt expiry notices, nginx only
DASHBOARD_USERNAME=<pick a username>       # (already set in step 2)
DASHBOARD_PASSWORD=<pick a strong password># (already set in step 2)
```

Then apply it:

```sh
sh run.sh recreate     # picks up the new override, publishes 80/443
```

This override removes the API gateway's own host port binding (`:8000`
is no longer published directly) and replaces it with a TLS proxy on
`:443`, using the `jonasal/nginx-certbot` image — it issues and
auto-renews the Let's Encrypt cert *inside* the container, no host-level
Certbot cron job needed. It proxies `/auth`, `/rest`, `/graphql`,
`/realtime`, `/storage`, `/functions`, `/mcp`, `/sso` to the gateway, and
everything else (Studio) behind `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`
basic auth. See `volumes/proxy/nginx/supabase-nginx.conf.tpl` in the
vendored checkout for the exact routing if you need to customize it.

**Caddy is the simpler alternative** (`sh run.sh config add caddy`) if
you'd rather not manage `CERTBOT_EMAIL` — Caddy's automatic HTTPS needs
only `PROXY_DOMAIN` plus the same dashboard credentials, and also picks up
HTTP/3. Functionally equivalent routing either way.

Finally, set `SUPABASE_PUBLIC_URL`/`API_EXTERNAL_URL`/`SITE_URL` in
`docker/.env` to `https://supabase.<your-domain>`, run
`sh run.sh recreate` again, and propagate the same public URL into
`VITE_SUPABASE_URL` in `../swarm/env/.env` (step 5's table) — a mismatch
here is the most common self-host misconfiguration.

### 8. Attach this node to the `mhews` overlay network (private aggregator traffic)

Verified against this repo's own code: `server/`, `raster-importer/`, and
`wind-importer/` only ever talk to Supabase via `@supabase/supabase-js`
(using `SUPABASE_SERVICE_ROLE_KEY`) — there's no direct
`postgres://` connection anywhere, every read/write goes through the API
gateway. Since this node and the Swarm manager are the **same machine**,
that traffic can skip the public internet entirely:

```sh
cp docker-compose.override.yml.example docker/docker-compose.override.yml
cd docker
sh run.sh recreate
```

`docker-compose.override.yml` is Docker Compose's own standard override
filename — auto-loaded with no `config add`/`COMPOSE_FILE` change needed,
and `update.sh` treats it as user-owned state it preserves across
upgrades. It attaches this node's `api-gw` **and `db`** services to the
`mhews` overlay network (created `--attachable` by `../install.sh`, so a
plain `docker compose` container can join it, not just Swarm services).
`db` joining `mhews` is what lets `../backups/`'s Swarm Job reach Postgres
directly (`pg_dump -h supabase-db`) instead of needing Docker socket
access — see `../backups/README.md`.

Now go back to step 5's table and set `SUPABASE_URL` in
`../swarm/env/.env` to `http://api-gw:8000` — `aggregator`/importers
reach this node directly over `mhews`, no published port or public
round-trip involved. `VITE_SUPABASE_URL` stays the public HTTPS URL from
step 7 regardless — the browser isn't on `mhews`.

If this node ever moves to a genuinely separate host from the Swarm
manager, skip this step and use a public/VPN-reachable address for
`SUPABASE_URL` instead.

### 9. Point the backup script at this node

Copy this node's `docker/` path into `../backups/env/.env` (create it
from `../backups/env/.env.example`):

```
SUPABASE_DIR=/opt/mhews/infra/supabase/docker   # wherever this checkout actually lives
```

Also copy `POSTGRES_PASSWORD` out of `docker/.env` (`sh run.sh secrets`
shows it too) — the backup/restore Swarm Job connects to `db` directly
over `mhews` (step 8) and needs real Postgres credentials, unlike the old
`docker exec`-based approach which relied on local trust auth.

See [`../backups/README.md`](../backups/README.md) for the rest of that
setup (`backup`/`restore` now run as a Swarm Job, not on this node).

## Updating

```sh
cd docker
sh update.sh          # pulls the latest self-hosted/v* tag, 3-way merges
                      # over your files — see Supabase's own upgrade docs
```

Stable snapshots are published roughly monthly by Supabase.

## Still open / not required for a working install

- **SMTP** — required for real auth emails (password reset, invites);
  upstream defaults to a fake local mail catcher. Supabase recommends AWS
  SES. Set `SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/`SMTP_PASS`/
  `SMTP_ADMIN_EMAIL`/`SMTP_SENDER_NAME` in `docker/.env` once decided.
- **Storage backend** — defaults to local disk (`docker/volumes/storage`).
  Switch to S3-compatible storage (AWS S3/MinIO/R2/RustFS) via
  `sh run.sh config add s3` if needed; set `GLOBAL_S3_BUCKET`/`REGION` in
  `docker/.env`.
- **Analytics/Logs (Logflare + Vector)** — off by default (lower resource
  footprint); enable via `sh run.sh config add logs` for Studio's Log
  Explorer.
- **Firewall** — raw Postgres (`5432`/pooler `6543`) and Studio (already
  behind dashboard basic auth once step 7 is done) don't need public
  exposure — only the monitoring stack's read-only datasource
  (`../monitoring/`) and an admin's own IP need access to those; the
  public gateway (`:443`) is the only thing open to everyone.
- **Secrets handling** — `docker/.env` is gitignored (see repo-root
  `.gitignore`), unlike `server/.env`, which this project tracks in git.
  This is intentional for this file.

See [`../backups/README.md`](../backups/README.md) for backup/restore,
and the top-level [`../README.md`](../README.md)'s "Install order" for
where this node fits relative to the other `infra/` stacks.
