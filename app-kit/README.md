# App kit: get preview environments for your repo

Copy the app-kit files into your repo and fill in the manifest to get per-environment URLs. Database provisioning and app-specific connection variables are explicit operations; the platform does not provision or wire a database from a manifest flag.

## 1. Copy

```
your-repo/
├── .deploy/
│   ├── manifest.env          ← required deployment settings
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
| Frontend-only repo | `frontend.manifest.env` | `myapp-web-pr-8.<domain>` |

The starter at [.deploy/manifest.env](.deploy/manifest.env) documents every accepted manifest setting. The supported settings are:

| Setting | Meaning |
|---|---|
| `APP_NAME`, `TYPE`, `IMAGE_REPO` | App identity, one of `monolith`, `frontend`, `backend`, `split`, and image name/prefix |
| `<APP\|WEB\|API>_CONTEXT`, `<APP\|WEB\|API>_DOCKERFILE` | CI build context and optional Dockerfile path, relative to the repository |
| `<APP\|WEB\|API>_IMAGE` | Optional fixed image override; `{tag}` is replaced by the deployment tag |
| `<APP\|WEB\|API>_PORT` | Container listen port |
| `<APP\|WEB\|API>_HOST_<CLASS>` | Optional host override for a component and environment class, such as `WEB_HOST_PROD` |
| `<APP\|WEB\|API>_REQUIRED_ENV` | Space-separated required runtime variable names; deploy blocks if any are missing |
| `MIGRATE_CMD`, `MIGRATE_SERVICE` | Optional migration command and service for the one-off migration container |
| `MAX_PREVIEWS_PER_APP` | Optional per-app preview cap |
| `PREVIEW_AUTH`, `API_PREVIEW_AUTH` | Optional preview authentication switches (`true`/`false`) |
| `EXTRA_MIDDLEWARES` | Comma-separated names of platform-configured Traefik middlewares |

Unknown manifest keys are errors, not ignored warnings. Put application settings such as `DATABASE_URL`, `API_URL`, or `FRONTEND_URL` in `.deploy/env/` or server-side variables, not in `manifest.env`.

CPU and memory limits are infra-owned and are deliberately not accepted in app manifests. The server operator sets inventory defaults and hard per-container/per-stack ceilings; per-app, environment, or preview overrides are managed in the Infra Console under **Manage → Container Resources**. Changes apply on redeploy.

## 3. Requirements for your container

1. **Listen on `$PORT`**, set in the manifest as `APP_PORT`/`WEB_PORT`/`API_PORT`.
2. **Expose a health endpoint** (`GET /health` returning 200) and a Docker `HEALTHCHECK`. The deploy only succeeds once it passes.
3. **Read config from env vars at runtime.** These are injected for you:

   | Variable | Example |
   |---|---|
   | `APP_ENV` | `pr-42`, `develop`, `staging`, `prod` |
   | `ENV_CLASS` / `IS_PREVIEW` | `preview` / `true` |
   | `PUBLIC_URL` | `https://myapp-pr-42.apps.example.com` |
   | `INFRA_DOMAIN` | platform domain; app may use it for environment-specific CORS policy |
   | `GIT_COMMIT`, `GIT_BRANCH`, `IMAGE_TAG` | for logs and Sentry releases |

   `DATABASE_URL`, `API_URL`, `FRONTEND_URL`, and other app-specific variables are **not** injected. Configure them in `.deploy/env/common.env`, `.deploy/env/<class>.env`, `.deploy/env/<class>.<component>.env`, or in server-side variables. Environment-specific server values can use `<env>.env` / `<env>.<component>.env` scopes.

   For the platform Postgres, deploy the app first, then create and wire a database explicitly:
   ```bash
   infra db create myapp pr-42
   infra db use myapp pr-42 --key DATABASE_URL
   infra redeploy myapp pr-42
   ```
   Preview databases can be seeded from a sanitised template created with `infra db template`. No `NEEDS_DB` or `DB_PREVIEW_SOURCE` manifest option exists.

4. **Frontends: don't bake `API_URL` in at build time.** One image runs in every environment. For static SPAs, use `dockerfiles/spa-nginx.Dockerfile`, which writes `window.__ENV__` at container start. For Next.js, read `process.env.API_URL` on the server side (or expose it through a small `/api/config` route) rather than `NEXT_PUBLIC_*`.
5. **Migrations must be idempotent.** `MIGRATE_CMD` runs before rollout only when its service has a connection URL to that environment's own platform database. Otherwise migrations are skipped; the deploy log says why.
6. **Log to stdout/stderr**, not files. The platform rotates and collects them (`https://logs.<domain>`).

## Frontend and backend in different repos

The platform does not discover or automatically link a frontend to a backend by repository or branch. Set the frontend's API variable (for example `API_URL` or `VITE_API_URL`) explicitly in the appropriate `.deploy/env/` file or server-side environment scope. Configure different values for `develop`, `staging`, `prod`, and previews as your workflow requires. The frontend must read that setting at runtime.

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
