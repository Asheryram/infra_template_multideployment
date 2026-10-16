# App kit — deploy any repo in 3 steps

Everything the platform needs lives in one file: `.infradeploy/infra.yml`. It lists **services**; each service is
deployed independently, exactly as if it lived in its own repo. A monolith is one service, a split app is two, a repo
with a worker and a cache is three. There are no project "types".

```
your-repo/
├── .infradeploy/
│   ├── infra.yml            ← the one config file
│   └── env/                 ← optional static, non-secret variables
│       ├── common.env       ← every environment
│       ├── <class>.env      ← prod | staging | develop | preview
│       └── <class>.<service>.env   ← one service only
├── .github/workflows/deploy.yml   ← copy from app-kit/.github/workflows/
└── Dockerfile(s)            ← stay wherever they are; infra.yml points at them
```

## 1. Fill in `.infradeploy/infra.yml`

Start from the annotated [.infradeploy/infra.yml](.infradeploy/infra.yml) or an example in [examples/](examples/):

| Repo shape | Example |
|---|---|
| One app (Next.js, Django, Rails, Laravel, Spring…) | `monolith.infra.yml` |
| Frontend + backend folders in one repo | `split.infra.yml` |
| Backend only | `backend.infra.yml` |
| Frontend only | `frontend.infra.yml` |

```yaml
name: myapp
services:
  api:
    image: ghcr.io/your-org/myapp-api   # no tag — CI pushes <image>:<tag>
    build_context: ./backend
    dockerfile: backend/Dockerfile
    port: 8080
    health_path: /api/health
    required_env: [JWT_SECRET]          # deploy is blocked until set
    databases:
      - inject_as: DATABASE_URL         # created + injected automatically
  web:
    image: ghcr.io/your-org/myapp-web
    port: 80
    required_env: [API_URL]             # an ordinary variable you set in the console
```

Service fields: `image`, `port`, `health_path`, `build_context`, `dockerfile`, `required_env`, `databases`,
`host.<class>`, `extra_middlewares`. Top level: `name`, `services`, `migrate`, `max_previews_per_app`, `environments`.
Anything else is rejected.

### URLs

| Service name | Production | Other environments |
|---|---|---|
| `web` or `app` | `myapp.<domain>` | `myapp-staging.<domain>`, `myapp-pr-12.<domain>` |
| anything else (e.g. `api`) | `api-myapp.<domain>` | `api-myapp-staging.<domain>`, `api-myapp-pr-12.<domain>` |

### A frontend that calls its API

Nothing to put in `infra.yml`. A browser cannot call a second host that sits behind the access gate (the call carries no sign-in cookie and the gate's answer has no CORS headers), and people would otherwise need access to both projects. An administrator links the two projects **in the console** (**Access → Project links**): `/api` on the frontend's address is served from the API project's service, over the platform's private network, behind the frontend's gate. Whoever may open the frontend can use its API through it, the API can drop its own public address, and `API_URL` can be set to the frontend's own address. The link applies to every environment of the same class (previews to previews, develop to develop, prod to prod). It is **not** configurable from the repository, on purpose: `infra.yml` comes from the repository, so otherwise anyone who can open a pull request could route into another project. See [access-control.md](../docs/access-control.md#project-links-frontend--api).

## 2. Databases and variables

* **Databases** — `databases:` only *declares* what a service needs. Nothing is created on deploy. In the console
  (environment → Database) each declared database has a **Create database** button; it provisions the database in the
  shared Postgres with its own role and a generated password (`password:` pins a fixed one), then redeploys so the
  URL is injected as `inject_as`. Until then the service runs without that variable. Wiping drops the data and stops
  injecting; destroying an environment drops every database it created. CLI: `infra db create <app> <env> [--db svc:KEY]`.
* **Static config** — `environments:` in `infra.yml`, or `.infradeploy/env/*.env`. Never commit secrets.
* **Secrets** — DevOps sets them in the console (Variables tab). Declare the key in `required_env` so a missing secret
  blocks the deploy instead of shipping a broken release.
* **Linking services** — nothing is auto-derived. If `web` needs the API address, give it `API_URL` like any other
  variable. It may point at a sibling service, another app, or an external API.
* Previews are behind a login by default (Keycloak when the platform uses it: only people whose role covers that environment get in). Turn it off per service with `environments.preview.<service>.auth: false`, or turn it **on** for another class with `environments.<class>.auth: true` (e.g. `staging`); `develop`/`staging`/`prod` are public by default.

## 3. CI

1. DevOps registers the project (`infra project add <name from infra.yml> --repo <owner/repo>`) and gives you
   `INFRA_WEBHOOK_URL` + `INFRA_WEBHOOK_SECRET` → add both as repo Actions secrets.
2. Copy [.github/workflows/deploy.yml](.github/workflows/deploy.yml), replace `YOUR_ORG/infra`.
3. Open a PR → preview `pr-<n>`; push to `develop` / `staging` / `main` → that environment. Closing the PR destroys
   the preview and its databases.

CI builds one image per service that declares `image:` and pushes `<image>:sha-<12 chars>`.

## Adding a feature that needs a new secret

Add the key to the service's `required_env` in the same PR, and tell DevOps the key name. The PR's preview shows as
*blocked* in the console until it is set.
