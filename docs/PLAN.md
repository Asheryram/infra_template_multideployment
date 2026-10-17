# Plan / handover

Living to-do list for this repo. **To resume in a new session:** say *"continue with docs/PLAN.md"*. Work top to bottom, tick items off here, and commit after each one.

_Last updated: 2026-10-12 · next up: item 3 (item 5 is done)_

---

## Where things stand

**Implemented** (last verified on WSL Ubuntu with 7 pre-existing Docker Desktop containers):

- Shared-host-safe platform: `HOST_MODE=shared`, preflight, `infra.managed` labels, `infra-` prefix, no global prune, `bootstrap/uninstall.sh`
- Traefik (8880/8443 locally), Postgres, Uptime Kuma, Dozzle, and the **console** at `https://console.<domain>` (`platform/console/`)
- **One config format (2026-10-12):** `.infradeploy/infra.yml` lists independent `services`; no project types. Databases are declared per service and created on demand (console button), then injected; `required_env` blocks deploys. Parsed by `scripts/parse-manifest.py`. `manifest.env`, `compose.extra.yml` and `templates/components` were removed (clean break).
- App connections are configured as ordinary environment variables; cross-repo branch matching and automatic relinking are not implemented.
- Variables per app and scope (common / class / single env / `.component`), `*_REQUIRED_ENV` blocking, "will miss" warnings
- Validation scripts: `local/smoke-test.sh`, `local/e2e/run.sh`, and `local/verify-isolation.sh`. Run them for current results; assertion totals change as coverage evolves.

**Git state:** this plan is committed with the current `main` branch; check `git status -sb` for current synchronization status rather than relying on a remembered commit list.

**Local test env still running** in WSL `Ubuntu` (as root: `wsl -d Ubuntu -u root`):

- the platform and smoke-test stacks (`infra list`)
- Re-sync after editing on Windows: `.\local\wsl-up.ps1 -Name Ubuntu -Domain 127-0-0-1.sslip.io`
- Remove everything: `sudo bash /opt/infra/bootstrap/uninstall.sh`

**Discarded on purpose (2026-10-09):** the "one repo, frontend/ and backend/ deployed independently" mode (multiple `.deploy/` dirs + `WATCH_PATHS`). `WATCH_PATHS` is not a supported manifest key.

---

## To do

### 1. Per-environment network isolation ✅ DONE

Each deployment environment has its own `<stack>_net`. Traefik joins networks for routing, and Postgres joins only networks of environments that use the platform database. `infra networks list|reconnect|migrate` manages and migrates the runtime attachments. Cross-app DB sharing attaches only the required network. The local e2e and isolation scripts cover direct-container isolation and database reachability. After Docker Desktop restarts under WSL, restart `infra-traefik` and `infra-console` if their bind mounts were unavailable at startup.

### 2. Project registry + signed webhook trigger ✅ DONE

`infra project add|list|show|set|rotate-secret|remove` manages per-project repository access and credentials; webhook secrets are generated, stored under `$STATE_DIR/projects/`, and revealed only when issued. The console's Projects tab provides project registration and management. Signed webhooks validate freshness/replay protection, repository and environment authorization, production branch, and the bundled manifest; jobs run asynchronously. App-kit uses webhooks by default, with the self-hosted runner available through `INFRA_TRIGGER=runner`. `local/e2e/run.sh` exercises successful deploy/destroy and rejection cases including invalid signatures, stale/replayed requests, unauthorized repos/environments, and unsafe bundles.

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
- [ ] Future, not currently supported: decide whether to add a manifest option for seeding previews from another environment. Do not put `DB_PREVIEW_SOURCE` in manifests until parser and implementation support it.

**Test / accept:**
- [ ] e2e: develop has N visits, seed pr-X from develop → pr-X shows N+1. `--from prod` without the flag is refused, and no `*.dump` files exist anywhere under `/tmp`, `$STATE_DIR` or `$DEPLOY_ROOT` afterwards.

### 4. Multi-project management polish

- [ ] Console Environments: filter/search by project and a per-project summary (env count, previews, RAM in use via `docker stats --no-stream` filtered by label).
- [x] Per-project preview cap: `max_previews_per_app` in `.infradeploy/infra.yml`, in addition to the global inventory cap.
- [ ] Per-project aggregate resource budget across environments. Per-container and per-deployment-stack ceilings are enforced; this broader budget is still needed to prevent many individually capped environments from exceeding a project's allocation.
- [ ] `infra project report`: which projects, owners, envs, last deploy, disk/RAM. Print in the CLI and show in the console.
- [ ] Validate the tenant identity-provider integrations end-to-end: Keycloak/OIDC and Authentik login, role isolation, account lifecycle, recovery, backup/restore, and VPN-only routing. See `docs/access-control.md`.

