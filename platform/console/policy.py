"""Policy engine: AWS-style authorization for the infra console.

A permission is (action, resource, conditions), denied by default. Policies hold statements:

    {"Effect": "Allow" | "Deny",
     "Action":    ["environment:List", "logs:*"],          # wildcards allowed
     "Resource":  ["acme/shop-api/*", "acme/shop-web/pr-*"],   # <organization>/<project>/<environment>
     "Condition": {"branch": ["feature/*"], "class": ["preview"], "expires": "2026-12-31"}}

An explicit Deny always wins; otherwise one matching Allow is enough; otherwise the request is denied.
The existing "quick access" grants (a role on the organization / a project / an environment / a class / a branch)
are compiled into the same statements, so there is exactly one evaluator.
"""
import datetime
import fnmatch
import re

# action -> (access level, description, delegable). An organization admin holds every action inside their organization,
# so everything is delegable; set a flag to False to reserve an action for platform administrators only.
ACTIONS = {
    "environment:List":       ("List",       "See the environment in lists (name, status, branch)", True),
    "environment:View":       ("Read",       "Open its details: endpoints, image tag, commit, who deployed", True),
    "environment:Open":       ("Read",       "Pass the access gate and open its URLs (previews and gated environments)", True),
    "logs:Read":              ("Read",       "Read container logs", True),
    "variables:List":         ("Read",       "See variable names and where each comes from (values masked)", True),
    "variables:ReadValues":   ("Read",       "See variable values", True),
    "database:Describe":      ("Read",       "See which databases exist and their size", True),
    "resources:Read":         ("Read",       "See CPU and memory limits", True),
    "environment:Redeploy":   ("Write",      "Redeploy the environment", True),
    "environment:Restart":    ("Write",      "Restart its containers", True),
    "environment:Rollback":   ("Write",      "Roll back to the previous version", True),
    "variables:Write":        ("Write",      "Create, change and delete variables", True),
    "database:Create":        ("Write",      "Create declared databases", True),
    "database:Use":           ("Write",      "Point a variable at another environment's database", True),
    "environment:Destroy":    ("Privileged", "Destroy the environment and its databases", True),
    "database:Wipe":          ("Privileged", "Drop a database's data", True),
    "database:Dump":          ("Privileged", "Download a copy of a database (all its data)", True),
    "database:Restore":       ("Privileged", "Replace a database's data with an uploaded dump", True),
    "database:RevealUrl":     ("Privileged", "Show a database's full connection URL", True),
    "secrets:Reveal":         ("Privileged", "Show a secret variable's value", True),
    "resources:Write":        ("Privileged", "Change CPU and memory limits", True),
}
LEVELS = ["List", "Read", "Write", "Privileged"]

_VIEWER = ["environment:List", "environment:View", "environment:Open", "logs:Read", "variables:List",
           "database:Describe", "resources:Read"]
_OPERATOR = _VIEWER + ["environment:Redeploy", "environment:Restart", "environment:Rollback"]
_MAINTAINER = _OPERATOR + ["variables:ReadValues", "variables:Write", "database:Create", "database:Use"]
PRESETS = {
    "viewer":     {"name": "Viewer",     "description": "See and open; read logs and masked variables", "actions": _VIEWER},
    "operator":   {"name": "Operator",   "description": "Viewer + redeploy, restart, roll back", "actions": _OPERATOR},
    "maintainer": {"name": "Maintainer", "description": "Operator + edit variables, create databases", "actions": _MAINTAINER},
}

