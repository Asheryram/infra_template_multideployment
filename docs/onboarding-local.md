# Onboarding walkthrough: from new project to production (local server)

This walkthrough takes two new projects, `shop-api` (backend) and `shop-web` (frontend), from "never heard of the platform" to running in production. Along the way you'll use every DevOps control: previews, wiring, variables, rollback and merging.

You'll play **three roles**:

| Role | Where | Does |
|---|---|---|
| 🛠 **DevOps (you)** | the console in your browser | lets projects in, sets secrets, rewires, watches |
| 👩‍💻 **Developer** | the repos in `Desktop\infra-demo-projects\` | writes code, makes branches, merges |
| 🤖 **GitHub** | `ci-local.sh` in the server shell | builds the image and sends the signed webhook (locally, nobody else can) |

Tick the boxes as you go. Each step says what you should see. If you don't see it, check [Troubleshooting](#troubleshooting) at the end.

---

## Part 0: Get ready (5 min, once)

**0.1** Make sure **Docker Desktop is running** (whale icon in the Windows tray).
- [ ] done

**0.2** Open the **server shell** in PowerShell, and keep this window open the whole time:
```powershell
wsl -d Ubuntu -u root
```
- [ ] prompt shows `root@…`

**0.3** Paste this once per shell session. It sets shortcuts used in every step below:
```bash
P="/mnt/c/Users/YramAsherTetteh-Abot/OneDrive - AmaliTech gGmbH/Desktop/infra-demo-projects"
CI="bash /opt/infra/local/ci-local.sh"
cd /tmp
git config --global user.name  >/dev/null || git config --global user.name  "Asher (local)"
git config --global user.email >/dev/null || git config --global user.email "asher@local"
git config --global --add safe.directory "$P/shop-api"
git config --global --add safe.directory "$P/shop-web"
```
- [ ] no errors

**0.4** Check the platform:
```bash
sudo -u deploy infra platform up | tail -7
```
You should see links ending in `console…`, `hooks…/webhook`, `traefik…`, `logs…` and `status…`.
- [ ] done

If Docker Desktop was restarted since last time, run `docker restart infra-traefik infra-console` first.

**0.5** Open the **console** in your browser: <https://console.127-0-0-1.sslip.io:8443>. Accept the certificate warning (Advanced → Proceed) and log in as `admin` / `admin`.
- [ ] you see the console with tabs *Environments · Projects · Variables · Activity*

---

## Part 1: 🛠 Let the projects in (once per project)

**1.1** Console → **Projects** → *Add a project*:

| Field | Value |
|---|---|
| App name | `shop-api` |
| Repo | `local/shop-api` |
| Allowed environments | leave all 4 ticked · prod from `main` |

Click **Add project**.
- [ ] a box shows the webhook secret, with copy buttons

**1.2** With real GitHub, you'd now give the team the two values shown as repo secrets. **Locally there's nothing to copy**: the local "GitHub" (`ci-local.sh`) runs on the server and reads the secret from the registry itself.
- [ ] click **I've saved it**

**1.3** Repeat 1.1–1.2 for `shop-web` with repo `local/shop-web`.
- [ ] both projects listed under *Registered projects*, with "none yet" running

> The app name must match `APP_NAME` in each repo's `.deploy/manifest.env`. Look in `Desktop\infra-demo-projects\shop-api\.deploy\manifest.env` to see what the team ships.

---

## Part 2: 🤖 First deploy: the `develop` branch

Both repos are already on `develop`.

**2.1** Deploy the backend:
```bash
$CI "$P/shop-api" push
```
You should see `▶ build …`, `▶ signed webhook → deploy shop-api/develop`, then `✔ succeeded: https://shop-api-develop…`.
- [ ] succeeded

**2.2** Deploy the frontend. The platform does not select or inject its API URL:
```bash
$CI "$P/shop-web" push
```
- [ ] frontend deploy succeeded

Set the frontend's API URL variable (the exact key is whatever the app reads) for `develop` to `https://shop-api-develop.127-0-0-1.sslip.io:8443`, then redeploy the frontend. If the backend needs a platform database, create and wire it explicitly with `infra db create shop-api develop` and `infra db use shop-api develop --key DATABASE_URL`.

**2.3** Check in the browser:
1. Open <https://shop-api-develop.127-0-0-1.sslip.io:8443/api/products> and **accept the certificate**. You should see 3 products as JSON.
2. Open <https://shop-web-develop.127-0-0-1.sslip.io:8443>. You should see the product list after its API URL has been configured.
- [ ] both work

**2.4** In the console:
- **Environments** shows both apps on `develop`, green, with links and any detected database connection.
- **Activity** shows `webhook:deploy …` and `deploy:ok …` lines.
- [ ] seen

---

## Part 3: 🤖 First release to production

Releasing means merging `develop` into `main` and pushing `main`.

**3.1**
```bash
for r in shop-api shop-web; do
  git -C "$P/$r" checkout -q main && git -C "$P/$r" merge -q develop
  $CI "$P/$r" push
  git -C "$P/$r" checkout -q develop
done
```
- [ ] two `✔ succeeded` lines (prod URLs have no `-develop`)

