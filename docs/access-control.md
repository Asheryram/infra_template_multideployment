# Console access control and supply-chain operations

This guide covers tenant-facing access through the Infra Console. It does not grant app teams shell, SSH, Docker, or VPS access. The console process can control Docker, so compromise of the console is still a host-level incident.

## Access model

- **Platform administrators** belong to the configured identity-provider group (`AUTHENTIK_PLATFORM_ADMIN_GROUP` or `KEYCLOAK_PLATFORM_ADMIN_GROUP`, default `infra-platform-admins`). They can create organizations, connect registered projects, assign any project role, and manage organization-admin roles.
- **Organization admins** can add/remove ordinary members and assign/revoke project roles only in organizations where they are admins. They cannot create organizations, link projects, appoint/change organization admins, or administer another organization.
- **Project roles are explicit and per project.** Organization membership never grants project visibility by itself. A user may be a member of multiple organizations and may have different roles in each project's access list.
- **Viewer** reads assigned project information. **Operator** can deploy, restart, and roll back. **Maintainer** can also manage project runtime variables. Platform-only operations such as resource policy changes, project destruction, database wipes, and secret reveal remain restricted to platform administrators.
- Removing an organization member also removes their project grants for that organization's projects.

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

## Preview environments with Keycloak (optional)

By default every preview sits behind one shared basic-auth password (`PREVIEW_AUTH_PLAIN`). With `PREVIEW_AUTH_MODE=keycloak`, previews use the same Keycloak identities and project roles as the console instead.

**Who can open a preview:** someone who is signed in to Keycloak **and** either is a platform administrator or has a project role (viewer, operator or maintainer) on that app. Roles are per app and never inherited: a viewer of `shop-web` cannot open `shop-api` previews. Signed in but without a role shows a "no access" page; the person is registered under their email, so an organization admin can grant the role from the console's **Access** tab. Revoking a role takes effect within about 15 seconds. A service with `environments.preview.<service>.auth: false` in `infra.yml` stays public, exactly as with basic auth.

How it works: Traefik asks the console (`/auth/preview?app=<app>`) before every preview request. The console asks a dedicated `oauth2-previews` proxy whether the browser's session cookie is valid (identity is taken only from that answer, never from request headers). Signed-out browsers are sent to Keycloak and back to the exact preview URL. The login cookie is shared across `*.<domain>`, and the OIDC callback is one fixed host, `sso.<domain>`, because Keycloak cannot register wildcard hosts. `sso.<domain>` is VPN-restricted like `auth.<domain>`, so previewers must reach Keycloak (VPN) to sign in.

1. In `/etc/infra/platform.secrets.env` add `OAUTH2_PREVIEWS_CLIENT_SECRET` (`openssl rand -hex 32`) and `OAUTH2_PREVIEWS_COOKIE_SECRET` (`openssl rand -base64 24`, exactly 32 characters).
2. Create the Keycloak client `infra-previews` (override with `OAUTH2_PREVIEWS_CLIENT_ID`): either run `sudo bash platform/keycloak/create-previews-client.sh` (creates or updates only that client; `--dry-run` shows what it would do), or create it by hand exactly like the console client in step 6 above, with the single redirect URI `https://sso.<domain><public-port-if-nonstandard>/oauth2/callback`. It needs the same `groups` mapper (and Audience mapper) as the console client.
3. In `/etc/infra/infra.env` set `PREVIEW_AUTH_MODE=keycloak` and add `keycloak-previews` to `PLATFORM_PROFILES` (for example `keycloak,keycloak-auth,keycloak-previews`). Requires `CONSOLE_AUTH_MODE=keycloak`. `infra platform up` refuses inconsistent combinations.
4. Apply with `sudo -u deploy infra platform up`. Existing previews switch on their **next deploy** (the middleware is generated per service); redeploy them or push to the PR.

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
4. Assign the user a Viewer, Operator, or Maintainer role separately for each project they need. A user's organization-admin status does not grant access to deployments.
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
