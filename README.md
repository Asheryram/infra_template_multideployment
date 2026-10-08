# infra — Amplify-style environments on a single server

Every repo gets **prod, staging, develop and a preview per pull request**, each with its own URL and its own database, on one VPS. App teams add two files to their repo; this repo runs everything else.

**It's safe on a server that already runs other apps.** By default (`HOST_MODE=shared`) it never changes host-wide settings and never touches containers, images, volumes or databases it didn't create. See [docs/shared-host.md](docs/shared-host.md).

```
                       *.apps.example.com  →  server IP
                                 │
                         ┌───────▼────────┐
                         │    Traefik     │  wildcard TLS, routes by container labels
                         └───────┬────────┘
     ┌───────────────────┬───────┴──────────┬──────────────────────┐
 shop.apps…        shop-staging.apps…   shop-pr-42.apps…     api-shop-pr-42.apps…
 (prod stack)      (staging stack)      (preview, basic-auth)  (preview api)
                                 │
                       ┌─────────▼─────────┐
                       │  Postgres (shared) │  shop_prod · shop_staging · shop_pr_42 …
                       └───────────────────┘
```

## What's in here

| Path | What it is |
|---|---|
| [bin/infra](bin/infra) | The one CLI for everything (`infra help`) |
| [scripts/](scripts/) | deploy · destroy · list · logs · db · backup · cleanup · host-check · secrets |
| [templates/components/](templates/components/) | Compose templates for the 3 building blocks: `app`, `web`, `api` |
| [platform/](platform/) | Always-on services: Traefik, Postgres, Uptime Kuma, Dozzle, optional Prometheus/Grafana |
| [bootstrap/](bootstrap/) | Turns a fresh Ubuntu box into a hardened server (idempotent) |
| [inventory/](inventory/) | Per-server settings. **The only thing that differs between laptop VM and real VPS** |
| [.github/workflows/](.github/workflows/) | Reusable workflows app repos call (build, deploy, destroy) |
| [app-kit/](app-kit/) | **Drag-and-drop folder for app repos**: manifest, CI workflow, Dockerfiles |
| [local/](local/) | Multipass "fake VPS" + an end-to-end smoke test |
| [docs/](docs/) | [Architecture](docs/architecture.md) · [Runbook](docs/runbook.md) · [Shared host](docs/shared-host.md) |

## Project types

| `TYPE` | Components | Hosts (non-prod adds `-<env>`) |
|---|---|---|
| `monolith` | `app` | `shop.<domain>` |
| `frontend` | `web` | `shop-web.<domain>`, its API is resolved from another repo (see below) |
| `backend` | `api` | `shop-api.<domain>` |
| `split` | `web` + `api` | `shop.<domain>` + `api-shop.<domain>` |

Anything else (Redis, workers, cron containers, Mongo) goes in the app's optional `.deploy/compose.extra.yml`.

## Environments

| Trigger | Env | Notes |
|---|---|---|
| PR opened/updated | `pr-<n>` | basic-auth, `noindex`, own DB (cloned from a seed template), auto-removed |
| push `develop` | `develop` | |
| push `staging` | `staging` | |
| push `main` | `prod` | gate it with required reviewers on the `prod` GitHub Environment |

**How the frontend finds its backend.** A frontend preview uses the backend preview built from the **same branch name**. If there isn't one, it uses `develop`. When the matching backend preview appears or disappears later, the frontend is redeployed automatically with the new `API_URL`.

---

## Quick start A: test on your laptop (no VPS)