**3.2** Before testing the frontend, configure the API URL variable that `shop-web` reads for its `prod` environment to `https://shop-api.127-0-0-1.sslip.io:8443`, then redeploy it. The platform does not infer the frontend's backend from repo names or branch names. Provision a database separately if the API requires one.
- [ ] frontend uses the explicitly configured prod API URL

---

## Part 4: 👩‍💻 A feature: PRs on both repos

The repos may use matching branch names for team coordination, but the platform does not match branches or automatically connect their previews. Configure the frontend preview's API URL explicitly.

**4.1** Backend change on branch `feature/sale`:
```bash
cd "$P/shop-api"
git checkout -q -b feature/sale
sed -i 's/VERSION = "1.0.0"/VERSION = "1.1.0"/' app.py
git commit -qam "Sale: bump API to 1.1.0"
cd /tmp
$CI "$P/shop-api" pr 1
```
- [ ] `✔ succeeded: https://shop-api-pr-1…`

**4.2** Frontend change on the **same branch name**:
```bash
cd "$P/shop-web"
git checkout -q -b feature/sale
sed -i 's|<h1>Shop</h1>|<h1>Shop — SALE</h1>|' site/index.html
git commit -qam "Sale banner"
cd /tmp
$CI "$P/shop-web" pr 2
```
- [ ] frontend preview deploy succeeded

**4.3** In Variables or Environments → Manage, set the frontend's API URL variable for `pr-2` to `https://shop-api-pr-1.127-0-0-1.sslip.io:8443`, then redeploy. If the API uses a database, provision and wire it separately with `infra db create` and `infra db use`.

Check the browser. Previews are password-protected with `preview` / `preview`.
1. Accept the cert for <https://shop-api-pr-1.127-0-0-1.sslip.io:8443>.
2. Open <https://shop-web-pr-2.127-0-0-1.sslip.io:8443>. It should show **"Shop — SALE"** and call the explicitly configured API preview.
3. <https://shop-web-develop.127-0-0-1.sslip.io:8443> remains configured independently.
- [ ] both preview URLs behave as configured

**4.4** A developer pushes again to the PR (GitHub calls this "synchronize"):
```bash
cd "$P/shop-web"; sed -i 's|Shop — SALE|Shop — BIG SALE|' site/index.html; git commit -qam "Bigger banner"; cd /tmp
$CI "$P/shop-web" pr 2
```
- [ ] reload pr-2: it says "BIG SALE"

---

## Part 5: 🛠 DevOps controls in the console

**5.0 Environment variables: add or edit app overrides.** Go to Environments → `shop-web` / `pr-2` → **Manage** → *Environment variables*.

This shows every variable the container has, and where it came from:
- *set by the platform*
- *from the repo* (`.deploy/env/…`)
- *set in the console*, with its scope

