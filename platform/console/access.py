"""Organization and project authorization for the infra console."""

import fnmatch
import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager

SLUG = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
PROJECT_ROLES = {"viewer", "operator", "maintainer"}
ROLE_ORDER = {"viewer": 1, "operator": 2, "maintainer": 3}
ENV_CLASSES = ("prod", "staging", "develop", "preview")
# Environment-scoped grants narrow a role to part of a project:
#   env:<name>        one environment            (env:develop, env:pr-12)
#   class:<class>     every environment of a class (class:preview = all previews)
#   branch:<pattern>  every environment deployed from a matching branch (branch:feature/checkout*)
ENV_SCOPE = re.compile(r"^(env:[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?|class:(prod|staging|develop|preview)|branch:[A-Za-z0-9._/*-]{1,100})$")


EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
INVITE_TTL = 14 * 86400


def env_class_of(env):
    return "preview" if env.startswith("pr-") else env


def scope_matches(scope, env, branch):
    kind, _, value = scope.partition(":")
    if kind == "env":
        return env == value
    if kind == "class":
        return env_class_of(env) == value
    if kind == "branch":
        return bool(branch) and fnmatch.fnmatchcase(branch, value)
    return False


def strongest(*roles):
    roles = [r for r in roles if r in ROLE_ORDER]
    return max(roles, key=ROLE_ORDER.get) if roles else None


