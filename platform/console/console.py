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
import uuid
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

from access import AccessStore, PROJECT_ROLES, ROLE_ORDER

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


def require_project_role(actor, store, app, minimum="viewer"):
    role = store.role_for_project(actor["uid"], app, is_platform_admin(actor))
    if role == "platform_admin":
        return role
    if role not in PROJECT_ROLES or ROLE_ORDER[role] < ROLE_ORDER[minimum]:
        raise PermissionError("project access denied")
    return role


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

    def preview_gate(self, s, q):
        """Traefik forwardAuth target for preview environments. 200 = let through, 302 = go sign in, 403 = no access."""
        app = q.get("app", "")
        if s["console_auth_mode"] != "keycloak" or not NAME.match(app):
            return self.send(404, {"error": "not found"})
        try:
            ident = preview_identity(self.headers.get("Cookie", ""))
        except Exception:
            return self.send(503, b"Sign-in service unavailable", "text/plain; charset=utf-8")
        sso = f"https://sso.{s['domain']}{s['suffix']}"
        if ident is None:
            if self.headers.get("X-Forwarded-Method", "GET").upper() not in ("GET", "HEAD"):
                return self.send(401, b"Sign in required", "text/plain; charset=utf-8")
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
            return
        uid = "keycloak:" + ident["uid"]
        store = access_store(s)
        if uid not in PREVIEW_SEEN:           # register the person so an admin can grant them access by email
            store.observe_identity(uid, ident["username"], ident["email"], ident["username"] or ident["email"])
            PREVIEW_SEEN.add(uid)
        groups = {g.strip().strip("/") for g in re.split(r"[,;]", ident["groups"]) if g.strip()}
        role = store.role_for_project(uid, app, s["keycloak_platform_admin_group"] in groups)
        if role == "platform_admin" or role in PROJECT_ROLES:
            return self.send(200, {"ok": True})
        page = (
            "<!doctype html><html lang='en'><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'><title>No access</title>"
            "<body style='font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:14vh auto;padding:1rem;color:#17181c'>"
            f"<h1 style='font-size:1.4rem'>You don't have access to this preview</h1>"
            f"<p>You are signed in as <b>{html.escape(ident['email'])}</b>, but you have no role on "
            f"<b>{html.escape(app)}</b>.</p>"
            "<p>Ask a project maintainer or organization administrator to grant you the <b>viewer</b> role "
            "(your account is already registered under this email).</p>"
            f"<p><a href='{html.escape(sso)}/oauth2/sign_out'>Sign out</a></p></body></html>"
        )
        return self.send(403, page.encode(), "text/html; charset=utf-8")

    def audit(self, s, action, detail):
        audit_line(s, self.user(), action, detail)

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
                    "<p>Your Infra Console session has ended. Your Keycloak session may still be active.</p>"
                    "<p><a href='/'>Sign in again</a></p></body></html>"
                )
                return self.send(200, page, "text/html; charset=utf-8")
            if u.path == "/auth/preview":
                return self.preview_gate(s, q)
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
                visible = set(store.visible_apps(actor["uid"], is_platform_admin(actor)))
                if not is_platform_admin(actor):
                    rows = [row for row in rows if row["APP"] in visible]
                for row in rows:
                    row["ROLE"] = roles.get(row["APP"], "platform_admin" if is_platform_admin(actor) else "")
                access = store.list_access(actor["uid"], is_platform_admin(actor))
                access["platform_admin"] = is_platform_admin(actor)
                access["project_roles"] = roles
                access["auth_mode"] = s["console_auth_mode"]
                return self.send(200, {"settings": s, "user": actor["display_name"],
                                       "access": access, "deployments": rows})
            if u.path == "/api/access":
                if s["console_auth_mode"] not in ("authentik", "keycloak"):
                    return self.send(409, {"error": "tenant access management requires an identity-provider mode"})
                memberships = store.list_access(actor["uid"])["organizations"]
                if not (is_platform_admin(actor) or
                        any(org["role"] == "org_admin" for org in memberships)):
                    return self.send(403, {"error": "organization administration required"})
                access = store.list_access(actor["uid"], is_platform_admin(actor))
                access["platform_admin"] = is_platform_admin(actor)
                registered = projects(s) if is_platform_admin(actor) else []
                return self.send(200, {"access": access, "registered_projects": registered})
            if u.path == "/api/env":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                role = require_project_role(actor, store, app)
                d = f"{s['deploy_root']}/{app}/{env}"
                runtime = {}
                for f in sorted(glob.glob(f"{d}/runtime/*.env")):
                    runtime[os.path.basename(f)[:-4]] = [{"key": k, "value": mask(k, v)} for k, v in read_env(f).items()]
                if role not in ("maintainer", "platform_admin") and not is_platform_admin(actor):
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
                role = require_project_role(actor, store, app, "maintainer")
                return self.send(200, {"files": secrets(s, app),
                                       "can_manage": is_platform_admin(actor) or role == "maintainer"})
            if u.path == "/api/logs":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_project_role(actor, store, app)
                ok, out = infra("tail", app, env, str(min(int(q.get("n", 200)), 2000)), timeout=60)
                return self.send(200, {"ok": ok, "output": out})
            if u.path == "/api/database":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                role = require_project_role(actor, store, app)
                ok, out = infra("db", "info", app, env, "--json", timeout=30)
                try:
                    info = json.loads(out.strip().splitlines()[-1])
                except (ValueError, IndexError):
                    return self.send(200, {"error": out[-500:]})
                for item in info.get("databases", []):
                    item["url_masked"] = mask_url(item.pop("url", ""))   # full URLs only ever go into variables, server-side
                info["can_manage"] = is_platform_admin(actor) or role == "maintainer"
                info["can_wipe"] = is_platform_admin(actor)
                info["can_reveal"] = is_platform_admin(actor)
                return self.send(200, info)
            if u.path == "/api/database/reveal":
                app, env, db = q.get("app", ""), q.get("env", ""), q.get("db", "")
                if not (NAME.match(app) and NAME.match(env)
                        and re.fullmatch(r"[a-z0-9-]+:[A-Za-z_][A-Za-z0-9_]*", db)):
                    return self.send(400, {"error": "bad request"})
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "only a platform administrator may reveal a database URL"})
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
                role = require_project_role(actor, store, app)
                variables = env_variables(s, app, env)
                editable = is_platform_admin(actor) or role == "maintainer"
                for rows in variables.values():
                    for row in rows:
                        row["editable"] = editable
                        if not editable:
                            row["value"] = "••••••"
                return self.send(200, {"components": variables})
            if u.path == "/api/resources":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                require_project_role(actor, store, app)
                try:
                    policy = resource_policy(s, app, env)
                    policy["can_manage"] = is_platform_admin(actor)
                    return self.send(200, policy)
                except ValueError:
                    return self.send(200, {"components": [], "can_manage": is_platform_admin(actor)})
            if u.path == "/api/reveal":
                app, env, comp, key = q.get("app", ""), q.get("env", ""), q.get("comp", ""), q.get("key", "")
                if not (NAME.match(app) and NAME.match(env) and NAME.match(comp) and KEY.match(key)):
                    return self.send(400, {"error": "bad request"})
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "only a platform administrator may reveal secret values"})
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
                    uid = body.get("uid") or store.identity_uid(body.get("email", ""))
                    if not may_change_org_member_role(actor, store, organization, uid, role):
                        return self.send(403, {"error": "only a platform administrator may assign or change organization administrators"})
                    store.set_member(organization, uid, role)
                    self.audit(s, "organization:member", f"{organization} uid={uid} role={role}")
                elif operation == "project-grant":
                    app, uid, role = body.get("app", ""), body.get("uid", ""), body.get("role", "")
                    organization = store.organization_for_project(app)
                    if not organization:
                        return self.send(400, {"error": "project is not assigned to an organization"})
                    if not store.can_admin_organization(actor["uid"], organization,
                                                        is_platform_admin(actor)):
                        return self.send(403, {"error": "organization administrator required"})
                    store.grant_project(app, uid, role)
                    self.audit(s, "project:grant", f"{app} uid={uid} role={role}")
                else:
                    return self.send(400, {"error": "unknown access operation"})
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
                require_project_role(actor, store, app, "maintainer")
                scope = body.get("scope", "common")
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
                require_project_role(actor, store, app, "maintainer")
                scope, key, value = body.get("scope", ""), body.get("key", ""), body.get("value")
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
                if not is_platform_admin(actor):
                    return self.send(403, {"error": "only a platform administrator may change resource limits"})
                env, comp, scope = body.get("env", ""), body.get("component", ""), body.get("scope", "")
                if not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
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
                    require_project_role(actor, store, app, "operator")
                    args = [action, app, env]
                elif action == "destroy":
                    if not is_platform_admin(actor):
                        return self.send(403, {"error": "only a platform administrator may destroy an environment"})
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
                    require_project_role(actor, store, app, "maintainer")
                    args = ["db", "create", app, env, *db_args]
                elif op == "wipe":
                    if not is_platform_admin(actor):
                        return self.send(403, {"error": "only a platform administrator may wipe a database"})
                    if body.get("confirm") != f"{app}/{env}":
                        return self.send(400, {"error": f"type {app}/{env} to confirm"})
                    args = ["db", "wipe", app, env, *db_args] + (["--i-really-mean-prod"] if env == "prod" else [])
                elif op == "use":
                    require_project_role(actor, store, app, "maintainer")
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
        except PermissionError as e:
            return self.send(403, {"error": str(e)})
        except (ValueError, sqlite3.IntegrityError) as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:
            return self.send(500, {"error": str(e)})


if __name__ == "__main__":
    print("infra console listening on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
