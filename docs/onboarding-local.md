# Try it: onboard a new project onto the local server

Two small example repos live next to this one in `Desktop\infra-demo-projects\`:

| Repo | What it is | Platform type |
|---|---|---|
| `shop-api` | Python API + Postgres (`/api/products`) | `backend` |
| `shop-web` | Static page that lists the products via the API | `frontend` (finds the API by branch name) |

Both are already "drag-and-dropped": each has `.deploy/manifest.env`, a `Dockerfile`, and the app-kit workflow (that last one is for real GitHub later).

**Locally, you play GitHub.** Your laptop server can't receive webhooks from github.com, so `local/ci-local.sh` does what the workflow does: it builds the image from the repo's current commit, then sends the **same signed webhook**. Everything server-side is exactly what production will run.

---

## 0. Open the server shell

Docker Desktop must be running. In PowerShell:
```powershell
wsl -d Ubuntu -u root
```
Keep this window open. Every command below runs in it.
```bash
P="/mnt/c/Users/YramAsherTetteh-Abot/OneDrive - AmaliTech gGmbH/Desktop/infra-demo-projects"
cd /tmp
```
Then check the platform is up. You should see `console.…` and `hooks.…` in the output:
```bash
sudo -u deploy infra platform up | tail -6
```
If Docker Desktop was restarted, run `docker restart infra-traefik infra-console` first.

## 1. DevOps: register the projects (once per project)

```bash
sudo -u deploy infra project add shop-api --repo local/shop-api --envs preview,develop,staging,prod
sudo -u deploy infra project add shop-web --repo local/shop-web --envs preview,develop,staging,prod
```
Each command prints an `INFRA_WEBHOOK_SECRET`. On real GitHub you'd hand it to the team as a repo secret. Locally, save it where `ci-local.sh` looks for it:
```bash
mkdir -p /root/.infra-secrets && chmod 700 /root/.infra-secrets
echo '<secret printed for shop-api>' > /root/.infra-secrets/shop-api
echo '<secret printed for shop-web>' > /root/.infra-secrets/shop-web
sudo -u deploy infra project list
```

## 2. First deploy: push to `develop`

Both repos are on their `develop` branch.
```bash
bash /opt/infra/local/ci-local.sh "$P/shop-api" push
bash /opt/infra/local/ci-local.sh "$P/shop-web" push
```
Open in the Windows browser:
- `https://shop-api-develop.127-0-0-1.sslip.io:8443/api/products`. Accept the certificate warning **once for this API host**.
- `https://shop-web-develop.127-0-0-1.sslip.io:8443`. You should see the 3 products, and that it's talking to `shop-api` on `develop`.

## 3. A feature branch with PRs on both repos

Edit on Windows (VS Code), or in the shell. Backend first:
```bash
cd "$P/shop-api"
git checkout -b feature/sale
sed -i 's/VERSION = "1.0.0"/VERSION = "1.1.0"/' app.py
git commit -qam "Sale prices" && cd /tmp
bash /opt/infra/local/ci-local.sh "$P/shop-api" pr 1          # → shop-api preview pr-1, own empty DB + migrations
```
Frontend, using the **same branch name**:
```bash
cd "$P/shop-web"
git checkout -b feature/sale
sed -i 's/<h1>Shop<\/h1>/<h1>Shop — SALE<\/h1>/' site/index.html
git commit -qam "Sale banner" && cd /tmp
bash /opt/infra/local/ci-local.sh "$P/shop-web" pr 2          # → uses API pr-1 automatically (same branch)
```
Previews are password-protected (`preview` / `preview`):
- `https://shop-web-pr-2.127-0-0-1.sslip.io:8443` shows "SALE" and backend `1.1.0` from `pr-1`, with its own database.
- `https://shop-web-develop.127-0-0-1.sslip.io:8443` is unchanged.

Push another commit to a PR, then re-run the same `ci-local.sh … pr <n>` (that's GitHub's "synchronize").

## 4. You, as DevOps, in the console

Open `https://console.127-0-0-1.sslip.io:8443` (`admin` / `admin`):

- **Environments:** all four environments with links, status, branch, which API each frontend calls, and which DB each API uses.
- **Manage → Frontend → API:** point `shop-web/pr-2` at `shop-api/develop`, then back to *Automatic*. Reload the page in between to see it change.
- **Manage → API → database:** let `shop-api/pr-1` *share* `shop-api/develop`'s database, then back to *its own*.
- **Variables:** try a feature that needs a secret.
  1. In `$P/shop-api/.deploy/manifest.env`, uncomment `API_REQUIRED_ENV="PAYMENT_API_KEY"`, commit, and run `ci-local.sh "$P/shop-api" pr 1` again. The deploy is **blocked**, and the old version keeps running.
  2. In the console, go to Variables → `shop-api` → scope `pr-1` → `PAYMENT_API_KEY` → Save, then Environments → Manage → **Retry deploy**.
  3. The console now warns that develop/staging/prod **will miss** that key.
- **Activity:** every webhook and every click, recorded with who did it.

## 5. Merge, close, release

```bash
cd "$P/shop-api"; git checkout -q develop; git merge -q --no-ff feature/sale -m "Merge PR #1"; cd /tmp
bash /opt/infra/local/ci-local.sh "$P/shop-api" close 1      # PR closed → preview + its DB + PR-only vars deleted
bash /opt/infra/local/ci-local.sh "$P/shop-api" push         # develop gets the feature
```
If you added the required key in step 4, this deploy is blocked until you set `PAYMENT_API_KEY` for `develop`, or for `common` (all environments). That's exactly the safety net.

Also close the frontend PR, then release to prod:
```bash
bash /opt/infra/local/ci-local.sh "$P/shop-web" close 2
cd "$P/shop-api"; git checkout -q main; git merge -q develop; cd /tmp
bash /opt/infra/local/ci-local.sh "$P/shop-api" push         # → https://shop-api.127-0-0-1.sslip.io:8443 (prod)
```

## 6. Clean up when done

```bash
for a in shop-web shop-api; do
  for e in $(ls /srv/deployments/$a 2>/dev/null); do sudo -u deploy infra destroy --app $a --env $e --i-really-mean-prod; done
  sudo -u deploy infra project remove $a; rm -f /root/.infra-secrets/$a
done
```

---

## What changes on a real server with real GitHub

| Local | Real |
|---|---|
| `ci-local.sh` builds on the server and sends the webhook | The app-kit workflow builds on GitHub, pushes to GHCR, and sends the webhook |
| `--repo local/shop-api` | `--repo your-org/shop-api` (the platform checks it matches) |
| Secret saved in `/root/.infra-secrets` | Secret stored as repo secrets `INFRA_WEBHOOK_URL` + `INFRA_WEBHOOK_SECRET` |
| `IMAGE_REPO=local/shop-api` | `IMAGE_REPO=ghcr.io/your-org/shop-api`, plus `infra project add … --registry-token` if the images are private |
| `127-0-0-1.sslip.io:8443`, self-signed | your wildcard domain on 443 with Let's Encrypt |
