# Runbook

All commands run on the server. `infra` works for any user in the `deploy` group. Use `sudo -u deploy infra …` from the admin account.

## Add a new app
1. The team copies `app-kit/` into their repo and sets `APP_NAME` (unique on the server).
2. Add runtime secrets (if any) for each class:
   `sudo infra secrets edit <app> preview` / `develop` / `staging` / `prod` (or `prod.api` for one component)
3. Optional: seed previews with `infra db template <app> sanitised.dump`
4. The team opens a PR. The preview URL appears as a comment.

## Change secrets or env config
```bash
sudo infra secrets edit shop prod
infra redeploy shop prod
```
Repo-side non-secret config (`.deploy/env/*.env`) takes effect on the next CI deploy.

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
ls /srv/backups/                                   # or: restic snapshots
infra db restore shop prod /srv/backups/2026-10-07/shop_prod.dump
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
