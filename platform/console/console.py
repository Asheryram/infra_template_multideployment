#!/usr/bin/env python3
"""infra console: a web UI over the infra CLI for the DevOps engineer.

Runs as the platform container `infra-console`, behind Traefik's ops-auth. Every change goes
through bin/infra (the same code CI and the CLI use), so the three can never disagree.
Python stdlib only.
"""
import base64
import glob
import hashlib
import hmac
import html
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tarfile
import threading
import time
import urllib.error
import urllib.request
import secrets as token_source
import uuid
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlparse

import policy as policy_mod
from access import AccessStore, ENV_SCOPE, PROJECT_ROLES, ROLE_ORDER

INFRA_ROOT = os.environ["INFRA_ROOT"]
ENV_FILE = os.environ.get("INFRA_ENV_FILE", "/etc/infra/infra.env")
HERE = os.path.dirname(os.path.abspath(__file__))

NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
SCOPE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?(\.[a-z0-9-]+)?$")
KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SENSITIVE = re.compile(r"PASS|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|DATABASE_URL|DSN|AUTH", re.I)
PLATFORM_MANAGED_KEYS = {
    "APP_NAME", "APP_ENV", "ENV_CLASS", "IS_PREVIEW", "PORT", "PUBLIC_URL",
    "INFRA_DOMAIN", "IMAGE_TAG", "GIT_BRANCH", "GIT_COMMIT",
}
# Preview access (PREVIEW_AUTH_MODE=keycloak): Traefik asks /auth/preview before every preview request.
# Identity comes ONLY from the previews oauth2-proxy's answer for the browser's session cookie — never from
# request headers, which a client could forge. Access = a project role on the app (viewer or above) or platform admin.
PREVIEW_AUTH_URL = os.environ.get("INFRA_PREVIEW_AUTH_URL", "http://oauth2-previews:4180/oauth2/auth")
PREVIEW_SESSIONS = {}          # sha256(cookie) -> (expires, identity); short TTL so revoked access bites within seconds
PREVIEW_SEEN = set()           # uids already recorded in the access store (first sight registers the person)
# Account creation for invitations (optional). A dedicated Keycloak service-account client (infra-user-admin) lets the
# console CREATE accounts in the realm. Keycloak has no per-group delegation for this, so the console itself is
# deliberately create-only: it never reads, edits, resets or groups an account it did not just create, and it never
# touches the platform-admin group. Without KEYCLOAK_USER_ADMIN_SECRET invitations still work (accounts come from
# elsewhere: a platform admin, or the client's own identity provider).
KC_ADMIN_URL = os.environ.get("KEYCLOAK_ADMIN_URL", "http://infra-keycloak:8080").rstrip("/")
KC_ADMIN_CLIENT = os.environ.get("KEYCLOAK_USER_ADMIN_CLIENT", "infra-user-admin")
KC_ADMIN_SECRET = os.environ.get("KEYCLOAK_USER_ADMIN_SECRET", "")
KC_REALM = os.environ.get("KEYCLOAK_REALM", "infra")
INVITE_CREATE_ACCOUNTS = os.environ.get("INVITE_CREATE_ACCOUNTS", "true").lower() != "false"
KC_TOKEN = {"value": "", "exp": 0.0}
INVITE_LOG = {}                      # actor uid -> timestamps of recent invitations (rate limit)
INVITE_PER_HOUR = 30
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


# --------------------------------------------------------------------------- helpers