class AccessStore:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS identities (
                    uid TEXT PRIMARY KEY,
                    username TEXT NOT NULL,
                    email TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    last_seen INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS organizations (
                    slug TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS organization_projects (
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    app TEXT NOT NULL UNIQUE,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (organization, app)
                );
                CREATE TABLE IF NOT EXISTS organization_members (
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('member', 'org_admin')),
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (organization, uid)
                );
                CREATE TABLE IF NOT EXISTS project_grants (
                    app TEXT NOT NULL REFERENCES organization_projects(app) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'maintainer')),
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (app, uid)
                );
                CREATE TABLE IF NOT EXISTS invitations (
                    id TEXT PRIMARY KEY,
                    email TEXT NOT NULL,
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    member_role TEXT NOT NULL CHECK (member_role IN ('member', 'org_admin')),
                    invited_by TEXT NOT NULL,
                    grants TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    UNIQUE (email, organization)
                );
                CREATE TABLE IF NOT EXISTS environment_grants (
                    app TEXT NOT NULL REFERENCES organization_projects(app) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    scope TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'maintainer')),
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (app, uid, scope)
                );
            """)
        os.chmod(path, 0o660)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def observe_identity(self, uid, username, email, display_name):
        if not uid or not email:
            raise ValueError("identity provider did not supply a stable user id and email")
        now = int(time.time())
        with self.connect() as db:
            db.execute("""
                INSERT INTO identities (uid, username, email, display_name, last_seen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(uid) DO UPDATE SET
                    username = excluded.username,
                    email = excluded.email,
                    display_name = excluded.display_name,
                    last_seen = excluded.last_seen
            """, (uid, username or email, email, display_name or username or email, now))
        return {"uid": uid, "username": username or email, "email": email,
                "display_name": display_name or username or email}

    def create_organization(self, slug, name):
        if not SLUG.fullmatch(slug or "") or not isinstance(name, str) or not name.strip():
            raise ValueError("organization needs a valid slug and non-empty name")
        with self.connect() as db:
            db.execute("INSERT INTO organizations (slug, name, created_at) VALUES (?, ?, ?)",
                       (slug, name.strip(), int(time.time())))

    def identity_uid(self, email):
        if not isinstance(email, str) or "@" not in email or len(email) > 320:
            raise ValueError("enter a valid email address")
        with self.connect() as db:
            rows = db.execute("SELECT uid FROM identities WHERE lower(email)=lower(?)",
                              (email.strip(),)).fetchall()
        if len(rows) != 1:
            raise ValueError("user must sign in through the console once before access can be assigned")
        return rows[0]["uid"]

    def link_project(self, organization, app):
        if not SLUG.fullmatch(organization or "") or not SLUG.fullmatch(app or ""):
            raise ValueError("invalid organization or project name")
        with self.connect() as db:
            db.execute("INSERT INTO organization_projects (organization, app, created_at) VALUES (?, ?, ?)",
                       (organization, app, int(time.time())))

    def set_member(self, organization, uid, role):
        if role not in {"member", "org_admin", "none"}:
            raise ValueError("organization role must be member, org_admin, or none")
        with self.connect() as db:
            if role == "none":
                db.execute("DELETE FROM organization_members WHERE organization=? AND uid=?",
                           (organization, uid))
                db.execute("""
                    DELETE FROM project_grants WHERE uid=? AND app IN (
                        SELECT app FROM organization_projects WHERE organization=?
                    )
                """, (uid, organization))
                db.execute("""
                    DELETE FROM environment_grants WHERE uid=? AND app IN (
                        SELECT app FROM organization_projects WHERE organization=?
                    )
                """, (uid, organization))
            else:
                db.execute("""
                    INSERT INTO organization_members (organization, uid, role, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(organization, uid) DO UPDATE SET role=excluded.role
                """, (organization, uid, role, int(time.time())))

    def organization_member_role(self, organization, uid):
        with self.connect() as db:
            row = db.execute("""
                SELECT role FROM organization_members WHERE organization=? AND uid=?
            """, (organization, uid)).fetchone()
            return row["role"] if row else None

    def grant_project(self, app, uid, role):
        if role not in PROJECT_ROLES | {"none"}:
            raise ValueError("project role must be viewer, operator, maintainer, or none")
        with self.connect() as db:
            if role == "none":
                db.execute("DELETE FROM project_grants WHERE app=? AND uid=?", (app, uid))
                return
            member = db.execute("""
                SELECT 1 FROM organization_members om
                JOIN organization_projects op ON op.organization=om.organization
                WHERE op.app=? AND om.uid=?
            """, (app, uid)).fetchone()
            if not member:
                raise ValueError("project access requires membership in its organization")
            db.execute("""
                INSERT INTO project_grants (app, uid, role, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(app, uid) DO UPDATE SET role=excluded.role
            """, (app, uid, role, int(time.time())))

    # ---- invitations: membership + initial grants for an email that has not (necessarily) signed in yet.
    # Nothing is applied until the invited person accepts while signed in with that (verified) email, so an
    # organization admin never learns whether an account exists and nobody is added without their consent.

    def create_invitation(self, organization, email, invited_by, grants=(), member_role="member"):
        email = (email or "").strip().lower()
        if not EMAIL.fullmatch(email):
            raise ValueError("enter a valid email address")
        if member_role not in ("member", "org_admin"):
            raise ValueError("bad membership role")
        clean = []
        with self.connect() as db:
            if not db.execute("SELECT 1 FROM organizations WHERE slug=?", (organization,)).fetchone():
                raise ValueError("unknown organization")
            for g in list(grants)[:20]:
                app, role, scope = g.get("app", ""), g.get("role", ""), g.get("scope", "") or ""
                if role not in PROJECT_ROLES:
                    raise ValueError("grant role must be viewer, operator or maintainer")
                if scope and not ENV_SCOPE.fullmatch(scope):
                    raise ValueError("scope must be env:<name>, class:<class> or branch:<pattern>")
                if not db.execute("SELECT 1 FROM organization_projects WHERE organization=? AND app=?", (organization, app)).fetchone():
                    raise ValueError(f"{app or 'project'} does not belong to this organization")
                clean.append({"app": app, "role": role, "scope": scope})
            now = int(time.time())
            ident = secrets.token_hex(8)
            db.execute("""
                INSERT INTO invitations (id, email, organization, member_role, invited_by, grants, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(email, organization) DO UPDATE SET member_role=excluded.member_role, invited_by=excluded.invited_by,
                    grants=excluded.grants, created_at=excluded.created_at, expires_at=excluded.expires_at
            """, (ident, email, organization, member_role, invited_by, json.dumps(clean), now, now + INVITE_TTL))
            return db.execute("SELECT id FROM invitations WHERE email=? AND organization=?", (email, organization)).fetchone()["id"]

    def pending_for_email(self, email):
        with self.connect() as db:
            rows = db.execute("""
                SELECT i.id, i.organization, o.name AS organization_name, i.member_role, i.grants, i.created_at, i.expires_at
                FROM invitations i JOIN organizations o ON o.slug=i.organization
                WHERE i.email=? AND i.expires_at>? ORDER BY i.created_at
            """, ((email or "").strip().lower(), int(time.time()))).fetchall()
        return [{**dict(r), "grants": json.loads(r["grants"])} for r in rows]

    def accept_invitation(self, uid, email, invitation_id):
        """Apply an invitation for the signed-in person. The invitation's email must be the account's email."""
        email = (email or "").strip().lower()
        with self.connect() as db:
            inv = db.execute("SELECT * FROM invitations WHERE id=? AND email=? AND expires_at>?",
                             (invitation_id, email, int(time.time()))).fetchone()
        if not inv:
            raise ValueError("no such pending invitation for this account")
        current = self.organization_member_role(inv["organization"], uid)
        if current is None or (current == "member" and inv["member_role"] == "org_admin"):
            self.set_member(inv["organization"], uid, inv["member_role"])      # never downgrade an existing org admin
        for g in json.loads(inv["grants"]):
            if g["scope"]:
                self.grant_environment(g["app"], uid, g["scope"], g["role"])
            else:
                self.grant_project(g["app"], uid, g["role"])
        with self.connect() as db:
            db.execute("DELETE FROM invitations WHERE id=?", (invitation_id,))
        return inv["organization"]

    def decline_invitation(self, email, invitation_id):
        with self.connect() as db:
            db.execute("DELETE FROM invitations WHERE id=? AND email=?", (invitation_id, (email or "").strip().lower()))

    def revoke_invitation(self, invitation_id, organization):
        with self.connect() as db:
            db.execute("DELETE FROM invitations WHERE id=? AND organization=?", (invitation_id, organization))

    def invitation_organization(self, invitation_id):
        with self.connect() as db:
            row = db.execute("SELECT organization FROM invitations WHERE id=?", (invitation_id,)).fetchone()
            return row["organization"] if row else None

    def member_uid_by_email(self, organization, email):
        """Resolve an email to a uid ONLY among the members of one organization (no global account lookup)."""
        with self.connect() as db:
            row = db.execute("""
                SELECT i.uid FROM organization_members om JOIN identities i ON i.uid=om.uid
                WHERE om.organization=? AND lower(i.email)=lower(?)
            """, (organization, (email or "").strip())).fetchone()
            return row["uid"] if row else None

    def list_invitations(self, uid, platform_admin=False):
        with self.connect() as db:
            if platform_admin:
                rows = db.execute("""SELECT id, email, organization, member_role, grants, created_at, expires_at, invited_by
                                     FROM invitations WHERE expires_at>? ORDER BY organization, email""", (int(time.time()),)).fetchall()
            else:
                rows = db.execute("""SELECT i.id, i.email, i.organization, i.member_role, i.grants, i.created_at, i.expires_at, i.invited_by
                                     FROM invitations i JOIN organization_members me ON me.organization=i.organization
                                     WHERE me.uid=? AND me.role='org_admin' AND i.expires_at>? ORDER BY i.organization, i.email""",
                                  (uid, int(time.time()))).fetchall()
        return [{**dict(r), "grants": json.loads(r["grants"])} for r in rows]

    def grant_environment(self, app, uid, scope, role):
        """Give <uid> a role on part of a project (see ENV_SCOPE). role 'none' removes that one grant."""
        if not ENV_SCOPE.fullmatch(scope or ""):
            raise ValueError("scope must be env:<name>, class:<prod|staging|develop|preview> or branch:<pattern>")
        if role not in PROJECT_ROLES | {"none"}:
            raise ValueError("role must be viewer, operator, maintainer, or none")
        with self.connect() as db:
            if role == "none":
                db.execute("DELETE FROM environment_grants WHERE app=? AND uid=? AND scope=?", (app, uid, scope))
                return
            member = db.execute("""
                SELECT 1 FROM organization_members om
                JOIN organization_projects op ON op.organization=om.organization
                WHERE op.app=? AND om.uid=?
            """, (app, uid)).fetchone()
            if not member:
                raise ValueError("access requires membership in the project's organization")
            db.execute("""
                INSERT INTO environment_grants (app, uid, scope, role, created_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(app, uid, scope) DO UPDATE SET role=excluded.role
            """, (app, uid, scope, role, int(time.time())))

    def role_for_environment(self, uid, app, env, branch="", platform_admin=False):
        """Effective role in one environment: the project-wide role or any matching scoped grant, whichever is highest."""
        if platform_admin:
            return "platform_admin"
        with self.connect() as db:
            project = db.execute("SELECT role FROM project_grants WHERE uid=? AND app=?", (uid, app)).fetchone()
            scoped = [row["role"] for row in db.execute(
                "SELECT scope, role FROM environment_grants WHERE uid=? AND app=?", (uid, app))
                if scope_matches(row["scope"], env, branch or "")]
        return strongest(project["role"] if project else None, *scoped)

    def environment_grants_for(self, uid):
        with self.connect() as db:
            return [dict(row) for row in db.execute(
                "SELECT app, scope, role FROM environment_grants WHERE uid=? ORDER BY app, scope", (uid,))]

    def role_for_project(self, uid, app, platform_admin=False):
        if platform_admin:
            return "platform_admin"
        with self.connect() as db:
            row = db.execute("SELECT role FROM project_grants WHERE uid=? AND app=?",
                             (uid, app)).fetchone()
            return row["role"] if row else None

    def can_admin_organization(self, uid, organization, platform_admin=False):
        if platform_admin:
            return True
        with self.connect() as db:
            row = db.execute("""
                SELECT 1 FROM organization_members
                WHERE uid=? AND organization=? AND role='org_admin'
            """, (uid, organization)).fetchone()
            return row is not None

    def organization_for_project(self, app):
        with self.connect() as db:
            row = db.execute("SELECT organization FROM organization_projects WHERE app=?",
                             (app,)).fetchone()
            return row["organization"] if row else None

    def visible_apps(self, uid, platform_admin=False):
        with self.connect() as db:
            if platform_admin:
                return [row["app"] for row in db.execute(
                    "SELECT app FROM organization_projects ORDER BY app")]
            return [row["app"] for row in db.execute(
                """SELECT app FROM project_grants WHERE uid=?
                   UNION SELECT app FROM environment_grants WHERE uid=? ORDER BY app""", (uid, uid))]

    def list_access(self, uid, platform_admin=False):
        with self.connect() as db:
            if platform_admin:
                organizations = db.execute("""
                    SELECT o.slug, o.name, NULL AS role FROM organizations o ORDER BY o.name
                """).fetchall()
                identities = db.execute("""
                    SELECT uid, username, email, display_name, last_seen
                    FROM identities ORDER BY email
                """).fetchall()
                projects = db.execute("""
                    SELECT op.app, op.organization, i.uid, i.email, pg.role
                    FROM organization_projects op
                    LEFT JOIN project_grants pg ON pg.app=op.app
                    LEFT JOIN identities i ON i.uid=pg.uid
                    ORDER BY op.organization, op.app, i.email
                """).fetchall()
                members = db.execute("""
                    SELECT om.organization, om.uid, i.email, om.role
                    FROM organization_members om JOIN identities i ON i.uid=om.uid
                    ORDER BY om.organization, i.email
                """).fetchall()
            else:
                organizations = db.execute("""
                    SELECT o.slug, o.name, om.role FROM organizations o
                    JOIN organization_members om ON om.organization=o.slug
                    WHERE om.uid=? ORDER BY o.name
                """, (uid,)).fetchall()
                identities = db.execute("""
                    SELECT DISTINCT i.uid, i.username, i.email, i.display_name, i.last_seen
                    FROM identities i JOIN organization_members om ON om.uid=i.uid
                    JOIN organization_members mine ON mine.organization=om.organization
                    WHERE mine.uid=? AND mine.role='org_admin' ORDER BY i.email
                """, (uid,)).fetchall()
                projects = db.execute("""
                    SELECT op.app, op.organization, i.uid, i.email, pg.role
                    FROM organization_projects op
                    JOIN organization_members mine ON mine.organization=op.organization
                    LEFT JOIN project_grants pg ON pg.app=op.app
                    LEFT JOIN identities i ON i.uid=pg.uid
                    WHERE mine.uid=? AND mine.role='org_admin'
                    ORDER BY op.organization, op.app, i.email
                """, (uid,)).fetchall()
                members = db.execute("""
                    SELECT om.organization, om.uid, i.email, om.role
                    FROM organization_members om JOIN identities i ON i.uid=om.uid
                    JOIN organization_members mine ON mine.organization=om.organization
                    WHERE mine.uid=? AND mine.role='org_admin'
                    ORDER BY om.organization, i.email
                """, (uid,)).fetchall()
            if platform_admin:
                env_rows = db.execute("""
                    SELECT eg.app, op.organization, eg.uid, i.email, eg.scope, eg.role
                    FROM environment_grants eg JOIN organization_projects op ON op.app=eg.app
                    JOIN identities i ON i.uid=eg.uid ORDER BY eg.app, i.email, eg.scope
                """).fetchall()
            else:
                env_rows = db.execute("""
                    SELECT eg.app, op.organization, eg.uid, i.email, eg.scope, eg.role
                    FROM environment_grants eg JOIN organization_projects op ON op.app=eg.app
                    JOIN identities i ON i.uid=eg.uid
                    JOIN organization_members mine ON mine.organization=op.organization
                    WHERE mine.uid=? AND mine.role='org_admin' ORDER BY eg.app, i.email, eg.scope
                """, (uid,)).fetchall()
            return {
                "organizations": [dict(row) for row in organizations],
                "identities": [dict(row) for row in identities],
                "projects": [dict(row) for row in projects],
                "members": [dict(row) for row in members],
                "environment_grants": [dict(row) for row in env_rows],
                "invitations": self.list_invitations(uid, platform_admin),
            }

    def project_roles(self, uid, platform_admin=False):
        if platform_admin:
            return {}
        with self.connect() as db:
            return {row["app"]: row["role"] for row in db.execute(
                "SELECT app, role FROM project_grants WHERE uid=?", (uid,))}
