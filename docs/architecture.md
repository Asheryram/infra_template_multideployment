# Architecture

## Design rules

1. **An environment is data, not config.** `(app, env, tag, manifest)` fully describes a deployment. `infra deploy` turns it into a compose project named `<app>-<env>`. Nothing is hand-edited on the server.
2. **Build once, run anywhere.** Images are built in CI, tagged `sha-<12>`, and the same image runs in every environment. Environment-specific values arrive at runtime as env vars, never at build time.
3. **The server pulls, CI never pushes in.** A self-hosted runner on the server picks up deploy jobs, so there is no inbound SSH and no deploy keys in GitHub.
4. **Laptop VM and VPS run identical code.** Only `inventory/*.env` differs: domain, TLS mode and sizes.
5. **Everything has a limit.** Every log, container, preview count, backup and alert has one.

## Request flow

```
browser ──https──▶ Traefik ──(Host header)──▶ shop-pr-7 containers      on infra-shop-pr-7_net
                     │                       ▶ shop-prod containers      on infra-shop-prod_net
                     │                       ▶ blog-develop containers   on infra-blog-develop_net
     middlewares: secure-headers, compress,          │
     preview-auth + noindex (previews only)          └─▶ infra-postgres, attached ONLY to the
                                                         networks of environments that use the DB
```

**Every environment has its own private network** (`<stack>_net`). Only these containers are on it:
- the environment's own containers (including sidecars from `compose.extra.yml`)
- Traefik
- Postgres, but only if the environment uses the platform DB

That gives you:
- **No cross-project access.** `blog` can't open a connection to `shop`'s containers, so it can't bypass Traefik, preview auth or middlewares.
- **No cross-environment access.** A PR preview can't reach prod's containers of the same app.
- **No DB route for apps that don't need one.** Frontends have no path to Postgres.
- **No extra networks.** The network replaces the default one Compose would have created per stack anyway.

The deploy script creates the network and attaches Traefik and Postgres at runtime (`ensure_stack_network`). Destroy detaches them and removes it. Recreating a platform container drops runtime attachments, so `infra platform up` runs `infra networks reconnect`. The old shared `infra_proxy` / `infra_data` networks now hold only platform containers. `infra networks migrate` moves stacks deployed before this change, and the e2e chapter "4b" proves the isolation with a probe container.

Traefik learns routes from container labels, which it reads through `socket-proxy` (read-only Docker API). Adding or removing an environment never touches Traefik config.

**TLS.** In `letsencrypt` mode, Traefik gets a single `*.DOMAIN` certificate via DNS challenge. All hosts are exactly one level deep (`shop-pr-42.apps.example.com`, never `pr-42.shop.apps…`), so one wildcard covers every environment. New previews are instantly on HTTPS with no rate-limit risk. In `selfsigned` mode, `platform.sh` generates an equivalent wildcard.

## What `infra deploy` does

```
1. validate env name, load manifest            8. write runtime/<component>.env   (injected < repo env < secrets)
2. lock <app>-<env> (flock)                    9. write stack.env + compose-files
3. enforce MAX_PREVIEWS for new previews      10. compose config  (fail fast)
4. snapshot .deploy/ into the stack dir        11. registry login, pull
5. compute hosts / images / limits / mw        12. MIGRATE_CMD in a one-off container
6. use a database only if explicitly provisioned and wired
                                                13. compose up --wait (healthchecks)
7. assemble runtime env from platform metadata, repo env and server secrets
                                                14. write meta.env
```

On-disk state per environment (`/srv/deployments/<app>/<env>/`):

| File | Purpose |
|---|---|
| `deploy/` | Snapshot of the repo's `.deploy/`, used by `redeploy`/`rollback` without the repo |
| `stack.env` | Variables for the compose templates (images, hosts, limits) |
| `compose-files` | Which templates plus extra file make up this stack |
| `runtime/*.env` | Final container env per component (0600) |
| `meta.env` | Tag, previous tag, branch, platform URLs, deploy time and actor |
| `.db_password` | Generated per environment (0600) |

## Frontend → backend configuration

```
frontend deployment
   └─ API endpoint comes from the app's own .deploy/env/ or server-side variables
```

The platform does not discover backend repositories, match branches, or relink frontends when backend environments appear or disappear. Set the API URL explicitly for each environment or preview that needs one. Use server-side variables for secrets and `.deploy/env/` for non-secret defaults.

Frontends must read their API URL **at runtime** (see `app-kit/dockerfiles/spa/`). A value baked in at build time cannot vary by environment. `API_URL` is not injected by the platform.

## Databases

- One shared Postgres container. Databases are optional and explicitly created per environment with `infra db create <app> <env>`; each gets a database and role named `<app>_<env>` (dashes become underscores).
- `infra db use <app> <env> --key <VAR>` wires the generated URL into an app variable. Preview databases can be cloned from `<app>__template`; load that template from a **sanitised** dump with `infra db template`. Never clone prod data into previews.
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

Set `MAX_PREVIEWS` based on available host capacity. Infra inventory configures default and preview CPU/memory limits, with hard per-container and per-stack ceilings; operators can set scoped app overrides in the console. These are container caps, not reservations of host capacity, so size preview counts and limits for the actual server.

## Possible next steps

- **Zero-downtime prod**: run two replicas, or use blue/green (`<app>-prod-blue`/`-green` stacks, health-gate, then flip the Traefik router).
- **Secrets in git**: encrypt `/etc/infra/secrets` with sops + age and decrypt during deploy.
- **More servers**: keep the same CLI and point the inventory at a second host (e.g. previews on a cheap box, prod on a bigger one) by changing the runner label per environment.
- **Central logs**: add Loki + Promtail to the `metrics` profile if Dozzle's live view isn't enough.
