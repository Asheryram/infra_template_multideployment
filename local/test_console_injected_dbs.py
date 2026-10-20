#!/usr/bin/env python3
"""A created database's URL counts as available to the next deploy; a missing or wiped one does not."""
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "platform", "console"))
os.environ.setdefault("INFRA_ROOT", ROOT)

import console  # noqa: E402

MANIFEST = {"services": {"api": {"databases": [{"inject_as": "DATABASE_URL"}, {"inject_as": "ANALYTICS_DATABASE_URL"}]},
                         "web": {}}}


class InjectedDatabaseKeys(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.s = {"deploy_root": self.t.name, "secrets_root": os.path.join(self.t.name, "secrets")}
        self.d = os.path.join(self.t.name, "jkbk", "pr-5")
        os.makedirs(self.d)
        p = patch.object(console, "load_manifest", lambda _d: MANIFEST)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.t.cleanup)

    def touch(self, name):
        open(os.path.join(self.d, name), "w").close()

    def test_created_databases_are_available(self):
        self.touch(".db_password_jkbk_pr_5_api_database_url")
        self.touch(".db_password_jkbk_pr_5_api_analytics_database_url")
        self.assertEqual(console.available_keys(self.s, "jkbk", "pr-5", "api"), {"DATABASE_URL", "ANALYTICS_DATABASE_URL"})

    def test_not_created_or_wiped_are_not(self):
        self.touch(".db_password_jkbk_pr_5_api_database_url")
        self.touch(".db_wiped_jkbk_pr_5_api_database_url")
        self.assertEqual(console.available_keys(self.s, "jkbk", "pr-5", "api"), set())

    def test_other_services_get_nothing(self):
        self.touch(".db_password_jkbk_pr_5_api_database_url")
        self.assertEqual(console.available_keys(self.s, "jkbk", "pr-5", "web"), set())


if __name__ == "__main__":
    unittest.main()
