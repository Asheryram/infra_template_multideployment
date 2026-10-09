# Plan / handover

Living to-do list for this repo. **To resume in a new session:** say *"continue with docs/PLAN.md"*. Work top to bottom, tick items off here, and commit after each one.

_Last updated: 2026-10-09 · last commit at time of writing: `eed1c72`_

---

## Where things stand

**Built and tested** (WSL Ubuntu with 7 pre-existing Docker Desktop containers):

- Shared-host-safe platform: `HOST_MODE=shared`, preflight, `infra.managed` labels, `infra-` prefix, no global prune, `bootstrap/uninstall.sh`
- Traefik (8880/8443 locally), Postgres, Uptime Kuma, Dozzle, and the **console** at `https://console.<domain>` (`platform/console/`)
- Project types: `monolith`, `split` (one repo, web+api together), `frontend` + `backend` (two repos, branch matching)
- DevOps overrides: `infra link`, `infra attach-db`, and the console's Wiring section
- Variables per app and scope (common / class / single env / `.component`), `*_REQUIRED_ENV` blocking, "will miss" warnings
- Tests:
  - `local/smoke-test.sh`: 17/17
  - `local/e2e/run.sh`: **47/47**
  - `local/verify-isolation.sh`: 47/47

**Not yet pushed:** commits after `68b3da7` are local only (`fd93bc3`, `41d0fc3`, `8e872a7`, `eed1c72` and anything newer). Run `git push` when ready.

**Local test env still running** in WSL `Ubuntu` (as root: `wsl -d Ubuntu -u root`):

- the platform and smoke-test stacks (`infra list`)
- Re-sync after editing on Windows: `.\local\wsl-up.ps1 -Name Ubuntu -Domain 127-0-0-1.sslip.io`
- Remove everything: `sudo bash /opt/infra/bootstrap/uninstall.sh`

**Discarded on purpose (2026-10-09):** the "one repo, frontend/ and backend/ deployed independently" mode (multiple `.deploy/` dirs + `WATCH_PATHS`). Don't redo it unless asked.

---

## To do

### 1. Per-project network isolation (security fix, highest priority)

**Problem:** every app joins the shared `infra_proxy` network, and DB apps join `infra_data`. Project A's containers can reach project B's containers directly, bypassing Traefik, preview basic auth and middlewares. Postgres is reachable from all of them (credentials still separate databases).

**Do:**
- [ ] `deploy.sh`: create a network per app, `infra_p_<app>` (labels `infra.managed=true`, `infra.app=<app>`). Connect `infra-traefik` to it (`docker network connect`, idempotent). If the app needs a DB, also connect `infra-postgres` to it.
- [ ] Templates `templates/components/{app,web,api}.yml`: replace `proxy` and `data` with one external network `${APP_NETWORK}`. Set label `traefik.docker.network=${APP_NETWORK}`. Write `APP_NETWORK` into `stack.env`.
- [ ] `destroy.sh`: when the app's **last** environment is destroyed, disconnect traefik/postgres and remove `infra_p_<app>`.
- [ ] Console/platform containers keep `infra_proxy` (platform-only network).
- [ ] Overrides: `attach-db --share` across apps must also connect the borrower to the lender's network. `--url host.docker.internal` is unchanged.
- [ ] `compose.extra.yml.example`: use `${APP_NETWORK}` instead of `data`.
- [ ] Migration: existing stacks move on their next redeploy. Provide `infra migrate-networks`, which redeploys every stack once.
- [ ] Docker address pools: one network per **app** (not per env) keeps the count low. Document it in `docs/shared-host.md`.

**Test / accept:**
- [ ] New e2e chapter: from inside a `demo-web` container, a request to a `demo-api` container must FAIL directly but WORK through its public URL.
- [ ] `demo-api` reaches Postgres, while a `frontend`-only app has no route to Postgres.
- [ ] smoke 17/17, e2e all green, isolation all green.

### 2. Project registry + signed webhook trigger (scales to many repos/orgs)

**Problem:** deploys run through a self-hosted GitHub runner. On personal accounts that's one runner per repo, and across many projects and orgs it's painful.

**Do:**
- [ ] `infra project add <app> --repo <owner/repo> [--envs prod,staging,develop,preview]` stores `$STATE_DIR/projects/<app>.env` (0600): repo, allowed envs, `WEBHOOK_SECRET` (random 32 bytes, shown once). Also `infra project list|rotate-secret|remove`, plus a Console "Projects" tab.
- [ ] Console `POST /webhook` (bypasses ops-auth via a separate Traefik router on `hooks.<domain>` with rate-limit):
  - verify `X-Infra-Signature: sha256=HMAC(secret, body)` (constant-time compare)
  - `X-Infra-Timestamp` within ±300 s (replay protection) and a nonce cache
  - the repo in the payload must match the registered project
  - env must be allowed, and `prod` only from the `main` branch
  - payload `{app, repo, env, tag, branch, commit, action: deploy|destroy, manifest_b64}`. Manifest limited to 64 KB; validate APP_NAME = registered app
  - run `infra deploy` asynchronously (job queue, one per stack via the existing flock), return a `202` + job id, and `GET /webhook/jobs/<id>` (same HMAC) for status/log
  - audit everything to `console.log`
