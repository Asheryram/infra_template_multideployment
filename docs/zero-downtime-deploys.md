# Zero-downtime deploys, automatic rollback and high availability

Written for: developers who ship an app on this platform.

## What happens when you deploy to `prod` or `staging`

1. The new version starts **next to** the running one (same host name, same Traefik router). Traefik only sends traffic to a
   container once its Docker healthcheck says healthy, so nobody reaches a half-started copy.
2. For a short **canary** window (default 60 s) the platform watches the new copies: it sends requests through Traefik and counts
   server errors (5xx).
3. If the new version never becomes healthy, or 5% or more of the requests fail, it is **removed and the old version keeps
   serving**. It never stopped. You get an email alert and the deploy ends with the reason.
4. Otherwise the old containers are drained and removed, and the deploy is done.

`develop` and previews keep the simple "replace in place" deploy (a short gap, half the memory). Change that per environment:

```yaml
environments:
  prod:
    replicas: 2               # copies kept running behind Traefik (1 to 4); survives a crash or a slow container
    strategy: rolling         # rolling (default for prod and staging) or recreate
    canary_seconds: 60        # how long a new version is watched before the old one is retired (0 = health check only)
    rollback_error_percent: 5 # roll back when this share of requests (and at least 3) fail with a 5xx
    api:
      replicas: 3             # one service only (overrides the line above for `api`)
  develop:
    strategy: rolling         # opt in; develop is replace-in-place by default
```

**Give every deployable service a `HEALTHCHECK`.** The platform trusts it to decide "ready". Without one, a container counts as
ready the moment it starts, and only the canary protects you.

While a rolling deploy runs, both versions run, so the environment briefly needs about twice its normal memory. The deploy
fails cleanly (and rolls back) if the host cannot fit it.

## Rolling back

| Command | What it does |
|---|---|
| `infra rollback <app> <env>` | back to the previous version |
| `infra rollback <app> <env> --to <tag>` | back to any of the last 5 versions (`TAG_HISTORY` in the environment's `meta.env`) |

A rollback is itself a rolling deploy: new copies start, are checked, then the old ones leave. It works as long as the image
is still on the server (images this platform pulled are kept for 7 days after their last use).

## The one rule that makes rollback safe: additive migrations only

Both versions run against the **same database** during a deploy, and a rollback puts the old code back on the database the
new code already changed. So a release must never break the version before it.

**Expand, then contract**, across two releases:

| Release | Do | Don't |
|---|---|---|
| N (expand) | add tables and columns, make new columns nullable or give them defaults, write to both the old and new column | drop or rename anything, add `NOT NULL` without a default |
| N+1 (contract) | remove columns, tables and code paths nothing uses any more | do it in the same release that stopped using them |

Examples:

- **Rename a column:** release N adds the new column and writes both; release N+1 reads only the new one; release N+2 drops
  the old one.
- **New required field:** add it nullable with a default in release N; make it `NOT NULL` in N+1.

If a migration cannot be made additive, deploy it in a maintenance window with `strategy: recreate` for that release and take a
dump first (console → Databases → Download dump). Restoring a dump brings back the old data but loses everything written since,
so it is the last resort, not the plan.

## High availability: what is and is not covered

On one server, `replicas: 2` and rolling deploys protect against: a crashing or hung app container, a bad release, a slow
start, and a failed migration in the new version (the old copies keep serving).

They do **not** protect against the server itself failing, or against Postgres, Traefik or the console failing, because those
exist once. Surviving that needs a second server, a replicated database and a floating address. Until then, keep off-server
backups and the alerts on (see `docs/runbook.md`).
