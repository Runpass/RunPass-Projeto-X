import unittest
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from runpass.catalog import CatalogFilters, CatalogService
from runpass.identity import Principal
from runpass.operator_admin import FIXTURE_ORIGIN, grant_access, load_catalog
from runpass.service import IdentityService
from runpass.store import MemoryStore

from .dynamo_fake import SerializingDynamoStore

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/catalog.synthetic.json"
NOW = datetime(2026, 11, 4, 15, tzinfo=timezone.utc)


class OperatorAdminTest(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW
        )
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        self.operator = Principal("op", True, "operator", "digest")

    def session(self):
        key = ("operations", "OPERATOR#op", "SESSION#digest")
        access = self.store.get(("identity", "OPERATOR#op", "ACCESS"))
        self.store.commit(
            {key: None},
            {
                key: {
                    "factor": "SOFTWARE_TOKEN_MFA",
                    "accessVersion": access["_rev"],
                    "expiresAt": int(NOW.timestamp()) + 1000,
                }
            },
        )

    def test_grant_requires_distinct_responsible_and_known_permissions(self):
        with self.assertRaises(ValueError):
            grant_access(self.store, "op", ["catalog_admin"], "op")
        with self.assertRaises(ValueError):
            grant_access(self.store, "op", ["root"], "other")
        with self.assertRaises(ValueError):
            grant_access(self.store, "op", [], "other")

    def test_grant_is_versioned_and_minimal(self):
        first = grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.assertEqual(first["permissions"], ["catalog_admin"])
        self.assertEqual(first["state"], "active")
        second = grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.assertEqual(second["_rev"], first["_rev"] + 1)

    def test_load_without_access_or_session_is_refused(self):
        with self.assertRaises(Exception):
            load_catalog(self.catalog, self.operator, FIXTURE.read_text())

    def test_load_through_real_importer_is_idempotent_and_labelled(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        ids = load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        again = load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.assertEqual(ids, again)
        self.assertEqual(len(ids), 5)
        manifest = self.store.get(("catalog", "EDITION#synthetic-sp-2026", "V#1"))
        self.assertEqual(manifest["origin"], FIXTURE_ORIGIN)
        self.assertTrue(FIXTURE_ORIGIN.startswith("https://"))
        runner = Principal("runner", True)
        self.identity.create_profile(runner, "p", {"username": "runner", "displayName": "R"})
        self.identity.admit(runner, "a", {"birthDate": "1990-01-01", "declaresAdult": True})
        listed = self.catalog.list(runner, CatalogFilters())["items"]
        self.assertTrue(all("Sint" in e["name"] for e in listed))

    def test_changed_entry_publishes_a_new_version_with_the_archive_reason(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        text = FIXTURE.read_text()
        load_catalog(self.catalog, self.operator, text)
        changed = text.replace('"archivedReason":"cancelled"', '"archivedReason":"unavailable"')
        self.assertNotEqual(changed, text)
        load_catalog(self.catalog, self.operator, changed)
        load_catalog(self.catalog, self.operator, changed)  # repetir nao cria versao nova
        head = self.store.get(("catalog", "EDITION#synthetic-archived", "HEAD"))
        self.assertEqual(head["version"], 2)
        runner = Principal("runner", True)
        self.identity.create_profile(runner, "p", {"username": "runner", "displayName": "R"})
        self.identity.admit(runner, "a", {"birthDate": "1990-01-01", "declaresAdult": True})
        body = self.catalog.detail(runner, "synthetic-archived")
        self.assertEqual(body["status"], "archived")
        self.assertEqual(body["archivedReason"], "unavailable")

    def test_update_works_with_dynamodb_decimal_versions(self):
        # DynamoDB devolve numeros como Decimal; a versao esperada precisa virar inteiro.
        store = SerializingDynamoStore()
        identity = IdentityService(store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW)
        catalog = CatalogService(identity, Fernet.generate_key())
        grant_access(store, "op", ["catalog_admin"], "other", NOW)
        access = store.get(("identity", "OPERATOR#op", "ACCESS"))
        key = ("operations", "OPERATOR#op", "SESSION#digest")
        store.commit(
            {key: None},
            {
                key: {
                    "factor": "SOFTWARE_TOKEN_MFA",
                    "accessVersion": access["_rev"],
                    "expiresAt": int(NOW.timestamp()) + 1000,
                }
            },
        )
        text = FIXTURE.read_text()
        load_catalog(catalog, self.operator, text)
        changed = text.replace('"archivedReason":"cancelled"', '"archivedReason":"ended"')
        load_catalog(catalog, self.operator, changed)
        load_catalog(catalog, self.operator, changed)
        head = store.get(("catalog", "EDITION#synthetic-archived", "HEAD"))
        self.assertEqual(head["version"], 2)

    def test_revoked_access_stops_the_load(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        key = ("identity", "OPERATOR#op", "ACCESS")
        self.store.commit(
            {key: self.store.get(key)}, {key: {"state": "suspended", "permissions": []}}
        )
        with self.assertRaises(Exception):
            load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.assertIsNone(self.store.get(("catalog", "EDITION#synthetic-sp-2026", "HEAD")))


if __name__ == "__main__":
    unittest.main()
