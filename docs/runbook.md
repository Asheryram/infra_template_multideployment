# Runbook

All commands run on the server. `infra` works for any user in the `deploy` group. Use `sudo -u deploy infra …` from the admin account.

## Add a new app
1. The team copies `app-kit/` into their repo and sets `APP_NAME` (unique on the server).
2. Register the app and repo for signed webhook deploys (the app-kit default):
   `sudo -u deploy infra project add <app> --repo <owner/repo>`
   Save the one-time `INFRA_WEBHOOK_URL` and `INFRA_WEBHOOK_SECRET` output as repository Actions secrets. For the legacy runner workflow, set repository variable `INFRA_TRIGGER=runner` instead.
3. Add runtime secrets (if any) for each class:
   `sudo infra secrets edit <app> preview` / `develop` / `staging` / `prod` (or `prod.api` for one component)
4. Optional: seed previews with `infra db template <app> sanitised.dump`
5. The team opens a PR. The preview URL appears as a comment.

## Change secrets or env config
```bash
sudo infra secrets edit shop prod
infra redeploy shop prod
```
Repo-side non-secret config (`.deploy/env/*.env`) takes effect on the next CI deploy.

## The console (web UI)

`https://console.<domain>` (ops login, using the `DASHBOARD_AUTH_*` credentials). It has four tabs:

| Tab | What you do there |
|---|---|
| **Environments** | Every app and environment with open-links, status, branch/tag, which API it calls, which DB it uses, missing variables. **Manage** opens: API wiring, DB wiring, redeploy / restart / rollback / destroy, effective variables (masked), last 200 log lines |
| **Projects** | Register repositories, configure allowed environments, issue or rotate webhook secrets, and remove project access. The webhook secret is shown once; save it as the repo's `INFRA_WEBHOOK_SECRET` Actions secret. |
| **Variables** | Server-side variables per app and scope: *all environments* (`common`), a class (`preview`, `develop`, `staging`, `prod`), or one environment (`pr-12`), optionally limited to one component (`.api` / `.web` / `.app`). Platform-managed metadata is read-only. App override changes apply on the next deploy; save and redeploy when they should take effect immediately. |
| **Activity** | Who did what (console audit log) interleaved with deploy logs |

Everything the console does goes through the same `infra` CLI that CI uses, and it shares the deploy locks, so console, CLI and CI never fight. It runs as the deploy user, but it controls Docker, so treat the ops login like a root password: use a long password, and ideally allow it only from your VPN or IP.

### Register a repository for signed webhook deploys

Register each app name used by `.deploy/manifest.env` and copy the one-time secret output into the repository's Actions secrets:

```bash
sudo -u deploy infra project add shop-api --repo your-org/shop-api --envs preview,develop,staging,prod
sudo -u deploy infra project list
```

The command prints `INFRA_WEBHOOK_URL` and `INFRA_WEBHOOK_SECRET`; the secret is not shown again. Use `infra project rotate-secret <app>` to revoke the old secret and issue a replacement. Webhook deployments are the app-kit default. To use the legacy self-hosted-runner workflow instead, set the repository variable `INFRA_TRIGGER=runner`.

## A feature needs new variables

1. The developer's PR adds the key to `<COMPONENT>_REQUIRED_ENV` in `.deploy/manifest.env`, and puts any non-secret default in `.deploy/env/`.
2. The preview deploy is **blocked** (nothing changes, the old version keeps running). The console shows the environment as *blocked* with the missing keys, and an alert is sent.
3. Console → **Variables** → app → scope `pr-12` (just this PR) or `preview` (all PRs) → add the key → **Retry deploy**.
4. Before merge, add the key for `develop`, `staging` and `prod`. The banner on the Variables tab lists every environment still missing it.

CLI equivalent: `sudo infra secrets edit <app> <scope>` then `infra redeploy <app> <env>`.

## Rewire environments by hand (DevOps overrides)

CI and branch matching decide the default wiring. You can override it per environment, or for all of an app's previews with scope `preview`. Overrides survive CI redeploys, apply immediately, and are deleted with the environment.

