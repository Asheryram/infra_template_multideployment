# Runbook: fresh install, from nothing to a working platform

Start-to-finish for the **local WSL host** (Docker Desktop + the existing Ubuntu distro, treated as a shared host). Every command below was run in this order on a clean machine. Where a real server differs, there is a **Production** note.

**You end up with:** Traefik, Postgres, the console and Uptime Kuma · Keycloak (realm `infra`) as the only login for the console **and** for preview environments · organizations (clients) with projects and granular access · your repos deploying themselves on `git push`.

| Where | Shell | Shows as |
|---|---|---|
| Windows | PowerShell, in the repo folder | `PS>` |
| The server | `wsl -d Ubuntu -u root` (keep it open) | `root@…#` |

> The server shell is root. Platform commands that touch state run as the `deploy` user (`sudo -u deploy infra …`) so file ownership stays right.

---

## 0. Wipe the old installation (skip on a brand-new machine)

Removes **only what this template created** — every infra container, all deployments and their databases, the platform volumes (**including Keycloak's data**), our networks, our images and firewall rules, `/etc/infra`, the state dirs and the `deploy` user. Other containers on the host are never touched.

```bash
# root@…#  — shows exactly which containers are NOT ours; they must still be there at the end
docker ps -a --format '{{.Names}}' | grep -v '^infra-'

bash /opt/infra/bootstrap/uninstall.sh --yes
```

Old backups are moved aside to `/srv/backups.uninstalled-<date>` (they contain the previous secrets — delete by hand when sure: `rm -r /srv/backups.uninstalled-*`).

Mop up leftovers of ours that the uninstaller leaves (empty stack networks and the images the demo apps built):

```bash
for n in $(docker network ls --format '{{.Name}}' | grep '^infra-'); do
  [ "$(docker network inspect -f '{{len .Containers}}' "$n")" = 0 ] && docker network rm "$n"
done
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(local/|infra-console:)' | xargs -r docker rmi
```

- [ ] `docker ps -a | grep '^infra-'` prints nothing, `docker volume ls | grep infra` prints nothing, and your own containers are all still listed.

---

## 1. Sync the repo into the server

```powershell
PS> .\local\wsl-up.ps1 -Name Ubuntu -Domain 127-0-0-1.sslip.io
```

Copies the repo to `/opt/infra` (it replaces what is there) and writes `DOMAIN` into `inventory\local.env`. Re-run it after every change you make on Windows.

- [ ] ends with `DOMAIN: 127-0-0-1.sslip.io`

Check `inventory\local.env` (your local file, git-ignored). The Keycloak lines must be there:

```
PLATFORM_PROFILES=keycloak
CONSOLE_AUTH_MODE=basic
PREVIEW_AUTH_MODE=basic
KEYCLOAK_REALM=infra
KEYCLOAK_PLATFORM_ADMIN_GROUP=infra-platform-admins
KEYCLOAK_VPN_CIDRS=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

> **Local only:** the address your browser reaches Traefik from changes whenever Docker Desktop restarts, so the allowlist uses the private ranges. **Production:** put your VPN subnet there instead, e.g. `10.8.0.0/24`.

## 2. Record what is yours, then install

```bash
# root@…#
bash /opt/infra/local/verify-isolation.sh --record          # snapshot of your containers, volumes, images, firewall
bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env
```

Shared-host mode only adds: the `deploy` user, `/etc/infra`, `/srv/deployments`, `/var/lib/infra`, a cron file, the `infra` CLI, the `infra-gitops` service and ufw *allow* rules for 8880/8443.

- [ ] ends with `Bootstrap complete.`
- [ ] `grep -c '@[A-Z_0-9]*@' /etc/infra/platform.secrets.env` prints `0` (no unfilled placeholders)

> If it stops at preflight with `/srv/backups already exists`, move it aside: `mv /srv/backups /srv/backups.old`.

## 3. Start the platform (phase 1: Keycloak runs, console still on basic auth)

```bash
sudo -u deploy infra platform up
```

First run builds the console image and pulls Keycloak (a few minutes).

- [ ] ends with `platform is up:` and every container healthy: `docker ps --format '{{.Names}} {{.Status}}' | grep '^infra-'`
- [ ] a line `WARN: could not restart the GitOps watcher as deploy` is **expected** — it is handled in step 7.

## 4. Create the Keycloak realm, clients and your admin user

One idempotent script creates the realm `infra`, the group `infra-platform-admins`, the two OIDC clients (`infra-console`, `infra-previews`) with their `groups` and audience mappers, **your first admin user**, and switches **everything** to Keycloak login (see the table in step 8).

```bash
bash /opt/infra/platform/keycloak/bootstrap-realm.sh \
  --admin-user <your-username> --admin-email <you@your-domain> --apply
```

It prints a one-time password for that user (Keycloak makes you change it at first sign-in). `--dry-run` shows what it would do; running it again is safe.

- [ ] output shows `created realm infra`, both clients, `<you> is in infra-platform-admins`, and `platform is up`
- [ ] `docker ps | grep -E 'oauth2-(proxy|previews)'` shows both proxies
- [ ] `grep -E '^(PLATFORM_PROFILES|CONSOLE_AUTH_MODE|PREVIEW_AUTH_MODE|OPS_AUTH_MODE)=' /etc/infra/infra.env` shows `keycloak,keycloak-auth,keycloak-previews` and `keycloak` three times

> **Production:** the same script works. Keep `KEYCLOAK_VPN_CIDRS` to your real VPN subnet — `auth.<domain>` and `sso.<domain>` are VPN-only, so people must be on the VPN to sign in.

## 5. Sign in

Open `https://console.127-0-0-1.sslip.io:8443` (accept the self-signed certificate once per host). You are sent to Keycloak; sign in with the one-time password, set a new one. You land in the console as a **platform administrator**.

- [ ] the console loads and the sidebar shows Environments, Projects, Variables, Activity, **Access**
- [ ] `https://auth.127-0-0-1.sslip.io:8443/admin/master/console/` opens (sign in with `KEYCLOAK_ADMIN_USERNAME` / `KEYCLOAK_ADMIN_PASSWORD` from `/etc/infra/platform.secrets.env`) — only needed for advanced Keycloak work

---

## 6. Organizations, projects and who can do what

**The model**

```
Platform admin  (member of the Keycloak group infra-platform-admins — everything)
 └─ Organization  = one client / tenant ("acme")      a role here covers every project below, now and later
     ├─ Members   = people of that client (member | organization admin)
     └─ Project   = one registered app (shop-api …)   a role here covers all its environments
         └─ Environment (develop, prod, pr-12 …)       a role here covers just this one
             └─ patterns: "all previews", "feature/*", an environment name   (cover future environments too)
```

Roles: **viewer** (read, and open previews) · **operator** (+ redeploy, restart, roll back) · **maintainer** (+ edit variables, create databases). A role set on a level applies to **everything below it**; an environment's **effective role is the highest** role set on any level above it or on the environment itself, and people only *see* environments they can access. Resource limits, project registration, database wipes, destroying environments and revealing secrets stay **platform-admin-only**. The same rules decide who may open a **preview** (step 8).

Do this once, in the console → **Access** (everything is audited):

1. **Create the client organization** (Organizations card): name `Acme Corp`, slug `acme`.
2. **Register the projects** (step 7), then **assign** each to the organization (Organizations card, "Assign registered project").
3. **Invite people** (Organization membership card): email, optional name, and the groups to put them in. They get a pending invitation, accept it themselves after signing in, and — if they have no account — the console creates one (an email to set a password, or a one-time password shown to you once when no mail server is configured). You never need the Keycloak admin console for this. See `docs/access-control.md` → *Inviting people*.
4. **Policies and groups** — console → **Access**: write a policy (Visual or JSON editor; start from a preset and narrow its resources), create a group, attach the policy to the group, add people. Examples:

| Person | Policy / group | Result |
|---|---|---|
| Client's tech lead | make them an **organization admin** | runs every project of the client |
| Client's developer Alice | group *shop-web-devs* with the Maintainer preset on `acme/shop-web/*`, condition branch `feature/checkout*` | sees/edits only the previews built from her feature branches |
| QA team | group *qa* with the Viewer preset on `acme/*`, condition class `preview` | can open every preview, nothing else |
| Product owner | policy: `environment:List`, `environment:View`, `environment:Open` on `acme/shop-web/develop` | opens develop only |
| DevOps contractor | Operator preset on `acme/shop-web/staging`, expires `2026-12-31` | can redeploy/restart staging until the date |
| A reviewer who may see but not open | `environment:List` + `environment:View` on `acme/*` | sees every environment, opens none |

- [ ] invite a test email into a group whose policy is the Viewer preset on `acme/*` with condition class `preview`: after they accept they see just previews; a member with no group or policy sees nothing.
- [ ] the full permission matrix is in `docs/access-control.md`.

---

## 7. Register the projects and let GitHub deploy them

Each repo needs `.infradeploy/infra.yml` (see `app-kit/README.md`) and the app-kit workflow, then:

```bash
# root@…#  — one per repo; --repo must match GitHub exactly
sudo -u deploy infra project add shop-api --repo <owner>/shop-api --gh-token <github-token>
sudo -u deploy infra project add shop-web --repo <owner>/shop-web --gh-token <github-token>
sudo -u deploy infra project list
```

- `<app>` is the `name:` in the repo's `infra.yml`.
- `--gh-token` (read access to the repo) is required for private repos and **recommended for public ones** — unauthenticated GitHub allows only 60 requests/hour and the watcher polls every 30 s.
- Environments are mapped from branches: `main` → prod, `staging` → staging, `develop` → develop, each open PR → `pr-<n>` preview (destroyed when the PR closes). Limit them with `--envs preview,develop`.

Now start the **GitOps watcher** (it polls GitHub for every registered project and deploys on each push — this is what replaces running anything by hand):

```bash
systemctl restart infra-gitops
journalctl -u infra-gitops -f          # watch it; Ctrl-C to stop watching
```

Then, in each repo: `git push origin develop` (and open PRs).

- [ ] the push shows up in the watcher log and the environment appears in the console within ~30 s
- [ ] **Access tab** → assign each registered project to its organization (step 6.2)

**Real GitHub Actions instead of the watcher** (a server GitHub can reach): each project also has a webhook secret (printed once by `project add`; issue a new one with `infra project rotate-secret <app>`); add `INFRA_WEBHOOK_URL` / `INFRA_WEBHOOK_SECRET` as repo Actions secrets and use `app-kit/.github/workflows/deploy.yml`.

### What happens on the first deploy

- Variables: if `infra.yml` lists `required_env` keys that aren't set, the deploy is **blocked** (nothing changes) and the console shows exactly which — set them in **Variables**, then *Retry deploy*.
- Databases: declared in `infra.yml`, **never created automatically**. Open the environment → **Databases → Create database**; the URL is injected on the redeploy that button triggers. Platform admins can **Reveal** the full URL there.
- `API_URL`-style links between services are plain variables you set per environment; nothing is auto-wired.

---

## 8. What is behind Keycloak (and what is deliberately not)

After step 4 there is **no shared basic-auth password anywhere**:

| Surface | Who gets in | Mechanism |
|---|---|---|
| `console.<domain>` | people with any access (platform admins see everything; others only their environments) | Keycloak, then the console's roles |
| Preview environments (`pr-<n>`) | platform admins, or anyone whose role covers *that* environment (project-wide, `env:`, `class:preview`, or a `branch:` grant) | Keycloak + console gate (`PREVIEW_AUTH_MODE=keycloak`) |
| `traefik.<domain>`, `logs.<domain>`, `status.<domain>` (and `grafana.` if enabled) | **platform admins only** | Keycloak + console gate (`OPS_AUTH_MODE=keycloak`) |
| `develop` / `staging` / `prod` apps | **public by default**; opt in per class or per service in `infra.yml` (below) | same gate as previews, same grants |
| `hooks.<domain>/webhook` | GitHub / the watcher | signed requests (HMAC) — a machine endpoint, intentionally not Keycloak |
| `auth.<domain>`, `sso.<domain>` | people on the VPN / allowed networks | Keycloak itself (`KEYCLOAK_VPN_CIDRS`) |

Previews are protected by default. To protect another class (or one service of it), in the repo's `.infradeploy/infra.yml`:

```yaml
environments:
  staging:
    auth: true            # whole staging; reachable only with a matching role (e.g. env:staging, class:staging)
  prod:
    web:
      auth: false         # per service overrides win (here: explicit, default is already public)
  preview:
    api:
      auth: false         # keep the API of previews public
```

`PREVIEW_AUTH_ENABLED=false` in the inventory switches every environment gate off. An environment's gate decides exactly like step 6: platform admin, or a role that covers it. People without one get a "no access" page showing the email they signed in with, and are registered so an admin can grant access straight away. Revoking takes effect in about 15 seconds.

- [ ] open a preview in a private window → Keycloak sign-in → (no role) "no access" → grant `class:preview` viewer in **Access** → reload → the app
- [ ] `traefik.<domain>/dashboard/` and `logs.<domain>` as a non-admin → "limited to platform administrators"

---

## 9. Verify the whole thing

```bash
sudo -u deploy bash /opt/infra/local/smoke-test.sh    # creates and removes its own smoke-* stacks
bash /opt/infra/local/verify-isolation.sh              # your containers/volumes/images/firewall unchanged
```

- [ ] smoke test: all PASS (it needs free preview slots: `MAX_PREVIEWS` minus the previews you already have must be ≥ 2)
- [ ] isolation: `failed: 0`

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Keycloak page says **403** | `auth.` and `sso.` only accept the networks in `KEYCLOAK_VPN_CIDRS`. After a Docker Desktop restart your address changed → keep the private ranges locally (step 1), then `sudo -u deploy infra platform up`. |
| Console login shows `invalid_scope` | A proxy requests a scope the realm doesn't define. Both proxies request only `openid email profile`; check `OAUTH2_PROXY_SCOPE` in `platform/docker-compose.yml` wasn't edited back to include `groups`. |
| `infra-console` / `infra-socket-proxy` exit 127 after Docker Desktop restarted | Bind mounts weren't ready: `sudo -u deploy infra platform up`, then `docker restart infra-traefik`. |
| Traefik unhealthy after the socket-proxy was recreated | `docker restart infra-traefik`. |
| `platform up` → `…require CONSOLE_AUTH_MODE=keycloak…` | The settings must agree: `PLATFORM_PROFILES` has `keycloak,keycloak-auth,keycloak-previews` ⇔ `CONSOLE_AUTH_MODE=keycloak` and at least one of `PREVIEW_AUTH_MODE` / `OPS_AUTH_MODE` is `keycloak`. |
| An invited person sees nothing | They must **accept** the invitation in the console (banner on the Environments tab) while signed in with the invited email; grants apply on acceptance. Check Access → Pending invitations (expires after 14 days). |
| Invite says the account could not be created | See the message; a platform admin can create it in Keycloak. The invitation stays pending. Check `KEYCLOAK_USER_ADMIN_SECRET` and that `bootstrap-realm.sh` created the `infra-user-admin` client. |
| A deploy says `preview limit reached` | `MAX_PREVIEWS` (inventory) counts every environment named `pr-*`; destroy old ones or raise it. |
| Deploy blocked: missing variables | Set them in **Variables** (scope matters: `pr-7` = one preview, `preview` = all previews, `common` = everything), then *Retry deploy*. |
| Forgot the Keycloak admin password | `grep KEYCLOAK_ADMIN_PASSWORD /etc/infra/platform.secrets.env` |
| Undo Keycloak login | `CONSOLE_AUTH_MODE=basic`, `PREVIEW_AUTH_MODE=basic`, `OPS_AUTH_MODE=basic`, drop `keycloak-auth,keycloak-previews` from `PLATFORM_PROFILES` in `/etc/infra/infra.env`, `sudo -u deploy infra platform up`, redeploy previews. |

## Production notes

- Use `inventory/prod.env.example`: `TLS_MODE=letsencrypt` (+ `/etc/infra/traefik.env` DNS token), real `DASHBOARD_AUTH_USERS`/`PREVIEW_AUTH_USERS` hashes, `KEYCLOAK_VPN_CIDRS=<VPN subnet>` (never the broad private ranges), `HOST_MODE=shared` on a server that hosts other things.
- Back up Postgres **and** `/etc/infra/platform.secrets.env` together — Keycloak's users and sessions live in that Postgres.
- `infra platform up` is idempotent: run it after any change to `/etc/infra/infra.env`.
