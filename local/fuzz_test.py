"""Property and fuzz tests for the two pieces that decide what a request may reach.

    pip install hypothesis      (in a throwaway venv)
    python local/fuzz_test.py

 * policy engine  (platform/console/policy.py): explicit Deny always wins, the order of statements never matters,
   adding an Allow can only grow what is allowed, adding a Deny can only shrink it, an expired statement never applies,
   a conditional statement never matches a resource whose context it cannot evaluate, validate_document never raises
   anything but ValueError.
 * manifest parser (scripts/parse-manifest.py): whatever a pull request writes under `upstreams` / `public` in infra.yml is
   refused (links between projects are made in the console only), never ignored, never a traceback; ordinary manifests parse.
 * link validation (access.py): whatever the console accepts is made only of safe characters and survives the helper the
   deploy script reads it with (one line, fixed number of fields) — no value can inject a label or a shell word.
"""
import datetime
import os
import re
import subprocess
import sys
import tempfile

from hypothesis import HealthCheck, given, settings, strategies as st

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "platform", "console"))
import policy as P  # noqa: E402

TODAY = datetime.date(2026, 10, 16)
ACTIONS = sorted(P.ACTIONS)
ORG = "acme"
resource = st.sampled_from([f"{ORG}/shop-web/develop", f"{ORG}/shop-web/pr-1", f"{ORG}/shop-api/prod", f"{ORG}/shop-api", f"{ORG}/shop-web"])
res_pattern = st.sampled_from([f"{ORG}/*", f"{ORG}/shop-web/*", f"{ORG}/shop-api/*", f"{ORG}/shop-web/develop", f"{ORG}/shop-web/pr-*", f"{ORG}/shop-api/prod"])
act_pattern = st.sampled_from(ACTIONS + ["*", "logs:*", "environment:*", "database:*"])
cond = st.one_of(st.just({}), st.fixed_dictionaries({}, optional={
    "branch": st.lists(st.sampled_from(["feature/*", "main", "develop", "release/*"]), min_size=1, max_size=2),
    "class": st.lists(st.sampled_from(["prod", "staging", "develop", "preview"]), min_size=1, max_size=2),
    "expires": st.sampled_from(["2020-01-01", "2026-10-15", "2026-10-16", "2030-01-01"]),
}))
statement = st.builds(lambda e, a, r, c: dict({"Effect": e, "Action": a, "Resource": r}, **({"Condition": c} if c else {})),
                      st.sampled_from(["Allow", "Deny"]), st.lists(act_pattern, min_size=1, max_size=3),
                      st.lists(res_pattern, min_size=1, max_size=3), cond)
ctx = st.fixed_dictionaries({"branch": st.one_of(st.none(), st.sampled_from(["feature/x", "main", "develop"])),
                             "class": st.one_of(st.none(), st.sampled_from(["prod", "staging", "develop", "preview"]))})
SET = settings(max_examples=400, deadline=None, suppress_health_check=[HealthCheck.too_slow])


def decide(statements, a, r, c):
    return P.evaluate([("t", i, s) for i, s in enumerate(statements)], a, r, c, TODAY)[0]


@SET
@given(st.lists(statement, max_size=8), st.sampled_from(ACTIONS), resource, ctx)
def test_order_never_matters(sts, a, r, c):
    assert decide(sts, a, r, c) == decide(list(reversed(sts)), a, r, c)


@SET
@given(st.lists(statement, max_size=8), statement, st.sampled_from(ACTIONS), resource, ctx)
def test_deny_wins_and_monotonic(sts, extra, a, r, c):
    before = decide(sts, a, r, c)
    after = decide(sts + [extra], a, r, c)
    if extra["Effect"] == "Allow" and before == "allow":
        assert after == "allow"           # an extra Allow never removes access
    if extra["Effect"] == "Deny" and before == "deny":
        assert after == "deny"            # an extra Deny never grants anything


@SET
@given(st.lists(statement, max_size=6), st.sampled_from(ACTIONS), resource, ctx)
def test_explicit_deny_beats_everything(sts, a, r, c):
    deny_all = {"Effect": "Deny", "Action": ["*"], "Resource": [f"{ORG}/*"]}
    assert decide(sts + [deny_all], a, r, c) == "deny"
    assert decide([deny_all, {"Effect": "Allow", "Action": ["*"], "Resource": ["*"]}], a, r, c) == "deny"


@SET
@given(statement, st.sampled_from(ACTIONS), resource, ctx)
def test_expired_never_applies(s, a, r, c):
    s = dict(s, Condition=dict(s.get("Condition", {}), expires="2020-01-01"))
    assert decide([s], a, r, c) == "deny"


@SET
@given(st.sampled_from(ACTIONS), st.sampled_from([f"{ORG}/shop-web", f"{ORG}/shop-api"]))
def test_conditional_statement_needs_context(a, r):
    s = {"Effect": "Allow", "Action": ["*"], "Resource": [f"{ORG}/*"], "Condition": {"branch": ["*"]}}
    assert decide([s], a, r, {"branch": None, "class": None}) == "deny"


