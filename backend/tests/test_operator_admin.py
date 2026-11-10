import unittest
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from dynamo_fake import SerializingDynamoStore
from runpass.catalog import CatalogFilters, CatalogService
from runpass.identity import Principal
from runpass.operator_admin import (
    FIXTURE_ORIGIN,
    approve_banner,
    grant_access,
    load_catalog,
    retire_catalog,
)
from runpass.service import IdentityService
from runpass.store import MemoryStore
from runpass.upload import MemoryBlobStore, UploadService

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

    def test_retire_archives_and_unlists_but_keeps_detail_and_is_repeatable(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        first = retire_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.assertEqual(len(first["tiradas_da_lista"]), 5)
        again = retire_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.assertEqual(again["arquivadas"], [])
        runner = Principal("runner", True)
        self.identity.create_profile(runner, "p", {"username": "runner", "displayName": "R"})
        self.identity.admit(runner, "a", {"birthDate": "1990-01-01", "declaresAdult": True})
        self.assertEqual(self.catalog.list(runner, CatalogFilters())["items"], [])
        self.assertEqual(self.catalog.detail(runner, "synthetic-sp-2026")["status"], "archived")

    def test_retire_without_session_is_refused_and_ignores_unloaded(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        out = retire_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.assertEqual(len(out["ausentes"]), 5)
        self.session()
        load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        self.store.commit(
            {
                ("operations", "OPERATOR#op", "SESSION#digest"): self.store.get(
                    ("operations", "OPERATOR#op", "SESSION#digest")
                )
            },
            {("operations", "OPERATOR#op", "SESSION#digest"): None},
        )
        with self.assertRaises(Exception):
            retire_catalog(self.catalog, self.operator, FIXTURE.read_text())

    def png(self):
        import io

        from PIL import Image

        out = io.BytesIO()
        Image.new("RGB", (640, 360), (200, 60, 20)).save(out, format="PNG")
        return out.getvalue()

    def test_banner_needs_credit_and_rights_note_and_publishes_only_after_both(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        blobs = MemoryBlobStore()
        args = (self.catalog, blobs, self.operator, "synthetic-sp-2025", self.png(), "image/png")
        with self.assertRaises(ValueError):
            approve_banner(
                *args, "", "Autorizacao por e-mail do organizador em 10/11", "https://x.exemplo/o"
            )
        with self.assertRaises(ValueError):
            approve_banner(*args, "Divulgação: Org", "ok", "https://x.exemplo/o")
        self.assertEqual(blobs.derived, {})  # nada foi guardado sem credito e base de autorizacao
        result = approve_banner(
            *args,
            "Divulgação: Org",
            "Autorizacao por e-mail do organizador em 10/11",
            "https://x.exemplo/o",
        )
        self.assertTrue(result["reference"].startswith("banner_"))
        runner = Principal("runner", True)
        self.identity.create_profile(runner, "p", {"username": "runner", "displayName": "R"})
        self.identity.admit(runner, "a", {"birthDate": "1990-01-01", "declaresAdult": True})
        edition = self.catalog.detail(runner, "synthetic-sp-2025")
        self.assertEqual(edition["imageCredit"], "Divulgação: Org")
        link = UploadService(self.identity, blobs).edition_banner(runner, edition)
        self.assertEqual(link["credit"], "Divulgação: Org")
        self.assertEqual(link["contentType"], "image/png")
        self.assertIn("banner_", link["url"])
        # a base de autorizacao fica so na tabela de operacoes, nunca na API
        row = self.store.get(
            ("operations", "EDITION#synthetic-sp-2025", "IMAGE#" + result["reference"])
        )
        self.assertIn("Autorizacao", row["rightsNote"])
        self.assertNotIn("rightsNote", edition)
        other = self.catalog.detail(runner, "synthetic-sp-2024")
        with self.assertRaises(Exception) as none:
            UploadService(self.identity, blobs).edition_banner(runner, other)
        self.assertEqual(none.exception.code, "IMAGE_NOT_AVAILABLE")

    def test_banner_refuses_a_file_that_is_not_the_declared_image(self):
        grant_access(self.store, "op", ["catalog_admin"], "other", NOW)
        self.session()
        load_catalog(self.catalog, self.operator, FIXTURE.read_text())
        blobs = MemoryBlobStore()
        with self.assertRaises(Exception):
            approve_banner(
                self.catalog,
                blobs,
                self.operator,
                "synthetic-sp-2025",
                b"<html>nao e imagem</html>",
                "image/png",
                "Divulgação: Org",
                "Autorizacao por e-mail do organizador",
                "https://x.exemplo/o",
            )
        self.assertEqual(blobs.derived, {})

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