CONDITION_KEYS = ("branch", "class", "expires")
MAX_STATEMENTS = 50
MAX_ITEMS = 40
PATTERN = re.compile(r"^[A-Za-z0-9_.:*/@+\-]{1,160}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# ----------------------------------------------------------------------------------------------- matching

def _listify(v):
    return [v] if isinstance(v, str) else list(v or [])


def action_matches(pattern, action):
    return fnmatch.fnmatchcase(action, pattern)


def resource_matches(pattern, resource):
    """`acme/shop-api/*` covers the project itself and everything below it; `acme/*` the whole organization."""
    if fnmatch.fnmatchcase(resource, pattern):
        return True
    return pattern.endswith("/*") and resource == pattern[:-2]


def condition_ok(cond, ctx, today):
    """All keys must hold. A key whose context value is unknown (for example `branch` on a project-level
    resource) does not match, so a conditional statement never leaks to resources it cannot evaluate."""
    if not cond:
        return True
    expires = cond.get("expires")
    if expires and today.isoformat() > expires:
        return False
    for key in ("branch", "class"):
        wanted = _listify(cond.get(key))
        if not wanted:
            continue
        value = ctx.get(key)
        if value is None or not any(fnmatch.fnmatchcase(value, p) for p in wanted):
            return False
    return True


def statement_matches(st, action, resource, ctx, today):
    return (any(action_matches(p, action) for p in _listify(st.get("Action")))
            and any(resource_matches(p, resource) for p in _listify(st.get("Resource")))
            and condition_ok(st.get("Condition") or {}, ctx, today))


def evaluate(statements, action, resource, ctx=None, today=None):
    """statements: [(source, index, statement)]. → (decision, reason, matches)
    decision 'allow' | 'deny'; reason 'explicit-deny' | 'allow' | 'implicit-deny'; matches = the statements that decided."""
    ctx = ctx or {}
    today = today or datetime.date.today()
    allows = []
    for source, index, st in statements:
        if not statement_matches(st, action, resource, ctx, today):
            continue
        if st.get("Effect") == "Deny":
            return "deny", "explicit-deny", [(source, index, st)]
        allows.append((source, index, st))
    if allows:
        return "allow", "allow", allows
    return "deny", "implicit-deny", []


# ----------------------------------------------------------------------------------------------- compiling

def preset_statement(role, resource, cond=None):
    st = {"Effect": "Allow", "Action": list(PRESETS[role]["actions"]), "Resource": [resource]}
    if cond:
        st["Condition"] = cond
    return st


def compile_grants(org_grants, project_grants, env_grants):
    """The quick-access grants as statements.
    org_grants: [(org, role)]; project_grants: [(org, app, role)]; env_grants: [(org, app, scope, role)]."""
    out = []
    for org, role in org_grants:
        out.append((f"quick access: {PRESETS[role]['name']} on {org}/*", 0, preset_statement(role, f"{org}/*")))
    for org, app, role in project_grants:
        out.append((f"quick access: {PRESETS[role]['name']} on {org}/{app}/*", 0, preset_statement(role, f"{org}/{app}/*")))
    for org, app, scope, role in env_grants:
        kind, _, value = scope.partition(":")
        label = f"quick access: {PRESETS[role]['name']} on {org}/{app}"
        if kind == "env":
            out.append((f"{label}/{value}", 0, preset_statement(role, f"{org}/{app}/{value}")))
        elif kind == "class":
            out.append((f"{label} · class {value}", 0, preset_statement(role, f"{org}/{app}/*", {"class": [value]})))
        elif kind == "branch":
            out.append((f"{label} · branch {value}", 0, preset_statement(role, f"{org}/{app}/*", {"branch": [value]})))
    return out


# ----------------------------------------------------------------------------------------------- validation

def validate_document(doc, organization, platform_admin=False):
    """Normalize and validate a policy document for one organization. Raises ValueError with a precise message."""
    if not isinstance(doc, dict) or not isinstance(doc.get("Statement"), list) or not doc["Statement"]:
        raise ValueError('a policy is {"Statement": [ … ]} with at least one statement')
    if len(doc["Statement"]) > MAX_STATEMENTS:
        raise ValueError(f"at most {MAX_STATEMENTS} statements")
    out = []
    for n, st in enumerate(doc["Statement"], 1):
        where = f"statement {n}"
        if not isinstance(st, dict):
            raise ValueError(f"{where}: must be an object")
        unknown = set(st) - {"Sid", "Effect", "Action", "Resource", "Condition"}
        if unknown:
            raise ValueError(f"{where}: unknown field {sorted(unknown)[0]!r}")
        if st.get("Effect") not in ("Allow", "Deny"):
            raise ValueError(f'{where}: "Effect" must be "Allow" or "Deny"')
        actions, resources = _listify(st.get("Action")), _listify(st.get("Resource"))
        if not actions or not resources:
            raise ValueError(f'{where}: "Action" and "Resource" are required')
        if len(actions) > MAX_ITEMS or len(resources) > MAX_ITEMS:
            raise ValueError(f"{where}: at most {MAX_ITEMS} actions and resources")
        for a in actions:
            if not isinstance(a, str) or not PATTERN.match(a):
                raise ValueError(f"{where}: bad action {a!r}")
            hits = [name for name in ACTIONS if action_matches(a, name)]
            if not hits:
                raise ValueError(f"{where}: action {a!r} matches nothing (see the action list)")
            if st["Effect"] == "Allow" and not platform_admin:
                privileged = [h for h in hits if not ACTIONS[h][2]]
                if privileged:
                    raise ValueError(f"{where}: {a!r} would allow {privileged[0]}, which only a platform administrator may grant "
                                     "— list the permitted actions explicitly")
        for r in resources:
            if not isinstance(r, str) or not PATTERN.match(r):
                raise ValueError(f"{where}: bad resource {r!r}")
            if not (r == organization or r.startswith(organization + "/")):
                raise ValueError(f"{where}: resource {r!r} must be inside the organization — start it with {organization!r}/")
        cond = st.get("Condition") or {}
        if not isinstance(cond, dict) or set(cond) - set(CONDITION_KEYS):
            raise ValueError(f"{where}: conditions are {', '.join(CONDITION_KEYS)}")
        clean = {}
        for key in ("branch", "class"):
            if key in cond:
                vals = _listify(cond[key])
                if not vals or len(vals) > MAX_ITEMS or any(not isinstance(v, str) or not PATTERN.match(v) for v in vals):
                    raise ValueError(f"{where}: condition {key!r} must be a list of patterns")
                clean[key] = vals
        if "expires" in cond:
            if not isinstance(cond["expires"], str) or not DATE.match(cond["expires"]):
                raise ValueError(f"{where}: condition 'expires' must be a date like 2026-12-31")
            try:
                datetime.date.fromisoformat(cond["expires"])
            except ValueError:
                raise ValueError(f"{where}: condition 'expires' is not a real date") from None
            clean["expires"] = cond["expires"]
        item = {"Effect": st["Effect"], "Action": actions, "Resource": resources}
        if st.get("Sid"):
            item["Sid"] = str(st["Sid"])[:60]
        if clean:
            item["Condition"] = clean
        out.append(item)
    return {"Statement": out}


def role_of(allowed):
    """The preset name ('maintainer' > 'operator' > 'viewer') whose actions the person fully has, else '' (custom)."""
    have = set(allowed)
    for name in ("maintainer", "operator", "viewer"):
        if set(PRESETS[name]["actions"]) <= have:
            return name
    return ""


def org_admin_statement(organization):
    """An organization administrator may do everything inside their organization."""
    return {"Effect": "Allow", "Action": ["*"], "Resource": [f"{organization}/*"]}


def catalog():
    return [{"name": n, "level": lvl, "description": d, "delegable": deleg} for n, (lvl, d, deleg) in ACTIONS.items()]
