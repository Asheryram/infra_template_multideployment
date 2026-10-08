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