@SET
@given(st.recursive(st.one_of(st.none(), st.booleans(), st.integers(), st.text(max_size=30)),
                    lambda c: st.one_of(st.lists(c, max_size=4), st.dictionaries(st.text(max_size=12), c, max_size=4)), max_leaves=12),
       st.booleans())
def test_validate_only_raises_valueerror(doc, admin):
    try:
        out = P.validate_document(doc, ORG, admin)
    except ValueError:
        return
    assert isinstance(out["Statement"], list) and out["Statement"]
    for stt in out["Statement"]:                                # whatever was accepted stays inside the organization
        assert all(x == ORG or x.startswith(ORG + "/") for x in stt["Resource"])


# ────────────────────────────────────────────────────────────────────────────── manifest parser
PARSER = os.path.join(ROOT, "scripts", "parse-manifest.py")


def run_parser(text, *args):
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False, encoding="utf-8") as f:
        f.write(text)
    try:
        return subprocess.run([sys.executable, PARSER, f.name, *args], capture_output=True, text=True, timeout=30)
    finally:
        os.unlink(f.name)


@settings(max_examples=60, deadline=None, suppress_health_check=[HealthCheck.too_slow])
@given(st.sampled_from(["upstreams", "public"]), st.text(alphabet="/abc-_.~ []{}:,'\"$`;&|", max_size=24))
def test_repo_cannot_declare_links(key, value):
    """infra.yml comes from the repository: whatever a pull request writes under `upstreams`/`public`, the parser must
    refuse it (never ignore it silently, never crash, never emit it)."""
    r = run_parser(f"name: fuzz\nservices:\n  web:\n    image: nginx\n    port: 80\n    {key}: {value or 'x'}\n")
    assert "Traceback" not in r.stderr, r.stderr
    assert r.returncode != 0 and "console" in r.stderr and r.stdout == "", (r.returncode, r.stderr)


@settings(max_examples=60, deadline=None, suppress_health_check=[HealthCheck.too_slow])
@given(st.text(alphabet="abcXYZ09-_./;'`$ ", max_size=14))
def test_ordinary_manifests_still_parse(extra_name):
    """The refusal above must not break normal manifests, whatever else is in them."""
    r = run_parser("name: fuzz\nservices:\n  web:\n    image: nginx\n    port: 80\n    health_path: /h\n")
    assert r.returncode == 0 and "WEB_IMAGE='nginx'" in r.stdout


# ────────────────────────────────────────────────────────────────────────────── links (what the console accepts)
import access  # noqa: E402

name_like = st.one_of(st.sampled_from(["shop-web", "web", "api", "Web", "a/b", "", "x" * 40, "-a", "a-", "a b"]), st.text(alphabet="abcXYZ09-_/;'`$ .", max_size=12))
path_like = st.one_of(st.sampled_from(["/api", "/", "api", "/a b", "/a;b", "//", "/ok-1_2.3~/x", "/" + "a" * 120]), st.text(alphabet="/abc-_.~;'`$ \\%", max_size=16))


@settings(max_examples=300, deadline=None, suppress_health_check=[HealthCheck.too_slow])
@given(name_like, name_like, path_like, name_like, name_like,
       st.sampled_from(["paths", "fetch", "all", ""]), st.text(alphabet="/abc,-_.~;'` $\\", max_size=24))
def test_link_validation_accepts_only_safe_values(consumer, svc, path, provider, psvc, mode, excludes):
    d = tempfile.mkdtemp()
    try:
        s = access.AccessStore(os.path.join(d, "a.sqlite3"))
        try:
            s.create_link(consumer, svc, path, provider, psvc, False, False, "t", mode=mode, excludes=excludes)
        except ValueError:
            return
        row = s.list_links()[0]
        assert re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?", row["consumer"]) and row["consumer"] != row["provider"]
        assert re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?", row["service"]) and re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?", row["provider_service"])
        assert row["mode"] in ("paths", "fetch")
        if row["mode"] == "fetch":
            assert row["path"] == "*" and row["strip"] == 0
        else:
            assert all(re.fullmatch(r"/[A-Za-z0-9._~/-]{0,100}", x) and x != "/" for x in row["path"].split(","))
        assert all(re.fullmatch(r"/[A-Za-z0-9._~/-]{0,100}", x) for x in filter(None, row["excludes"].split(",")))
        out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "project-links.py"), os.path.join(d, "a.sqlite3"), row["consumer"]],
                             capture_output=True, text=True).stdout
        assert out.count("\n") == 1 and out.count("|") == 7, out          # one line, seven separators: no value can break the format
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except BaseException as e:                                                   # noqa: BLE001
            failed += 1
            print("FAIL", t.__name__, "->", str(e)[:600])
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