- [ ] App-kit workflow: add `TRIGGER: webhook | runner` (default webhook). The webhook job builds/pushes on GitHub, then `curl`s the signed payload. Secrets: `INFRA_WEBHOOK_URL`, `INFRA_WEBHOOK_SECRET`. It polls the job status and posts the PR comment from GitHub (no runner needed).
- [ ] The server needs registry pull access per project. Store `REGISTRY_USER/TOKEN` per project in the registry file (fall back to the global ones).
- [ ] Docs: onboarding a new project = `infra project add` → copy app-kit → set 2 repo secrets → open a PR.

**Test / accept:**
- [ ] `local/e2e/gh-sim.sh` gains a `--webhook` mode that signs payloads like the workflow.
- [ ] Tests:
  - bad signature → 401
  - old timestamp → 401
  - wrong repo → 403
  - prod from a non-main branch → 403
  - a valid request deploys
  - a valid close destroys

### 3. Seed a preview DB from another environment (no dump file on disk)

**Do:**
- [ ] `infra db seed <app> <target-env> --from <source-env> [--yes]`:
  - streams `docker exec infra-postgres pg_dump -Fc <src> | docker exec -i infra-postgres pg_restore --clean --if-exists --no-owner --role=<target-role> -d <target>`
  - no temp file ever exists, so nothing to `shred`
- [ ] Guards:
  - `--from prod` refused unless `--allow-prod`
  - the target must be a preview or develop/staging, never prod
  - the target must OWN its DB (`DB_MODE=own`)
  - takes the stack lock, writes an audit line
- [ ] Console: a Manage → "Seed database from…" dropdown (envs of the same app with their own DB), with typed confirmation.
- [ ] Optional `DB_PREVIEW_SOURCE=env:develop` in the manifest: auto-seed new previews from develop at creation (default stays `template`). Docs warn about real/personal data in previews.

**Test / accept:**
- [ ] e2e: develop has N visits, seed pr-X from develop → pr-X shows N+1. `--from prod` without the flag is refused, and no `*.dump` files exist anywhere under `/tmp`, `$STATE_DIR` or `$DEPLOY_ROOT` afterwards.

### 4. Multi-project management polish

- [ ] Console Environments: filter/search by project and a per-project summary (env count, previews, RAM in use via `docker stats --no-stream` filtered by label).
- [ ] Per-project preview cap, `MAX_PREVIEWS` in the project registry (the global cap stays).
- [ ] Per-project resource ceiling: sum of `mem_limit` across a project's envs. Refuse a deploy over the budget.
- [ ] `infra project report`: which projects, owners, envs, last deploy, disk/RAM. Print in the CLI and show in the console.
- [ ] Optional: per-project console access (team leads see only their project). That needs real users instead of a single ops basic-auth, e.g. Traefik forward-auth + GitHub OAuth.

### 5. Optional: `devops.yaml` manifest format

- [ ] Accept `.deploy/devops.yaml` in addition to `manifest.env`. Convert YAML → env with `yq` (install in bootstrap/console image), with a schema check. `manifest.env` stays the canonical internal format.
- [ ] App-kit: ship `devops.yaml.example` next to `manifest.env`.

### 6. Real-world rollout (after 1–3)

- [ ] `git push` all local commits. Consider transferring the repo to an org.
- [ ] Real server, read-only checks first:
  - `ss -ltnp '( sport = :80 or sport = :443 )'`
  - `docker compose version`
  - `docker network ls | wc -l`
  - `getent passwd infradeploy`
- [ ] `inventory/<server>.env` from `prod.env.example`. Run preflight only: `install.sh <inv> 00`. Then the full bootstrap, then `infra platform up`.
- [ ] Onboard one real project end to end (webhook mode): PR → preview → comment → close.
- [ ] Off-server backups: set `RESTIC_REPOSITORY`, and test a restore once.

### 7. Hardening / honest limits (decide, don't necessarily build)

- [ ] **Docker access = root.** The deploy user and the console can control Docker, so treat the ops login like root. Real per-tenant least privilege means rootless Docker per tenant (a big change). Write up the trade-off in `docs/architecture.md`.
- [ ] **The console login is basic auth.** Add an IP allowlist middleware (`ipAllowList`) option for `console.` / `logs.` / `traefik.`.
- [ ] Pin platform image versions/digests in the inventory (currently `:latest` / major tags).
- [ ] Run shellcheck locally or in CI (the `lint.yml` workflow exists, but it hasn't been confirmed green on GitHub).

---

## How to work on this (conventions)

- Edit on Windows, sync to WSL with `wsl-up.ps1 -Name Ubuntu -Domain 127-0-0-1.sslip.io`, then test inside `wsl -d Ubuntu -u root`.
- Never touch anything not labelled `infra.managed=true` (the shared host rule). After changes, run:
  - `sudo -u deploy bash /opt/infra/local/smoke-test.sh`
  - `sudo bash /opt/infra/local/e2e/run.sh`
  - `sudo bash /opt/infra/local/verify-isolation.sh`
- Keep CLI, console and CI on the same code path (`bin/infra`). The console only shells out to it.
- Commit per item, with the attribution line used in earlier commits.
