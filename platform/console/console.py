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
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

INFRA_ROOT = os.environ["INFRA_ROOT"]
ENV_FILE = os.environ.get("INFRA_ENV_FILE", "/etc/infra/infra.env")
HERE = os.path.dirname(os.path.abspath(__file__))

NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
SCOPE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?(\.(app|web|api))?$")
KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SENSITIVE = re.compile(r"PASS|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|DATABASE_URL|DSN|AUTH", re.I)
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
    }


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


def overrides(s, app, scope):
    ov = read_env(f"{s['state_dir']}/overrides/{app}/{scope}.env")
    if "DB_URL" in ov:
        ov["DB_URL"] = mask_url(ov["DB_URL"])
    return ov


def env_class(env):
    return "preview" if env.startswith("pr-") else env


def components(type_):
    return {"monolith": ["app"], "frontend": ["web"], "backend": ["api"], "split": ["web", "api"]}.get(type_, [])


def required_missing(s, app, env):
    """Keys the manifest requires that the environment's runtime env lacks."""
    d = f"{s['deploy_root']}/{app}/{env}"
    man = read_env(f"{d}/deploy/manifest.env")
    missing = []
    for comp in components(man.get("TYPE", "")):
        have = read_env(f"{d}/runtime/{comp}.env")
        for key in man.get(f"{comp.upper()}_REQUIRED_ENV", "").split():
            if not have.get(key):
                missing.append(f"{comp}:{key}")
    return missing


def available_keys(s, app, env, comp):
    """Keys an environment WOULD get on its next deploy (repo env files + server variables)."""
    cls = env_class(env)
    repo = f"{s['deploy_root']}/{app}/{env}/deploy/env"
    srv = f"{s['secrets_root']}/{app}"
    files = [f"{repo}/common.env", f"{repo}/{cls}.env", f"{repo}/{cls}.{comp}.env",
             f"{srv}/common.env", f"{srv}/{cls}.env", f"{srv}/{cls}.{comp}.env"]
    if env != cls:
        files += [f"{srv}/{env}.env", f"{srv}/{env}.{comp}.env"]
    keys = set()
    for f in files:
        keys |= {k for k, v in read_env(f).items() if v}
    return keys


def required_by_app(s):
    """{app: {(component, key)}} — union of REQUIRED_ENV across every deployed branch of the app.
    A key a PR introduces shows up here before it reaches develop/staging/prod."""
    req = {}
    for man in glob.glob(f"{s['deploy_root']}/*/*/deploy/manifest.env"):
        app = man.split("/")[-4]
        m = read_env(man)
        for comp in components(m.get("TYPE", "")):
            for key in m.get(f"{comp.upper()}_REQUIRED_ENV", "").split():
                req.setdefault(app, set()).add((comp, key))
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
        m["OVERRIDES"] = {**overrides(s, app, "preview"), **overrides(s, app, env)} if env.startswith("pr-") \
            else overrides(s, app, env)
        m["HAS_OWN_DB"] = os.path.exists(f"{d}.db_password")
        comps = components(m.get("TYPE", ""))
        m["UPCOMING_MISSING"] = sorted(
            f"{c}:{k}" for c, k in required.get(app, set())
            if c in comps and f"{c}:{k}" not in m["MISSING"] and k not in available_keys(s, app, env, c))
        rows.append(m)
    return rows


def secrets(s, app):
    out = {}
    for f in sorted(glob.glob(f"{s['secrets_root']}/{app}/*.env")):
        scope = os.path.basename(f)[:-4]
        out[scope] = [{"key": k, "value": mask(k, v), "sensitive": bool(SENSITIVE.search(k))}
                      for k, v in read_env(f).items()]
    return out


def set_secret(s, app, scope, key, value):
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
            lines = [ln for ln in f.read().splitlines() if not re.match(rf"^(export\s+)?{key}=", ln)]
    else:
        lines = [f"# Variables for {app} ({scope}) — managed in the infra console / 'infra secrets edit'."]
    if value is not None:
        lines.append(f"{key}={value}")
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
#          "branch": "…", "commit": "…", "bundle": "<base64 tar.gz of the .deploy directory>"}
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
    if not os.path.isfile(os.path.join(d, "manifest.env")):
        raise ValueError("bundle has no manifest.env at its root (tar the .deploy directory itself)")
    return d


def run_job(s, job_id, args, workdir, app, env):
    with WORKERS:
        JOBS[job_id]["status"] = "running"
        ok, out = infra(*args)
    meta = read_env(f"{s['deploy_root']}/{app}/{env}/meta.env") if ok and args[0] == "deploy" else {}
    JOBS[job_id].update(status="succeeded" if ok else "failed", ok=ok, output=out[-6000:], finished=time.time(),
                        url=meta.get("URL", ""), api_url=meta.get("API_URL", ""),
                        upstream_api_url=meta.get("UPSTREAM_API_URL", ""))
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
        if read_env(os.path.join(workdir, "manifest.env")).get("APP_NAME") != app:
            shutil.rmtree(workdir, ignore_errors=True)
            return deny(f"bundle APP_NAME is not {app}")
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
            "created_at": p.get("CREATED_AT", ""), "created_by": p.get("CREATED_BY", ""),
            "environments": sorted(os.path.basename(d.rstrip("/")) for d in glob.glob(f"{s['deploy_root']}/{app}/*/")),
        })
    return out


