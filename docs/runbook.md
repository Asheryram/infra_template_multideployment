# Runbook

All commands run on the server. `infra` works for any user in the `deploy` group. Use `sudo -u deploy infra …` from the admin account. **Installing from scratch?** See [runbook-fresh-install.md](runbook-fresh-install.md).

## Add a new app
1. The team copies `app-kit/.infradeploy/` and `app-kit/.github/` into their repo and sets `name:` (unique on the server) and the services in `.infradeploy/infra.yml`.
2. Register the repo: `sudo -u deploy infra project add <app> --repo <owner/repo> --gh-token <token>` (`<app>` = the `name:`). The GitOps watcher (`systemctl restart infra-gitops`) then deploys on every push. For the GitHub Actions webhook path, save the one-time `INFRA_WEBHOOK_URL` / `INFRA_WEBHOOK_SECRET` output as repository Actions secrets instead.
3. In the console → **Access**, assign the project to its client organization.
4. Add runtime secrets (if any): console → **Variables**, or `sudo infra secrets edit <app> preview` / `develop` / `staging` / `prod` (or `prod.api` for one service).
5. The team pushes or opens a PR. Databases declared in `infra.yml` are created from the environment's **Databases** section.

## Change secrets or env config
```bash
sudo infra secrets edit shop prod
infra redeploy shop prod
```
Repo-side non-secret config (`.infradeploy/env/*.env`) takes effect on the next deploy.

## The console (web UI)

`https://console.<domain>` is protected by Keycloak (or, for a bare local test, shared basic auth — operator-only). Organization/project access needs Keycloak or Authentik as described in [Access control](./access-control.md). Do not give app teams shared credentials.

In identity-provider mode, the console has an **Access** tab for platform administrators and organization admins in addition to the operational tabs:

| Access task | Who can do it |
|---|---|
| Create an organization; assign registered projects to it | Platform admin |
| Invite people (membership + groups, optionally creating their account) and revoke invitations | Platform admin or that organization's admin |
| Grant or revoke a project-wide role, or a role on one environment / a class / a branch pattern | Platform admin or that organization's admin |
| Remove a member | Platform admin or that organization's admin (not other admins) |
| Invite or change an organization admin | Platform admin only |

Invitations are accepted by the invitee in the console; nothing is applied before that. The full model and the permission matrix are in [access-control.md](./access-control.md#permission-matrix).

Operational tabs:

| Tab | What you do there |
|---|---|
| **Environments** | Every app and environment with a link per service, status, branch/tag, database state and what needs attention (blocked deploys, missing variables, databases to create); filter by class or search. **Manage** opens redeploy / restart / rollback / destroy, databases (create / wipe / reveal URL), container resources, effective variables (masked), and logs |
| **Projects** | Register repositories, configure allowed environments, issue or rotate webhook secrets, and remove project access. The webhook secret is shown once; save it as the repo's `INFRA_WEBHOOK_SECRET` Actions secret. |
| **Variables** | Server-side variables per app and scope: *all environments* (`common`), a class (`preview`, `develop`, `staging`, `prod`), or one environment (`pr-12`), optionally limited to one service (`.<service>`, e.g. `.api`). Platform-managed metadata is read-only. App override changes apply on the next deploy; save and redeploy when they should take effect immediately. |
| **Activity** | Who did what (console audit log) interleaved with deploy logs |

Everything the console does goes through the same `infra` CLI that CI uses, and it shares the deploy locks, so console, CLI and CI never fight. The console process controls Docker and is a high-trust boundary; follow the VPN-only access and recovery guidance in [access-control.md](./access-control.md).

### Register a repository for signed webhook deploys

Register each app name used as `name:` in `.infradeploy/infra.yml` and copy the one-time secret output into the repository's Actions secrets:

```bash
sudo -u deploy infra project add shop-api --repo your-org/shop-api --envs preview,develop,staging,prod
sudo -u deploy infra project list
```

The command prints `INFRA_WEBHOOK_URL` and `INFRA_WEBHOOK_SECRET`; the secret is not shown again. Use `infra project rotate-secret <app>` to revoke the old secret and issue a replacement. Webhook deployments are the app-kit default. To use the legacy self-hosted-runner workflow instead, set the repository variable `INFRA_TRIGGER=runner`.

## A feature needs new variables

1. The developer's PR adds the key to the service's `required_env` in `.infradeploy/infra.yml`, and puts any non-secret default in `.infradeploy/env/`.
2. The preview deploy is **blocked** (nothing changes, the old version keeps running). The console shows the environment as *blocked* with the missing keys, and an alert is sent.
3. Console → **Variables** → app → scope `pr-12` (just this PR) or `preview` (all PRs) → add the key → **Retry deploy**.
4. Before merge, add the key for `develop`, `staging` and `prod`. The banner on the Variables tab lists every environment still missing it.

CLI equivalent: `sudo infra secrets edit <app> <scope>` then `infra redeploy <app> <env>`.

## Set application connections

The platform does not discover backend repos, match branches, or change connection targets automatically. Set an app's API or external database URL in **Variables** (console) or with `sudo infra secrets edit <app> <scope>`, then redeploy.

Databases are **declared** under a service in `infra.yml` and created on demand: console → the environment → **Databases → Create database** (it redeploys so the URL is injected as the declared variable). CLI equivalent:

```bash
infra db info shop-api pr-7           # what is declared, what exists
infra db create shop-api pr-7         # all missing, or: --db api:DATABASE_URL
infra redeploy shop-api pr-7          # injects the URL (the console does this for you)
infra db use shop-api pr-7 --key REPORTS_DB_URL --from shop-api/develop   # point a variable at ANOTHER environment's database
```

For shared or external databases, set the connection variable your app expects and verify access policies yourself. The platform cannot protect data in an externally configured database.

## A deploy failed
```bash
tail -n 100 /var/log/infra/deploy.log
infra ps shop pr-42
infra logs shop pr-42
infra config shop pr-42      # what compose actually ran
infra env shop pr-42         # resolved env (secrets masked)
```
Common causes:
- the image isn't listening on the service's `port:` in `infra.yml`
- the image's own `HEALTHCHECK` fails (the platform injects none)
- `migrate.cmd` failed (the old version keeps running)
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
| Keycloak admin / proxy secrets | edit `/etc/infra/platform.secrets.env`, re-run `bootstrap-realm.sh` (keeps the clients in sync), `infra platform up` |
| Basic-auth (only if a surface is still on basic) | edit `*_USERS` in the inventory, re-run bootstrap step 50, `infra platform up` |
| Registry token | `/etc/infra/platform.secrets.env`, next deploy picks it up |
| A database's password | delete `/srv/deployments/<app>/<env>/.db_password_<db>`, `infra db create <app> <env>`, `infra redeploy <app> <env>` |
| Postgres superuser | `infra db psql`-style `ALTER ROLE postgres PASSWORD …` (it's only used inside the container) |

## Remove an app completely
```bash
for e in $(ls /srv/deployments/shop); do infra destroy --app shop --env "$e" --i-really-mean-prod; done
infra db drop-template shop
sudo rm -rf /etc/infra/secrets/shop
```
