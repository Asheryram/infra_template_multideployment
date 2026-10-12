# Console access control and supply-chain operations

This guide covers tenant-facing access through the Infra Console. It does not grant app teams shell, SSH, Docker, or VPS access. The console process can control Docker, so compromise of the console is still a host-level incident.

## Access model

- **Platform administrators** belong to the configured identity-provider group (`KEYCLOAK_PLATFORM_ADMIN_GROUP`, default `infra-platform-admins`). They create organizations, connect registered projects, appoint organization admins and may use every action, including the privileged ones.
- An **organization** is one client. Inside it a person is either an **organization admin** — has **every action on everything scoped to that organization** (all its projects and environments, including destroy, database wipe / URL reveal and secrets) and manages its people, groups and policies. Registering projects, GitOps, the activity log and the platform ops tools stay with platform administrators — or a **member**, who can do **nothing** until they are put in a **group** or have a **policy** attached.
- **Permissions are policies** (see below): *Allow* or *Deny* individual **actions** on **resources** `organization/project/environment`, optionally limited by branch, environment class or an expiry date. Policies attach to **groups** (and to single people); a person's permissions are the union of everything attached to them and their groups; an explicit Deny always wins.
- **Groups** belong to one organization (QA, Backend, Client X…). Put people in groups, attach policies to the groups: changing a policy changes everyone in the group at once.
- Least privilege is the default: what a person cannot **list** does not exist for them (404, not 403).
- Removing an organization member also removes their group memberships and attached policies in that organization.

## Enable Keycloak

Keycloak is the recommended self-hosted option in this deployment. oauth2-proxy handles the OIDC flow and proxies authenticated requests to the console, so browsers receive the normal redirect to Keycloak. The console continues to enforce organization and project grants. The Keycloak browser/admin host is VPN-restricted by Traefik. oauth2-proxy reaches Keycloak over the Docker network using an internal TLS certificate, so its OIDC backchannel does not have to bypass the VPN restriction.

1. Back up `/etc/infra`, `$STATE_DIR`, and the Postgres data. Keep the console in Basic mode until Keycloak, the realm, and the OIDC client have been configured and tested.
2. In `/etc/infra/infra.env`, set:

   ```dotenv
   PLATFORM_PROFILES=keycloak
   CONSOLE_AUTH_MODE=basic
   KEYCLOAK_REALM=infra
   KEYCLOAK_VPN_CIDRS=<actual-vpn-client-cidr>
   KEYCLOAK_PLATFORM_ADMIN_GROUP=infra-platform-admins
   ```

   Replace the example CIDR with the actual client source range Traefik sees. `KEYCLOAK_VPN_CIDRS` accepts comma-separated IPv4/IPv6 CIDRs.
3. Ensure `/etc/infra/platform.secrets.env` contains generated values for `KEYCLOAK_POSTGRES_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `OAUTH2_PROXY_CLIENT_SECRET`, and `OAUTH2_PROXY_COOKIE_SECRET`. New bootstrap runs create these values. For an existing installation, generate missing values with `openssl rand -hex 32` for the first three and `openssl rand -base64 24` for the 32-character oauth2-proxy cookie secret. Keep them root-owned and private.
4. Start Keycloak by itself while Basic Auth remains enabled. This keeps oauth2-proxy from trying to discover a realm before you create one:

   ```bash
   sudo -u deploy infra platform up
   ```

5. While connected to the VPN, open `https://auth.<domain>` and sign in to the Keycloak admin console using `KEYCLOAK_ADMIN_USERNAME` (default `admin`) and the password from the secrets file. Create the realm named by `KEYCLOAK_REALM` (default `infra`).
6. In that realm, create an **OpenID Connect** client with ID `OAUTH2_PROXY_CLIENT_ID` (default `infra-console`), client authentication enabled, Standard Flow enabled, Direct Access Grants disabled, and the exact redirect URI `https://console.<domain><public-port-if-nonstandard>/oauth2/callback`. Set the client secret to the value in `OAUTH2_PROXY_CLIENT_SECRET`.
7. Add a **Group Membership** mapper to the client that emits a `groups` claim in both the ID and access tokens. Add an **Audience** mapper that includes the `infra-console` client in the ID and access tokens; oauth2-proxy validates the audience. Create the `infra-platform-admins` group and add your operator account. User accounts must have a verified email address.
8. Add `keycloak-auth` to `PLATFORM_PROFILES` (for example, `keycloak,keycloak-auth`) and set `CONSOLE_AUTH_MODE=keycloak`. Then apply:

   ```bash
   sudo -u deploy infra platform up
   ```

   Verify the console redirects to Keycloak, a platform administrator sees administrative functions, and an ordinary user sees no projects until explicit project grants are added. Create or invite users in Keycloak; after each user signs in to the console once, manage their organization memberships and project grants in the console's **Access** tab. The console does not create Keycloak accounts. **Sign out** ends the oauth2-proxy console session; Keycloak's own SSO session may remain active. Check `infra platform logs keycloak`, `infra platform logs oauth2-proxy`, and `infra platform logs traefik`.

