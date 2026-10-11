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

`https://console.<domain>` is protected by the configured console authentication mode. Basic mode is transitional and operator-only; for organization/project access, use Keycloak or Authentik as described in [Access control](./access-control.md). Do not give app teams the shared dashboard Basic Auth credentials.

In identity-provider mode, the console has an **Access** tab for platform administrators and organization admins in addition to the operational tabs:

| Access task | Who can do it |
|---|---|
| Create an organization and link registered projects to it | Platform admin |
| Add or remove organization members | Platform admin or that organization's admin |
| Grant or revoke a project role | Platform admin or that organization's admin |
| Assign or change an organization-admin role | Platform admin only |

Every user must sign in through the configured identity provider at least once before they can be assigned by email. Organization membership alone does not expose deployments; grant a role for each project the user needs.

Operational tabs:

| Tab | What you do there |
|---|---|
| **Environments** | Every app and environment with open-links, status, branch/tag, reported API/DB connection, and missing variables. **Manage** opens redeploy / restart / rollback / destroy, effective variables (masked), database actions, and last 200 log lines |
| **Projects** | Register repositories, configure allowed environments, issue or rotate webhook secrets, and remove project access. The webhook secret is shown once; save it as the repo's `INFRA_WEBHOOK_SECRET` Actions secret. |
| **Variables** | Server-side variables per app and scope: *all environments* (`common`), a class (`preview`, `develop`, `staging`, `prod`), or one environment (`pr-12`), optionally limited to one component (`.api` / `.web` / `.app`). Platform-managed metadata is read-only. App override changes apply on the next deploy; save and redeploy when they should take effect immediately. |
| **Activity** | Who did what (console audit log) interleaved with deploy logs |

Everything the console does goes through the same `infra` CLI that CI uses, and it shares the deploy locks, so console, CLI and CI never fight. The console process controls Docker and is a high-trust boundary; follow the VPN-only access and recovery guidance in [access-control.md](./access-control.md).

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

## Set application connections

The platform does not discover backend repos, match branches, or change connection targets automatically. Set an app's API or external database URL in **Variables** (console) or with `sudo infra secrets edit <app> <scope>`, then redeploy.

To provision this environment's own platform database:

```bash
infra db create shop-api pr-7
infra db use shop-api pr-7 --key DATABASE_URL
infra redeploy shop-api pr-7
```

For shared or external databases, set the connection variable your app expects and verify production/preview access policies yourself. The platform cannot protect data in an externally configured database.
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
Lower `MAX_PREVIEWS` / `PREVIEW_TTL_DAYS`, adjust the infra-owned `RESOURCE_PREVIEW_*` inventory defaults, or set a scoped override under **Manage → Container Resources** in the console. Per-container and per-stack ceilings are enforced on every deploy.

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
