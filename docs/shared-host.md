# Running on a server that already hosts other apps

The live server already runs other people's apps and databases. The rule is simple: **this platform never changes, restarts or deletes anything it didn't create.** `HOST_MODE=shared` is the default.

## What shared mode does and doesn't do

| Area | Shared (default) | Dedicated |
|---|---|---|
| Packages | Installs only **missing** packages (`--no-upgrade`) | Also `apt upgrade`, unattended upgrades |
| Docker | Installs it if absent. If present: **no daemon.json change, no restart** | Applies daemon.json and restarts (live-restore) |
| SSH | **Untouched** | Key-only, `AllowUsers`, no root |
| Firewall | Never changes defaults. If ufw is active, **adds** allow rules for Traefik's public ports only | default-deny + fail2ban |
| journald / sysctl / swap / timezone | **Untouched** | Configured |
| Our user / dirs / cron | `DEPLOY_USER`, `/etc/infra`, `/srv/deployments`, `/srv/backups`, `/var/lib/infra`, `/etc/cron.d/infra`, `/usr/local/bin/infra` (preflight refuses if any exist and aren't ours) | same |

Dedicated mode is refused if containers we didn't create exist.

## How runtime operations stay in their own lane

| Operation | Scope |
|---|---|
| Container identity | Every container we create is labelled `infra.managed=true`. Compose projects are prefixed: `infra-<app>-<env>` |
| `infra deploy` | Refuses if the target project already has containers we didn't create |
| `infra destroy` | `compose down` on our own project only. The fallback path removes only containers carrying our label |
| `infra cleanup` | **No global `docker prune`.** It removes only images *we* pulled (recorded at pull time) that no container uses |
| `infra host-check` | Disk and memory are host-wide (informational). Container alerts cover **our** containers only |
| Dozzle (logs UI) | `DOZZLE_FILTER=label=infra.managed=true`: other users' logs are never shown |
| Databases | Our own `infra-postgres` container on an internal network with no host port. It never connects to existing DB servers |
| `infra platform up` | Preflight refuses if any of our container or network names, or Traefik's ports, are already taken |

## Ports 80/443: who owns them?

Run this on the server first:
```bash
sudo ss -ltnp '( sport = :80 or sport = :443 )'
```

### A. Nothing listens on 80/443
Traefik takes them. Use the defaults (`TRAEFIK_BIND=0.0.0.0`, ports 80/443, `TLS_MODE=letsencrypt`). Other apps on other ports are unaffected.

### B. An existing nginx/apache/caddy already serves 80/443
Keep it as the front door and hand `*.apps.example.com` to Traefik on a local port:

```bash
# inventory
TLS_MODE=external
TRAEFIK_BIND=127.0.0.1
TRAEFIK_HTTP_PORT=8080
TRAEFIK_HTTPS_PORT=8443     # plain HTTP despite the name; only reachable from localhost
```

Then add **one new server block** to the existing nginx. It's a new file, so nothing existing changes. Its TLS cert is the existing proxy's job, e.g. `certbot certonly --dns-<provider> -d '*.apps.example.com'`:

```nginx
# /etc/nginx/sites-available/infra-apps  (then: ln -s ../sites-available/infra-apps /etc/nginx/sites-enabled/ && nginx -t && systemctl reload nginx)
server {
    listen 443 ssl;
    http2 on;
    server_name .apps.example.com;

    ssl_certificate     /etc/letsencrypt/live/apps.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/apps.example.com/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 120s;
    }
}
server {
    listen 80;
    server_name .apps.example.com;
    return 301 https://$host$request_uri;
}
```
`nginx -t` validates before reload. A reload is graceful and doesn't drop the other sites' connections. Coordinate this change with whoever owns nginx.

## Before touching the real server

1. Run the whole flow on the local VM with the simulated workload:
   ```bash
   sudo bash /opt/infra/local/simulate-existing.sh
   sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env
   sudo -u deploy infra platform up
   sudo -u deploy bash /opt/infra/local/smoke-test.sh
   sudo bash /opt/infra/local/verify-isolation.sh       # must be all PASS
   ```
2. On the real server, look before you leap. These commands change nothing:
   ```bash
   sudo bash bootstrap/install.sh inventory/vps-1.env 00     # preflight only
   ```
   Then run `infra platform check` after step 50.
3. Pick a `DEPLOY_USER` name that doesn't exist yet (`getent passwd <name>`).
4. Check that Docker has the Compose v2 plugin (`docker compose version`). On an existing Docker setup we won't install it for you.
5. Check that Docker's address pools have room. Each environment creates one private bridge network (that's what isolates it from every other app), and default pools allow about 30 networks in total, *including other users'* (`docker network ls | wc -l`). If you'll exceed that, agree a `default-address-pools` change with the server owner. That change requires a Docker restart, so it's never done automatically.