def webhook_url(s):
    return f"https://hooks.{s['domain']}{s['suffix']}/webhook"


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

    def user(self):
        return self.headers.get("X-Infra-User") or "unknown"

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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
            if u.path == "/":
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if u.path == "/api/state":
                return self.send(200, {"settings": s, "user": self.user(), "deployments": deployments(s)})
            if u.path == "/api/env":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                d = f"{s['deploy_root']}/{app}/{env}"
                runtime = {}
                for f in sorted(glob.glob(f"{d}/runtime/*.env")):
                    runtime[os.path.basename(f)[:-4]] = [{"key": k, "value": mask(k, v)} for k, v in read_env(f).items()]
                return self.send(200, {"runtime": runtime, "manifest": {k: v for k, v in read_env(f"{d}/deploy/manifest.env").items()
                                                                        if not SENSITIVE.search(k)}})
            if u.path == "/api/secrets":
                app = q.get("app", "")
                if not NAME.match(app):
                    return self.send(400, {"error": "bad app"})
                return self.send(200, {"files": secrets(s, app)})
            if u.path == "/api/logs":
                app, env = q.get("app", ""), q.get("env", "")
                if not (NAME.match(app) and NAME.match(env)):
                    return self.send(400, {"error": "bad app/env"})
                ok, out = infra("tail", app, env, str(min(int(q.get("n", 200)), 2000)), timeout=60)
                return self.send(200, {"ok": ok, "output": out})
            if u.path == "/api/projects":
                return self.send(200, {"projects": projects(s), "webhook_url": webhook_url(s)})
            if u.path == "/api/activity":
                lines = tail(f"{s['log_dir']}/console.log", 100) + tail(f"{s['log_dir']}/deploy.log", 150)
                lines = [ln for ln in lines if ln[:4].isdigit()]
                lines.sort()
                return self.send(200, {"lines": lines[-200:]})
            return self.send(404, {"error": "not found"})
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
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        except json.JSONDecodeError:
            return self.send(400, {"error": "bad json"})
        u = urlparse(self.path).path
        app = body.get("app", "")
        if not NAME.match(app):
            return self.send(400, {"error": "bad app"})
        try:
            if u == "/api/project":
                op = body.get("op", "")
                repo, envs = body.get("repo", ""), body.get("envs", "")
                prod_branch = body.get("prod_branch", "")
                reg_user, reg_token = body.get("registry_user", ""), body.get("registry_token", "")
                if repo and not REPO_RE.match(repo):
                    return self.send(400, {"error": "repo must look like owner/repo"})
                if envs and not ENVS_RE.match(envs):
                    return self.send(400, {"error": "environments must be a comma list, e.g. preview,develop"})
                if prod_branch and not BRANCH_RE.match(prod_branch):
                    return self.send(400, {"error": "bad prod branch"})
                if any(c in reg_user + reg_token for c in "'\n\r\" "):
                    return self.send(400, {"error": "registry user/token contain invalid characters"})
                opts = []
                for flag, val in (("--repo", repo), ("--envs", envs), ("--prod-branch", prod_branch),
                                  ("--registry-user", reg_user), ("--registry-token", reg_token)):
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

            if u == "/api/secret":
                scope, key, value = body.get("scope", ""), body.get("key", ""), body.get("value")
                if not SCOPE.match(scope) or not KEY.match(key):
                    return self.send(400, {"error": "bad scope or key"})
                if value is not None and ("\n" in value or "\r" in value):
                    return self.send(400, {"error": "values can't contain newlines"})
                set_secret(s, app, scope, key, value)
                self.audit(s, "variable", f"{app} scope={scope} key={key} {'deleted' if value is None else 'set'}")
                return self.send(200, {"ok": True})

            if u == "/api/action":
                env, action = body.get("env", ""), body.get("action", "")
                if not NAME.match(env):
                    return self.send(400, {"error": "bad env"})
                if action in ("redeploy", "rollback", "restart"):
                    args = [action, app, env]
                elif action == "destroy":
                    if body.get("confirm") != f"{app}/{env}":
                        return self.send(400, {"error": f"type {app}/{env} to confirm"})
                    args = ["destroy", "--app", app, "--env", env] + (["--i-really-mean-prod"] if env == "prod" else [])
                else:
                    return self.send(400, {"error": "unknown action"})
                self.audit(s, action, f"{app}/{env}")
                ok, out = infra(*args)
                self.audit(s, f"{action}:{'ok' if ok else 'FAILED'}", f"{app}/{env}")
                return self.send(200, {"ok": ok, "output": out})

            if u == "/api/link":
                scope, mode = body.get("scope", ""), body.get("mode", "")
                if not NAME.match(scope):
                    return self.send(400, {"error": "bad scope"})
                args = {"auto": ["--auto"], "api": ["--api", body.get("target", "")],
                        "url": ["--api-url", body.get("url", "")]}.get(mode)
                if not args:
                    return self.send(400, {"error": "bad mode"})
                self.audit(s, "link", f"{app}/{scope} {mode} {body.get('target') or body.get('url') or ''}")
                ok, out = infra("link", app, scope, *args)
                return self.send(200, {"ok": ok, "output": out})

            if u == "/api/db":
                scope, mode = body.get("scope", ""), body.get("mode", "")
                if not NAME.match(scope):
                    return self.send(400, {"error": "bad scope"})
                args = {"own": ["--own"], "share": ["--share", body.get("target", "")],
                        "url": ["--url", body.get("url", "")]}.get(mode)
                if not args:
                    return self.send(400, {"error": "bad mode"})
                if body.get("allow_prod"):
                    args.append("--allow-prod")
                if body.get("migrate"):
                    args.append("--migrate")
                self.audit(s, "attach-db", f"{app}/{scope} {mode} {body.get('target') or mask_url(body.get('url', ''))}")
                ok, out = infra("attach-db", app, scope, *args)
                return self.send(200, {"ok": ok, "output": mask_url(out)})

            return self.send(404, {"error": "not found"})
        except Exception as e:
            return self.send(500, {"error": str(e)})


if __name__ == "__main__":
    print("infra console listening on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
