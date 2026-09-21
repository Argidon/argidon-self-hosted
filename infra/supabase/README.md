# infra/supabase/

Self-hosted Supabase, running as plain `docker compose` on the **same
machine as the Swarm manager** — sharing the `mhews` overlay network so
`aggregator` reaches it directly without a public round-trip, while still
publishing a public HTTPS endpoint for the browser/mobile app, which call
Supabase directly for Auth/Realtime/Storage/Edge Functions. Not a Swarm
*service* itself — a separate `docker compose` project running alongside
the Swarm stacks on that one node.

`setup.sh` here is a thin wrapper that pins and calls Supabase's own
official installer (version fixed to `self-hosted/v0.8.0` for complience), which is what actually copies
`docker/`, generates secrets, and writes `docker/.env`. 

This guide walks through installing this node, start to finish.

## Prerequisites

- Linux host (Tested on Ubuntu 26.04) — see [Supabase's
  self-hosting docs](https://supabase.com/docs/guides/self-hosting/docker)
  for other OSes.
- Run `install-docker.sh` and `install-network.sh` scripts before installing supabase

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
(`https://supabase.link/setup.sh`), pinned to `self-hosted/v0.8.0`. Run it
from inside this checkout (step 1) — it does not clone the repo itself. It
will:
- Install supabase (You need to input 4 env vars during this step)
- Start Supabase
- Install nginx (If you don't have a domain name yet, get a free sslip.io domain name for placeholder)
- Connect to mhews network

During installation:
**Prompt you interactively** for the four URL/domain variables below:
| Variable | What to enter |
|---|---|
| `SUPABASE_PUBLIC_URL` | The public address this node will be reached at. **On a remote host (EC2/VPS), never leave this as `http://localhost:8000`** — your own browser resolves `localhost` to itself, not the server, so the UI will be unreachable. Use `http://<instance-public-ip>:8000` instead, or if you're doing HTTPS (below), `https://<PROXY_DOMAIN value>`. No domain yet? Get a free sslip.io hostname — `<instance-public-ip>.sslip.io` (dots or dashes) automatically resolves to your instance's IP, no signup, no cost. |
| `API_EXTERNAL_URL` | Same value as `SUPABASE_PUBLIC_URL` added `/auth/v1` — used to construct Auth's OAuth callbacks/email links. |
| `SITE_URL` | Where `frontend` (this app's Vue bundle) is served from, e.g. `https://<your-app-domain>`. Drives Auth email redirect links (password reset, invites). |
| `PROXY_DOMAIN` | For nginx/caddy HTTPS proxy. **Must be a bare hostname only** — e.g. `supabase.<your-domain>` or `<instance-public-ip>.sslip.io`. Do **not** include a scheme (`http://`/`https://`) or a port — the setup script does not validate this field, and a URL here breaks Certbot's certificate request silently. `CERTBOT_EMAIL` is derived automatically from this value, no separate prompt. |

If you skipped a value or need to change it later, edit `docker/.env`
directly and re-run `sh run.sh recreate`

### 3. Create roles for grafana_reader & postgres_exporter

The monitoring stack's "Supabase Postgres" datasource must **not**
connect as the `postgres` superuser. On this node, create 2 roles scoped
accordingly:

```sh
docker exec -it supabase-db psql -U postgres
```

(Or paste the same SQL into Supabase Studio's SQL Editor instead.)

Create grafana_reader role:
```sql
CREATE ROLE grafana_reader WITH LOGIN PASSWORD '<GRAFANA_READONLY_PASSWORD>';
GRANT CONNECT ON DATABASE postgres TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
```

Create postgres_exporter role:
```sql
CREATE ROLE postgres_exporter WITH LOGIN PASSWORD '<EXPORTER_READONLY_PASSWORD>';
GRANT pg_monitor TO postgres_exporter;
GRANT CONNECT ON DATABASE postgres TO postgres_exporter;
```

### 4. Update secrets.txt

Copy and paste these values into `./infra/secrets/secrets.txt`:

| Get Value from this node | Paste it into `./infra/secrets/secrets.txt` as value |
|---|---|
| `SUPABASE_PUBLIC_URL` | `VITE_SUPABASE_URL` (the browser/mobile app — must be the public URL) |
| `ANON_KEY`| `SUPABASE_ANON_KEY` **and** `VITE_SUPABASE_ANON_KEY` |
| `SERVICE_ROLE_KEY` | `SUPABASE_SERVICE_ROLE_KEY` |
| `GRAFANA_READONLY_PASSWORD` password you entered above | `GRAFANA_READONLY_PASSWORD` |
| `DATA_SOURCE_NAME` | Data source name for postgres exporter. `DATA_SOURCE_NAME=postgresql://postgres_exporter:<EXPORTER_READONLY_PASSWORD>@<host-ip>:5432/postgres?sslmode=disable`  |
| `DATA_SOURCE_NAME_GRAFANA` | Data source name for Grafana `DATA_SOURCE_NAME_GRAFANA=postgresql://grafana_reader:<GRAFANA_READONLY_PASSWORD>@<host-ip>:5432/postgres?sslmode=disable` |
| `POSTGRES_PASSWORD` |`POSTGRES_PASSWORD` |
