#!/usr/bin/env python3
"""
Parse .infradeploy/infra.yml and emit shell-safe KEY=value lines.

Usage:
  parse-manifest.py <infra.yml> [--service <svc>] [--field <field>] [--databases]

Without --service/--field: emits the full parsed manifest as KEY=value for shell sourcing.
With --service <svc>:       emits service-level fields for that service.
With --field <field>:       emits a single top-level field value (raw, for scripting).

Exit 1 on any validation error (message on stderr).
"""
import json
import re
import sys
import os

# ── tiny YAML subset parser ──────────────────────────────────────────────────
# Supports: mappings, sequences, scalars (quoted + unquoted), comments, multiline.
# No anchors, no tags, no complex keys. Enough for infra.yml.

def _parse_yaml(text):
    lines = text.splitlines()
    pos = [0]

    def peek():
        while pos[0] < len(lines):
            l = lines[pos[0]]
            stripped = l.lstrip()
            if stripped == '' or stripped.startswith('#'):
                pos[0] += 1
                continue
            return l
        return None

    def indent_of(l):
        return len(l) - len(l.lstrip())

    def parse_value(l, base_indent):
        stripped = l.strip()
        # inline sequence
        if stripped.startswith('['):
            inner = stripped[1:stripped.rindex(']')]
            return [_unquote(x.strip()) for x in inner.split(',') if x.strip()]
        # inline mapping
        if stripped.startswith('{'):
            inner = stripped[1:stripped.rindex('}')]
            out = {}
            for pair in inner.split(','):
                if ':' in pair:
                    k, v = pair.split(':', 1)
                    out[k.strip()] = _unquote(v.strip())
            return out
        # block sequence
        if stripped == '':
            return parse_block(base_indent)
        return _unquote(stripped)

    def parse_block(min_indent):
        result = None
        while True:
            l = peek()
            if l is None:
                break
            ind = indent_of(l)
            if ind < min_indent:
                break
            stripped = l.strip()
            if stripped.startswith('- ') or stripped == '-':
                # sequence
                if result is None:
                    result = []
                pos[0] += 1
                item_text = stripped[2:].strip() if stripped != '-' else ''
                if item_text == '' or item_text.startswith('#'):
                    result.append(parse_block(ind + 2))
                elif ':' in item_text and not item_text.startswith('"') and not item_text.startswith("'"):
                    # inline mapping item
                    sub = {}
                    k, v = item_text.split(':', 1)
                    v = v.strip()
                    if v and not v.startswith('#'):
                        sub[k.strip()] = _val(v)
                    else:
                        sub[k.strip()] = parse_block(ind + 2)
                    # more keys at same indent
                    while True:
                        nl = peek()
                        if nl is None or indent_of(nl) <= ind:
                            break
                        ns = nl.strip()
                        if ns.startswith('- ') or ns == '-':
                            break
                        if ':' in ns:
                            pos[0] += 1
                            k2, v2 = ns.split(':', 1)
                            v2 = v2.strip()
                            if v2 and not v2.startswith('#'):
                                sub[k2.strip()] = _val(v2)
                            else:
                                sub[k2.strip()] = parse_block(indent_of(nl) + 2)
                    result.append(sub)
                else:
                    result.append(_unquote(item_text))
            elif ':' in stripped and not stripped.startswith('"') and not stripped.startswith("'"):
                # mapping
                if result is None:
                    result = {}
                pos[0] += 1
                k, v = stripped.split(':', 1)
                k = k.strip()
                v = v.strip()
                if v == '' or v.startswith('#'):
                    result[k] = parse_block(ind + 2)
                else:
                    result[k] = _val(v)
            else:
                break
        return result

    def _val(v):
        """Scalar, or an inline [a, b] / {k: v} collection."""
        v = re.sub(r'\s+#.*$', '', v.strip()) if v[:1] not in ('"', "'") else v.strip()
        if v.startswith('[') and v.endswith(']'):
            return [_unquote(x.strip()) for x in v[1:-1].split(',') if x.strip()]
        if v.startswith('{') and v.endswith('}'):
            out = {}
            for pair in v[1:-1].split(','):
                if ':' in pair:
                    k, val = pair.split(':', 1)
                    out[k.strip()] = _unquote(val.strip())
            return out
        return _unquote(v)

    def _unquote(s):
        if not s:
            return ''
        s = s.strip()
        # strip inline comment from unquoted scalars
        if s and s[0] not in ('"', "'"):
            s = re.sub(r'\s+#.*$', '', s).strip()
        if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
            return s[1:-1]
        if s.lower() == 'true':
            return True
        if s.lower() == 'false':
            return False
        if s.lower() in ('null', '~', ''):
            return None
        try:
            return int(s)
        except ValueError:
            pass
        try:
            return float(s)
        except ValueError:
            pass
        return s

    return parse_block(0)


# ── validation ───────────────────────────────────────────────────────────────

