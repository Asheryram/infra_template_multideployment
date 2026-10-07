# Architecture

## Design rules

1. **An environment is data, not config.** `(app, env, tag, manifest)` fully describes a deployment. `infra deploy` turns it into a compose project named `<app>-<env>`. Nothing is hand-edited on the server.
2. **Build once, run anywhere.** Images are built in CI, tagged `sha-<12>`, and the same image runs in every environment. Environment-specific values arrive at runtime as env vars, never at build time.
3. **The server pulls, CI never pushes in.** A self-hosted runner on the server picks up deploy jobs, so there is no inbound SSH and no deploy keys in GitHub.
4. **Laptop VM and VPS run identical code.** Only `inventory/*.env` differs: domain, TLS mode and sizes.
5. **Everything has a limit.** Every log, container, preview count, backup and alert has one.

## Request flow

```
browser ──https──▶ Traefik :443 ──(Host header)──▶ container on network infra_proxy
                       │                                   │
          middlewares: secure-headers, compress,           └──▶ infra-postgres on infra_data (internal)
          preview-auth + noindex (previews only)
```

Traefik learns routes from container labels, which it reads through `socket-proxy` (read-only Docker API). Adding or removing an environment never touches Traefik config.

**TLS.** In `letsencrypt` mode, Traefik gets a single `*.DOMAIN` certificate via DNS challenge. All hosts are exactly one level deep (`shop-pr-42.apps.example.com`, never `pr-42.shop.apps…`), so one wildcard covers every environment. New previews are instantly on HTTPS with no rate-limit risk. In `selfsigned` mode, `platform.sh` generates an equivalent wildcard.

## What `infra deploy` does

```
1. validate env name, load manifest            8. write runtime/<component>.env   (injected < repo env < secrets)
2. lock <app>-<env> (flock)                    9. write stack.env + compose-files
3. enforce MAX_PREVIEWS for new previews      10. compose config  (fail fast)
4. snapshot .deploy/ into the stack dir        11. registry login, pull
5. compute hosts / images / limits / mw        12. MIGRATE_CMD in a one-off container
6. ensure DB + role (clone template if preview) 13. compose up --wait (healthchecks)
7. resolve API_URL (frontend)                  14. write meta.env, relink dependent frontends
```

On-disk state per environment (`/srv/deployments/<app>/<env>/`):

| File | Purpose |
|---|---|
| `deploy/` | Snapshot of the repo's `.deploy/`, used by `redeploy`/`rollback`/relink without the repo |
| `stack.env` | Variables for the compose templates (images, hosts, limits) |
| `compose-files` | Which templates plus extra file make up this stack |
| `runtime/*.env` | Final container env per component (0600) |
| `meta.env` | Tag, previous tag, branch, URLs, upstream API, deploy time and actor |
| `.db_password` | Generated per environment (0600) |

## Frontend → backend resolution

```
frontend preview (branch B)
   │
   ├─ manifest API_URL_<CLASS> set? ──────────────▶ use it
   ├─ backend has pr-* with BRANCH == B? ──────────▶ use that preview's API_URL
   └─ else ────────────────────────────────────────▶ backend/<BACKEND_FALLBACK_ENV> (develop)

frontend non-preview (staging) ──────────────────▶ backend/staging
```

The reverse direction is handled too. After a backend preview deploys, `relink_frontends` finds frontend previews with the same `BACKEND_APP` and branch that point elsewhere, and redeploys them. Destroying a backend preview relinks them back to the fallback. Teams don't coordinate merge order. They just use the same branch name in both repos.

Frontends must read `API_URL` **at runtime** (see `app-kit/dockerfiles/spa/`). A value baked in at build time can't follow the backend.

## Databases

- One Postgres container and one database plus role per environment: `<app>_<env>` (dashes become underscores).
- Previews clone `<app>__template` if it exists (`CREATE DATABASE … TEMPLATE`). That's near-instant and gives realistic seeded data. Load the template from a **sanitised** dump with `infra db template`. Never clone prod data into previews.
- Roles get a generated password and `REVOKE ALL … FROM PUBLIC`, so one app's credentials can't open another app's DB.
- Postgres sits on an internal network with no published port. Reach it with `infra db psql` or an SSH tunnel.

## Security model

| Layer | Control |
|---|---|
| Host | ufw (22 rate-limited, 80, 443), fail2ban, key-only SSH, `AllowUsers`, unattended security upgrades |
| Docker | Only Traefik publishes ports (Docker bypasses ufw). Socket proxy, `no-new-privileges`, pid/mem/cpu limits |
| Access | `deploy` user has no sudo but is in the `docker` group, which is root-equivalent, so protect it like root |
| Secrets | `/etc/infra` is root:deploy 0750. Per-app secrets live outside git. Containers only see their own app's files |
| Previews | Basic-auth plus `noindex`. Fork PRs never deploy |
| CI | The runner is org-level and private-repo only, and runs the deploy job only (builds happen on GitHub-hosted runners) |

## Capacity planning (rule of thumb)

| Item | RAM |
|---|---|
| OS + Docker | ~400 MB |
| Traefik + socket proxy + Dozzle + Kuma | ~250 MB |
| Postgres | 256 MB – 1 GB |
| `metrics` profile | ~400 MB |
| Each small preview (web 128 MB + api 256 MB) | ~400 MB |

On a 4 GB VPS, plan for prod, staging, develop and roughly 3–4 previews. On 8 GB, roughly 10 previews. Set `MAX_PREVIEWS` accordingly and use `PREVIEW_MEM_LIMIT`.

## Possible next steps

- **Zero-downtime prod**: run two replicas, or use blue/green (`<app>-prod-blue`/`-green` stacks, health-gate, then flip the Traefik router).
- **Secrets in git**: encrypt `/etc/infra/secrets` with sops + age and decrypt during deploy.
- **More servers**: keep the same CLI and point the inventory at a second host (e.g. previews on a cheap box, prod on a bigger one) by changing the runner label per environment.
- **Central logs**: add Loki + Promtail to the `metrics` profile if Dozzle's live view isn't enough.