The `keycloak` Compose profile can run while `CONSOLE_AUTH_MODE=basic` during setup. Enable `keycloak-auth` only after creating the realm and OIDC client. Keycloak credentials are stored in the shared Postgres service; back up Postgres and `/etc/infra/platform.secrets.env` together.

Keycloak user IDs are stored with a `keycloak:` prefix and are intentionally distinct from Authentik IDs. Switching from Authentik requires re-adding users to organizations and re-granting project roles; do not remove the old provider data until the new grants are verified.

## Organizations, groups and policies

```
Platform admin  (Keycloak group infra-platform-admins — everything)
 └─ Organization  = one client / tenant ("acme")
     ├─ People:   organization admin | member
     ├─ Groups:   QA, Backend, Client X …  (people + attached policies)
     └─ Policies: "Allow/Deny these actions on these organization/project/environment resources"
```

**Setting it up** — console → **Access**: create **policies** (Policies card — start a statement from a preset such as Viewer / Operator / Maintainer, then narrow its resources), create **groups** (Groups card), attach policies to groups and add members; or attach a policy straight to one person. The **Members** table shows each person's groups and policies. People are added by **invitation**, which can already put them in groups. Use the **simulator** to see exactly what someone can do on an environment and which statement allows or denies it.

Presets (copy them into a policy): **Viewer** = list, view, open, read logs, list variables (masked), describe databases, read resources · **Operator** = Viewer + redeploy, restart, roll back · **Maintainer** = Operator + read/write variables, create databases, use a database from another environment.

## Permission matrix

Actors: **platform admin** · **organization admin** (every action in their organization, plus managing its people, groups and policies) · **organization member** (nothing until in a group or given a policy). The columns are the three presets; a policy can mix any actions.

| Action (a role is a preset of the actions below; see Policies for the exact action names) | viewer | operator | maintainer | platform admin only |
|---|:-:|:-:|:-:|:-:|
| See the environment; open it when its gate is on | ✓ | ✓ | ✓ | |
| Read logs; see variables (values masked) | ✓ | ✓ | ✓ | |
| See variable **values** | | | ✓ | |
| Redeploy, restart, roll back | | ✓ | ✓ | |
| Edit variables · create a database · point a variable at a database | | | ✓ | |
| Edit resource limits | | | | ✓ |
| Wipe a database · reveal a database URL or secret value | | | | ✓ |
| Destroy an environment | | | | ✓ |
| Register projects · GitOps · activity log · Traefik / logs / status | | | | ✓ |

Variable scopes: `common` or a class (`preview`) need a maintainer on the **project or organization level**; one environment's scopes (`pr-7`, `pr-7.api`, `develop`) need a maintainer **covering that environment** (any level, or a matching pattern). People management: a platform admin creates organizations, assigns projects and appoints organization admins; an organization admin invites people, grants and revokes access **within their own organization** only. To take something away use a **Deny** in a [policy](#policies-allow-or-deny-individual-actions-aws-style).

## Policies: allow or deny individual actions (AWS-style)

Underneath, **every permission is an action on a resource, denied by default** — the three roles are just ready-made sets of actions, and the console checks each request against the person's actions, not against a role. Use a **policy** (console → **Access → Policies**) when you need finer control: *see* every environment but not *open* it, read logs on `prod` but change nothing, work only on `feature/*` branches, or temporary access until a date.

**Resources** are `organization/project/environment`, with `*` wildcards: `acme/*` (everything of the client), `acme/shop-api/*` (a project), `acme/shop-api/prod`, `acme/shop-web/pr-*`.

**Actions**, by access level (Privileged actions are the dangerous ones; an organization admin can allow them inside their own organization):

