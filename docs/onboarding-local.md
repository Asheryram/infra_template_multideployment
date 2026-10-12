# Walkthrough: from a new project to production (local server)

This takes two demo projects — `shop-api` (backend + Postgres) and `shop-web` (frontend) from `Desktop\infra-demo-projects\` — from "the platform has never heard of them" to running in production, using every control a real team would: previews per PR, required secrets, databases on demand, rollback, a release, and giving a client scoped access.

> **Install first.** This assumes the platform is installed, Keycloak is set up and you can sign in to the console — [runbook-fresh-install.md](runbook-fresh-install.md), steps 0–5. Everything here happens in the **console**, a **PowerShell** window for the repos, and the **server shell** (`wsl -d Ubuntu -u root`).

Roles you play: 🛠 **DevOps** (the console), 👩‍💻 **Developer** (the repos), 🤖 **GitHub** (here: the `infra-gitops` watcher, which polls your real GitHub repos and deploys on every push — nothing to run by hand).

Tick the boxes as you go. If something doesn't match, see [Troubleshooting](runbook-fresh-install.md#troubleshooting).

---

## 1. Look at what the platform reads from a repo

Each repo carries **one config file** and optional static variables:

```
shop-api/.infradeploy/infra.yml        # services, ports, required secrets, databases, migrations
shop-api/.infradeploy/env/*.env        # non-secret variables per environment class
```

```yaml
name: shop-api
services:
  api:                                  # → api-shop-api.<domain>   (a service called web/app gets <app>.<domain>)
    image: local/shop-api               # locally the watcher builds it; on a real server: ghcr.io/<owner>/shop-api
    port: 8080
    health_path: /health
    required_env: []                    # a feature that needs a secret lists its key here, in the same PR
    databases:
      - inject_as: DATABASE_URL         # declared, NOT created automatically
migrate: { service: api, cmd: python migrate.py }
```

`shop-web` is the same with a `web` service. They are **independent services**: nothing is auto-linked between them.

- [ ] you can explain why `api` gets `api-shop-api.<domain>` and `web` gets `shop-web.<domain>`

## 2. Let the projects in (🛠 DevOps)

Register each repo (the name must equal `name:` in its `infra.yml`; a token is recommended even for public repos — unauthenticated GitHub allows 60 requests/hour):

```bash
# server shell
sudo -u deploy infra project add shop-api --repo <owner>/shop-api --gh-token <token>
sudo -u deploy infra project add shop-web --repo <owner>/shop-web --gh-token <token>
systemctl restart infra-gitops && journalctl -u infra-gitops -f      # Ctrl-C to stop watching
```

Then in the console → **Access**: create the client organization (e.g. `acme`) and **assign** both projects to it.

- [ ] **Projects** tab lists both; **Access** shows them under the organization

## 3. First pushes (👩‍💻 Developer)

In `Desktop\infra-demo-projects\shop-api` and `shop-web` (commit the `.infradeploy/` folder first), push `develop`:

```powershell
git push origin develop
```

Within ~30 s the watcher builds the image and deploys.

- [ ] **Environments** shows `shop-api / develop` and `shop-web / develop` with their own endpoint links
- [ ] open the api's endpoint: it answers, but reports **no database** — it was declared, not created

## 4. A database, on demand (🛠 DevOps)

Open `shop-api / develop` → **Databases → Create database**. The platform creates the role and database, redeploys, runs the migration, and injects `DATABASE_URL`.

- [ ] the card shows *created*, and the api now reports its database name
- [ ] (platform admins only) **Reveal** shows the full connection URL, with Copy/Hide

## 5. Connect the frontend explicitly (🛠 DevOps)

Nothing wires `shop-web` to the api. In **Variables → shop-web**, scope `develop`: `API_URL` = the api's endpoint, then *Redeploy affected*.

- [ ] the page shows the API URL and reaches the api

## 6. A preview per pull request (👩‍💻 Developer)

```powershell
git checkout -b feature/login ; # edit something ; git commit -am "login page" ; git push -u origin feature/login
# open a pull request on GitHub
```

The watcher deploys `pr-<n>`. **Previews are behind the access gate**: signed-out visitors are sent to Keycloak, and only people whose role covers that environment get in (step 9).

- [ ] opening the preview in a private window shows the Keycloak sign-in; a platform admin gets the page
- [ ] closing the PR removes the preview and its database

## 7. A feature that needs a new secret (👩‍💻 + 🛠)

Add the key to the service's `required_env` in the same PR, push. The deploy is **blocked** before anything changes; the console shows the missing key (and warns that `develop`/`prod` *will miss it* once this lands). Set it in **Variables** (scope `pr-<n>` for just this preview, `preview` for all previews, `common` for everything), then **Retry deploy**.

- [ ] the old version keeps serving while blocked; after setting the variable the new one deploys

## 8. A bad release → roll back (🛠 DevOps)

Push a broken commit to the PR. The preview now serves it. Open the environment → **Roll back to <previous tag>**.

- [ ] the previous version is live again within seconds

## 9. Give the client scoped access (🛠 DevOps)

Console → **Access** → *Organization membership* → **Invite**: the client's email, an optional name and the groups to put them in (create a group first — for example one whose policy is the Maintainer preset on `acme/shop-web/*` with condition branch `feature/login*`). The person gets a pending invitation, accepts it themselves after signing in, and — if they have no account — one is created for them (an email to set a password, or a one-time password shown to you once). Change access later by editing the group's policies or moving the person between groups (**Access → Groups / Policies**); the simulator shows the result.

- [ ] the invitee sees only the environments their groups' policies cover; everyone else sees nothing
- [ ] the permission matrix (who can do what, where) is in [access-control.md](access-control.md#permission-matrix)

## 10. Release (👩‍💻 Developer)

Merge the PR to `develop` (develop redeploys), then `develop → staging → main`. `main` deploys **prod**, which is public unless `infra.yml` opts in with `environments.prod.auth: true`.

- [ ] prod answers at `shop-web.<domain>` and `api-shop-api.<domain>`; each environment kept its own database

## 11. Tear the demo down

Remove the environments in the console (**Manage → Destroy**, platform admins only; it drops the databases the environment created), then:

```bash
sudo -u deploy infra project remove shop-api
sudo -u deploy infra project remove shop-web
```

Delete the demo organization and any invited test people from **Access** if you created them.

---

*Want it automated?* `local/e2e/run.sh` plays this whole story (plus the signed-webhook and access chapters) against your live platform and removes everything it created — see the header of that script.
