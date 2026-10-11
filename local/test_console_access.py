#!/usr/bin/env python3
"""Focused tests for console organization and project authorization."""
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "platform", "console"))
os.environ.setdefault("INFRA_ROOT", ROOT)

from access import AccessStore  # noqa: E402
from console import may_change_org_member_role, require_project_role  # noqa: E402


class AccessStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = AccessStore(os.path.join(self.temp.name, "access.sqlite3"))
        self.store.create_organization("sage-org", "SageOrg")
        self.store.create_organization("yram-org", "YramOrg")
        self.store.link_project("sage-org", "shop-web")
        self.store.link_project("sage-org", "shop-api")
        self.store.link_project("yram-org", "income-api")
        self.sage_user = self.store.observe_identity("authentik-1", "sage", "sage@example.test", "Sage")
        self.yram_user = self.store.observe_identity("authentik-2", "yram", "yram@example.test", "Yram")
        self.store.observe_identity("authentik-3", "staff", "staff@example.test", "Staff")
        self.store.set_member("sage-org", self.sage_user["uid"], "member")
        self.store.set_member("sage-org", "authentik-3", "member")
        self.store.set_member("yram-org", self.yram_user["uid"], "member")

    def tearDown(self):
        self.temp.cleanup()

    def test_project_grants_are_explicit_and_isolated(self):
        self.store.grant_project("shop-api", self.sage_user["uid"], "viewer")
        self.assertEqual(self.store.visible_apps(self.sage_user["uid"]), ["shop-api"])
        self.assertEqual(self.store.role_for_project(self.sage_user["uid"], "shop-api"), "viewer")
        self.assertIsNone(self.store.role_for_project(self.sage_user["uid"], "shop-web"))
        self.assertIsNone(self.store.role_for_project(self.yram_user["uid"], "shop-api"))

    def test_membership_is_required_before_project_grant(self):
        with self.assertRaisesRegex(ValueError, "requires membership"):
            self.store.grant_project("shop-web", self.yram_user["uid"], "operator")

    def test_org_admin_does_not_inherit_project_access(self):
        self.store.set_member("sage-org", self.sage_user["uid"], "org_admin")
        self.assertTrue(self.store.can_admin_organization(self.sage_user["uid"], "sage-org"))
        self.assertIsNone(self.store.role_for_project(self.sage_user["uid"], "shop-web"))
        self.assertFalse(self.store.can_admin_organization(self.sage_user["uid"], "yram-org"))

    def test_only_platform_admins_can_assign_or_change_org_admins(self):
        self.store.set_member("sage-org", self.sage_user["uid"], "org_admin")
        org_admin = {"uid": self.sage_user["uid"], "platform_admin": False}
        platform_admin = {"uid": "platform", "platform_admin": True}
        self.assertTrue(may_change_org_member_role(
            org_admin, self.store, "sage-org", "authentik-3", "member"))
        self.assertFalse(may_change_org_member_role(
            org_admin, self.store, "sage-org", "authentik-3", "org_admin"))
        self.assertFalse(may_change_org_member_role(
            org_admin, self.store, "sage-org", self.sage_user["uid"], "none"))
        self.assertTrue(may_change_org_member_role(
            platform_admin, self.store, "sage-org", self.sage_user["uid"], "none"))

    def test_removing_org_membership_revokes_all_project_grants(self):
        self.store.grant_project("shop-web", self.sage_user["uid"], "maintainer")
        self.store.set_member("sage-org", self.sage_user["uid"], "none")
        self.assertIsNone(self.store.role_for_project(self.sage_user["uid"], "shop-web"))
        self.assertEqual(self.store.visible_apps(self.sage_user["uid"]), [])

    def test_email_assignment_requires_a_known_unique_authentik_identity(self):
        self.assertEqual(self.store.identity_uid("SAGE@example.test"), self.sage_user["uid"])
        with self.assertRaisesRegex(ValueError, "sign in through Authentik"):
            self.store.identity_uid("unknown@example.test")

    def test_role_hierarchy_is_enforced_by_shared_policy(self):
        self.store.grant_project("shop-api", self.sage_user["uid"], "viewer")
        actor = {"uid": self.sage_user["uid"], "platform_admin": False}
        self.assertEqual(require_project_role(actor, self.store, "shop-api"), "viewer")
        with self.assertRaises(PermissionError):
            require_project_role(actor, self.store, "shop-api", "operator")
        self.store.grant_project("shop-api", self.sage_user["uid"], "operator")
        self.assertEqual(require_project_role(actor, self.store, "shop-api", "operator"), "operator")
        admin = {"uid": "admin", "platform_admin": True}
        self.assertEqual(require_project_role(admin, self.store, "income-api", "maintainer"),
                         "platform_admin")


if __name__ == "__main__":
    unittest.main()