NAME_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$')
IMAGE_RE = re.compile(r'^[a-zA-Z0-9._/:@{}-]+$')
PORT_RE  = re.compile(r'^[0-9]{1,5}$')
PATH_RE  = re.compile(r'^[a-zA-Z0-9_./-]+$')
KEY_RE   = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
HOST_RE  = re.compile(r'^[a-z0-9.-]+$')
MW_RE    = re.compile(r'^[a-zA-Z0-9@,_-]+$')

RESERVED_APPS = {'console', 'traefik', 'logs', 'status', 'hooks', 'grafana', 'www', 'api', 'auth', 'sso'}

def err(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def validate(manifest):
    name = manifest.get('name')
    if not name or not NAME_RE.match(str(name)):
        err(f"'name' must be a lowercase slug (got {name!r})")
    if str(name) in RESERVED_APPS:
        err(f"'name' {name!r} is reserved by the platform")

    services = manifest.get('services')
    if not services or not isinstance(services, dict):
        err("'services' must be a non-empty mapping")

    for svc, cfg in services.items():
        if not NAME_RE.match(str(svc)):
            err(f"service name {svc!r} must be a lowercase slug")
        if not isinstance(cfg, dict):
            err(f"service {svc!r}: must be a mapping")

        image = cfg.get('image', '')
        if not image or not IMAGE_RE.match(str(image)):
            err(f"service {svc!r}: 'image' is required and must be a valid image reference")

        port = cfg.get('port')
        if port is not None and not PORT_RE.match(str(port)):
            err(f"service {svc!r}: 'port' must be a number (got {port!r})")

        for key in cfg.get('required_env', []):
            if not KEY_RE.match(str(key)):
                err(f"service {svc!r}: required_env key {key!r} is not a valid env var name")

        for db in cfg.get('databases', []):
            if not isinstance(db, dict):
                err(f"service {svc!r}: each database entry must be a mapping")
            inject_as = db.get('inject_as', '')
            if not KEY_RE.match(str(inject_as)):
                err(f"service {svc!r}: database 'inject_as' must be a valid env var name")
            if 'username' in db:
                err(f"service {svc!r}: database 'username' is not supported (roles are namespaced per database)")
            pw = db.get('password')
            if pw is not None and not re.match(r'^[A-Za-z0-9._~-]{8,128}$', str(pw)):
                err(f"service {svc!r}: database 'password' must be 8-128 URL-safe characters [A-Za-z0-9._~-]")

        hp = cfg.get('health_path', '')
        if hp and not str(hp).startswith('/'):
            err(f"service {svc!r}: 'health_path' must start with /")

        for forbidden in ('upstreams', 'public'):
            if forbidden in cfg:
                err(f"service {svc!r}: '{forbidden}' is not part of infra.yml. Links between projects are managed in the "
                    "console (Access → Project links) so a pull request cannot create them")

        ctx = cfg.get('build_context', '')
        if ctx and not PATH_RE.match(str(ctx)):
            err(f"service {svc!r}: 'build_context' contains invalid characters")

        df = cfg.get('dockerfile', '')
        if df and not PATH_RE.match(str(df)):
            err(f"service {svc!r}: 'dockerfile' contains invalid characters")

        for cls, val in (cfg.get('host', {}) or {}).items():
            if not HOST_RE.match(str(val)):
                err(f"service {svc!r}: host.{cls} {val!r} is not a valid hostname")

        mw = cfg.get('extra_middlewares', '')
        if mw and not MW_RE.match(str(mw)):
            err(f"service {svc!r}: 'extra_middlewares' contains invalid characters")

    envs = manifest.get('environments', {}) or {}
    if not isinstance(envs, dict):
        err("'environments' must be a mapping")

    migrate = manifest.get('migrate', {}) or {}
    if migrate:
        svc = migrate.get('service', '')
        if svc and svc not in services:
            err(f"migrate.service {svc!r} is not a declared service")

    max_prev = manifest.get('max_previews_per_app')
    if max_prev is not None:
        try:
            int(max_prev)
        except (TypeError, ValueError):
            err(f"'max_previews_per_app' must be an integer (got {max_prev!r})")


# ── URL convention ────────────────────────────────────────────────────────────
# service named 'web' or 'app' → appname[-env].domain
# any other name               → svcname-appname[-env].domain

def service_host(app, svc, env, domain):
    base = app if env == 'prod' else f"{app}-{env}"
    if svc in ('web', 'app'):
        return f"{base}.{domain}"
    return f"{svc}-{base}.{domain}"


# ── emit ──────────────────────────────────────────────────────────────────────

def shell_quote(v):
    if isinstance(v, bool):
        v = 'true' if v else 'false'
    s = str(v) if v is not None else ''
    if "'" in s:
        err(f"value contains a single quote, cannot shell-quote: {s!r}")
    return f"'{s}'"

def emit_manifest(manifest):
    """Print the full manifest as KEY=value for shell sourcing."""
    name = str(manifest['name'])
    print(f"APP_NAME={shell_quote(name)}")

    services = manifest['services']
    svc_names = list(services.keys())
    print(f"SERVICES={shell_quote(' '.join(svc_names))}")

    for svc, cfg in services.items():
        S = svc.upper().replace('-', '_')
        print(f"{S}_IMAGE={shell_quote(cfg.get('image', ''))}")
        print(f"{S}_PORT={shell_quote(cfg.get('port', ''))}")
        print(f"{S}_HEALTH_PATH={shell_quote(cfg.get('health_path', '/'))}")
        print(f"{S}_BUILD_CONTEXT={shell_quote(cfg.get('build_context', '.'))}")
        print(f"{S}_DOCKERFILE={shell_quote(cfg.get('dockerfile', ''))}")
        print(f"{S}_REQUIRED_ENV={shell_quote(' '.join(str(k) for k in cfg.get('required_env', [])))}")
        print(f"{S}_EXTRA_MIDDLEWARES={shell_quote(cfg.get('extra_middlewares', ''))}")
        # databases: emit as JSON for deploy.sh to parse
        dbs = cfg.get('databases', [])
        print(f"{S}_DATABASES={shell_quote(json.dumps(dbs))}")
        # per-env-class host overrides: host.prod, host.staging, etc.
        for cls, val in (cfg.get('host', {}) or {}).items():
            CLS = cls.upper().replace('-', '_')
            print(f"{S}_HOST_{CLS}={shell_quote(val)}")

    migrate = manifest.get('migrate', {}) or {}
    print(f"MIGRATE_CMD={shell_quote(migrate.get('cmd', ''))}")
    print(f"MIGRATE_SERVICE={shell_quote(migrate.get('service', ''))}")

    max_prev = manifest.get('max_previews_per_app', '')
    print(f"MAX_PREVIEWS_PER_APP={shell_quote(max_prev if max_prev != '' else '')}")

    # environments block: emit per-service env vars per class
    envs = manifest.get('environments', {}) or {}
    for cls, cls_cfg in envs.items():
        if not isinstance(cls_cfg, dict):
            continue
        CLS = cls.upper().replace('-', '_')
        # top-level keys in an env class (auth: true, etc.)
        for k, v in cls_cfg.items():
            if k in services:
                continue
            K = k.upper().replace('-', '_')
            print(f"ENV_{CLS}_{K}={shell_quote(v)}")
        # per-service keys
        for svc in svc_names:
            svc_env = cls_cfg.get(svc, {}) or {}
            if not isinstance(svc_env, dict):
                continue
            S = svc.upper().replace('-', '_')
            for k, v in svc_env.items():
                K = k.upper().replace('-', '_')
                print(f"ENV_{CLS}_{S}_{K}={shell_quote(v)}")


def emit_service(manifest, svc):
    services = manifest.get('services', {})
    if svc not in services:
        err(f"service {svc!r} not found in manifest")
    cfg = services[svc]
    S = svc.upper().replace('-', '_')
    print(f"IMAGE={shell_quote(cfg.get('image', ''))}")
    print(f"PORT={shell_quote(cfg.get('port', ''))}")
    print(f"HEALTH_PATH={shell_quote(cfg.get('health_path', '/'))}")
    print(f"BUILD_CONTEXT={shell_quote(cfg.get('build_context', '.'))}")
    print(f"DOCKERFILE={shell_quote(cfg.get('dockerfile', ''))}")
    print(f"REQUIRED_ENV={shell_quote(' '.join(str(k) for k in cfg.get('required_env', [])))}")
    print(f"EXTRA_MIDDLEWARES={shell_quote(cfg.get('extra_middlewares', ''))}")
    print(f"DATABASES={shell_quote(json.dumps(cfg.get('databases', [])))}")


def emit_databases(manifest):
    """One line per declared database: <service>|<inject_as>|<fixed password or empty>."""
    for svc, cfg in manifest['services'].items():
        for db in cfg.get('databases') or []:
            print(f"{svc}|{db['inject_as']}|{db.get('password') or ''}")


def emit_field(manifest, field):
    val = manifest.get(field)
    if val is None:
        print('')
    elif isinstance(val, (dict, list)):
        print(json.dumps(val))
    else:
        print(str(val))


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__)
        sys.exit(0)

    yml_path = args[0]
    rest = args[1:]

    if not os.path.isfile(yml_path):
        err(f"file not found: {yml_path}")

    with open(yml_path) as f:
        text = f.read()

    try:
        manifest = _parse_yaml(text)
    except Exception as e:
        err(f"YAML parse error: {e}")

    if not isinstance(manifest, dict):
        err("infra.yml must be a YAML mapping at the top level")

    validate(manifest)

    if '--databases' in rest:
        emit_databases(manifest)
    elif '--service' in rest:
        idx = rest.index('--service')
        svc = rest[idx + 1]
        emit_service(manifest, svc)
    elif '--field' in rest:
        idx = rest.index('--field')
        field = rest[idx + 1]
        emit_field(manifest, field)
    else:
        emit_manifest(manifest)


if __name__ == '__main__':
    main()