| Level | Actions |
|---|---|
| List | `environment:List` — the environment appears in lists. **Without it the environment does not exist for that person** (404, not 403) |
| Read | `environment:View` (details, endpoints, who deployed) · `environment:Open` (pass the access gate, open its URLs) · `logs:Read` · `variables:List` (names, values masked) · `variables:ReadValues` · `database:Describe` · `resources:Read` |
| Write | `environment:Redeploy` · `environment:Restart` · `environment:Rollback` · `variables:Write` · `database:Create` · `database:Use` |
| Privileged | `environment:Destroy` · `database:Wipe` · `database:RevealUrl` · `secrets:Reveal` · `resources:Write` |

**Statements** — `Effect` Allow/Deny, `Action` (wildcards like `logs:*`), `Resource`, optional `Condition`: `branch` (patterns like `feature/*`), `class` (`prod`, `staging`, `develop`, `preview`) and `expires` (a date). All conditions must hold; a conditional statement never matches a resource it cannot evaluate (a `branch` condition does not apply to a project-level resource).

**How a request is decided:** an explicit **Deny** always wins; otherwise one matching **Allow** is enough; otherwise it is denied. Everything combines freely: add a policy with a Deny to carve an exception out of a broad Allow.

```json
{ "Statement": [
  { "Effect": "Allow", "Action": ["environment:List", "environment:View"], "Resource": ["acme/shop-web/*"] },
  { "Effect": "Allow", "Action": ["environment:Open", "logs:Read"],        "Resource": ["acme/shop-web/*"],
    "Condition": { "branch": ["feature/*"], "expires": "2026-12-31" } },
  { "Effect": "Deny",  "Action": ["*"],                                    "Resource": ["acme/shop-web/prod"] }
] }
```

**Editing:** the editor has a **Visual** mode (Effect, actions grouped by level with *select all*, resources with suggestions from your real environments, conditions) and a **JSON** mode; both validate on save (an action that matches nothing, a resource outside the organization is refused with a precise message). A policy belongs to one organization and is **attached to members**; removing a member detaches their policies.

**Policy simulator** (same page): pick person, project, environment and optionally one action → *Allowed / Denied*, the reason (explicit Deny / Allow / nothing allows it) and the exact statement that decided, plus every action the person has on that environment. Use it before and after changing access.

What the console shows follows the actions: no `environment:View` → no details, no `environment:Open` → endpoints are shown but not clickable (and the preview/ops gate refuses), no `logs:Read` → no Logs section, and so on. Platform administrators always have every action.

## Inviting people

Nobody is added to an organization by looking up their account. An organization admin (or a platform admin) **invites by email** in **Access → Organization membership**: the organization, the email, an optional name and, optionally, the **groups** to put them in. Nothing is applied yet; the invitation is **pending** (14 days) and the admin never learns whether an account for that address exists.