To change one:
1. Click **Add override** next to `API_URL`.
2. Type `https://shop-api.127-0-0-1.sslip.io:8443` (prod's API).
3. Keep "only pr-2" and click **Save & redeploy**.
4. Reload pr-2: the backend is now `prod`.
5. Click **Remove** on your override, then **Redeploy now**. The value falls back to the repo configuration, if one is defined.

To add or change an app variable, use **Add an app override** (or **Add override** beside a repository value), enter the key and value, and choose the scope: *only this env*, *all previews*, or *all environments*. Platform-managed metadata such as `APP_ENV`, `PUBLIC_URL`, `IMAGE_TAG`, and `GIT_COMMIT` is read-only. Sensitive keys (`…KEY`, `…SECRET`, `…TOKEN`, `…PASSWORD`) are masked. Use **Show** to reveal one; reveals are logged. Use **Save & redeploy** when the change should apply immediately.
- [ ] done

The platform does not auto-fill `API_URL` or select a backend. Set the variable name your frontend actually reads (for example, `API_URL` or `VITE_API_URL`) in the repo environment files or as a server-side variable. To change a database connection, explicitly create/use a platform database or configure the app's expected external DB variable; take care not to point previews at production data.

**5.3 Logs.** In Manage, click **Last 200 lines** for live container logs. You can also use <https://logs.127-0-0-1.sslip.io:8443>, which shows only platform containers.
- [ ] seen

---

## Part 6: 👩‍💻 + 🛠 A feature that needs a new secret

**6.1** The developer declares the new required variable in the same PR:
```bash
cd "$P/shop-api"
sed -i 's|^# API_REQUIRED_ENV="PAYMENT_API_KEY"|API_REQUIRED_ENV="PAYMENT_API_KEY"|' .deploy/manifest.env
git commit -qam "Payments need PAYMENT_API_KEY"
cd /tmp
$CI "$P/shop-api" pr 1
```
- [ ] it FAILS with `missing required variables: api:PAYMENT_API_KEY`. That's expected: nothing changed, and the old pr-1 keeps running.

**6.2** In the console:
- **Environments:** `shop-api / pr-1` shows **blocked**.
- `develop` and `prod` show **"will miss 1"**. The console warns you *before* the merge.
- [ ] seen

**6.3** Fix it as DevOps: **Variables** → app `shop-api` → scope **pr-1** → key `PAYMENT_API_KEY` → value `test_key_123` → **Save**. Then Environments → `shop-api / pr-1` → **Manage** → **Retry deploy**.
- [ ] pr-1 is green again

**6.4** Before merging, give develop and prod their value too. In **Variables**, set scope **all environments** (`common`) with key `PAYMENT_API_KEY` and value `live_key_456`. The "will miss" warnings disappear.
- [ ] no more "will miss"

---

## Part 7: 🤖 Merge and close the PRs

**7.1** Merge the backend PR into develop. Closing PR #1 deletes its preview, its database and its PR-only variables.
```bash
git -C "$P/shop-api" checkout -q develop && git -C "$P/shop-api" merge -q --no-ff feature/sale -m "Merge PR #1"
$CI "$P/shop-api" close 1
$CI "$P/shop-api" push
```
- [ ] `destroy … succeeded`, then develop deploys **1.1.0** (no block, thanks to 6.4)
- [ ] console: `shop-web / pr-2` now talks to `shop-api-develop`. It fell back automatically when pr-1 went away.

**7.2** Merge the frontend PR:
```bash
git -C "$P/shop-web" checkout -q develop && git -C "$P/shop-web" merge -q --no-ff feature/sale -m "Merge PR #2"
$CI "$P/shop-web" close 2
$CI "$P/shop-web" push
```
- [ ] <https://shop-web-develop.127-0-0-1.sslip.io:8443> shows "BIG SALE" with backend 1.1.0

---

## Part 8: 🤖 Release to production, and roll back if needed

**8.1**
```bash
for r in shop-api shop-web; do
  git -C "$P/$r" checkout -q main && git -C "$P/$r" merge -q develop
  $CI "$P/$r" push
  git -C "$P/$r" checkout -q develop
done
```
- [ ] <https://shop-web.127-0-0-1.sslip.io:8443> shows BIG SALE with backend 1.1.0 on `prod`, with prod's own data

**8.2** Something's wrong in prod? Console → Environments → `shop-api / prod` → Manage → **Roll back to sha-…**.
- [ ] backend shows 1.0.0 again. Use **Redeploy**, or push again, to go forward.

**8.3** Look at **Activity**: every webhook, deploy, variable change and click, with who did it.
- [ ] 🎉 done: a project from zero to production

---

## Part 9: Clean up (optional)

**9.1 In the console:** destroy each environment with Manage → **Destroy…**. Then go to **Projects** and remove `shop-api` and `shop-web`.

**9.2 Or in the shell:**
```bash
for a in shop-web shop-api; do
  for e in $(ls /srv/deployments/$a 2>/dev/null); do sudo -u deploy infra destroy --app $a --env $e --i-really-mean-prod; done
  sudo -u deploy infra project remove $a; rm -f /root/.infra-secrets/$a
done
```

**9.3 To run the whole walkthrough again**, reset the demo repos:
```bash
for r in shop-api shop-web; do git -C "$P/$r" checkout -q develop; git -C "$P/$r" reset -q --hard "$(git -C "$P/$r" rev-list --max-parents=0 HEAD)"; git -C "$P/$r" branch -D feature/sale 2>/dev/null; git -C "$P/$r" branch -f main develop; done
```

---

## Troubleshooting

| You see | Do |
|---|---|
| Browser can't open any `…sslip.io:8443` page | Start Docker Desktop. Then run `docker restart infra-traefik infra-console` in the server shell |
| Frontend says "Network error" / "unreachable" | Open that environment's **API URL** once in the browser and accept its certificate (local self-signed only) |
| `project shop-api is not registered` | Add it in the console → **Projects** (step 1.1) |
| `rejected: HTTP 401` | A stale `/root/.infra-secrets/<app>` file overrides the registry: delete it |
| `rejected: HTTP 403 … not registered` / `not allowed` | The repo or environment isn't allowed for that project. Projects → **Environments…** |
| `missing required variables: …` | Expected when the manifest requires a key: add it in **Variables**, then **Retry deploy** |
| `the stack violates the platform policy` | The repo's `compose.extra.yml` asked for something dangerous (ports, host mounts, privileges…), and the message lists what |
| `fatal: detected dubious ownership` | Re-run the `safe.directory` lines from step 0.3 |
| `Please tell me who you are` (git) | Re-run the `git config user.name/email` lines from step 0.3 |

## What's different on a real server with real GitHub

| Local | Real |
|---|---|
| 🤖 `ci-local.sh` builds on the server and sends the webhook | The app-kit workflow builds on GitHub, pushes to GHCR, and sends the same webhook |
| Repo `local/shop-api` | `your-org/shop-api` (the platform checks it matches) |
| Secret saved in `/root/.infra-secrets` | Two repo secrets: `INFRA_WEBHOOK_URL`, `INFRA_WEBHOOK_SECRET` |
| `IMAGE_REPO=local/shop-api` | `ghcr.io/your-org/shop-api`, plus a registry token on the project if the images are private |
| `127-0-0-1.sslip.io:8443`, self-signed | your wildcard domain on 443 with Let's Encrypt |
