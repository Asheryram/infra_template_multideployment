"""Organization and project authorization for the infra console."""

import fnmatch
import json
import os
import re
import secrets
import sqlite3
import time
import policy
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


def policy_class(env):
    return env_class_of(env) if env else None


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
                CREATE TABLE IF NOT EXISTS organization_grants (
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'maintainer')),
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (organization, uid)
                );
                CREATE TABLE IF NOT EXISTS environment_grants (
                    app TEXT NOT NULL REFERENCES organization_projects(app) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    scope TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('viewer', 'operator', 'maintainer')),
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (app, uid, scope)
                );
                CREATE TABLE IF NOT EXISTS policies (
                    id TEXT PRIMARY KEY,
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    document TEXT NOT NULL,
                    created_by TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (organization, name)
                );
                CREATE TABLE IF NOT EXISTS groups (
                    id TEXT PRIMARY KEY,
                    organization TEXT NOT NULL REFERENCES organizations(slug) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    UNIQUE (organization, name)
                );
                CREATE TABLE IF NOT EXISTS group_members (
                    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (group_id, uid)
                );
                CREATE TABLE IF NOT EXISTS group_policies (
                    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    policy_id TEXT NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (group_id, policy_id)
                );
                CREATE TABLE IF NOT EXISTS policy_attachments (
                    policy_id TEXT NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
                    uid TEXT NOT NULL REFERENCES identities(uid) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (policy_id, uid)
                );
            """)
        os.chmod(path, 0o660)
        self.migrate_legacy_grants()

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
                db.execute("DELETE FROM organization_grants WHERE organization=? AND uid=?", (organization, uid))
                db.execute("DELETE FROM policy_attachments WHERE uid=? AND policy_id IN (SELECT id FROM policies WHERE organization=?)", (uid, organization))
                db.execute("DELETE FROM group_members WHERE uid=? AND group_id IN (SELECT id FROM groups WHERE organization=?)", (uid, organization))
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
                if g.get("group"):                          # join a group of this organization
                    if not db.execute("SELECT 1 FROM groups WHERE organization=? AND name=?", (organization, g["group"])).fetchone():
                        raise ValueError(f"group {g['group']!r} does not exist in this organization")
                    clean.append({"group": g["group"]})
                    continue
                app, role, scope = g.get("app", ""), g.get("role", ""), g.get("scope", "") or ""
                if role not in PROJECT_ROLES:
                    raise ValueError("grant role must be viewer, operator or maintainer")
                if scope and not ENV_SCOPE.fullmatch(scope):
                    raise ValueError("scope must be env:<name>, class:<class> or branch:<pattern>")
                if app == "*":                              # the whole organization
                    scope = ""
                elif not db.execute("SELECT 1 FROM organization_projects WHERE organization=? AND app=?", (organization, app)).fetchone():
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
            if g.get("group"):
                gid = self.group_id_by_name(inv["organization"], g["group"])
                if gid:
                    self.add_group_member(gid, uid)
            elif g["app"] == "*":
                self.grant_organization(inv["organization"], uid, g["role"])
            elif g["scope"]:
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

    def grant_organization(self, organization, uid, role):
        """A role on a whole organization: applies to every project below it, now and later."""
        if role not in PROJECT_ROLES | {"none"}:
            raise ValueError("role must be viewer, operator, maintainer, or none")
        with self.connect() as db:
            if role == "none":
                db.execute("DELETE FROM organization_grants WHERE organization=? AND uid=?", (organization, uid))
                return
            if not db.execute("SELECT 1 FROM organization_members WHERE organization=? AND uid=?", (organization, uid)).fetchone():
                raise ValueError("access requires membership in the organization")
            db.execute("""INSERT INTO organization_grants (organization, uid, role, created_at) VALUES (?, ?, ?, ?)
                          ON CONFLICT(organization, uid) DO UPDATE SET role=excluded.role""", (organization, uid, role, int(time.time())))

    def set_member_access(self, organization, uid, org_role, grants):
        """Replace EVERYTHING this person may do inside one organization, atomically (all or nothing).
        org_role: '' or a role for the whole organization. grants: [{"app", "scope" ('' = the whole project), "role"}]."""
        if org_role and org_role not in PROJECT_ROLES:
            raise ValueError("organization role must be viewer, operator or maintainer")
        wanted, seen = [], set()
        with self.connect() as db:
            if not db.execute("SELECT 1 FROM organization_members WHERE organization=? AND uid=?", (organization, uid)).fetchone():
                raise ValueError("that person is not a member of this organization")
            apps = {r["app"] for r in db.execute("SELECT app FROM organization_projects WHERE organization=?", (organization,))}
            for g in list(grants)[:500]:
                app, scope, role = g.get("app", ""), g.get("scope", "") or "", g.get("role", "")
                if app not in apps:
                    raise ValueError(f"{app or 'project'} does not belong to this organization")
                if role not in PROJECT_ROLES:
                    raise ValueError("role must be viewer, operator or maintainer")
                if scope and not ENV_SCOPE.fullmatch(scope):
                    raise ValueError("scope must be env:<name>, class:<class> or branch:<pattern>")
                if (app, scope) in seen:
                    raise ValueError(f"{app} {scope or 'whole project'} is listed twice")
                seen.add((app, scope)); wanted.append((app, scope, role))
            now = int(time.time())
            db.execute("DELETE FROM project_grants WHERE uid=? AND app IN (SELECT app FROM organization_projects WHERE organization=?)", (uid, organization))
            db.execute("DELETE FROM environment_grants WHERE uid=? AND app IN (SELECT app FROM organization_projects WHERE organization=?)", (uid, organization))
            db.execute("DELETE FROM organization_grants WHERE organization=? AND uid=?", (organization, uid))
            if org_role:
                db.execute("INSERT INTO organization_grants (organization, uid, role, created_at) VALUES (?, ?, ?, ?)", (organization, uid, org_role, now))
            for app, scope, role in wanted:
                if scope:
                    db.execute("INSERT INTO environment_grants (app, uid, scope, role, created_at) VALUES (?, ?, ?, ?, ?)", (app, uid, scope, role, now))
                else:
                    db.execute("INSERT INTO project_grants (app, uid, role, created_at) VALUES (?, ?, ?, ?)", (app, uid, role, now))

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
            org = db.execute("""SELECT og.role FROM organization_grants og JOIN organization_projects op ON op.organization=og.organization
                                WHERE og.uid=? AND op.app=?""", (uid, app)).fetchone()
            scoped = [row["role"] for row in db.execute(
                "SELECT scope, role FROM environment_grants WHERE uid=? AND app=?", (uid, app))
                if scope_matches(row["scope"], env, branch or "")]
        return strongest(org["role"] if org else None, project["role"] if project else None, *scoped)

    # ------------------------------------------------------------------ policies

    def statements_for(self, uid):
        """Every statement that applies to a person: quick-access grants compiled + attached custom policies."""
        with self.connect() as db:
            org_g = [(r["organization"], r["role"]) for r in db.execute(
                "SELECT organization, role FROM organization_grants WHERE uid=?", (uid,))]
            proj_g = [(r["organization"], r["app"], r["role"]) for r in db.execute(
                """SELECT op.organization, pg.app, pg.role FROM project_grants pg
                   JOIN organization_projects op ON op.app=pg.app WHERE pg.uid=?""", (uid,))]
            env_g = [(r["organization"], r["app"], r["scope"], r["role"]) for r in db.execute(
                """SELECT op.organization, eg.app, eg.scope, eg.role FROM environment_grants eg
                   JOIN organization_projects op ON op.app=eg.app WHERE eg.uid=?""", (uid,))]
            out = policy.compile_grants(org_g, proj_g, env_g)
            for r in db.execute("SELECT organization FROM organization_members WHERE uid=? AND role='org_admin'", (uid,)):
                out.append((f"organization admin of {r['organization']}", 0, policy.org_admin_statement(r["organization"])))
            for r in db.execute("""SELECT p.name, p.document, NULL AS grp FROM policies p
                                   JOIN policy_attachments a ON a.policy_id=p.id WHERE a.uid=?
                                   UNION
                                   SELECT p.name, p.document, g.name FROM policies p
                                   JOIN group_policies gp ON gp.policy_id=p.id JOIN groups g ON g.id=gp.group_id
                                   JOIN group_members gm ON gm.group_id=g.id WHERE gm.uid=? ORDER BY 1""", (uid, uid)):
                via = f" (via group {r['grp']})" if r["grp"] else ""
                for i, st in enumerate(json.loads(r["document"])["Statement"], 1):
                    out.append((f"policy {r['name']}{via} #{i}", i, st))
        return out

    def authorize(self, uid, action, app, env=None, branch="", platform_admin=False, statements=None):
        """→ (allowed, reason, matches). `env` None checks at project level (the resource is `org/app`)."""
        if platform_admin:
            return True, "platform-admin", []
        org = self.organization_for_project(app)
        if not org:
            return False, "implicit-deny", []
        resource = f"{org}/{app}" + (f"/{env}" if env else "")
        ctx = {"branch": branch or None, "class": policy_class(env) if env and env != "*" else None}
        decision, reason, matches = policy.evaluate(statements if statements is not None else self.statements_for(uid), action, resource, ctx)
        return decision == "allow", reason, matches

    def allowed_actions(self, uid, app, env, branch="", platform_admin=False, statements=None):
        if platform_admin:
            return sorted(policy.ACTIONS)
        org = self.organization_for_project(app)
        if not org:
            return []
        statements = statements if statements is not None else self.statements_for(uid)
        ctx = {"branch": branch or None, "class": policy_class(env)}
        resource = f"{org}/{app}/{env}"
        return sorted(a for a in policy.ACTIONS if policy.evaluate(statements, a, resource, ctx)[0] == "allow")

    def list_policies(self, organization=None):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM policies" + (" WHERE organization=?" if organization else "") + " ORDER BY organization, name",
                              (organization,) if organization else ()).fetchall()
            out = []
            for r in rows:
                d = dict(r)
                d["document"] = json.loads(d["document"])
                d["attached"] = [dict(x) for x in db.execute(
                    "SELECT i.uid, i.email FROM policy_attachments a JOIN identities i ON i.uid=a.uid WHERE a.policy_id=? ORDER BY i.email", (r["id"],))]
                out.append(d)
            return out

    def policy_organization(self, policy_id):
        with self.connect() as db:
            r = db.execute("SELECT organization FROM policies WHERE id=?", (policy_id,)).fetchone()
            return r["organization"] if r else None

    def save_policy(self, organization, name, description, document, created_by, policy_id=None):
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,59}$", name or ""):
            raise ValueError("policy name: 1-60 letters, digits, space, . _ -")
        now = int(time.time())
        with self.connect() as db:
            if policy_id:
                cur = db.execute("UPDATE policies SET name=?, description=?, document=?, updated_at=? WHERE id=? AND organization=?",
                                 (name, description[:300], json.dumps(document), now, policy_id, organization))
                if not cur.rowcount:
                    raise ValueError("policy not found")
                return policy_id
            pid = secrets.token_hex(8)
            try:
                db.execute("INSERT INTO policies (id, organization, name, description, document, created_by, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                           (pid, organization, name, description[:300], json.dumps(document), created_by, now, now))
            except sqlite3.IntegrityError:
                raise ValueError("a policy with that name already exists in this organization") from None
            return pid

    def delete_policy(self, policy_id):
        with self.connect() as db:
            db.execute("DELETE FROM policies WHERE id=?", (policy_id,))

    def attach_policy(self, policy_id, uid):
        with self.connect() as db:
            org = db.execute("SELECT organization FROM policies WHERE id=?", (policy_id,)).fetchone()
            if not org:
                raise ValueError("policy not found")
            if not db.execute("SELECT 1 FROM organization_members WHERE organization=? AND uid=?", (org["organization"], uid)).fetchone():
                raise ValueError("that person is not a member of the organization")
            db.execute("INSERT OR IGNORE INTO policy_attachments (policy_id, uid, created_at) VALUES (?,?,?)", (policy_id, uid, int(time.time())))

    # ------------------------------------------------------------------ groups

    def create_group(self, organization, name, description=""):
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$", name or ""):
            raise ValueError("group name: 1-40 letters, digits, space, . _ -")
        with self.connect() as db:
            if not db.execute("SELECT 1 FROM organizations WHERE slug=?", (organization,)).fetchone():
                raise ValueError("unknown organization")
            gid = secrets.token_hex(8)
            try:
                db.execute("INSERT INTO groups (id, organization, name, description, created_at) VALUES (?,?,?,?,?)",
                           (gid, organization, name, (description or "")[:300], int(time.time())))
            except sqlite3.IntegrityError:
                raise ValueError("a group with that name already exists in this organization") from None
            return gid

    def group_organization(self, group_id):
        with self.connect() as db:
            r = db.execute("SELECT organization FROM groups WHERE id=?", (group_id,)).fetchone()
            return r["organization"] if r else None

    def group_id_by_name(self, organization, name):
        with self.connect() as db:
            r = db.execute("SELECT id FROM groups WHERE organization=? AND name=?", (organization, name)).fetchone()
            return r["id"] if r else None

    def delete_group(self, group_id):
        with self.connect() as db:
            db.execute("DELETE FROM groups WHERE id=?", (group_id,))

    def add_group_member(self, group_id, uid):
        with self.connect() as db:
            g = db.execute("SELECT organization FROM groups WHERE id=?", (group_id,)).fetchone()
            if not g:
                raise ValueError("group not found")
            if not db.execute("SELECT 1 FROM organization_members WHERE organization=? AND uid=?", (g["organization"], uid)).fetchone():
                raise ValueError("that person is not a member of the organization")
            db.execute("INSERT OR IGNORE INTO group_members (group_id, uid, created_at) VALUES (?,?,?)", (group_id, uid, int(time.time())))

    def remove_group_member(self, group_id, uid):
        with self.connect() as db:
            db.execute("DELETE FROM group_members WHERE group_id=? AND uid=?", (group_id, uid))

    def attach_group_policy(self, group_id, policy_id):
        with self.connect() as db:
            g = db.execute("SELECT organization FROM groups WHERE id=?", (group_id,)).fetchone()
            p = db.execute("SELECT organization FROM policies WHERE id=?", (policy_id,)).fetchone()
            if not g or not p:
                raise ValueError("group or policy not found")
            if g["organization"] != p["organization"]:
                raise ValueError("the policy belongs to another organization")
            db.execute("INSERT OR IGNORE INTO group_policies (group_id, policy_id, created_at) VALUES (?,?,?)", (group_id, policy_id, int(time.time())))

    def detach_group_policy(self, group_id, policy_id):
        with self.connect() as db:
            db.execute("DELETE FROM group_policies WHERE group_id=? AND policy_id=?", (group_id, policy_id))

    def list_groups(self, organization=None):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM groups" + (" WHERE organization=?" if organization else "") + " ORDER BY organization, name",
                              (organization,) if organization else ()).fetchall()
            out = []
            for r in rows:
                d = dict(r)
                d["members"] = [dict(x) for x in db.execute(
                    "SELECT i.uid, i.email FROM group_members m JOIN identities i ON i.uid=m.uid WHERE m.group_id=? ORDER BY i.email", (r["id"],))]
                d["policies"] = [dict(x) for x in db.execute(
                    "SELECT p.id, p.name FROM group_policies gp JOIN policies p ON p.id=gp.policy_id WHERE gp.group_id=? ORDER BY p.name", (r["id"],))]
                out.append(d)
            return out

    def groups_of(self, organization, uid):
        with self.connect() as db:
            return [r["name"] for r in db.execute(
                "SELECT g.name FROM groups g JOIN group_members m ON m.group_id=g.id WHERE g.organization=? AND m.uid=? ORDER BY g.name",
                (organization, uid))]

    def migrate_legacy_grants(self):
        """Roles (viewer/operator/maintainer on an organization, project or environment pattern) are now just policies:
        turn any stored role grant into a policy attached to the same person, then drop the grant. Idempotent."""
        with self.connect() as db:
            people = db.execute("""SELECT DISTINCT o.slug AS organization, g.uid FROM (
                    SELECT organization, uid FROM organization_grants
                    UNION SELECT op.organization, pg.uid FROM project_grants pg JOIN organization_projects op ON op.app=pg.app
                    UNION SELECT op.organization, eg.uid FROM environment_grants eg JOIN organization_projects op ON op.app=eg.app
                ) g JOIN organizations o ON o.slug=g.organization""").fetchall()
        for person in people:
            org, uid = person["organization"], person["uid"]
            with self.connect() as db:
                org_g = [(org, r["role"]) for r in db.execute("SELECT role FROM organization_grants WHERE organization=? AND uid=?", (org, uid))]
                proj_g = [(org, r["app"], r["role"]) for r in db.execute(
                    """SELECT pg.app, pg.role FROM project_grants pg JOIN organization_projects op ON op.app=pg.app
                       WHERE op.organization=? AND pg.uid=?""", (org, uid))]
                env_g = [(org, r["app"], r["scope"], r["role"]) for r in db.execute(
                    """SELECT eg.app, eg.scope, eg.role FROM environment_grants eg JOIN organization_projects op ON op.app=eg.app
                       WHERE op.organization=? AND eg.uid=?""", (org, uid))]
                email = (db.execute("SELECT email FROM identities WHERE uid=?", (uid,)).fetchone() or {"email": uid})["email"]
            statements = [st for _, _, st in policy.compile_grants(org_g, proj_g, env_g)]
            if not statements:
                continue
            base = re.sub(r"[^A-Za-z0-9 _.-]", "-", "migrated " + email.split("@")[0])[:50]
            name, n = base, 1
            while True:
                try:
                    pid = self.save_policy(org, name, "Created from the person's former role grants", {"Statement": statements}, "migration")
                    break
                except ValueError:
                    n += 1
                    name = f"{base} {n}"
            self.attach_policy(pid, uid)
            with self.connect() as db:
                db.execute("DELETE FROM organization_grants WHERE organization=? AND uid=?", (org, uid))
                db.execute("""DELETE FROM project_grants WHERE uid=? AND app IN (SELECT app FROM organization_projects WHERE organization=?)""", (uid, org))
                db.execute("""DELETE FROM environment_grants WHERE uid=? AND app IN (SELECT app FROM organization_projects WHERE organization=?)""", (uid, org))

    def detach_policy(self, policy_id, uid):
        with self.connect() as db:
            db.execute("DELETE FROM policy_attachments WHERE policy_id=? AND uid=?", (policy_id, uid))

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
            org = db.execute("""SELECT og.role FROM organization_grants og JOIN organization_projects op ON op.organization=og.organization
                                WHERE og.uid=? AND op.app=?""", (uid, app)).fetchone()
            return strongest(org["role"] if org else None, row["role"] if row else None)

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
                   UNION SELECT app FROM environment_grants WHERE uid=?
                   UNION SELECT op.app FROM organization_projects op JOIN organization_grants og ON og.organization=op.organization WHERE og.uid=?
                   ORDER BY app""", (uid, uid, uid))]

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
            if platform_admin:
                org_rows = db.execute("""SELECT og.organization, og.uid, i.email, og.role FROM organization_grants og
                                         JOIN identities i ON i.uid=og.uid ORDER BY og.organization, i.email""").fetchall()
            else:
                org_rows = db.execute("""SELECT og.organization, og.uid, i.email, og.role FROM organization_grants og
                                         JOIN identities i ON i.uid=og.uid
                                         JOIN organization_members mine ON mine.organization=og.organization
                                         WHERE mine.uid=? AND mine.role='org_admin' ORDER BY og.organization, i.email""", (uid,)).fetchall()
            return {
                "organizations": [dict(row) for row in organizations],
                "identities": [dict(row) for row in identities],
                "projects": [dict(row) for row in projects],
                "members": [dict(row) for row in members],
                "organization_grants": [dict(row) for row in org_rows],
                "environment_grants": [dict(row) for row in env_rows],
                "invitations": self.list_invitations(uid, platform_admin),
            }

    def project_roles(self, uid, platform_admin=False):
        if platform_admin:
            return {}
        with self.connect() as db:
            roles = {row["app"]: row["role"] for row in db.execute(
                "SELECT app, role FROM project_grants WHERE uid=?", (uid,))}
            for row in db.execute("""SELECT op.app, og.role FROM organization_grants og JOIN organization_projects op
                                     ON op.organization=og.organization WHERE og.uid=?""", (uid,)):
                roles[row["app"]] = strongest(roles.get(row["app"]), row["role"])
            return roles