```bash
# Frontend → which API
infra link shop-web pr-12   --api shop-api/staging          # test a PR against staging's API
infra link shop-web preview --api shop-api/develop          # ALL shop-web previews → develop API
infra link shop-web pr-12   --api-url https://api.partner.com
infra link shop-web pr-12   --auto                          # back to automatic

# API → which database
infra attach-db shop-api pr-7 --share shop-api/staging      # reproduce a bug on staging's data
infra attach-db shop-api pr-7 --url 'postgres://u:p@host.docker.internal:5433/legacy'   # a DB on the server
infra attach-db shop-api pr-7 --url 'postgres://u:p@10.0.0.5:5432/reporting'            # a DB elsewhere
infra attach-db shop-api pr-7 --own                         # back to its own DB (it was kept)

infra overrides                                             # what's overridden right now (passwords masked)
```

Safety rails:

| Rule | Why |
|---|---|
| Any prod target needs `--allow-prod` | A preview writing to prod data is the classic disaster |
| `MIGRATE_CMD` is **skipped** on a database the environment doesn't own (add `--migrate` to allow) | A PR's migration must not alter staging's or someone else's schema |
| `destroy` only ever drops the environment's **own** database | Shared and external databases are never dropped |
| `destroy` refuses while another environment borrows its database | Repoint the borrowers first (`--own`) |
| Pinned frontends are never moved by automatic relinking | Your choice wins until you set `--auto` |
| External DB passwords are stored in `/var/lib/infra/overrides` (0600) and masked in output | Prefer a dedicated least-privilege DB user |

## A deploy failed
```bash
tail -n 100 /var/log/infra/deploy.log
infra ps shop pr-42
infra logs shop pr-42
infra config shop pr-42      # what compose actually ran
infra env shop pr-42         # resolved env (secrets masked)
```
Common causes:
- the image isn't listening on `<C>_PORT`
- the healthcheck fails (no `/health` route)
- `MIGRATE_CMD` failed (the old version keeps running)
- the registry token expired
- the preview limit was reached

## Roll back prod
```bash
infra rollback shop prod             # previous tag
infra redeploy shop prod --tag sha-0123456789ab   # any tag still in the registry
```
Migrations are not rolled back. Write backward-compatible migrations (expand, then contract).

## Server is full / slow
```bash
df -h; free -h; docker stats --no-stream
infra list
infra cleanup --dry-run && infra cleanup
docker system df
```
Lower `MAX_PREVIEWS` / `PREVIEW_TTL_DAYS`, or set `PREVIEW_MEM_LIMIT` in noisy manifests.

## Restore a database
```bash
ls "${BACKUP_DIR:-/srv/backups}/"                   # or: restic snapshots
infra db restore shop prod "${BACKUP_DIR:-/srv/backups}/2026-10-07/shop_prod.dump"
infra restart shop prod
```

## Rebuild the server from scratch (disaster recovery)
1. New VPS, point DNS at it.
2. `git clone` this repo, copy the inventory, then run `bootstrap/install.sh`.
3. Restore `/etc/infra` from `etc-infra.tgz` in the latest backup (restic restore).
4. `infra platform up`
5. Restore roles: `docker exec -i infra-postgres psql -U postgres < globals.sql`, then `infra db restore` for each prod/staging DB.
6. Re-run the latest `main`/`staging`/`develop` workflows in each repo (or `infra deploy` by hand).

Practise this on the local VM (`local/reset.ps1`) before you need it.

## Update the platform
```bash
cd /opt/infra && git pull
sudo bash bootstrap/install.sh inventory/<server>.env   # idempotent, picks up changed files
infra platform pull && infra platform up
```

## Rotate credentials
| What | How |
|---|---|
| Dashboard / preview basic-auth | edit `*_USERS` in the inventory, re-run bootstrap step 50, `infra platform up` |
| Registry token | `/etc/infra/platform.secrets.env`, next deploy picks it up |
| App DB password | delete `/srv/deployments/<app>/<env>/.db_password`, `infra redeploy <app> <env>` |
| Postgres superuser | `infra db psql`-style `ALTER ROLE postgres PASSWORD …` (it's only used inside the container) |

## Remove an app completely
```bash
for e in $(ls /srv/deployments/shop); do infra destroy --app shop --env "$e" --i-really-mean-prod; done
infra db drop-template shop
sudo rm -rf /etc/infra/secrets/shop
```
