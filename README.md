# infra — Amplify-style environments on a single server

Every repo can get **prod, staging, develop and a preview per pull request**, each with its own URL. The platform database is optional and provisioned explicitly per environment; previews can be seeded from a sanitised template. App teams add the app-kit configuration to their repo; this repo runs everything else.

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
                       │ Postgres (optional)│  databases created only when needed
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
| `frontend` | `web` | `shop-web.<domain>`, configure its API URL as an app environment variable |
| `backend` | `api` | `shop-api.<domain>` |
| `split` | `web` + `api` | `shop.<domain>` + `api-shop.<domain>` |

Anything else (Redis, workers, cron containers, Mongo) goes in the app's optional `.deploy/compose.extra.yml`.

## Environments

| Trigger | Env | Notes |
|---|---|---|
| PR opened/updated | `pr-<n>` | basic-auth, `noindex`, optional explicitly provisioned DB (optionally seeded from a template), auto-removed |
| push `develop` | `develop` | |
| push `staging` | `staging` | |
| push `main` | `prod` | gate it with required reviewers on the `prod` GitHub Environment |

**Frontend/backend configuration.** The platform does not auto-discover or branch-match a frontend with a backend. Set the frontend's API URL in `.deploy/env/` or server-side variables for the appropriate environment.

---

## Quick start A: test on your laptop (no VPS)

**Prerequisites:** Windows with PowerShell and either Multipass or WSL2. The WSL2 path also requires WSL to be available. No existing VPS or globally installed `infra` CLI is needed; the VM bootstrap installs the platform.