Requires Multipass. **If Multipass/Hyper-V networking fails** (the VM shows `IPv4: N/A`, which is common on managed laptops), use the WSL2 variant instead: `.\local\wsl-up.ps1`. It creates a separate `fake-vps` distro. Then run `wsl -d fake-vps` and the same commands below (you're root, so `sudo` is optional). `wsl-reset.ps1` / `wsl-down.ps1` reset or remove it.

```powershell
.\local\up.ps1                       # creates VM "fake-vps", mounts repo at /opt/infra, writes inventory/local.env
multipass shell fake-vps
```
Inside the VM:
```bash
sudo bash /opt/infra/local/simulate-existing.sh          # make the VM look like the live server: other apps, DB, firewall
sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env
sudo -u deploy infra platform up
sudo -u deploy bash /opt/infra/local/smoke-test.sh      # deploys every project type, checks routing/auth/DB/relinking
sudo bash /opt/infra/local/verify-isolation.sh          # proves the "existing" apps were never touched
```
Open `https://traefik.<vm-ip-dashed>.sslip.io` (self-signed cert, accept the warning; login `admin/admin`).

`.\local\reset.ps1` rolls the VM back to fresh Ubuntu, so you can prove the bootstrap works from scratch.

## Quick start B: real VPS

1. DNS: `A apps.example.com` and `A *.apps.example.com` → server IP.
2. `cp inventory/prod.env.example inventory/vps-1.env` and fill it in (domain, ACME email, DNS provider, htpasswd lines).
3. On the server:
   ```bash
   sudo git clone <this repo> /opt/infra
   # copy inventory/vps-1.env there (it's gitignored)
   sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/vps-1.env
   sudo nano /etc/infra/traefik.env              # DNS API token for the wildcard cert
   sudo nano /etc/infra/platform.secrets.env     # registry token, restic, GH_TOKEN
   sudo -u infradeploy infra platform up      # your DEPLOY_USER
   ```
4. Self-hosted runner, so CI can deploy without SSH. Get a token under Org → Settings → Actions → Runners → New:
   ```bash
   sudo GH_RUNNER_URL=https://github.com/your-org GH_RUNNER_TOKEN=XXXX \
        bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/vps-1.env 60
   ```
5. In this repo on GitHub: Settings → Actions → General → Access → *accessible from repositories in the organization*.

## Onboarding an app (what teams do)

See [app-kit/README.md](app-kit/README.md). In short: copy `app-kit/.deploy/` and `app-kit/.github/` into the repo, set `APP_NAME` / `TYPE` / ports in `.deploy/manifest.env`, and open a PR.

## Day-to-day

**In the browser:** `https://console.<domain>` lists every environment with links. From there you can set variables and secrets per environment, rewire API and DB, redeploy, roll back, destroy, and read logs and the audit trail ([runbook](docs/runbook.md#the-console-web-ui)). There's also `traefik.`, `logs.` and `status.<domain>`.

**On the server:**
```bash
infra list                          # everything deployed, with URLs
infra logs shop pr-42               # or open https://logs.<domain>
infra redeploy shop staging         # after changing secrets
infra rollback shop prod
sudo infra secrets edit shop prod   # runtime secrets per app/env
infra db template shop seed.dump    # previews now start with seeded, sanitised data
infra link shop-web pr-12 --api shop-api/staging          # DevOps: point a frontend at any backend
infra attach-db shop-api pr-7 --share shop-api/staging    # DevOps: point an API at any database
infra cleanup --dry-run
```
More in the [runbook](docs/runbook.md).

## Built-in server hygiene

- **Logs**: Docker json-file 3×10 MB per container, journald capped at 500 MB, `/var/log/infra` rotated daily for 14 days
- **Disk**: nightly removal of images *we* pulled that are no longer used (never a global prune). Alert at 80%
- **Previews**: capped at `MAX_PREVIEWS`, removed on PR close (via CI, and nightly via the GitHub API), expire after `PREVIEW_TTL_DAYS`
- **Isolation**: memory/CPU/pid limits on every container. Postgres is on an internal network. Traefik reads Docker through a read-only socket proxy
- **Security**: `no-new-privileges` on every container, a read-only Docker socket proxy, and basic-auth on previews and ops tools. On `HOST_MODE=dedicated` servers it also sets SSH keys only, no root login, ufw (22/80/443 only), fail2ban and unattended security upgrades
- **Isolation**: everything is labelled `infra.managed=true` and prefixed `infra-`. Preflight checks refuse on any port, name or user collision
- **Backups**: nightly `pg_dump` of every non-preview DB plus `/etc/infra`, pushed off-server with restic
- **Alerts**: disk, memory, crash-looping or unhealthy containers, platform down, and failed deploys/migrations/backups go to your Slack/Discord/Teams webhook
- **Audit**: every deploy is logged to `/var/log/infra/deploy.log` with who, what tag and which branch

## Known limits

- **One server = one point of failure.** Backups and a rebuild from `bootstrap/` are your recovery plan. Practise it on the VM.
- **Brief blip on deploy.** `compose up` replaces the container, which takes a second or two for previews and prod alike. Zero-downtime prod needs blue/green (see architecture doc).
- **Shared Postgres.** It's efficient, but a runaway query in a preview can slow prod. Move prod to managed Postgres when it matters (set `NEEDS_DB=false` and put `DATABASE_URL` in the prod secrets).