def read_env(path):
    """Parse KEY=value / KEY='value' files (our meta, overrides, secrets, runtime env)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip().removeprefix("export ").strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                if KEY.match(k):
                    out[k] = v
    except (FileNotFoundError, PermissionError):
        pass
    return out


def settings():
    s = read_env(ENV_FILE)
    get = lambda k, d: s.get(k) or d  # noqa: E731
    port = get("TRAEFIK_HTTPS_PORT", "443")
    suffix = "" if get("TLS_MODE", "selfsigned") == "external" or port == "443" else f":{port}"
    return {
        "domain": s.get("DOMAIN", ""),
        "suffix": suffix,
        "server": get("SERVER_NAME", os.uname().nodename),
        "deploy_root": get("DEPLOY_ROOT", "/srv/deployments"),
        "state_dir": get("STATE_DIR", "/var/lib/infra"),
        "secrets_root": get("SECRETS_ROOT", "/etc/infra/secrets"),
        "log_dir": get("LOG_DIR", "/var/log/infra"),
        "prefix": get("STACK_PREFIX", "infra"),
        "max_previews": get("MAX_PREVIEWS", "8"),
        "console_auth_mode": get("CONSOLE_AUTH_MODE", "basic"),
        "authentik_platform_admin_group": get("AUTHENTIK_PLATFORM_ADMIN_GROUP", "infra-platform-admins"),
        "keycloak_platform_admin_group": get("KEYCLOAK_PLATFORM_ADMIN_GROUP", "infra-platform-admins"),
        "invite_accounts": kc_enabled(),
    }


def access_store(s):
    return AccessStore(os.path.join(s["state_dir"], "console-access.sqlite3"))


def is_platform_admin(actor):
    return actor.get("platform_admin", False)


def may_change_org_member_role(actor, store, organization, target_uid, role):
    if is_platform_admin(actor):
        return True
    return (role != "org_admin"
            and store.organization_member_role(organization, target_uid) != "org_admin")


def preview_identity(cookie):
    """{uid, email, username, groups} for a preview session cookie, or None when not signed in."""
    if not cookie:
        return None
    key = hashlib.sha256(cookie.encode()).hexdigest()
    now = time.time()
    hit = PREVIEW_SESSIONS.get(key)
    if hit and hit[0] > now:
        return hit[1]
    request = urllib.request.Request(PREVIEW_AUTH_URL, headers={"Cookie": cookie})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            h = {k.lower(): v for k, v in response.headers.items()}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return None
        raise
    uid, email = h.get("x-auth-request-user", "").strip(), h.get("x-auth-request-email", "").strip()
    if not uid or not email or len(uid) > 200 or len(email) > 320:
        return None
    ident = {"uid": uid, "email": email, "username": h.get("x-auth-request-preferred-username", "").strip()[:200],
             "groups": h.get("x-auth-request-groups", "")}
    if len(PREVIEW_SESSIONS) > 500:
        PREVIEW_SESSIONS.clear()
    PREVIEW_SESSIONS[key] = (now + 15, ident)
    return ident


def deployment_branch(s, app, env):
    """Branch a deployment was built from (authoritative: the platform's own record, not a request header)."""
    d = f"{s['deploy_root']}/{app}/{env}"
    return read_env(f"{d}/meta.env").get("BRANCH") or read_env(f"{d}/status.env").get("BRANCH", "")


def require_action(actor, store, s, app, env, action):
    """Least privilege: the person needs `action` on `org/app/env` (env '*' = project-wide). Someone who cannot even
    LIST the environment gets 'not found', so its existence is not revealed."""
    if is_platform_admin(actor):
        return
    branch = deployment_branch(s, app, env) if env and env != "*" else ""
    statements = store.statements_for(actor["uid"])
    if store.authorize(actor["uid"], action, app, env, branch, statements=statements)[0]:
        return
    if not store.authorize(actor["uid"], "environment:List", app, env, branch, statements=statements)[0]:
        raise LookupError("not found")
    raise PermissionError(f"not allowed: {action}")


def scope_env(s, app, scope):
    """The deployed environment a variable scope belongs to (`pr-7`, `pr-7.api`), or None for project-wide scopes."""
    base = scope.split(".")[0]
    return base if NAME.match(base) and os.path.isdir(f"{s['deploy_root']}/{app}/{base}") else None


def require_scope_role(actor, store, s, app, scope, minimum="maintainer"):
    """Project-wide scopes (common, a class) need a project-wide role; an environment's own scopes also accept a
    grant scoped to that environment."""
    env = scope_env(s, app, scope)
    require_action(actor, store, s, app, env or "*", "variables:Write")


def kc_enabled():
    return bool(KC_ADMIN_SECRET) and INVITE_CREATE_ACCOUNTS


def kc_call(method, path, body=None, form=None, token=True, timeout=10):
    """→ (status, json-or-None, headers). Raises only on network errors."""
    headers = {}
    data = None
    if form is not None:
        data = urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + kc_token()
    request = urllib.request.Request(KC_ADMIN_URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as r:
            raw, status, hdrs = r.read(), r.status, dict(r.headers.items())
    except urllib.error.HTTPError as e:
        raw, status, hdrs = e.read(), e.code, dict(e.headers.items())
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        parsed = None
    return status, parsed, hdrs


def kc_token():
    if KC_TOKEN["value"] and KC_TOKEN["exp"] > time.time() + 30:
        return KC_TOKEN["value"]
    status, body, _ = kc_call("POST", f"/realms/{KC_REALM}/protocol/openid-connect/token", token=False,
                              form={"grant_type": "client_credentials", "client_id": KC_ADMIN_CLIENT, "client_secret": KC_ADMIN_SECRET})
    if status != 200 or not body or "access_token" not in body:
        raise RuntimeError(f"Keycloak refused the user-admin client (HTTP {status})")
    KC_TOKEN.update(value=body["access_token"], exp=time.time() + int(body.get("expires_in", 60)))
    return KC_TOKEN["value"]


def kc_create_account(email, name, console_url):
    """Create the Keycloak account for an invited email, create-only.
    → {"account": "existing"|"created", "delivery": None|"email"|"one-time-password", "password": <only for the fallback>}"""
    email = email.strip().lower()
    status, found, _ = kc_call("GET", f"/admin/realms/{KC_REALM}/users?" + urlencode({"email": email, "exact": "true"}))
    if status != 200:
        raise RuntimeError(f"could not look up the account (HTTP {status})")
    if found:
        return {"account": "existing", "delivery": None}
    status, realm, _ = kc_call("GET", f"/admin/realms/{KC_REALM}")
    smtp = bool(status == 200 and realm and (realm.get("smtpServer") or {}).get("host"))
    first, _, last = (name or email.split("@")[0]).strip().partition(" ")
    user = {"username": email, "email": email, "enabled": True, "emailVerified": not smtp,
            "firstName": first[:60] or "User", "lastName": (last.strip() or "-")[:60],
            "requiredActions": (["VERIFY_EMAIL", "UPDATE_PASSWORD"] if smtp else ["UPDATE_PASSWORD"])}
    status, _, headers = kc_call("POST", f"/admin/realms/{KC_REALM}/users", body=user)
    if status == 409:
        return {"account": "existing", "delivery": None}
    location = headers.get("Location") or headers.get("location") or ""
    if status != 201 or "/users/" not in location:
        raise RuntimeError(f"Keycloak did not create the account (HTTP {status})")
    uid = location.rsplit("/", 1)[1]
    if smtp:
        status, _, _ = kc_call("PUT", f"/admin/realms/{KC_REALM}/users/{uid}/execute-actions-email?" +
                               urlencode({"client_id": "infra-console", "redirect_uri": console_url, "lifespan": 7 * 86400}),
                               body=["VERIFY_EMAIL", "UPDATE_PASSWORD"])
        if status in (200, 204):
            return {"account": "created", "delivery": "email"}
    # No mail server (or it failed): a one-time password, shown once to the inviting admin, who vouches for the address.
    password = token_source.token_urlsafe(15).replace("-", "x").replace("_", "y")[:20]
    status, _, _ = kc_call("PUT", f"/admin/realms/{KC_REALM}/users/{uid}/reset-password",
                           body={"type": "password", "value": password, "temporary": True})
    if status not in (200, 204):
        raise RuntimeError(f"account created but its password could not be set (HTTP {status})")
    kc_call("PUT", f"/admin/realms/{KC_REALM}/users/{uid}", body={**user, "emailVerified": True, "requiredActions": ["UPDATE_PASSWORD"]})
    return {"account": "created", "delivery": "one-time-password", "password": password}


def invite_allowed(uid):
    now = time.time()
    recent = [t for t in INVITE_LOG.get(uid, []) if now - t < 3600]
    if len(recent) >= INVITE_PER_HOUR:
        INVITE_LOG[uid] = recent
        return False
    INVITE_LOG[uid] = recent + [now]
    return True


def mask(key, value):
    if not value or not SENSITIVE.search(key):
        return value
    return "••••••" + (value[-3:] if len(value) > 10 else "")


def mask_url(url):
    return re.sub(r"(://[^:/@]+:)[^@]*@", r"\1••••@", url or "")


def infra(*args, timeout=900, actor=None):
    """Run the infra CLI; returns (ok, output)."""
    env = dict(os.environ, INFRA_ACTOR=f"console:{actor}") if actor else None
    try:
        p = subprocess.run(["bash", os.path.join(INFRA_ROOT, "bin", "infra"), *args],
                           capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode == 0, ANSI.sub("", p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"


DB_UPLOAD_MAX = int(os.environ.get("DB_UPLOAD_MAX_MB", "1024")) * 1024 * 1024
DB_BACKUPS_KEPT = 3
DB_ID = re.compile(r"[a-z0-9-]+:[A-Za-z_][A-Za-z0-9_]*")


def db_work_dir(s, name):
    """Private scratch space under the state dir (owner-only): dumps in flight and the pre-restore backups."""
    d = os.path.join(s["state_dir"], name)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def sweep_old(d, max_age):
    for f in glob.glob(os.path.join(d, "*")):
        try:
            if time.time() - os.path.getmtime(f) > max_age:
                os.remove(f)
        except OSError:
            pass


def db_file_stem(app, env, db_id):
    return re.sub(r"[^A-Za-z0-9_.-]", "-", f"{app}-{env}-{db_id.split(':', 1)[-1].lower()}")


def prune_backups(d, stem):
    old = sorted(glob.glob(os.path.join(d, f"{stem}-*.dump")), key=os.path.getmtime, reverse=True)[DB_BACKUPS_KEPT:]
    for f in old:
        try:
            os.remove(f)
        except OSError:
            pass


def running_counts():
    p = subprocess.run(["docker", "ps", "--format", '{{.Label "com.docker.compose.project"}}'],
                       capture_output=True, text=True)
    counts = {}
    for line in p.stdout.splitlines():
        counts[line] = counts.get(line, 0) + 1
    return counts
    return ov


def env_class(env):
    return "preview" if env.startswith("pr-") else env


def components(manifest):
    """Service names declared in a deployment's infra.yml."""
    return list((manifest.get("services") or {}).keys())


def resource_memory_bytes(value):
    match = re.fullmatch(r"([1-9][0-9]{0,8})([kKmMgG])", str(value))
    if not match:
        raise ValueError(f"invalid memory limit: {value}")
    number, unit = int(match.group(1)), match.group(2).lower()
    return number * {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[unit]


def resource_cpu(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]{1,3})?", str(value)):
        raise ValueError(f"invalid CPU limit: {value}")
    try:
        number = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError(f"invalid CPU limit: {value}") from exc
    if not number.is_finite() or number <= 0:
        raise ValueError(f"invalid CPU limit: {value}")
    return number


def resource_settings(s):
    env = read_env(ENV_FILE)
    defaults = {
        "mem_limit": env.get("RESOURCE_DEFAULT_MEM_LIMIT", "512m"),
        "cpus": env.get("RESOURCE_DEFAULT_CPUS", "1.0"),
        "preview_mem_limit": env.get("RESOURCE_PREVIEW_MEM_LIMIT", "256m"),
        "preview_cpus": env.get("RESOURCE_PREVIEW_CPUS", "0.5"),
        "max_container_mem_limit": env.get("RESOURCE_MAX_CONTAINER_MEM_LIMIT", "1g"),
        "max_container_cpus": env.get("RESOURCE_MAX_CONTAINER_CPUS", "2.0"),
        "max_stack_mem_limit": env.get("RESOURCE_MAX_STACK_MEM_LIMIT", "2g"),
        "max_stack_cpus": env.get("RESOURCE_MAX_STACK_CPUS", "3.0"),
    }
    default_memory = resource_memory_bytes(defaults["mem_limit"])
    preview_memory = resource_memory_bytes(defaults["preview_mem_limit"])
    max_memory = resource_memory_bytes(defaults["max_container_mem_limit"])
    resource_memory_bytes(defaults["max_stack_mem_limit"])
    default_cpu = resource_cpu(defaults["cpus"])
    preview_cpu = resource_cpu(defaults["preview_cpus"])
    max_cpu = resource_cpu(defaults["max_container_cpus"])
    resource_cpu(defaults["max_stack_cpus"])
    if (default_memory > max_memory or preview_memory > max_memory
            or default_cpu > max_cpu or preview_cpu > max_cpu):
        raise ValueError("resource defaults exceed configured per-container ceilings")
    return defaults


def resource_file(s, app, scope, comp):
    return f"{s['state_dir']}/resources/{app}/{scope}.{comp}.env"


def resource_policy(s, app, env, candidate=None):
    deployment = f"{s['deploy_root']}/{app}/{env}"
    comps = components(load_manifest(f"{deployment}/deploy"))
    if not comps or not os.path.isdir(deployment):
        raise ValueError(f"deployment not found: {app}/{env}")
    defaults = resource_settings(s)
    cls = env_class(env)
    scopes = ["common"] + (["preview"] if env.startswith("pr-") else []) + [env]
    ordered = ["common"] + ([cls] if cls != "common" else []) + ([env] if env != cls else [])
    result = []
    for comp in comps:
        overrides = {}
        for scope in scopes:
            raw = read_env(resource_file(s, app, scope, comp))
            overrides[scope] = {
                "mem_limit": raw.get("MEM_LIMIT", ""),
                "cpus": raw.get("CPUS", ""),
            }
        if candidate and candidate["comp"] == comp:
            overrides[candidate["scope"]] = candidate["values"]
        effective = {
            "mem_limit": defaults["preview_mem_limit"] if cls == "preview" else defaults["mem_limit"],
            "cpus": defaults["preview_cpus"] if cls == "preview" else defaults["cpus"],
        }
        for scope in ordered:
            effective.update({key: value for key, value in overrides.get(scope, {}).items() if value})
        result.append({
            "component": comp,
            "effective": effective,
            "overrides": {scope: {
                "mem_limit": overrides[scope].get("mem_limit", ""),
                "cpus": overrides[scope].get("cpus", ""),
            } for scope in scopes},
        })
    return {"components": result, "defaults": defaults, "scopes": scopes}


def save_resource_override(s, app, scope, comp, mem_limit=None, cpus=None):
    path = resource_file(s, app, scope, comp)
    values = read_env(path)
    for key, value in (("MEM_LIMIT", mem_limit), ("CPUS", cpus)):
        if value is None:
            values.pop(key, None)
        else:
            values[key] = value
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    if not values:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    temporary = f"{path}.{uuid.uuid4().hex}.tmp"
    with open(temporary, "w") as handle:
        os.chmod(temporary, 0o600)
        for key in ("MEM_LIMIT", "CPUS"):
            if key in values:
                handle.write(f"{key}={values[key]}\n")
    os.replace(temporary, path)


def parse_manifest_field(yml, field):
    """Value of a top-level infra.yml field via the platform's validating parser (never executes repo content)."""
    r = subprocess.run(["python3", os.path.join(INFRA_ROOT, "scripts", "parse-manifest.py"), yml, "--field", field],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    out = r.stdout.strip()
    try:
        return json.loads(out)
    except ValueError:
        return out


def load_manifest(deploy_dir):
    """{"name": str, "services": {svc: cfg}} from <deploy_dir>/infra.yml, or {} when absent/invalid."""
    yml = os.path.join(deploy_dir, "infra.yml")
    if not os.path.isfile(yml):
        return {}
    svcs = parse_manifest_field(yml, "services")
    return {"name": parse_manifest_field(yml, "name") or "", "services": svcs if isinstance(svcs, dict) else {}}


def required_missing(s, app, env):
    """Keys the manifest requires that the environment's runtime env lacks."""
    d = f"{s['deploy_root']}/{app}/{env}"
    missing = []
    for svc, cfg in (load_manifest(f"{d}/deploy").get("services") or {}).items():
        have = read_env(f"{d}/runtime/{svc}.env")
        for key in (cfg.get("required_env") or []):
            if not have.get(str(key)):
                missing.append(f"{svc}:{key}")
    return missing


def available_keys(s, app, env, svc):
    """Keys an environment WOULD get on its next deploy."""
    cls = env_class(env)
    repo = f"{s['deploy_root']}/{app}/{env}/deploy/env"
    srv = f"{s['secrets_root']}/{app}"
    files = [f"{repo}/common.env", f"{repo}/{cls}.env", f"{repo}/{cls}.{svc}.env",
             f"{srv}/common.env", f"{srv}/{cls}.env", f"{srv}/{cls}.{svc}.env"]
    if env != cls:
        files += [f"{srv}/{env}.env", f"{srv}/{env}.{svc}.env"]
    keys = set()
    for f in files:
        keys |= {k for k, v in read_env(f).items() if v}
    return keys


def required_by_app(s):
    """{app: {(service, key)}} across every deployed branch."""
    req = {}
    for deploy_dir in glob.glob(f"{s['deploy_root']}/*/*/deploy"):
        app = deploy_dir.split("/")[-3]
        for svc, cfg in (load_manifest(deploy_dir).get("services") or {}).items():
            for key in (cfg.get("required_env") or []):
                req.setdefault(app, set()).add((svc, str(key)))
    return req


def deployments(s):
    counts = running_counts()
    required = required_by_app(s)
    rows = []
    for d in sorted(glob.glob(f"{s['deploy_root']}/*/*/")):
        app, env = d.rstrip("/").split("/")[-2:]
        meta = read_env(f"{d}meta.env")
        status = read_env(f"{d}status.env")
        if not meta and not status:
            continue
        m = dict(status, **meta) if meta else dict(status)
        m.update(APP=app, ENV_NAME=env)
        m["RUNNING"] = counts.get(f"{s['prefix']}-{app}-{env}", 0)
        m["STATE"] = "blocked" if status.get("STATUS") == "blocked" else ("up" if m["RUNNING"] else "down")
        m["MISSING"] = status.get("MISSING", "").split() if status else required_missing(s, app, env)
        created = [p[len(f"{d}.db_password_"):] for p in glob.glob(f"{d}.db_password_*")]
        m["HAS_OWN_DB"] = any(not os.path.exists(f"{d}.db_wiped_{n}") for n in created)
        m["DB_PENDING"] = m.get("DB_PENDING", "").split()
        svcs = components(load_manifest(f"{d}/deploy"))
        m["SERVICES"] = svcs
        m["UPCOMING_MISSING"] = sorted(
            f"{c}:{k}" for c, k in required.get(app, set())
            if c in svcs and f"{c}:{k}" not in m["MISSING"] and k not in available_keys(s, app, env, c))
        rows.append(m)
    return rows


def env_scopes(env, svc):
    """Console variable files that apply to <env>/<svc>."""
    cls = env_class(env)
    scopes = ["common", cls, f"{cls}.{svc}"]
    if env != cls:
        scopes += [env, f"{env}.{svc}"]
    return scopes


def env_variables(s, app, env):
    """Per component: every variable the container has (from its runtime env file), where it came
    from, plus console changes saved but not yet deployed (pending)."""
    d = f"{s['deploy_root']}/{app}/{env}"
    out = {}
    for f in sorted(glob.glob(f"{d}/runtime/*.env")):
        comp = os.path.basename(f)[:-4]
        applied, source = {}, ("platform", None)
        with open(f) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("# --- from "):
                    path = line[len("# --- from "):]
                    if path.startswith(f"{s['secrets_root']}/{app}/"):
                        source = ("console", os.path.basename(path)[:-4])
                    elif path.startswith(f"{d}/deploy/env/"):
                        source = ("repo", ".infradeploy/env/" + os.path.basename(path))
                    continue
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if KEY.match(k):
                    applied[k] = (v, *source)
        console = {}
        for scope in env_scopes(env, comp):
            for k, v in read_env(f"{s['secrets_root']}/{app}/{scope}.env").items():
                console[k] = (v, scope)
        rows = []
        for k in sorted(set(applied) | set(console)):
            av = applied.get(k)
            cv = console.get(k)
            if cv:
                value, origin, scope = cv[0], "console", cv[1]
                pending = av is None or av[0] != cv[0] or av[1] != "console" or av[2] != cv[1]
            else:
                value, origin, scope = av
                pending = origin == "console"          # deleted in the console, still in the container
            rows.append({"key": k, "value": mask(k, value), "sensitive": bool(SENSITIVE.search(k)),
                         "origin": "deleted" if (pending and not cv) else origin,
                         "scope": scope, "pending": pending, "editable": True})
        out[comp] = rows
    return out


def reveal_variable(s, app, env, comp, key):
    for scope in reversed(env_scopes(env, comp)):
        v = read_env(f"{s['secrets_root']}/{app}/{scope}.env").get(key)
        if v is not None:
            return v
    rt = read_env(f"{s['deploy_root']}/{app}/{env}/runtime/{comp}.env")
    return rt.get(key)


def secrets(s, app):
    out = {}
    for f in sorted(glob.glob(f"{s['secrets_root']}/{app}/*.env")):
        scope = os.path.basename(f)[:-4]
        out[scope] = [{"key": k, "value": mask(k, v), "sensitive": bool(SENSITIVE.search(k))}
                      for k, v in read_env(f).items()]
    return out


def set_secret(s, app, scope, key, value, actor="unknown"):
    d = f"{s['secrets_root']}/{app}"
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o2770)
    except PermissionError:
        pass
    path = f"{d}/{scope}.env"
    lines = []
    if os.path.exists(path):
        with open(path) as f:
            lines = [ln for ln in f.read().splitlines() if not re.match(rf"^(export\s+)?{key}=", ln)
                     and not re.match(rf"^# {key} (set|deleted) by ", ln)]
    else:
        lines = [f"# Variables for {app} ({scope}) — managed in the infra console / 'infra secrets edit'."]
    ts = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    if value is not None:
        lines.append(f"# {key} set by {actor} at {ts}")
        lines.append(f"{key}={value}")
    else:
        lines.append(f"# {key} deleted by {actor} at {ts}")
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o660)
    os.replace(tmp, path)


def tail(path, n=150):
    try:
        with open(path, errors="replace") as f:
            return f.readlines()[-n:]
    except FileNotFoundError:
        return []


# --------------------------------------------------------------------------- signed webhooks
# A registered project (infra project add) deploys by POSTing a signed request to
# https://hooks.<domain>/webhook. Protocol:
#   X-Infra-Project:   <app>                    (APP_NAME, must be registered)
#   X-Infra-Timestamp: <unix seconds>           (±300 s, replay window)
#   X-Infra-Signature: sha256=<hex HMAC-SHA256(secret, "<timestamp>." + raw body)>
#   body: {"action": "deploy"|"destroy", "repo": "owner/repo", "env": "pr-12", "tag": "sha-…",
#          "branch": "…", "commit": "…", "bundle": "<base64 tar.gz of the .infradeploy directory>"}
# → 202 {"job": id}. Poll GET /webhook/jobs/<id>, signed the same way over "<timestamp>.<id>".

WEBHOOK_MAX = 512 * 1024
BUNDLE_MAX = 256 * 1024
TAG_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{0,200}$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{0,64}$")
NONCES, JOBS = {}, {}
LOCK = threading.Lock()
WORKERS = threading.Semaphore(3)           # at most 3 deploys at once (same stack: serialized by flock)


def audit_line(s, user, action, detail):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} [console] user={user} {action} {detail}\n"
    try:
        with open(f"{s['log_dir']}/console.log", "a") as f:
            f.write(line)
    except OSError:
        pass


def project(s, app):
    return read_env(f"{s['state_dir']}/projects/{app}.env") if NAME.match(app or "") else {}


def verify_signature(s, headers, payload):
    """→ project dict, or raises PermissionError(reason). Order: project, signature, freshness, replay."""
    app = headers.get("X-Infra-Project", "")
    ts = headers.get("X-Infra-Timestamp", "")
    sig = headers.get("X-Infra-Signature", "")
    p = project(s, app)
    if not p.get("SECRET"):
        raise PermissionError("unknown project")
    expected = "sha256=" + hmac.new(p["SECRET"].encode(), ts.encode() + b"." + payload, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        raise PermissionError("bad signature")
    if not ts.isdigit() or abs(time.time() - int(ts)) > 300:
        raise PermissionError("stale timestamp")
    with LOCK:
        now = time.time()
        for k in [k for k, t in NONCES.items() if now - t > 600]:
            del NONCES[k]
        if sig in NONCES:
            raise PermissionError("replayed request")
        NONCES[sig] = now
    return p


def extract_bundle(s, b64, job_id):
    raw = base64.b64decode(b64 or "", validate=True)
    if not raw or len(raw) > BUNDLE_MAX:
        raise ValueError(f"bundle missing or larger than {BUNDLE_MAX // 1024} KB")
    d = os.path.join(s["state_dir"], "incoming", job_id)
    os.makedirs(d, mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as t:
        members = t.getmembers()
        if len(members) > 200 or sum(m.size for m in members) > 2 * 1024 * 1024:
            raise ValueError("bundle has too many or too large files")
        t.extractall(d, filter="data")     # rejects absolute paths, '..', links out, devices
    if not os.path.isfile(os.path.join(d, "infra.yml")):
        raise ValueError("bundle has no infra.yml at its root (tar the .infradeploy directory itself)")
    return d


def run_job(s, job_id, args, workdir, app, env):
    with WORKERS:
        JOBS[job_id]["status"] = "running"
        ok, out = infra(*args)
    meta = read_env(f"{s['deploy_root']}/{app}/{env}/meta.env") if ok and args[0] == "deploy" else {}
    JOBS[job_id].update(status="succeeded" if ok else "failed", ok=ok, output=out[-6000:], finished=time.time(),
                        url=meta.get("URL", ""), urls=meta.get("URLS", ""))
    if workdir:
        shutil.rmtree(workdir, ignore_errors=True)
    audit_line(s, f"webhook:{app}", f"{args[0]}:{'ok' if ok else 'FAILED'}", f"{app}/{env} job={job_id}")


def webhook(s, headers, payload):
    """→ (http code, body)."""
    try:
        p = verify_signature(s, headers, payload)
    except PermissionError as e:
        audit_line(s, f"webhook:{headers.get('X-Infra-Project', '?')}", "webhook:REJECTED", str(e))
        return 401, {"error": "unauthorized"}          # same answer for every auth failure
    app = p["APP"]
    try:
        body = json.loads(payload)
    except json.JSONDecodeError:
        return 400, {"error": "bad json"}

    def deny(reason):
        audit_line(s, f"webhook:{app}", "webhook:REJECTED", reason)
        return 403, {"error": reason}

    action, env = body.get("action"), body.get("env", "")
    if str(body.get("repo", "")).lower() != p.get("REPO", "").lower():
        return deny(f"repo {body.get('repo')!r} is not registered for {app}")
    if not NAME.match(env):
        return 400, {"error": "bad env"}
    allowed = [e.strip() for e in p.get("ENVS", "").split(",") if e.strip()]
    if env_class(env) not in allowed:
        return deny(f"environment {env} is not allowed for {app} (allowed: {', '.join(allowed)})")
    branch, tag, commit = body.get("branch", ""), body.get("tag", ""), body.get("commit", "")
    if not (BRANCH_RE.match(branch) and COMMIT_RE.match(commit)):
        return 400, {"error": "bad branch or commit"}

    with LOCK:  # forget finished jobs after a day
        for k in [k for k, j in JOBS.items() if time.time() - j["created"] > 86400]:
            del JOBS[k]
    job_id = uuid.uuid4().hex[:16]
    if action == "deploy":
        if env == "prod" and branch != p.get("PROD_BRANCH", "main"):
            return deny(f"prod deploys only from branch {p.get('PROD_BRANCH', 'main')}")
        if not TAG_RE.match(tag):
            return 400, {"error": "bad tag"}
        try:
            workdir = extract_bundle(s, body.get("bundle"), job_id)
        except (ValueError, tarfile.TarError, base64.binascii.Error) as e:
            return 400, {"error": f"bundle: {e}"}
        if parse_manifest_field(os.path.join(workdir, "infra.yml"), "name") != app:
            shutil.rmtree(workdir, ignore_errors=True)
            return deny(f"infra.yml name is not {app} (or infra.yml is invalid)")
        args = ["deploy", "--manifest", workdir, "--env", env, "--tag", tag, "--branch", branch, "--commit", commit]
    elif action == "destroy":
        if not env.startswith("pr-"):
            return deny("only preview environments can be destroyed by webhook")
        workdir, args = None, ["destroy", "--app", app, "--env", env]
    else:
        return 400, {"error": "action must be deploy or destroy"}

    JOBS[job_id] = {"app": app, "env": env, "action": action, "status": "queued", "created": time.time()}
    audit_line(s, f"webhook:{app}", f"webhook:{action}", f"{app}/{env} tag={tag} branch={branch} job={job_id}")
    threading.Thread(target=run_job, args=(s, job_id, args, workdir, app, env), daemon=True).start()
    return 202, {"job": job_id}


REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ENVS_RE = re.compile(r"^[a-z0-9-]+(,[a-z0-9-]+)*$")
SECRET_RE = re.compile(r"INFRA_WEBHOOK_SECRET\s+([0-9a-f]{64})")


def projects(s):
    """Registered projects — never includes secrets or tokens."""
    out = []
    for f in sorted(glob.glob(f"{s['state_dir']}/projects/*.env")):
        p = read_env(f)
        app = p.get("APP", "")
        out.append({
            "app": app, "repo": p.get("REPO", ""), "envs": p.get("ENVS", ""),
            "prod_branch": p.get("PROD_BRANCH", "main"),
            "registry_user": p.get("REGISTRY_USER", ""), "has_registry_token": bool(p.get("REGISTRY_TOKEN")),
            "has_gh_token": bool(p.get("GH_TOKEN")),
            "created_at": p.get("CREATED_AT", ""), "created_by": p.get("CREATED_BY", ""),
            "environments": sorted(os.path.basename(d.rstrip("/")) for d in glob.glob(f"{s['deploy_root']}/{app}/*/")),
        })
    return out


def webhook_url(s):
    return f"https://hooks.{s['domain']}{s['suffix']}/webhook"


def gitops_status():
    """Is the GitOps watcher running? Returns {running, pid}."""
    pid_file = "/tmp/infra-gitops.pid"
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, 0)   # signal 0 = just check existence
        return {"running": True, "pid": pid}
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
        return {"running": False, "pid": None}


def webhook_job(s, headers, job_id):
    try:
        p = verify_signature(s, headers, job_id.encode())
    except PermissionError:
        return 401, {"error": "unauthorized"}
    j = JOBS.get(job_id)
    if not j or j["app"] != p["APP"]:
        return 404, {"error": "no such job"}
    return 200, {k: v for k, v in j.items() if k != "created"}


# --------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "infra-console"

    def log_message(self, fmt, *args):  # quiet access log; Traefik already logs requests
        pass

    def actor(self, s):
        mode = s["console_auth_mode"]
        if mode == "basic":
            username = self.headers.get("X-Infra-User", "").strip()
            if not username:
                return None
            return {"uid": "basic:" + username, "username": username, "email": "",
                    "display_name": username, "platform_admin": True}
        if mode == "authentik":
            uid = self.headers.get("X-authentik-uid", "").strip()
            email = self.headers.get("X-authentik-email", "").strip()
            username = self.headers.get("X-authentik-username", "").strip()[:200]
            display_name = self.headers.get("X-authentik-name", "").strip()[:200]
            groups_header = self.headers.get("X-authentik-groups", "")
            admin_group = s["authentik_platform_admin_group"]
            uid_prefix = ""
        elif mode == "keycloak":
            uid = (self.headers.get("X-Forwarded-User") or
                   self.headers.get("X-Auth-Request-User", "")).strip()
            email = (self.headers.get("X-Forwarded-Email") or
                     self.headers.get("X-Auth-Request-Email", "")).strip()
            username = (self.headers.get("X-Forwarded-Preferred-Username") or
                        self.headers.get("X-Auth-Request-Preferred-Username", "")).strip()[:200]
            display_name = username or email
            groups_header = (self.headers.get("X-Forwarded-Groups") or
                             self.headers.get("X-Auth-Request-Groups", ""))
            admin_group = s["keycloak_platform_admin_group"]
            uid_prefix = "keycloak:"
        else:
            raise ValueError("CONSOLE_AUTH_MODE must be basic, authentik or keycloak")
        if not uid or not email or len(uid) > 200 or len(email) > 320:
            return None
        groups = {group.strip().strip("/") for group in re.split(r"[,;]", groups_header)
                  if group.strip()}
        store = access_store(s)
        identity = store.observe_identity(uid_prefix + uid, username, email, display_name)
        identity["platform_admin"] = admin_group in groups
        return identity

    def user(self):
        if self.headers.get("X-authentik-uid"):
            return self.headers.get("X-authentik-email") or "unknown"
        if self.headers.get("X-Forwarded-User") or self.headers.get("X-Auth-Request-User"):
            return (self.headers.get("X-Forwarded-Email") or
                    self.headers.get("X-Auth-Request-Email") or "unknown")
        return self.headers.get("X-Infra-User") or "unknown"

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def gate_signin(self, s):
        """Shared first half of every Traefik forwardAuth gate (previews, environments, ops tools).
        Returns the signed-in identity, or None after having answered (302 to Keycloak / 401 / 503)."""
        try:
            ident = preview_identity(self.headers.get("Cookie", ""))
        except Exception:
            self.send(503, b"Sign-in service unavailable", "text/plain; charset=utf-8")
            return None
        sso = f"https://sso.{s['domain']}{s['suffix']}"
        if ident is None:
            if self.headers.get("X-Forwarded-Method", "GET").upper() not in ("GET", "HEAD"):
                self.send(401, b"Sign in required", "text/plain; charset=utf-8")
                return None
            proto = "http" if self.headers.get("X-Forwarded-Proto") == "http" else "https"
            host, uri = self.headers.get("X-Forwarded-Host", ""), self.headers.get("X-Forwarded-Uri", "/")
            hostname = host.split(":")[0].lower()
            back = (f"{proto}://{host}{uri}" if (hostname.endswith("." + s["domain"]) and uri.startswith("/"))
                    else sso + "/")           # a spoofed host never becomes a redirect target
            self.send_response(302)
            self.send_header("Location", f"{sso}/oauth2/start?rd={quote(back, safe='')}")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        uid = "keycloak:" + ident["uid"]
        if uid not in PREVIEW_SEEN:           # register the person so an admin can grant them access by email
            access_store(s).observe_identity(uid, ident["username"], ident["email"], ident["username"] or ident["email"])
            PREVIEW_SEEN.add(uid)
        ident["key"] = uid
        ident["is_admin"] = s["keycloak_platform_admin_group"] in {
            g.strip().strip("/") for g in re.split(r"[,;]", ident["groups"]) if g.strip()}
        return ident

    def no_access_page(self, s, ident, what):
        sso = f"https://sso.{s['domain']}{s['suffix']}"
        pending = access_store(s).pending_for_email(ident["email"])
        invite_hint = (f"<p><b>You have a pending invitation.</b> <a href='https://console.{html.escape(s['domain'])}{html.escape(s['suffix'])}/'>"
                       "Open the console to accept it</a>, then come back.</p>") if pending else ""
        page = (
            "<!doctype html><html lang='en'><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'><title>No access</title>"
            "<body style='font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:14vh auto;padding:1rem;color:#17181c'>"
            f"<h1 style='font-size:1.4rem'>You don't have access to {html.escape(what[0])}</h1>"
            f"<p>You are signed in as <b>{html.escape(ident['email'])}</b>. {what[1]}</p>{invite_hint}"
            f"<p><a href='{html.escape(sso)}/oauth2/sign_out?rd={quote('https://console.' + s['domain'] + s['suffix'] + '/signed-out', safe='')}'>Sign out</a></p></body></html>"
        )
        return self.send(403, page.encode(), "text/html; charset=utf-8")

    def preview_gate(self, s, q):
        """Traefik forwardAuth target for environments with auth on. 200 = let through, 302 = go sign in, 403 = no access.
        Who may pass: a platform admin, or anyone whose role (project-wide, or an environment/class/branch grant)
        covers that environment."""
        app = q.get("app", "")
        if s["console_auth_mode"] != "keycloak" or not NAME.match(app):
            return self.send(404, {"error": "not found"})
        ident = self.gate_signin(s)
        if ident is None:
            return
        env = q.get("env", "")
        env = env if NAME.match(env) else ""                       # no env (old labels): project-wide roles only
        allowed = ident["is_admin"] or access_store(s).authorize(
            ident["key"], "environment:Open", app, env or None, deployment_branch(s, app, env) if env else "")[0]
        if allowed:
            return self.send(200, {"ok": True})
        return self.no_access_page(s, ident, (
            "this environment",
            f"You have no role on <b>{html.escape(app)}</b>{(' that covers <b>' + html.escape(env) + '</b>') if env else ''}. "
            "Ask a project maintainer or organization administrator to grant you access "
            "(your account is already registered under this email)."))

    def platform_gate(self, s):
        """Traefik forwardAuth target for the platform's own tools (Traefik dashboard, container logs):
        signed in with Keycloak AND a platform administrator."""
        if s["console_auth_mode"] != "keycloak":
            return self.send(404, {"error": "not found"})
        ident = self.gate_signin(s)
        if ident is None:
            return
        if ident["is_admin"]:
            return self.send(200, {"ok": True})
        return self.no_access_page(s, ident, ("this tool", "It is limited to platform administrators."))

    def audit(self, s, action, detail):
        audit_line(s, self.user(), action, detail)

    def db_restore(self, s, actor, store):
        """POST /api/dbrestore?app&env&db with the dump file as the raw body. Replaces that database's data; the
        current data is dumped to a backup first, and the environment is redeployed afterwards."""
        q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
        app, env, db = q.get("app", ""), q.get("env", ""), q.get("db", "")
        if not (NAME.match(app) and NAME.match(env) and DB_ID.fullmatch(db)):
            return self.send(400, {"error": "bad app, environment or database id"})
        try:
            require_action(actor, store, s, app, env, "database:Restore")
        except LookupError:
            return self.send(404, {"error": "not found"})
        except PermissionError as e:
            return self.send(403, {"error": str(e)})
        if self.headers.get("X-Confirm") != f"{app}/{env}":
            return self.send(400, {"error": f"type {app}/{env} to confirm"})
        if env == "prod" and self.headers.get("X-Allow-Prod") != "yes":
            return self.send(400, {"error": "restoring into prod needs an explicit prod confirmation"})
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return self.send(400, {"error": "no file received"})
        if length > DB_UPLOAD_MAX:
            return self.send(413, {"error": f"file too large (limit {DB_UPLOAD_MAX // 1048576} MB)"})
        work = db_work_dir(s, "db-transfer")
        sweep_old(work, 3600)
        upload = os.path.join(work, f"upload-{token_source.token_hex(8)}.dump")
        try:
            remaining, first = length, b""
            with open(upload, "wb") as fh:
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1 << 20))
                    if not chunk:
                        return self.send(400, {"error": "upload ended early"})
                    first = first or chunk[:5]
                    fh.write(chunk)
                    remaining -= len(chunk)
            if first != b"PGDMP":
                return self.send(400, {"error": "not a pg_dump custom-format file (make it with: pg_dump -Fc --no-owner --no-acl)"})
            backups = db_work_dir(s, "db-backups")
            stem = db_file_stem(app, env, db)
            backup = os.path.join(backups, f"{stem}-{time.strftime('%Y%m%d-%H%M%S')}.dump")
            self.audit(s, "db:restore", f"{app}/{env} {db} {length} bytes")
            ok, out = infra("db", "dump", app, env, backup, "--db", db, timeout=1800, actor=self.user())
            if not (ok and os.path.exists(backup)):
                return self.send(200, {"ok": False, "output": "Nothing was changed: the current data could not be backed up first.\n" + mask_url(out)})
            prune_backups(backups, stem)
            args = ["db", "restore", app, env, upload, "--db", db] + (["--i-really-mean-prod"] if env == "prod" else [])
            ok, out = infra(*args, timeout=3600, actor=self.user())
            self.audit(s, f"db:restore:{'ok' if ok else 'FAILED'}", f"{app}/{env} {db}")
            out = mask_url(out) + chr(10) + f"Previous data saved as {os.path.basename(backup)} (kept: last {DB_BACKUPS_KEPT})."
            if ok:
                ok2, out2 = infra("redeploy", app, env, timeout=600, actor=self.user())
                ok, out = ok and ok2, out + chr(10) + out2
            return self.send(200, {"ok": ok, "output": out})
        finally:
            try:
                os.remove(upload)
            except OSError:
                pass

    def db_dump(self, s, actor, store, q):
        app, env, db = q.get("app", ""), q.get("env", ""), q.get("db", "")
        if not (NAME.match(app) and NAME.match(env) and DB_ID.fullmatch(db)):
            return self.send(400, {"error": "bad app, environment or database id"})
        require_action(actor, store, s, app, env, "database:Dump")
        work = db_work_dir(s, "db-transfer")
        sweep_old(work, 3600)
        out_file = os.path.join(work, f"dump-{token_source.token_hex(8)}.dump")
        self.audit(s, "db:dump", f"{app}/{env} {db}")
        try:
            ok, out = infra("db", "dump", app, env, out_file, "--db", db, timeout=1800, actor=self.user())
            if not (ok and os.path.exists(out_file)):
                return self.send(500, {"error": mask_url(out)[-400:] or "dump failed"})
            size = os.path.getsize(out_file)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", f'attachment; filename="{db_file_stem(app, env, db)}-{time.strftime("%Y%m%d-%H%M%S")}.dump"')
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(out_file, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile, 1 << 20)
        finally:
            try:
                os.remove(out_file)
            except OSError:
                pass

    def via_hooks_host(self):
        """Requests arriving on hooks.<domain> (no ops login) may ONLY reach /webhook."""
        return self.headers.get("Host", "").split(":")[0].startswith("hooks.")

    def route_webhook(self, method):
        """Handle /webhook*; returns True if the request was handled here."""
        path = urlparse(self.path).path
        if not path.startswith("/webhook"):
            if self.via_hooks_host():
                self.send(404, {"error": "not found"})
                return True
            return False
        s = settings()
        if method == "POST" and path == "/webhook":
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length > WEBHOOK_MAX:
                self.send(413, {"error": "payload too large"})
                return True
            code, body = webhook(s, self.headers, self.rfile.read(length))
        elif method == "GET" and re.fullmatch(r"/webhook/jobs/[0-9a-f]{16}", path):
            code, body = webhook_job(s, self.headers, path.rsplit("/", 1)[1])
        else:
            code, body = 404, {"error": "not found"}
        self.send(code, body)
        return True

    # ---- GET
    def do_GET(self):
        if self.route_webhook("GET"):
            return
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        s = settings()
        try:
            if u.path == "/healthz":
                return self.send(200, {"ok": True})
            if u.path == "/signed-out" and s["console_auth_mode"] == "keycloak":
                page = (
                    "<!doctype html><html lang='en'><meta charset='utf-8'>"
                    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                    "<title>Signed out - Infra Console</title>"
                    "<body style='font:16px system-ui,sans-serif;max-width:36rem;margin:15vh auto;padding:1rem'>"
                    "<h1>You are signed out</h1>"
                    "<p>Your Infra Console, preview and Keycloak sessions have all ended. You will be asked for your password again.</p>"
                    "<p><a href='/'>Sign in again</a></p></body></html>"
                )
                return self.send(200, page, "text/html; charset=utf-8")
            if u.path == "/auth/preview":
                return self.preview_gate(s, q)
            if u.path == "/auth/platform":
                return self.platform_gate(s)
            actor = self.actor(s)
            if actor is None:
                return self.send(401, {"error": "authentication required"})
            store = access_store(s)
            if u.path == "/":
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if u.path == "/api/state":
                rows = deployments(s)
                roles = store.project_roles(actor["uid"], is_platform_admin(actor))
                statements = None if is_platform_admin(actor) else store.statements_for(actor["uid"])
                for row in rows:           # what this person may do in each ENVIRONMENT (actions); role kept for display
                    row["ALLOW"] = store.allowed_actions(actor["uid"], row["APP"], row["ENV_NAME"], row.get("BRANCH", ""),
                                                         is_platform_admin(actor), statements)
                    row["ROLE"] = "platform_admin" if is_platform_admin(actor) else policy_mod.role_of(row["ALLOW"])
                if not is_platform_admin(actor):
                    rows = [row for row in rows if "environment:List" in row["ALLOW"]]
                access = store.list_access(actor["uid"], is_platform_admin(actor))
                access["platform_admin"] = is_platform_admin(actor)
                access["project_roles"] = roles
                access["environment_grants_mine"] = [] if is_platform_admin(actor) else store.environment_grants_for(actor["uid"])
                access["my_invitations"] = store.pending_for_email(actor.get("email", ""))
                access["auth_mode"] = s["console_auth_mode"]
                return self.send(200, {"settings": s, "user": actor["display_name"],
                                       "access": access, "deployments": rows})
            if u.path == "/api/policies":
                memberships = store.list_access(actor["uid"])["organizations"]
                if not (is_platform_admin(actor) or any(o["role"] == "org_admin" for o in memberships)):
                    return self.send(403, {"error": "organization administration required"})
                administered = None if is_platform_admin(actor) else {o["slug"] for o in memberships if o["role"] == "org_admin"}
                pols = [p for p in store.list_policies() if administered is None or p["organization"] in administered]
                groups = [g for g in store.list_groups() if administered is None or g["organization"] in administered]
                return self.send(200, {"policies": pols, "groups": groups, "actions": policy_mod.catalog(), "levels": policy_mod.LEVELS,
                                       "presets": {k: {"name": v["name"], "description": v["description"], "actions": v["actions"]}
                                                   for k, v in policy_mod.PRESETS.items()},
                                       "condition_keys": list(policy_mod.CONDITION_KEYS)})
            if u.path == "/api/access":
                if s["console_auth_mode"] not in ("authentik", "keycloak"):
                    return self.send(409, {"error": "tenant access management requires an identity-provider mode"})
                memberships = store.list_access(actor["uid"])["organizations"]
                if not (is_platform_admin(actor) or
                        any(org["role"] == "org_admin" for org in memberships)):
                    return self.send(403, {"error": "organization administration required"})
                access = store.list_access(actor["uid"], is_platform_admin(actor))
                access["platform_admin"] = is_platform_admin(actor)
                administered = {p["app"] for p in access["projects"]}          # projects of organizations this person administers
                access["environments"] = [{"app": d["APP"], "env": d["ENV_NAME"], "branch": d.get("BRANCH", "")}
                                          for d in deployments(s) if d["APP"] in administered]
                mine = None if is_platform_admin(actor) else {p["app"] for p in access["projects"]}   # apps of organizations I administer
                access["project_links"] = [l for l in store.list_links() if mine is None or (l["consumer"] in mine and l["provider"] in mine)]
                registered = projects(s) if is_platform_admin(actor) else []
                return self.send(200, {"access": access, "registered_projects": registered})
            if u.path == "/api/env":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_action(actor, store, s, app, env, "environment:View")
                role = "platform_admin" if is_platform_admin(actor) else policy_mod.role_of(store.allowed_actions(actor["uid"], app, env, deployment_branch(s, app, env)))
                see_values = is_platform_admin(actor) or store.authorize(actor["uid"], "variables:ReadValues", app, env, deployment_branch(s, app, env))[0]
                d = f"{s['deploy_root']}/{app}/{env}"
                runtime = {}
                for f in sorted(glob.glob(f"{d}/runtime/*.env")):
                    runtime[os.path.basename(f)[:-4]] = [{"key": k, "value": mask(k, v)} for k, v in read_env(f).items()]
                if not see_values:
                    for rows in runtime.values():
                        for row in rows:
                            row["value"] = "••••••"
                man = load_manifest(f"{d}/deploy")
                return self.send(200, {"runtime": runtime, "manifest": {"name": man.get("name", ""), "services": {
                    k: {f: v for f, v in cfg.items() if f in ("image", "port", "health_path", "required_env")}
                    for k, cfg in (man.get("services") or {}).items()}}, "role": role})
            if u.path == "/api/secrets":
                app = q.get("app", "")
                if not NAME.match(app):
                    return self.send(400, {"error": "bad app"})
                files = secrets(s, app)
                if not is_platform_admin(actor):
                    st = store.statements_for(actor["uid"])
                    can = lambda env: store.authorize(actor["uid"], "variables:Write", app, env,
                                                      deployment_branch(s, app, env) if env != "*" else "", statements=st)[0]
                    if not can("*"):
                        # scoped writers only see (and may edit) the variable files of their own environments
                        files = {sc: rows for sc, rows in files.items() if scope_env(s, app, sc) and can(scope_env(s, app, sc))}
                        if not files and not any(can(os.path.basename(d)) for d in glob.glob(f"{s['deploy_root']}/{app}/*")):
                            raise LookupError("not found")
                role = "maintainer"
                return self.send(200, {"files": files,
                                       "can_manage": is_platform_admin(actor) or role == "maintainer"})
            if u.path == "/api/logs":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_action(actor, store, s, app, env, "logs:Read")
                ok, out = infra("tail", app, env, str(min(int(q.get("n", 200)), 2000)), timeout=60)
                return self.send(200, {"ok": ok, "output": out})
            if u.path == "/api/database":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_action(actor, store, s, app, env, "database:Describe")
                allow = lambda a: is_platform_admin(actor) or store.authorize(actor["uid"], a, app, env, deployment_branch(s, app, env))[0]
                ok, out = infra("db", "info", app, env, "--json", timeout=30)
                try:
                    info = json.loads(out.strip().splitlines()[-1])
                except (ValueError, IndexError):
                    return self.send(200, {"error": out[-500:]})
                for item in info.get("databases", []):
                    item["url_masked"] = mask_url(item.pop("url", ""))   # full URLs only ever go into variables, server-side
                info["can_manage"] = allow("database:Create")
                info["can_wipe"] = allow("database:Wipe")
                info["can_dump"] = allow("database:Dump")
                info["can_restore"] = allow("database:Restore")
                info["can_reveal"] = allow("database:RevealUrl")
                return self.send(200, info)
            if u.path == "/api/database/dump":
                return self.db_dump(s, actor, store, q)
            if u.path == "/api/database/reveal":
                app, env, db = q.get("app", ""), q.get("env", ""), q.get("db", "")
                if not (NAME.match(app) and NAME.match(env)
                        and re.fullmatch(r"[a-z0-9-]+:[A-Za-z_][A-Za-z0-9_]*", db)):
                    return self.send(400, {"error": "bad request"})
                require_action(actor, store, s, app, env, "database:RevealUrl")
                ok, out = infra("db", "url", app, env, "--db", db, timeout=30)
                url = next((ln.strip() for ln in reversed(out.splitlines()) if ln.strip().startswith("postgres://")), "")
                if not (ok and url):
                    return self.send(404, {"error": "database is not created"})
                self.audit(s, "db-reveal", f"{app}/{env} {db}")
                return self.send(200, {"url": url})
            if u.path == "/api/vars":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_action(actor, store, s, app, env, "variables:List")
                branch = deployment_branch(s, app, env)
                editable = is_platform_admin(actor) or store.authorize(actor["uid"], "variables:Write", app, env, branch)[0]
                readable = is_platform_admin(actor) or store.authorize(actor["uid"], "variables:ReadValues", app, env, branch)[0]
                variables = env_variables(s, app, env)
                for rows in variables.values():
                    for row in rows:
                        row["editable"] = editable
                        if not readable:
                            row["value"] = "••••••"
                return self.send(200, {"components": variables})
            if u.path == "/api/resources":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_action(actor, store, s, app, env, "resources:Read")
                try:
                    policy = resource_policy(s, app, env)
                    policy["can_manage"] = is_platform_admin(actor) or store.authorize(actor["uid"], "resources:Write", app, env, deployment_branch(s, app, env))[0]
                    return self.send(200, policy)
                except ValueError:
                    return self.send(200, {"components": [], "can_manage": False})
            if u.path == "/api/reveal":
                app, env, comp, key = q.get("app", ""), q.get("env", ""), q.get("comp", ""), q.get("key", "")
                if not (NAME.match(app) and NAME.match(env) and NAME.match(comp) and KEY.match(key)):
                    return self.send(400, {"error": "bad request"})
                require_action(actor, store, s, app, env, "secrets:Reveal")
                self.audit(s, "reveal", f"{app}/{env} {comp}:{key}")
                return self.send(200, {"value": reveal_variable(s, app, env, comp, key)})
            if u.path == "/api/projects":
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "platform administrator required"})
                return self.send(200, {"projects": projects(s), "webhook_url": webhook_url(s),
                                       "gitops": gitops_status()})
            if u.path == "/api/activity":
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "platform administrator required"})
                lines = tail(f"{s['log_dir']}/console.log", 100) + tail(f"{s['log_dir']}/deploy.log", 150)
                lines = [ln for ln in lines if ln[:4].isdigit()]
                lines.sort()
                return self.send(200, {"lines": lines[-200:]})
            return self.send(404, {"error": "not found"})
        except LookupError:
            return self.send(404, {"error": "not found"})
        except PermissionError as e:
            return self.send(403, {"error": str(e)})
        except (ValueError, sqlite3.IntegrityError) as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:  # never leak a stack trace to the page
            return self.send(500, {"error": str(e)})

    # ---- POST
    def do_POST(self):
        if self.route_webhook("POST"):
            return
        # CSRF guard: browsers can't send this header cross-site without a CORS preflight we never allow.
        if self.headers.get("X-Infra-Console") != "1":
            return self.send(403, {"error": "missing console header"})
        s = settings()
        try:
            actor = self.actor(s)
        except ValueError as e:
            return self.send(503, {"error": str(e)})
        if actor is None:
            return self.send(401, {"error": "authentication required"})
        store = access_store(s)
        if urlparse(self.path).path == "/api/dbrestore":          # raw file body, not JSON
            return self.db_restore(s, actor, store)
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        except json.JSONDecodeError:
            return self.send(400, {"error": "bad json"})
        u = urlparse(self.path).path
        try:
            if u == "/api/access":
                if s["console_auth_mode"] not in ("authentik", "keycloak"):
                    return self.send(409, {"error": "tenant access management requires an identity-provider mode"})
                operation = body.get("op", "")
                if operation == "organization-create":
                    if not is_platform_admin(actor):
                        return self.send(403, {"error": "platform administrator required"})
                    store.create_organization(body.get("slug", ""), body.get("name", ""))
                    self.audit(s, "organization:create", body["slug"])
                elif operation == "project-link":
                    if not is_platform_admin(actor):
                        return self.send(403, {"error": "platform administrator required"})
                    organization, app = body.get("organization", ""), body.get("app", "")
                    if not project(s, app).get("APP"):
                        return self.send(400, {"error": "register the project before assigning it to an organization"})
                    store.link_project(organization, app)
                    self.audit(s, "organization:link-project", f"{organization}/{app}")
                elif operation == "member":
                    organization, role = body.get("organization", ""), body.get("role", "")
                    if not store.can_admin_organization(actor["uid"], organization,
                                                        is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    if role == "none":                       # removal: resolve the person ONLY among this organization's members
                        uid = body.get("uid") or store.member_uid_by_email(organization, body.get("email", ""))
                        if not uid:
                            return self.send(400, {"error": "that person is not a member of this organization"})
                    elif not is_platform_admin(actor):
                        return self.send(400, {"error": "use Invite to add people: the invitee accepts it themselves"})
                    else:                                    # platform admin: direct add of a known account
                        uid = body.get("uid") or store.identity_uid(body.get("email", ""))
                    if not may_change_org_member_role(actor, store, organization, uid, role):
                        return self.send(403, {"error": "only a platform administrator may assign or change organization administrators"})
                    store.set_member(organization, uid, role)
                    self.audit(s, "organization:member", f"{organization} uid={uid} role={role}")
                elif operation == "invite":
                    organization = body.get("organization", "")
                    if not store.can_admin_organization(actor["uid"], organization, is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    member_role = body.get("member_role", "member")
                    if member_role == "org_admin" and not is_platform_admin(actor):
                        return self.send(403, {"error": "only a platform administrator may invite an organization administrator"})
                    if not invite_allowed(actor["uid"]):
                        return self.send(429, {"error": f"invitation limit reached ({INVITE_PER_HOUR} per hour)"})
                    email = body.get("email", "")
                    grants = body.get("grants", [])
                    if not isinstance(grants, list):
                        return self.send(400, {"error": "grants must be a list"})
                    invitation = store.create_invitation(organization, email, actor["uid"], grants, member_role)
                    account = {"account": "skipped", "delivery": None}
                    if body.get("create_account", True) and kc_enabled():
                        try:
                            account = kc_create_account(email, body.get("name", ""),
                                                        f"https://console.{s['domain']}{s['suffix']}/")
                        except Exception as e:                 # the invitation stands; the admin sees why no account was made
                            account = {"account": "error", "delivery": None, "error": str(e)[:200]}
                    self.audit(s, "organization:invite", f"{organization} email={email.strip().lower()} "
                                                          f"role={member_role} grants={len(grants)} account={account['account']}")
                    return self.send(200, {"ok": True, "id": invitation, "account": account})
                elif operation == "invitation-revoke":
                    invitation_id = body.get("id", "")
                    organization = store.invitation_organization(invitation_id)
                    if not organization:
                        return self.send(404, {"error": "no such invitation"})
                    if not store.can_admin_organization(actor["uid"], organization, is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    store.revoke_invitation(invitation_id, organization)
                    self.audit(s, "organization:invite-revoke", f"{organization} id={invitation_id}")
                elif operation in ("link-create", "link-delete", "link-apply"):
                    if operation == "link-create":
                        consumer, provider = body.get("consumer", ""), body.get("provider", "")
                    else:
                        link = store.get_link(body.get("id", ""))
                        if not link:
                            return self.send(404, {"error": "no such link"})
                        consumer, provider = link["consumer"], link["provider"]
                    if not store.can_manage_link(actor["uid"], consumer, provider, is_platform_admin(actor)):
                        return self.send(403, {"error": "a platform administrator (or the administrator of the organization both projects belong to) manages links"})
                    if operation == "link-create":
                        for app in (consumer, provider):
                            if not project(s, app).get("APP"):
                                return self.send(400, {"error": f"{app} is not a registered project"})
                        lid = store.create_link(consumer, body.get("service", ""), body.get("path", ""), provider, body.get("provider_service", ""),
                                                body.get("strip") is True, body.get("hide_provider") is True, actor["uid"],
                                                mode=body.get("mode", "paths") or "paths", excludes=body.get("excludes", "") or "")
                        self.audit(s, "link:create", f"{consumer}/{body.get('service')} {body.get('path')} -> {provider}/{body.get('provider_service')}")
                        return self.send(200, {"ok": True, "id": lid})
                    if operation == "link-delete":
                        store.delete_link(link["id"])
                        self.audit(s, "link:delete", f"{consumer}/{link['service']} {link['path']} -> {provider}")
                    else:                                    # redeploy every environment of both projects so the change takes effect
                        done = []
                        for d in deployments(s):
                            if d["APP"] in (consumer, provider) and d.get("STATE") != "blocked":
                                ok, _ = infra("redeploy", d["APP"], d["ENV_NAME"])
                                done.append(f"{d['APP']}/{d['ENV_NAME']}:{'ok' if ok else 'FAILED'}")
                        self.audit(s, "link:apply", " ".join(done))
                        return self.send(200, {"ok": True, "redeployed": done})
                elif operation in ("group-create", "group-delete", "group-member-add", "group-member-remove",
                                   "group-policy-attach", "group-policy-detach"):
                    gid = body.get("id", "")
                    organization = body.get("organization", "") if operation == "group-create" else store.group_organization(gid)
                    if not organization:
                        return self.send(404, {"error": "no such group"})
                    if not store.can_admin_organization(actor["uid"], organization, is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    if operation == "group-create":
                        gid = store.create_group(organization, (body.get("name") or "").strip(), body.get("description", ""))
                        self.audit(s, "group:create", f"{organization} name={body.get('name', '')}")
                        return self.send(200, {"ok": True, "id": gid})
                    if operation == "group-delete":
                        store.delete_group(gid)
                    elif operation == "group-member-add":
                        store.add_group_member(gid, body.get("uid", ""))
                    elif operation == "group-member-remove":
                        store.remove_group_member(gid, body.get("uid", ""))
                    elif operation == "group-policy-attach":
                        store.attach_group_policy(gid, body.get("policy", ""))
                    else:
                        store.detach_group_policy(gid, body.get("policy", ""))
                    self.audit(s, operation.replace("-", ":", 1), f"{organization} group={gid} uid={body.get('uid', '')} policy={body.get('policy', '')}")
                elif operation in ("policy-save", "policy-delete", "policy-attach", "policy-detach"):
                    pid = body.get("id", "")
                    organization = store.policy_organization(pid) if pid else body.get("organization", "")
                    if not organization:
                        return self.send(404, {"error": "no such policy"})
                    if not store.can_admin_organization(actor["uid"], organization, is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    if operation == "policy-save":
                        doc = policy_mod.validate_document(body.get("document"), organization, is_platform_admin(actor))
                        pid = store.save_policy(organization, body.get("name", ""), body.get("description", "") or "", doc,
                                                actor["uid"], pid or None)
                        self.audit(s, "policy:save", f"{organization} id={pid} name={body.get('name', '')} statements={len(doc['Statement'])}")
                        return self.send(200, {"ok": True, "id": pid})
                    if operation == "policy-delete":
                        store.delete_policy(pid)
                        self.audit(s, "policy:delete", f"{organization} id={pid}")
                    elif operation == "policy-attach":
                        store.attach_policy(pid, body.get("uid", ""))
                        self.audit(s, "policy:attach", f"{organization} id={pid} uid={body.get('uid', '')}")
                    else:
                        store.detach_policy(pid, body.get("uid", ""))
                        self.audit(s, "policy:detach", f"{organization} id={pid} uid={body.get('uid', '')}")
                else:
                    return self.send(400, {"error": "unknown access operation"})
                return self.send(200, {"ok": True})

            if u == "/api/simulate":
                organization, uid, app = body.get("organization", ""), body.get("uid", ""), body.get("app", "")
                if not store.can_admin_organization(actor["uid"], organization, is_platform_admin(actor)):
                    return self.send(403, {"error": "organization administrator required"})
                if not NAME.match(app) or store.organization_for_project(app) != organization:
                    return self.send(400, {"error": "that project is not in this organization"})
                if not store.organization_member_role(organization, uid):
                    return self.send(400, {"error": "that person is not a member of this organization"})
                env = body.get("env", "") or None
                if env and not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
                branch = body.get("branch") if body.get("branch") is not None else (deployment_branch(s, app, env) if env else "")
                allowed = store.allowed_actions(uid, app, env, branch or "") if env else []
                result = {"allowed_actions": allowed, "branch": branch or ""}
                action = body.get("action", "")
                if action:
                    if action not in policy_mod.ACTIONS:
                        return self.send(400, {"error": "unknown action"})
                    ok, reason, matches = store.authorize(uid, action, app, env, branch or "")
                    result.update({"action": action, "allowed": ok, "reason": reason,
                                   "matches": [{"source": src, "statement": st} for src, _, st in matches]})
                return self.send(200, result)

            if u == "/api/invitations":
                invitation_id = body.get("id", "")
                if not actor.get("email"):
                    return self.send(400, {"error": "your account has no email address"})
                if body.get("op") == "accept":
                    organization = store.accept_invitation(actor["uid"], actor["email"], invitation_id)
                    self.audit(s, "organization:invite-accept", f"{organization} uid={actor['uid']}")
                elif body.get("op") == "decline":
                    store.decline_invitation(actor["email"], invitation_id)
                    self.audit(s, "organization:invite-decline", f"id={invitation_id}")
                else:
                    return self.send(400, {"error": "op must be accept or decline"})
                return self.send(200, {"ok": True})

            if u == "/api/gitops":
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "platform administrator required"})
                op = body.get("op", "")
                interval = int(body.get("interval", 30))
                pid_file = "/tmp/infra-gitops.pid"
                watcher = os.path.join(INFRA_ROOT, "local", "watch-repo.sh")
                if op == "start":
                    st = gitops_status()
                    if st["running"]:
                        return self.send(200, {"ok": True, "output": f"already running (pid {st['pid']})"})
                    log_path = "/tmp/infra-gitops.log"
                    with open(log_path, "a") as lf:
                        proc = subprocess.Popen(
                            ["bash", watcher, "--interval", str(interval)],
                            stdout=lf, stderr=lf, start_new_session=True)
                    with open(pid_file, "w") as pf:
                        pf.write(str(proc.pid))
                    self.audit(s, "gitops:start", f"pid={proc.pid} interval={interval}")
                    return self.send(200, {"ok": True, "output": f"GitOps watcher started (pid {proc.pid}), logging to {log_path}"})
                elif op == "stop":
                    st = gitops_status()
                    if not st["running"]:
                        return self.send(200, {"ok": True, "output": "not running"})
                    os.kill(st["pid"], 15)  # SIGTERM
                    try:
                        os.remove(pid_file)
                    except FileNotFoundError:
                        pass
                    self.audit(s, "gitops:stop", f"pid={st['pid']}")
                    return self.send(200, {"ok": True, "output": f"GitOps watcher stopped (pid {st['pid']})"})
                elif op == "logs":
                    lines = tail("/tmp/infra-gitops.log", 100)
                    return self.send(200, {"ok": True, "output": "".join(lines)})
                return self.send(400, {"error": "op must be start, stop or logs"})

            app = body.get("app", "")
            if not NAME.match(app):
                return self.send(400, {"error": "bad app"})

            if u == "/api/project":
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "platform administrator required"})
                op = body.get("op", "")
                repo, envs = body.get("repo", ""), body.get("envs", "")
                prod_branch = body.get("prod_branch", "")
                reg_user, reg_token = body.get("registry_user", ""), body.get("registry_token", "")
                gh_token = body.get("gh_token", "")
                if repo and not REPO_RE.match(repo):
                    return self.send(400, {"error": "repo must look like owner/repo"})
                if envs and not ENVS_RE.match(envs):
                    return self.send(400, {"error": "environments must be a comma list, e.g. preview,develop"})
                if prod_branch and not BRANCH_RE.match(prod_branch):
                    return self.send(400, {"error": "bad prod branch"})
                if any(c in reg_user + reg_token + gh_token for c in "'\n\r\" "):
                    return self.send(400, {"error": "tokens contain invalid characters"})
                opts = []
                for flag, val in (("--repo", repo), ("--envs", envs), ("--prod-branch", prod_branch),
                                  ("--registry-user", reg_user), ("--registry-token", reg_token),
                                  ("--gh-token", gh_token)):
                    if val:
                        opts += [flag, val]
                if op == "add":
                    if not repo:
                        return self.send(400, {"error": "repo is required"})
                    args = ["project", "add", app, *opts]
                elif op == "set":
                    args = ["project", "set", app, *opts]
                elif op == "rotate":
                    args = ["project", "rotate-secret", app]
                elif op == "remove":
                    if body.get("confirm") != app:
                        return self.send(400, {"error": f"type {app} to confirm"})
                    args = ["project", "remove", app]
                else:
                    return self.send(400, {"error": "unknown op"})
                ok, out = infra(*args, timeout=60, actor=self.user())
                m = SECRET_RE.search(out)
                secret = m.group(1) if m else ""
                if secret:
                    out = out.replace(secret, "••••••")          # the secret is returned once, separately
                self.audit(s, f"project:{op}{'' if ok else ':FAILED'}", f"{app} {('repo=' + repo) if repo else ''}")
                return self.send(200, {"ok": ok, "output": out, "secret": secret, "webhook_url": webhook_url(s)})

            if u == "/api/secrets/bulk":
                scope = body.get("scope", "common")
                require_scope_role(actor, store, s, app, scope, "maintainer")
                pairs = body.get("pairs", [])
                if not SCOPE.match(scope):
                    return self.send(400, {"error": "bad scope"})
                if not isinstance(pairs, list) or len(pairs) > 200:
                    return self.send(400, {"error": "bad pairs"})
                saved = []
                for item in pairs:
                    k, v = item.get("key", ""), item.get("value", "")
                    if not KEY.match(k) or k in PLATFORM_MANAGED_KEYS:
                        continue
                    if "\n" in v or "\r" in v:
                        continue
                    set_secret(s, app, scope, k, v, actor=self.user())
                    saved.append(k)
                self.audit(s, "variable:bulk", f"{app} scope={scope} keys={','.join(saved)}")
                return self.send(200, {"ok": True, "saved": saved})

            if u == "/api/secret":
                scope, key, value = body.get("scope", ""), body.get("key", ""), body.get("value")
                require_scope_role(actor, store, s, app, scope, "maintainer")
                if not SCOPE.match(scope) or not KEY.match(key):
                    return self.send(400, {"error": "bad scope or key"})
                if value is not None and key in PLATFORM_MANAGED_KEYS:
                    return self.send(400, {"error": f"{key} is managed by the platform and cannot be overridden"})
                if value is not None and ("\n" in value or "\r" in value):
                    return self.send(400, {"error": "values can't contain newlines"})
                set_secret(s, app, scope, key, value, actor=self.user())
                self.audit(s, "variable", f"{app} scope={scope} key={key} {'deleted' if value is None else 'set'}")
                return self.send(200, {"ok": True})

            if u == "/api/resources":
                env, comp, scope = body.get("env", ""), body.get("component", ""), body.get("scope", "")
                if not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
                # limits of one environment need resources:Write there; `common`/`preview` span the project's environments
                require_action(actor, store, s, app, env if scope == env else "*", "resources:Write")
                policy = resource_policy(s, app, env)
                if comp not in [item["component"] for item in policy["components"]]:
                    return self.send(400, {"error": "component is not part of this deployment"})
                if scope not in policy["scopes"]:
                    return self.send(400, {"error": "scope must be this environment, preview, or common"})

                reset = body.get("reset") is True
                if reset:
                    values = {"mem_limit": "", "cpus": ""}
                    mem_limit = cpus = None
                else:
                    mem_limit, cpus = body.get("mem_limit"), body.get("cpus")
                    if not isinstance(mem_limit, str) or not isinstance(cpus, str):
                        return self.send(400, {"error": "memory and CPU limits are required"})
                    try:
                        max_mem = resource_memory_bytes(policy["defaults"]["max_container_mem_limit"])
                        if resource_memory_bytes(mem_limit) > max_mem:
                            raise ValueError("memory limit exceeds the per-container ceiling")
                        max_cpu = resource_cpu(policy["defaults"]["max_container_cpus"])
                        if resource_cpu(cpus) > max_cpu:
                            raise ValueError("CPU limit exceeds the per-container ceiling")
                    except ValueError as exc:
                        return self.send(400, {"error": str(exc)})
                    values = {"mem_limit": mem_limit, "cpus": cpus}

                candidate = {"comp": comp, "scope": scope, "values": values}
                revised = resource_policy(s, app, env, candidate)
                try:
                    max_stack_mem = resource_memory_bytes(policy["defaults"]["max_stack_mem_limit"])
                    max_stack_cpu = resource_cpu(policy["defaults"]["max_stack_cpus"])
                    total_mem = sum(resource_memory_bytes(item["effective"]["mem_limit"])
                                    for item in revised["components"])
                    total_cpu = sum((resource_cpu(item["effective"]["cpus"])
                                     for item in revised["components"]), Decimal(0))
                except ValueError as exc:
                    return self.send(400, {"error": str(exc)})
                if total_mem > max_stack_mem or total_cpu > max_stack_cpu:
                    return self.send(400, {"error": "combined component limits exceed this stack's configured ceiling"})
                save_resource_override(s, app, scope, comp, mem_limit, cpus)
                self.audit(s, "resource-policy", f"{app}/{env} scope={scope} component={comp} "
                                                   f"{'reset' if reset else f'mem={mem_limit} cpus={cpus}'}")
                return self.send(200, {"ok": True})

            if u == "/api/action":
                env, action = body.get("env", ""), body.get("action", "")
                if not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
                if action in ("redeploy", "rollback", "restart"):
                    require_action(actor, store, s, app, env, {"redeploy": "environment:Redeploy", "restart": "environment:Restart",
                                                              "rollback": "environment:Rollback"}[action])
                    args = [action, app, env]
                elif action == "destroy":
                    require_action(actor, store, s, app, env, "environment:Destroy")
                    if body.get("confirm") != f"{app}/{env}":
                        return self.send(400, {"error": f"type {app}/{env} to confirm"})
                    args = ["destroy", "--app", app, "--env", env] + (["--i-really-mean-prod"] if env == "prod" else [])
                else:
                    return self.send(400, {"error": "unknown action"})
                self.audit(s, action, f"{app}/{env}")
                ok, out = infra(*args)
                self.audit(s, f"{action}:{'ok' if ok else 'FAILED'}", f"{app}/{env}")
                return self.send(200, {"ok": ok, "output": out})

            if u == "/api/dbop":
                env, op = body.get("env", ""), body.get("op", "")
                if not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
                db_id = body.get("db", "")
                if db_id and not re.fullmatch(r"[a-z0-9-]+:[A-Za-z_][A-Za-z0-9_]*", db_id):
                    return self.send(400, {"error": "bad database id"})
                db_args = ["--db", db_id] if db_id else []
                if op == "create":
                    require_action(actor, store, s, app, env, "database:Create")
                    args = ["db", "create", app, env, *db_args]
                elif op == "wipe":
                    require_action(actor, store, s, app, env, "database:Wipe")
                    if body.get("confirm") != f"{app}/{env}":
                        return self.send(400, {"error": f"type {app}/{env} to confirm"})
                    args = ["db", "wipe", app, env, *db_args] + (["--i-really-mean-prod"] if env == "prod" else [])
                elif op == "use":
                    require_action(actor, store, s, app, env, "database:Use")
                    src, key, scope = body.get("from", f"{app}/{env}"), body.get("key", "DATABASE_URL"), body.get("scope", env)
                    if not (re.fullmatch(r"[a-z0-9-]+/[a-z0-9-]+", src) and KEY.match(key) and SCOPE.match(scope)):
                        return self.send(400, {"error": "bad source, key or scope"})
                    args = ["db", "use", app, env, "--from", src, "--key", key, "--scope", scope, *db_args]
                    if body.get("allow_prod"):
                        args.append("--allow-prod")
                else:
                    return self.send(400, {"error": "unknown op"})
                self.audit(s, f"db:{op}", f"{app}/{env} {body.get('from', '')} {body.get('key', '')}".strip())
                ok, out = infra(*args, timeout=120, actor=self.user())
                if ok and op in ("create", "wipe"):      # apply now: inject (or stop injecting) the URL and run migrations
                    ok2, out2 = infra("redeploy", app, env, timeout=600, actor=self.user())
                    ok, out = ok and ok2, out + chr(10) + out2
                return self.send(200, {"ok": ok, "output": mask_url(out)})

            return self.send(404, {"error": "not found"})
        except LookupError:
            return self.send(404, {"error": "not found"})
        except PermissionError as e:
            return self.send(403, {"error": str(e)})
        except (ValueError, sqlite3.IntegrityError) as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:
            return self.send(500, {"error": str(e)})


if __name__ == "__main__":
    print("infra console listening on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
