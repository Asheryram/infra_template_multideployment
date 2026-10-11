# Console access control and supply-chain operations

This guide covers tenant-facing access through the Infra Console. It does not grant app teams shell, SSH, Docker, or VPS access. The console process can control Docker, so compromise of the console is still a host-level incident.

## Access model

- **Platform administrators** belong to the Authentik group named by `AUTHENTIK_PLATFORM_ADMIN_GROUP` (default `infra-platform-admins`). They can create organizations, connect registered projects, assign any project role, and manage organization-admin roles.
- **Organization admins** can add/remove ordinary members and assign/revoke project roles only in organizations where they are admins. They cannot create organizations, link projects, appoint/change organization admins, or administer another organization.
- **Project roles are explicit and per project.** Organization membership never grants project visibility by itself. A user may be a member of multiple organizations and may have different roles in each project's access list.
- **Viewer** reads assigned project information. **Operator** can deploy, restart, and roll back. **Maintainer** can also manage project runtime variables. Platform-only operations such as resource policy changes, project destruction, database wipes, and secret reveal remain restricted to platform administrators.
- Removing an organization member also removes their project grants for that organization's projects.

## Enable Authentik

Do not enable Authentik mode until a real VPN subnet is known and the Authentik host can be reached from a VPN-connected client.

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

1. A platform admin creates or invites a user in Authentik. Users sign in through the console once so their stable Authentik UID and email are recorded locally.
2. In the console's **Access** tab, a platform admin creates the organization and links each already-registered project/repository to it. An app can be linked to only one organization.
3. A platform admin or that organization's admin adds the user by the email shown in Authentik. The email must match the user's first console sign-in. Org-admin roles can only be assigned by a platform admin.
4. Assign the user a Viewer, Operator, or Maintainer role separately for each project they need. A user's organization-admin status does not grant access to deployments.
5. Check the user's view by asking them to sign out and back in. They should see only explicitly granted projects and controls permitted by their role.

Treat `console-access.sqlite3` as security-critical state. Back it up with `$STATE_DIR`; losing it removes organization memberships and grants, though Authentik identities can be rediscovered on their next login.

## Recovery and account lifecycle

- **Lost platform-admin access:** From a trusted server session, temporarily set `CONSOLE_AUTH_MODE=basic` and run `sudo -u deploy infra platform up`. Basic mode is global operator access; restrict network access to the console first, rotate the Basic Auth credential, restore the Authentik group/provider, then switch back immediately. Do not use Basic mode for tenant onboarding.
- **User departure:** Disable the account in Authentik, then remove its organization membership or project grants in the console. Removing membership revokes project grants in that organization. Keep any audit records according to your retention policy.
- **Lost Authentik data:** Restore Postgres and the `authentik-media` volume from a consistent backup along with `/etc/infra/platform.secrets.env`. Rotating the Authentik signing secret without a recovery plan can invalidate sessions and integrations.
- Keep Authentik, the console, and VPN access limited to trusted management paths. Do not distribute Basic Auth operator credentials to project teams.

## Image pinning, scanning, and updates

Core platform images and console Dockerfile bases are currently pinned to immutable digests. Some optional-profile images use fixed version tags; they are scanned but are not all digest-pinned yet. The `container-security` workflow scans the declared platform images and built console image for unfixed High/Critical vulnerabilities on relevant pull requests, main-branch changes, and a weekly schedule. Dependabot proposes Docker and GitHub Actions updates weekly.

For each update:

1. Review the upstream release, changelog, and image provenance; do not auto-merge image updates.
2. Update the image reference in Compose or the Dockerfile and the corresponding scan matrix when needed. Prefer a digest for production references.
3. Review the Trivy result. Resolve High/Critical findings or record a time-bounded, owner-approved exception; do not silently weaken the workflow threshold.
4. Test the updated platform on a non-production host/profile, confirm health checks, routing, and rollback, then schedule the production update.
5. Back up platform state first and retain the previous working image reference for rollback.

The workflow is a vulnerability check, not a complete supply-chain attestation or runtime scanner. Continue to review dependency provenance, keep the runner and host patched, and test restores.
