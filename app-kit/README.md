# App kit: get preview environments for your repo

Copy the app-kit files into your repo and fill in the manifest to get per-environment URLs. Environments get an isolated platform database only when `NEEDS_DB=true`; preview databases can optionally be cloned from a sanitised seed template.

## 1. Copy

```
your-repo/
├── .deploy/
│   ├── manifest.env          ← the only file you must edit
│   ├── env/                  ← non-secret config per environment (optional)
│   └── compose.extra.yml     ← extra containers like redis/workers (optional, rename from .example)
├── .github/workflows/deploy.yml
└── Dockerfile                ← see dockerfiles/ for Node, Python and SPA starters
```

In `.github/workflows/deploy.yml`, replace `YOUR_ORG/infra` with the infra repo (DevOps will tell you).

## 2. Fill in `.deploy/manifest.env`

Start from the example matching your project in [examples/](examples/):

| Your repo | Example | You get |
|---|---|---|
| Single app (Next.js full-stack, Django, Rails, Laravel, Spring…) | `monolith.manifest.env` | `myapp-pr-12.<domain>` |
| Frontend and backend folders in one repo | `split.manifest.env` | `myapp-pr-12.<domain>` + `api-myapp-pr-12.<domain>` |
| Backend-only repo | `backend.manifest.env` | `myapp-api-pr-3.<domain>` |
| Frontend-only repo | `frontend.manifest.env` | `myapp-web-pr-8.<domain>`, wired to the backend repo |

## 3. Requirements for your container

1. **Listen on `$PORT`**, set in the manifest as `APP_PORT`/`WEB_PORT`/`API_PORT`.
2. **Expose a health endpoint** (`GET /health` returning 200) and a Docker `HEALTHCHECK`. The deploy only succeeds once it passes.
3. **Read config from env vars at runtime.** These are injected for you:

   | Variable | Example |
   |---|---|
   | `APP_ENV` | `pr-42`, `develop`, `staging`, `prod` |
   | `ENV_CLASS` / `IS_PREVIEW` | `preview` / `true` |
   | `PUBLIC_URL` | `https://myapp-pr-42.apps.example.com` |
   | `DATABASE_URL`, `PGHOST`, `PGUSER`… | when `NEEDS_DB=true` (app/api only) |
   | `API_URL` | frontends: which backend to call |
   | `FRONTEND_URL` | split APIs: for CORS |
   | `INFRA_DOMAIN` | for CORS: allow `https://*.${INFRA_DOMAIN}` outside prod |
   | `GIT_COMMIT`, `GIT_BRANCH`, `IMAGE_TAG` | for logs and Sentry releases |

4. **Frontends: don't bake `API_URL` in at build time.** One image runs in every environment. For static SPAs, use `dockerfiles/spa-nginx.Dockerfile`, which writes `window.__ENV__` at container start. For Next.js, read `process.env.API_URL` on the server side (or expose it through a small `/api/config` route) rather than `NEXT_PUBLIC_*`.
5. **Migrations must be idempotent.** They run before every deploy via `MIGRATE_CMD`.
6. **Log to stdout/stderr**, not files. The platform rotates and collects them (`https://logs.<domain>`).

## Frontend and backend in different repos

Use the **same branch name** in both repos (e.g. `feature/checkout`). The frontend preview then automatically talks to the backend preview from that branch. If there's no backend PR, it talks to `develop`. You don't need to coordinate merge order.

## Secrets and new variables

Never commit secrets. DevOps sets them in the infra console, per environment, and they're merged in at deploy time. Non-secret config goes in `.deploy/env/<env>.env`.

**When your feature needs a new variable**, do this in the same PR:
1. Non-secret value: add it to `.deploy/env/common.env`, or the per-env files.
2. Secret: declare it as required in `.deploy/manifest.env`, e.g. `API_REQUIRED_ENV="STRIPE_SECRET_KEY NEW_FEATURE_KEY"`, and tell DevOps the key name.
3. Until DevOps adds it, your preview deploy **stops with a clear message** ("missing required variables: api:NEW_FEATURE_KEY") instead of booting a broken app. Once it's added, DevOps hits *Retry deploy*.
4. Before merging, DevOps also adds it for develop, staging and prod. The console flags any environment that's still missing it.

## Branch → environment

| Event | Environment |
|---|---|
| PR opened / pushed | `pr-<number>` (password-protected, deleted when the PR closes) |
| push to `develop` | `develop` |
| push to `staging` | `staging` |
| push to `main` | `prod` (may require approval) |