If Multipass/Hyper-V networking fails (the VM shows `IPv4: N/A`, which is common on managed laptops), use the WSL2 variant instead: `.\local\wsl-up.ps1`. It creates a separate `fake-vps` distro. Then run `wsl -d fake-vps` and the same commands below (you're root, so `sudo` is optional). `wsl-reset.ps1` / `wsl-down.ps1` reset or remove it.

```powershell
.\local\up.ps1                       # creates VM "fake-vps", mounts repo at /opt/infra, writes inventory/local.env
multipass shell fake-vps
```
Inside the VM:
```bash
sudo bash /opt/infra/local/simulate-existing.sh          # make the VM look like the live server: other apps, DB, firewall
sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env
sudo -u deploy infra platform up
sudo -u deploy infra platform ps                 # platform containers should be running/healthy
sudo -u deploy bash /opt/infra/local/smoke-test.sh      # deploys every project type, checks routing/auth/DB/network isolation
sudo bash /opt/infra/local/verify-isolation.sh          # proves the "existing" apps were never touched
```
Open `https://traefik.<vm-ip-dashed>.sslip.io` (self-signed cert, accept the warning; login `admin/admin`).

**The full lifecycle story test** has two demo apps (`demo-api` + `demo-web`) and a GitHub simulator using real git branches. It exercises develop → prod → frontend and backend PRs → a feature that needs a new secret → release and rollback → merge and close. The script reports the current assertion totals when it runs:
```bash
sudo bash /opt/infra/local/e2e/run.sh            # ~5 min, cleans up after itself
sudo bash /opt/infra/local/e2e/run.sh --pause    # stops after each chapter with URLs to open in the browser
```
`local/e2e/gh-sim.sh` can also be driven by hand (`init`, `branch`, `commit`, `push`, `pr-open`, `pr-sync`, `pr-close --merge`, `merge`).

`.\local\reset.ps1` rolls the VM back to fresh Ubuntu, so you can prove the bootstrap works from scratch.

## Quick start B: real VPS

**Prerequisites:** an Ubuntu VPS with sudo access, a domain whose DNS you can manage, and credentials for the selected DNS challenge provider if using Let's Encrypt wildcard TLS. The bootstrap configures the host and installs Docker; do not run it against a shared host until you have reviewed [docs/shared-host.md](docs/shared-host.md).

1. DNS: `A apps.example.com` and `A *.apps.example.com` → server IP. Ensure the configured HTTP/HTTPS ports are reachable from clients.
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
   Verify with `sudo -u infradeploy infra platform ps` and `sudo -u infradeploy infra host-check`; then open the console URL for the configured domain.
4. By default, app-kit deploys use signed webhooks; no self-hosted runner is required. Register each app with `infra project add <app> --repo <org/repo>` and add the printed `INFRA_WEBHOOK_URL` and `INFRA_WEBHOOK_SECRET` values as repository Actions secrets. If you explicitly configure `INFRA_TRIGGER=runner`, install a self-hosted runner using a token under Org → Settings → Actions → Runners → New:
   ```bash
   sudo GH_RUNNER_URL=https://github.com/your-org GH_RUNNER_TOKEN=XXXX \
        bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/vps-1.env 60
   ```
5. In this repo on GitHub: Settings → Actions → General → Access → *accessible from repositories in the organization*.

## Onboarding an app (what teams do)

See [app-kit/README.md](app-kit/README.md) for the full app requirements and complete list of accepted manifest settings. In short: copy `app-kit/.deploy/` and `app-kit/.github/` into the repo, set `APP_NAME` / `TYPE` / ports in `.deploy/manifest.env`, register the repo with `infra project add <app> --repo <org/repo>`, add its printed `INFRA_WEBHOOK_URL` and `INFRA_WEBHOOK_SECRET` as GitHub Actions secrets, then open a PR. Unknown manifest settings fail deployment. Databases and app connection variables are provisioned/configured explicitly.

## Day-to-day

**In the browser:** `https://console.<domain>` lists every environment with links. From there you can set variables and secrets per environment, rewire API and DB, redeploy, roll back, destroy, and read logs and the audit trail ([runbook](docs/runbook.md#the-console-web-ui)). There's also `traefik.`, `logs.` and `status.<domain>`.

**On the server:**
```bash
infra list                          # everything deployed, with URLs
infra logs shop pr-42               # or open https://logs.<domain>
infra redeploy shop staging         # after changing secrets
infra rollback shop prod
sudo infra secrets edit shop prod   # runtime secrets per app/env
infra db template shop seed.dump    # set the sanitised seed used when explicitly creating preview DBs
infra db create shop pr-12
infra db use shop pr-12 --key DATABASE_URL
infra cleanup --dry-run
```
More in the [runbook](docs/runbook.md).

## Built-in server hygiene

- **Logs**: Docker json-file 3×10 MB per container, journald capped at 500 MB, `/var/log/infra` rotated daily for 14 days
- **Disk**: nightly removal of images *we* pulled that are no longer used (never a global prune). The alert threshold is `DISK_ALERT_PCT` (80% in the production example).
- **Previews**: capped at `MAX_PREVIEWS`, removed on PR close (via CI, and nightly via the GitHub API), expire after `PREVIEW_TTL_DAYS`
- **Runtime isolation**: memory/CPU/pid limits on every container. Postgres is on private per-environment networks. Traefik reads Docker through a read-only socket proxy
- **Security**: `no-new-privileges` on every container, a read-only Docker socket proxy, and basic-auth on previews and ops tools. On `HOST_MODE=dedicated` servers it also sets SSH keys only, no root login, ufw (22/80/443 only), fail2ban and unattended security upgrades
- **Resource ownership**: managed resources are labelled `infra.managed=true` and prefixed `infra-`. Preflight checks refuse on port, name or user collisions
- **Backups**: nightly `pg_dump` of every non-preview DB plus `/etc/infra`, pushed off-server with restic
- **Alerts**: disk, memory, crash-looping or unhealthy containers, platform down, and failed deploys/migrations/backups go to your Slack/Discord/Teams webhook
- **Audit**: every deploy is logged to `/var/log/infra/deploy.log` with who, what tag and which branch

## Known limits

- **One server = one point of failure.** Backups and a rebuild from `bootstrap/` are your recovery plan. Practise it on the VM.
- **Brief blip on deploy.** `compose up` replaces the container, which takes a second or two for previews and prod alike. Zero-downtime prod needs blue/green (see architecture doc).
- **Shared Postgres.** It's efficient, but a runaway query in a preview can slow prod. Move prod to managed Postgres when it matters and set its connection string as a production app variable.