### 5. infra.yml, Keycloak, access and invitations ✅ DONE (2026-10-12)

- [x] **infra.yml model**: independent services, URL convention, databases declared and created on demand (console button / `infra db create [--db svc:VAR]`), `required_env` blocks, explicit variables instead of auto-linking. Console shows per-service endpoints and database state.
- [x] **Fresh-install path validated** (wipe → `wsl-up.ps1` → `install.sh` → `platform up` → `bootstrap-realm.sh --apply`): [runbook-fresh-install.md](runbook-fresh-install.md). Fixed on the way: `groups` scope (`invalid_scope`), `uninstall.sh` volumes + `/srv/backups`, `platform up` vs the root-owned `infra-gitops` unit, unfilled previews secrets.
- [x] **Keycloak everywhere, no basic auth**: console, environment gates (previews by default; any class via `auth:`), ops tools (`OPS_AUTH_MODE`, platform admins only). Signed webhooks stay HMAC by design.
- [x] **Granular access**: organization → projects → members → project-wide role OR `env:`/`class:`/`branch:` grants (highest wins), enforced on every environment endpoint, variable scopes and the gates. Matrix in `docs/access-control.md`.
- [x] **Project links** (console → Access → Project links, not in `infra.yml`; no app change and no variable set by the link: either every fetch/XHR of the page (`Sec-Fetch-Dest: empty`, minus the frontend's own paths) or explicit paths go to the other project, behind the frontend's gate; the API can drop its public address; same environment class; managed by a platform admin or the organization's admin). Live test `local/e2e/upstreams.sh` 41 checks incl. a real browser running the unmodified demo frontend; `local/fuzz_test.py` 9 properties; `policy_test` 95. Not yet done: ZAP baseline, real-browser run as a real signed-in user, clean-install run on a separate server.
- [x] **Certificates**: `infra platform cert status|import <crt> <key>` (validates key match, names, expiry; keeps a backup; imported certs are never auto-replaced) + 30-day expiry warning on `platform up`; `docs/certificates.md` (mkcert for local). 18-case test.
- [x] **Groups, org admin/member only; roles removed from the UI** (permissions are policies attached to groups or people; existing role grants are migrated into policies automatically; org admin = every delegable action in the organization). `policy_test` 64, `env_grants` 43, `invites` 34; the tree editor and its `tree_test` are gone.
- [x] **Policies (AWS-style)**: actions (List/Read/Write/Privileged), Allow/Deny statements, resources `org/project/env`, conditions (branch, class, expires), presets, simulator, Visual+JSON editor, least-privilege visibility (non-listable -> 404). Quick-access grants compile into the same engine. Tests: `policy_test` 46, plus the earlier suites unchanged. Not yet applied to the live host (`wsl-up.ps1`, then `sudo -u deploy infra platform up`).
- [x] **Access as a tree** (organization → project → environment, a role on any level applies below it, highest wins; patterns for future environments; one atomic "Access by person" editor): `docs/access-control.md`. 24-case test (`local` suite `tree_test`) plus the earlier 50 + 34 pass.
- [x] **Invitations + account creation**: invite by email (nothing applied until the invitee accepts; no account lookup by org admins), console creates the Keycloak account through a create-only service account (email, or a one-time password shown once). Tested: 34 cases with a stub Keycloak admin API, and live against the real Keycloak (account created with no groups, throwaway user deleted).
- [x] **e2e rewritten** for the new model (`local/e2e/run.sh`, 72 assertions): develop → prod, DB on demand, explicit `API_URL`, gated preview, blocked deploy → variable → retry, rollback, organizations + scoped grants + invitations through the real console, signed webhooks, isolation. Removes everything it creates (`--cleanup-only` for interrupted runs). `docs/onboarding-local.md`, `README.md`, `docs/runbook.md`, `docs/architecture.md` brought in line.
- [ ] Still to exercise by hand with real people: scoped grants through actual Keycloak sign-ins (the logic is covered by 50 + 34 automated cases and the e2e, but not with a browser login), invitation emails once an SMTP server is configured in Keycloak, the GitOps watcher against a real GitHub repo.
- [ ] Remove the `python3` assumption on non-Linux dev machines (Windows Git Bash only has `python`).

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

- The console process can control Docker and remains a host-level trust boundary; tenant API authorization does not contain a compromised console process. A constrained deployment executor remains future hardening.
- Authentik and Keycloak/oauth2-proxy profiles, project-scoped roles, VPN allow-listing, core image digest pins, Dependabot, and Trivy scanning are implemented and have focused local/unit and Compose validation. They are not yet runtime/VPN validated or deployed; complete those checks before onboarding tenants.
- [ ] Pin remaining optional-profile image tags by digest and verify image provenance.
- [ ] Review container scanning results and establish a documented vulnerability exception/update cadence.
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