- **If the person has no account**, and `KEYCLOAK_USER_ADMIN_SECRET` is set (default on a fresh install), the console creates it in Keycloak: with a mail server configured the person is emailed to verify the address and choose a password; without one the admin is shown a **one-time password once** (never logged or stored) to pass on privately, and the address is marked verified because the admin vouches for it. The account gets **no groups and no roles** — never the platform-admin group.
- **If they already have an account** (or arrive through the client's own identity provider) nothing is created.
- **Acceptance:** when the person signs in with that (Keycloak-verified) email, the console shows *"You're invited to …"* with exactly what accepting gives them, and **Accept / Decline**. Accepting applies the membership and the grants; declining or revoking deletes the invitation. A preview link opened first shows a hint pointing at the console. An existing organization admin stays an admin when accepting a plain member invitation.
- **Limits:** only platform admins can invite an *organization admin*; 30 invitations per admin per hour; grants can only target projects of the inviting organization.
- **Trust model:** Keycloak cannot restrict a service account to "create only", so the `infra-user-admin` client technically may manage every account in the realm. The console only ever *creates* an account that does not exist yet and sets its password; it never edits, resets or groups anything else. To switch account creation off entirely set `INVITE_CREATE_ACCOUNTS=false` (or leave `KEYCLOAK_USER_ADMIN_SECRET` empty); invitations keep working and accounts then come from a platform admin or the client's own login.
- **Client logins (recommended for larger clients):** in Keycloak add the client's Azure AD / Google as an identity provider; people sign in with their own accounts and the invitation attaches their access on first sign-in.

## Preview environments with Keycloak (optional)

By default every preview sits behind one shared basic-auth password (`PREVIEW_AUTH_PLAIN`). With `PREVIEW_AUTH_MODE=keycloak`, previews use the same Keycloak identities and project roles as the console instead.

**Who can open a preview:** someone who is signed in to Keycloak **and** either is a platform administrator or has a role that covers that environment — a project-wide role, or an environment, class or branch grant that matches it (see above). Roles are per app and never inherited: a viewer of `shop-web` cannot open `shop-api` previews. Signed in but without a role shows a "no access" page; the person is registered under their email, so an organization admin can grant the role from the console's **Access** tab. Revoking a role takes effect within about 15 seconds. A service with `environments.preview.<service>.auth: false` in `infra.yml` stays public, exactly as with basic auth.

How it works: Traefik asks the console (`/auth/preview?app=<app>`) before every preview request. The console asks a dedicated `oauth2-previews` proxy whether the browser's session cookie is valid (identity is taken only from that answer, never from request headers). Signed-out browsers are sent to Keycloak and back to the exact preview URL. The login cookie is shared across `*.<domain>`, and the OIDC callback is one fixed host, `sso.<domain>`, because Keycloak cannot register wildcard hosts. `sso.<domain>` is VPN-restricted like `auth.<domain>`, so previewers must reach Keycloak (VPN) to sign in.

> On a fresh install everything below (secrets, realm, both clients, mappers, first admin user, switching the platform over) is done by `platform/keycloak/bootstrap-realm.sh --admin-user … --admin-email … --apply` — see [runbook-fresh-install.md](runbook-fresh-install.md). The manual steps remain for adding previews SSO to an existing platform.

1. In `/etc/infra/platform.secrets.env` add `OAUTH2_PREVIEWS_CLIENT_SECRET` (`openssl rand -hex 32`) and `OAUTH2_PREVIEWS_COOKIE_SECRET` (`openssl rand -base64 24`, exactly 32 characters).
2. Create the Keycloak client `infra-previews` (override with `OAUTH2_PREVIEWS_CLIENT_ID`): either run `sudo bash platform/keycloak/create-previews-client.sh` (creates or updates only that client; `--dry-run` shows what it would do), or create it by hand exactly like the console client in step 6 above, with the single redirect URI `https://sso.<domain><public-port-if-nonstandard>/oauth2/callback`. It needs the same two client mappers as the console client (a Group Membership mapper emitting `groups`, and an Audience mapper); the script adds both. Do not request a `groups` *scope* unless your realm defines one.
3. In `/etc/infra/infra.env` set `PREVIEW_AUTH_MODE=keycloak` and add `keycloak-previews` to `PLATFORM_PROFILES` (for example `keycloak,keycloak-auth,keycloak-previews`). Requires `CONSOLE_AUTH_MODE=keycloak`. `infra platform up` refuses inconsistent combinations.
4. Apply with `sudo -u deploy infra platform up`. Existing previews switch on their **next deploy** (the middleware is generated per service); redeploy them or push to the PR.

`OPS_AUTH_MODE=keycloak` (set by `bootstrap-realm.sh --apply`) puts the Traefik dashboard, container logs, the status page and Grafana behind the same login, limited to platform administrators (console endpoint `/auth/platform`). Any environment class can opt in to the gate with `environments.<class>.auth: true` in `infra.yml`; the roles above then decide who gets in.

Switching back: set `PREVIEW_AUTH_MODE=basic`, remove `keycloak-previews` from the profiles, run `infra platform up`, and redeploy the previews. `sso` and `auth` are reserved app names.

## Enable Authentik (alternative)

Authentik remains available as an alternative. Do not enable its tenant-auth mode until a real VPN subnet is known and the Authentik host can be reached from a VPN-connected client.

1. Back up `/etc/infra`, `$STATE_DIR`, the Postgres data, and the `authentik-media` Docker volume. Confirm the recovery path before changing the console authentication mode.
2. In the server's `/etc/infra/infra.env`, set:

   ```dotenv
   PLATFORM_PROFILES=authentik
   AUTHENTIK_VPN_CIDRS=<actual-vpn-client-cidr>
   CONSOLE_AUTH_MODE=basic
   ```

   The profile can be combined with other profiles, for example `metrics,authentik`. The CIDR is the client source range Traefik actually sees, not necessarily the VPN server's tunnel interface address. If traffic crosses a proxy or NAT, validate the forwarded client-IP behavior and trust only a proxy that overwrites forwarded headers.

3. Ensure `/etc/infra/platform.secrets.env` contains generated, private values for `AUTHENTIK_SECRET_KEY` and `AUTHENTIK_POSTGRES_PASSWORD`. Bootstrap creates them for new or existing installs. Keep this file root-owned and readable only by the deploy group; never commit it. Set `AUTHENTIK_BOOTSTRAP_EMAIL` and `AUTHENTIK_BOOTSTRAP_PASSWORD` only when deliberately using Authentik's bootstrap account flow, and remove/rotate temporary credentials after initial setup.
4. Start the profile while the console remains in Basic mode:

   ```bash
   sudo -u deploy infra platform up
   ```

5. While connected to the VPN, open `https://auth.<domain>`. Complete Authentik's initial setup if prompted. Create the `infra-platform-admins` group and add the platform operator account(s).
6. In Authentik, create a Proxy Provider in **Forward auth (single application)** mode for `https://console.<domain>`, select the appropriate authorization flow, create its application, and make the provider available through the embedded outpost. Verify the provider forwards the `X-authentik-uid`, `X-authentik-email`, `X-authentik-username`, `X-authentik-name`, and `X-authentik-groups` headers used by the console. The platform administrator group must appear in `X-authentik-groups`.
7. Test the Authentik login and VPN restriction before switching the console. From `/etc/infra/infra.env`, change `CONSOLE_AUTH_MODE=authentik`, then apply:

   ```bash
   sudo -u deploy infra platform up
   ```

   Check `infra platform ps`, `infra platform logs traefik`, and `infra platform logs authentik-server`. Verify the console redirects unauthenticated users to Authentik, a VPN client can reach the login host, and a non-VPN client cannot. Do not expose `auth.<domain>` through a public proxy.

The `authentik` Compose profile can run while `CONSOLE_AUTH_MODE=basic` during setup. The console continues to use Basic Auth until the explicit mode switch.

## Create users and grant access

1. A platform admin creates or invites a user in the configured identity provider. Users sign in through the console once so their stable provider ID and email are recorded locally.
2. In the console's **Access** tab, a platform admin creates the organization and links each already-registered project/repository to it. An app can be linked to only one organization.
3. A platform admin or that organization's admin adds the user by the email shown in the identity provider. The email must match the user's first console sign-in. Org-admin roles can only be assigned by a platform admin.
4. Put the user in a group (or attach a policy) for each project they need. A user's organization-admin status does not grant access to deployments.
5. Check the user's view by asking them to sign out and back in. They should see only explicitly granted projects and controls permitted by their role.

Treat `console-access.sqlite3` as security-critical state. Back it up with `$STATE_DIR`; losing it removes organization memberships and grants, though Authentik identities can be rediscovered on their next login.

## Recovery and account lifecycle

- **Lost platform-admin access:** From a trusted server session, temporarily set `CONSOLE_AUTH_MODE=basic` and run `sudo -u deploy infra platform up`. Basic mode is global operator access; restrict network access to the console first, rotate the Basic Auth credential, restore the identity-provider group/provider, then switch back immediately. Do not use Basic mode for tenant onboarding.
- **User departure:** Disable the account in Authentik, then remove its organization membership or project grants in the console. Removing membership revokes project grants in that organization. Keep any audit records according to your retention policy.
- **Lost identity-provider data:** Restore Postgres and any provider-specific state from a consistent backup along with `/etc/infra/platform.secrets.env`. Rotating signing or cookie secrets without a recovery plan can invalidate sessions and integrations.
- Keep the console and identity-provider admin access limited to trusted management paths. Do not distribute Basic Auth operator credentials to project teams.

## Image pinning, scanning, and updates

Core platform images and console Dockerfile bases are currently pinned to immutable digests. Some optional-profile images use fixed version tags; they are scanned but are not all digest-pinned yet. The `container-security` workflow scans the declared platform images and built console image for unfixed High/Critical vulnerabilities on relevant pull requests, main-branch changes, and a weekly schedule. Dependabot proposes Docker and GitHub Actions updates weekly.

For each update:

1. Review the upstream release, changelog, and image provenance; do not auto-merge image updates.
2. Update the image reference in Compose or the Dockerfile and the corresponding scan matrix when needed. Prefer a digest for production references.
3. Review the Trivy result. Resolve High/Critical findings or record a time-bounded, owner-approved exception; do not silently weaken the workflow threshold.
4. Test the updated platform on a non-production host/profile, confirm health checks, routing, and rollback, then schedule the production update.
5. Back up platform state first and retain the previous working image reference for rollback.

The workflow is a vulnerability check, not a complete supply-chain attestation or runtime scanner. Continue to review dependency provenance, keep the runner and host patched, and test restores.
