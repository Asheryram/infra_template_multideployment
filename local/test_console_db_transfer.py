#!/usr/bin/env python3
"""Console database dump / restore: who may do it, what is checked first, and the order of the steps.
Runs the real HTTP handler in-process with the infra CLI replaced by a recorder, so no Docker or Postgres is involved."""
import glob
import http.client
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "platform", "console"))
os.environ.setdefault("INFRA_ROOT", ROOT)

import console  # noqa: E402
from access import AccessStore  # noqa: E402

DUMP = b"PGDMP\x01\x0e\x00" + b"x" * 200


class DbTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = self.temp.name
        self.store = AccessStore(os.path.join(self.state, "access.sqlite3"))
        self.store.create_organization("acme", "Acme")
        self.store.link_project("acme", "shop")
        self.viewer = self.store.observe_identity("kc-1", "viewer", "viewer@example.test", "Viewer")
        self.dba = self.store.observe_identity("kc-2", "dba", "dba@example.test", "Dba")
        self.outsider = self.store.observe_identity("kc-3", "out", "out@example.test", "Out")
        for u in (self.viewer, self.dba):
            self.store.set_member("acme", u["uid"], "member")
        view = self.store.save_policy("acme", "view", "", {"Statement": [{
            "Effect": "Allow", "Action": ["environment:*", "database:Describe"], "Resource": ["acme/shop/*"]}]}, "t")
        full = self.store.save_policy("acme", "dba", "", {"Statement": [{
            "Effect": "Allow", "Action": ["environment:*", "database:*"], "Resource": ["acme/shop/*"]}]}, "t")
        self.store.attach_policy(view, self.viewer["uid"])
        self.store.attach_policy(full, self.dba["uid"])
        self.calls = []
        self.dump_ok = True

        def fake_infra(*args, timeout=900, actor=None):
            self.calls.append(args)
            if args[:2] == ("db", "dump"):
                if not self.dump_ok:
                    return False, "pg_dump: boom"
                with open(args[4], "wb") as fh:
                    fh.write(DUMP)
            return True, "ok " + args[0]

        people = {"admin": {"uid": "keycloak:admin", "username": "admin", "email": "", "display_name": "a", "platform_admin": True},
                  "viewer": dict(self.viewer, platform_admin=False), "dba": dict(self.dba, platform_admin=False),
                  "outsider": dict(self.outsider, platform_admin=False)}
        fake_settings = {"console_auth_mode": "keycloak", "state_dir": self.state, "deploy_root": self.state,
                         "domain": "x.test", "suffix": "", "server": "t", "secrets_root": self.state, "log_dir": self.state,
                         "prefix": "infra", "max_previews": "8", "keycloak_platform_admin_group": "g", "invite_accounts": False,
                         "authentik_platform_admin_group": "g"}
        self.patches = [
            patch.object(console, "settings", lambda: fake_settings),
            patch.object(console, "access_store", lambda s: self.store),
            patch.object(console, "infra", fake_infra),
            patch.object(console, "deployment_branch", lambda s, a, e: "main"),
            patch.object(console.Handler, "actor", lambda h, s: people.get(h.headers.get("X-Who"))),
            patch.object(console, "audit_line", lambda *a: None),
        ]
        for p in self.patches:
            p.start()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), console.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for p in self.patches:
            p.stop()
        self.temp.cleanup()

    def req(self, method, path, who, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        h = {"X-Who": who, "X-Infra-Console": "1", **(headers or {})}
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data, r

    def restore(self, who, env="develop", body=DUMP, confirm="shop/develop", extra=None):
        h = {"X-Confirm": confirm, **(extra or {})}
        return self.req("POST", f"/api/dbrestore?app=shop&env={env}&db=api:DATABASE_URL", who, body, h)

    def leftovers(self):
        """Files still in the scratch dir. The server removes them just after answering, so give it a moment."""
        import time
        for _ in range(50):
            found = glob.glob(os.path.join(self.state, "db-transfer", "*"))
            if not found:
                break
            time.sleep(0.1)
        return found

    # ---- dump
    def test_dump_downloads_for_a_person_who_may_and_cleans_up(self):
        st, data, r = self.req("GET", "/api/database/dump?app=shop&env=develop&db=api:DATABASE_URL", "dba")
        self.assertEqual(st, 200)
        self.assertEqual(data, DUMP)
        self.assertIn("attachment", r.getheader("Content-Disposition"))
        self.assertEqual(self.leftovers(), [])

    def test_dump_is_refused_without_the_action_but_not_a_lie_about_existence(self):
        self.assertEqual(self.req("GET", "/api/database/dump?app=shop&env=develop&db=api:DATABASE_URL", "viewer")[0], 403)
        self.assertEqual(self.req("GET", "/api/database/dump?app=shop&env=develop&db=api:DATABASE_URL", "outsider")[0], 404)
        self.assertEqual(self.calls, [])

    def test_failed_dump_reports_an_error_and_leaves_no_file(self):
        self.dump_ok = False
        st, data, _ = self.req("GET", "/api/database/dump?app=shop&env=develop&db=api:DATABASE_URL", "dba")
        self.assertEqual(st, 500)
        self.assertIn(b"boom", data)
        self.assertEqual(self.leftovers(), [])

    def test_bad_ids_are_rejected(self):
        self.assertEqual(self.req("GET", "/api/database/dump?app=shop&env=develop&db=x;rm", "admin")[0], 400)

    # ---- restore
    def test_restore_backs_up_first_then_restores_then_redeploys(self):
        st, data, _ = self.restore("dba")
        self.assertEqual(st, 200)
        self.assertIn(b'"ok": true', data)
        self.assertEqual([c[:2] for c in self.calls], [("db", "dump"), ("db", "restore"), ("redeploy", "shop")])
        self.assertEqual(len(glob.glob(os.path.join(self.state, "db-backups", "shop-develop-database_url-*.dump"))), 1)
        self.assertEqual(self.leftovers(), [])        # the upload never stays on disk

    def test_restore_needs_the_action_and_hides_what_you_cannot_list(self):
        self.assertEqual(self.restore("viewer")[0], 403)
        self.assertEqual(self.restore("outsider")[0], 404)
        self.assertEqual(self.calls, [])

    def test_restore_needs_the_typed_confirmation(self):
        self.assertEqual(self.restore("dba", confirm="nope")[0], 400)
        self.assertEqual(self.calls, [])

    def test_prod_needs_a_second_confirmation_and_the_flag(self):
        self.assertEqual(self.restore("admin", env="prod", confirm="shop/prod")[0], 400)
        st, _, _ = self.restore("admin", env="prod", confirm="shop/prod", extra={"X-Allow-Prod": "yes"})
        self.assertEqual(st, 200)
        self.assertIn("--i-really-mean-prod", [c for call in self.calls if call[1] == "restore" for c in call])

    def test_only_custom_format_dumps_are_accepted(self):
        st, data, _ = self.restore("dba", body=b"-- plain SQL\nCREATE TABLE t();")
        self.assertEqual(st, 400)
        self.assertIn(b"custom-format", data)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.leftovers(), [])

    def test_oversize_and_empty_uploads_are_refused(self):
        with patch.object(console, "DB_UPLOAD_MAX", 100):
            self.assertEqual(self.restore("dba")[0], 413)
        self.assertEqual(self.restore("dba", body=b"")[0], 400)
        self.assertEqual(self.calls, [])

    def test_no_backup_means_no_restore(self):
        self.dump_ok = False
        st, data, _ = self.restore("dba")
        self.assertEqual(st, 200)
        self.assertIn(b'"ok": false', data)
        self.assertIn(b"Nothing was changed", data)
        self.assertNotIn("restore", [c[1] for c in self.calls])

    def test_only_the_last_backups_are_kept(self):
        for _ in range(console.DB_BACKUPS_KEPT + 3):
            self.restore("dba")
            for f in glob.glob(os.path.join(self.state, "db-backups", "*")):
                os.utime(f, (os.path.getmtime(f) - 5, os.path.getmtime(f) - 5))
            # distinct names: the stamp is per second
            import time
            time.sleep(1.05)
        self.assertLessEqual(len(glob.glob(os.path.join(self.state, "db-backups", "*.dump"))), console.DB_BACKUPS_KEPT)

    def test_info_reports_what_the_person_may_do(self):
        console_info = '{"databases": []}'
        with patch.object(console, "infra", lambda *a, **k: (True, console_info)):
            st, data, _ = self.req("GET", "/api/database?app=shop&env=develop", "dba")
            self.assertIn(b'"can_dump": true', data)
            self.assertIn(b'"can_restore": true', data)
            st, data, _ = self.req("GET", "/api/database?app=shop&env=develop", "viewer")
            self.assertIn(b'"can_dump": false', data)
            self.assertIn(b'"can_restore": false', data)


if __name__ == "__main__":
    unittest.main()
