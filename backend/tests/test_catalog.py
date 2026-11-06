import json
import unittest
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from itertools import product
from pathlib import Path
from unittest.mock import Mock

from botocore.stub import Stubber
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from jsonschema import RefResolver
from openapi_schema_validator import OAS30Validator
from runpass.api import create_app
from runpass.catalog import CatalogFilters, CatalogImporter, CatalogService, seed_synthetic
from runpass.identity import AuthFailure, Principal
from runpass.service import IdentityService, Problem
from runpass.store import DynamoStore, MemoryStore, Unavailable

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "backend/fixtures/catalog.synthetic.json"
NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True}


def edition(id="one", **changes):
    return {
        "id": id,
        "name": "Corrida São Paulo",
        "city": "São Paulo",
        "state": "SP",
        "date": "2026-09-01",
        "distances": [{"id": "10k", "kilometers": 10}],
        **changes,
    }


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.now = NOW
        self.identity = IdentityService(
            self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: self.now
        )
        self.key = Fernet.generate_key()
        self.catalog = CatalogService(self.identity, self.key)
        self.importer = CatalogImporter(self.catalog)
        self.actor = self.admit("runner")
        seed_synthetic(self.catalog, FIXTURE)

    def admit(self, sub):
        actor = Principal(sub, True)
        self.identity.create_profile(actor, "create", {"username": sub, "displayName": sub})
        self.identity.admit(actor, "admit", ADULT)
        return actor

    def put(self, payload, version=0):
        return self.importer.put(
            payload, expected_version=version, origin="synthetic-fixture", synthetic=True
        )

    def all_pages(self, filters):
        cursor, found = None, []
        for _ in range(100):
            page = self.catalog.list(self.actor, filters, cursor)
            found += [v["id"] for v in page["items"]]
            cursor = page.get("nextCursor")
            if not cursor:
                return found
        self.fail("Pagination failed to terminate")

    def test_all_64_filter_combinations_return_expected_complete_set(self):
        all_ids = {
            "synthetic-sp-2024",
            "synthetic-sp-2025",
            "synthetic-sp-2026",
            "synthetic-rj-2026",
            "synthetic-archived",
        }
        samples = [
            (
                "namePrefix",
                " CORRIDA  SINTETICA ",
                {"synthetic-sp-2024", "synthetic-sp-2025", "synthetic-sp-2026"},
            ),
            ("city", "sao paulo", all_ids - {"synthetic-rj-2026"}),
            ("state", "sp", all_ids - {"synthetic-rj-2026"}),
            ("dateFrom", "2025-01-01", all_ids - {"synthetic-sp-2024"}),
            ("dateTo", "2026-10-28", all_ids - {"synthetic-sp-2026"}),
            ("distanceKm", "10.0", {"synthetic-sp-2024", "synthetic-sp-2025", "synthetic-rj-2026"}),
        ]
        for flags in product([False, True], repeat=6):
            expected, kwargs = set(all_ids), {"limit": 2}
            for flag, (name, value, ids) in zip(flags, samples, strict=True):
                if flag:
                    kwargs[name] = value
                    expected &= ids
            with self.subTest(flags=flags):
                actual = self.all_pages(CatalogFilters(**kwargs))
                self.assertEqual(set(actual), expected)
                self.assertEqual(len(actual), len(set(actual)))

    def test_cursor_bound_to_actor_filters_limit_environment_and_expiration(self):
        cursor = self.catalog.list(self.actor, CatalogFilters(limit=1))["nextCursor"]
        other = self.admit("other")
        calls = [
            lambda: self.catalog.list(other, CatalogFilters(limit=1), cursor),
            lambda: self.catalog.list(self.actor, CatalogFilters(limit=2), cursor),
            lambda: self.catalog.list(
                self.actor, CatalogFilters(limit=1, city="São Paulo"), cursor
            ),
            lambda: self.catalog.list(self.actor, CatalogFilters(limit=1), cursor[:-5] + "tamper"),
        ]
        for call in calls:
            with self.assertRaises(Problem) as error:
                call()
            self.assertEqual(error.exception.code, "INVALID_CURSOR")
        original = self.identity.environment
        self.identity.environment = "other-env"
        different = CatalogService(self.identity, self.key)
        with self.assertRaises(Problem):
            different.list(self.actor, CatalogFilters(limit=1), cursor)
        self.identity.environment = original
        self.now += timedelta(minutes=15)
        with self.assertRaises(Problem):
            self.catalog.list(self.actor, CatalogFilters(limit=1), cursor)

    def test_normalized_equivalent_filters_can_continue_cursor(self):
        first = self.catalog.list(
            self.actor, CatalogFilters(city="SÃO PAULO", distanceKm="10.0", limit=1)
        )
        second = self.catalog.list(
            self.actor,
            CatalogFilters(city="sao  paulo", distanceKm=10, limit=1),
            first["nextCursor"],
        )
        self.assertNotEqual(first["items"][0]["id"], second["items"][0]["id"])

    def test_seed_idempotent_and_no_fabricated_score_or_counter(self):
        before = deepcopy(self.store.items)
        self.assertEqual(seed_synthetic(self.catalog, FIXTURE), 5)
        self.assertEqual(self.store.items, before)
        body = self.catalog.detail(self.actor, "synthetic-sp-2024")
        self.assertEqual([int(d["kilometers"]) for d in body["distances"]], [5, 10])
        self.assertNotIn("runScore", body)
        self.assertNotIn("participantCount", body)
        self.assertNotIn("reviewRef", body)

    def test_archive_preserves_history_but_blocks_new_completion(self):
        body = self.catalog.detail(self.actor, "synthetic-archived")
        self.assertEqual(body["status"], "archived")
        with self.assertRaises(Problem) as error:
            self.catalog.require_completable(self.actor, "synthetic-archived", "5k")
        self.assertEqual(error.exception.code, "EDITION_ARCHIVED")
        self.assertIsNotNone(self.store.get(("catalog", "EDITION#synthetic-archived", "V#1")))
        with self.assertRaises(Problem):
            self.catalog.require_completable(self.actor, "synthetic-sp-2024", "wrong-distance")

    def test_current_date_changes_upcoming_without_archival(self):
        self.assertEqual(self.catalog.detail(self.actor, "synthetic-sp-2026")["status"], "upcoming")
        self.now = datetime(2026, 11, 9, tzinfo=timezone.utc)
        self.assertEqual(self.catalog.detail(self.actor, "synthetic-sp-2026")["status"], "past")

    def test_unauthenticated_unadmitted_and_deleted_have_no_catalog(self):
        new = Principal("new", True)
        with self.assertRaises(Problem):
            self.catalog.list(new, CatalogFilters())
        self.identity.delete_account(self.actor, "delete")
        with self.assertRaises(Problem):
            self.catalog.detail(self.actor, "synthetic-sp-2024")
        with self.assertRaises(Problem):
            self.catalog.list(self.actor, CatalogFilters())

    def test_nonpublic_or_stale_index_not_served(self):
        key = ("catalog", "EDITION#synthetic-sp-2024", "HEAD")
        previous = self.store.get(key)
        self.store.commit({key: previous}, {key: {**previous, "publicationState": "pending"}})
        self.assertNotIn("synthetic-sp-2024", self.all_pages(CatalogFilters()))
        with self.assertRaises(Problem) as error:
            self.catalog.detail(self.actor, "synthetic-sp-2024")
        self.assertEqual(error.exception.status, 404)

    def test_source_revalidated_and_old_generation_does_not_duplicate(self):
        self.put(edition())
        self.put(edition(name="Outra Corrida", city="Santos"), version=1)
        found = self.catalog.list(
            self.actor,
            CatalogFilters(city="São Paulo", namePrefix="Corrida", dateFrom="2026-01-01"),
        )
        self.assertNotIn("one", [v["id"] for v in found["items"]])
        matches = self.catalog.list(self.actor, CatalogFilters(city="Santos"))["items"]
        self.assertEqual([v["id"] for v in matches], ["one"])
        self.assertEqual(matches[0]["version"], 2)

    def test_empty_page_after_500_candidates_has_continuation(self):
        # 501 stale references exercise the work cap without creating fake public editions.
        pk = CatalogFilters(namePrefix="zzz", dateFrom="2026-01-01", limit=1).plan()[0]
        with self.store.lock:
            for i in range(501):
                self.store.items[("catalog", pk, f"2026-08-01#stale-{i:04}#1")] = {
                    "editionId": f"stale-{i}",
                    "version": 1,
                    "_rev": 1,
                }
        filters = CatalogFilters(namePrefix="zzz", dateFrom="2026-01-01", limit=1)
        first = self.catalog.list(self.actor, filters)
        self.assertEqual(first["items"], [])
        self.assertIn("nextCursor", first)
        second = self.catalog.list(self.actor, filters, first["nextCursor"])
        self.assertEqual(second, {"items": []})

    def test_interrupted_large_import_keeps_old_generation_and_resumes(self):
        self.put(edition())
        payload = edition(
            name="Nova Corrida", distances=[{"id": f"d{i}", "kilometers": i + 1} for i in range(21)]
        )
        original = self.store.commit
        batches = 0

        def fail_second_index_batch(expected, writes):
            nonlocal batches
            if any(k[0] == "catalog" and k[1].startswith("CAT#") for k in writes):
                batches += 1
                if batches == 2:
                    raise Unavailable()
            return original(expected, writes)

        self.store.commit = fail_second_index_batch
        with self.assertRaises(Unavailable):
            self.put(payload, version=1)
        self.assertEqual(self.catalog.detail(self.actor, "one")["version"], 1)
        self.store.commit = original
        self.assertEqual(self.put(payload, version=1)["version"], 2)
        self.assertEqual(self.catalog.detail(self.actor, "one")["name"], "Nova Corrida")

    def test_retire_old_indexes_preserves_current_and_immutable_history(self):
        self.put(edition())
        old = self.store.get(("catalog", "EDITION#one", "V#1"))
        self.put(edition(name="New Name"), version=1)
        self.importer.retire_indexes("one", 1, synthetic=True)
        self.assertEqual(self.catalog.detail(self.actor, "one")["version"], 2)
        self.assertEqual(self.store.get(("catalog", "EDITION#one", "V#1")), old)
        self.assertTrue(
            all(self.store.get(("catalog", pk, sk)) is None for pk, sk in old["indexKeys"])
        )
        with self.assertRaises(Problem):
            self.importer.retire_indexes("one", 2, synthetic=True)

    def test_archive_reason_requires_an_archived_edition(self):
        operator = Principal("operator", True, "operator", "digest")
        with self.assertRaises(Problem):
            self.importer.put(
                edition("reason", archivedReason="cancelled"),
                expected_version=0,
                origin="https://example.test/race",
                actor=operator,
            )
        with self.assertRaises(Problem):
            self.importer.put(
                edition("bad", archived=True, archivedReason="made-up"),
                expected_version=0,
                origin="https://example.test/race",
                actor=operator,
            )

    def test_revoked_operator_during_staging_cannot_activate(self):
        operator = Principal("operator", True, "operator", "digest")
        access = ("identity", "OPERATOR#operator", "ACCESS")
        session = ("operations", "OPERATOR#operator", "SESSION#digest")
        self.store.commit(
            {access: None, session: None},
            {
                access: {"state": "active", "permissions": ["catalog_admin"]},
                session: {
                    "factor": "SOFTWARE_TOKEN_MFA",
                    "accessVersion": 1,
                    "expiresAt": int(NOW.timestamp()) + 1000,
                },
            },
        )
        original = self.store.commit

        def revoke(expected, writes):
            original(expected, writes)
            if any(k[1].startswith("CAT#") for k in writes):
                current = self.store.get(access)
                original({access: current}, {access: {"state": "suspended", "permissions": []}})

        self.store.commit = revoke
        with self.assertRaises(AuthFailure):
            self.importer.put(
                edition(), expected_version=0, origin="https://example.test/race", actor=operator
            )
        self.assertIsNone(self.store.get(("catalog", "EDITION#one", "HEAD")))

    def test_invalid_readonly_score_version_and_image_are_rejected(self):
        for changes in (
            {"runScore": {"value": 5, "reviewCount": 999}},
            {"participantCount": 9},
            {"medalImageReference": "unvalidated"},
            {"date": "not-a-date"},
            {"distances": [{"id": "d", "kilometers": 0}]},
            {"distances": [{"id": "d", "kilometers": 5}, {"id": "d", "kilometers": 10}]},
        ):
            with self.subTest(changes=changes), self.assertRaises(Problem):
                self.put(edition(**changes))
        self.put(edition())
        with self.assertRaises(Problem):
            self.put(edition(name="Collision"))

    def test_invalid_future_version_does_not_reserve_an_orphan_slot(self):
        self.put(edition())
        before = deepcopy(self.store.items)
        with self.assertRaises(Problem):
            self.put(edition(name="Wrong future version"), version=99)
        self.assertEqual(self.store.items, before)

    def test_validated_catalog_image_pinned_with_reference_count(self):
        key = ("operations", "EDITION#one", "IMAGE#image-v1")
        self.store.commit(
            {key: None},
            {key: {"state": "valid", "origin": "admin", "environment": "local", "refs": 0}},
        )
        body = self.put(edition(medalImageReference="image-v1"))
        self.assertEqual(body["medalImageReference"], "image-v1")
        self.assertEqual(self.store.get(key)["refs"], 1)
        self.put(edition(medalImageReference="image-v1"))
        self.assertEqual(self.store.get(key)["refs"], 1)

    def test_real_import_requires_current_operator_mfa_and_auditable_origin(self):
        with self.assertRaises(Problem):
            self.importer.put(edition(), expected_version=0, origin="https://example.test/race")
        operator = Principal("operator", True, "operator", "digest")
        access = ("identity", "OPERATOR#operator", "ACCESS")
        session = ("operations", "OPERATOR#operator", "SESSION#digest")
        self.store.commit(
            {access: None, session: None},
            {
                access: {"state": "active", "permissions": ["catalog_admin"]},
                session: {
                    "factor": "SOFTWARE_TOKEN_MFA",
                    "accessVersion": 1,
                    "expiresAt": int(NOW.timestamp()) + 1000,
                },
            },
        )
        result = self.importer.put(
            edition(), expected_version=0, origin="https://example.test/race", actor=operator
        )
        self.assertEqual(result["version"], 1)
        self.assertEqual(
            self.store.get(("operations", "CATALOG#one", "REV#1"))["actor"], "operator"
        )
        self.assertNotIn("reviewedBy", self.store.get(("catalog", "EDITION#one", "V#1")))
        self.store.commit(
            {access: self.store.get(access)}, {access: {"state": "suspended", "permissions": []}}
        )
        with self.assertRaises(AuthFailure):
            self.importer.put(
                edition(name="Changed"),
                expected_version=1,
                origin="https://example.test/race",
                actor=operator,
            )


class CatalogApiTests(unittest.TestCase):
    def setUp(self):
        self.identity = IdentityService(
            MemoryStore(), b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW
        )
        self.actor = Principal("runner", True)
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, FIXTURE)

        def verify(token):
            if token != "synthetic":
                raise AuthFailure()
            return self.actor

        self.client = TestClient(create_app(self.identity, verify, self.catalog))
        self.headers = {"Authorization": "Bearer synthetic"}
        self.identity.create_profile(
            self.actor, "create", {"displayName": "Runner", "username": "runner"}
        )

    def test_admission_required_and_http_responses_match_canonical_schemas(self):
        self.assertEqual(self.client.get("/editions").status_code, 401)
        self.assertEqual(self.client.get("/editions", headers=self.headers).status_code, 403)
        self.identity.admit(self.actor, "admit", ADULT)
        contract = json.loads((ROOT / "PDLC/M4/API-RunPass-v1.openapi.json").read_text())
        for path, schema in [
            ("/editions?city=sao%20paulo&distanceKm=10&limit=1", "EditionPage"),
            (
                "/editions?q=sao&registrationStatus=unknown&lat=-23.55&lon=-46.63&radiusKm=50",
                "EditionPage",
            ),
            ("/editions/synthetic-sp-2024", "Edition"),
        ]:
            response = self.client.get(path, headers=self.headers)
            self.assertEqual(response.status_code, 200, response.text)
            OAS30Validator(
                contract["components"]["schemas"][schema],
                resolver=RefResolver.from_schema(contract),
            ).validate(response.json())
        self.identity.delete_account(self.actor, "delete")
        self.assertEqual(
            self.client.get("/editions/synthetic-sp-2024", headers=self.headers).status_code, 403
        )

    def test_invalid_filters_rejected_without_mutation(self):
        self.identity.admit(self.actor, "admit", ADULT)
        before = deepcopy(self.identity.store.items)
        for query in (
            "limit=101",
            "distanceKm=-5",
            "distanceKm=NaN",
            "state=BAD",
            "dateFrom=2027-01-01&dateTo=2026-01-01",
            "city=%20%20",
            "cursor=",
            "lat=-23.5&lon=-46.6",  # raio incompleto
            "radiusKm=10",
            "lat=95&lon=0&radiusKm=5",
            "registrationStatus=aberta",
            "q=%20%20",
        ):
            response = self.client.get("/editions?" + query, headers=self.headers)
            self.assertEqual(response.status_code, 422, query)
        self.assertEqual(before, self.identity.store.items)


class CatalogDynamoTests(unittest.TestCase):
    def test_query_is_partition_scoped_strong_and_continues_exclusive_start_key(self):
        import boto3

        client = boto3.client(
            "dynamodb",
            region_name="sa-east-1",
            aws_access_key_id="synthetic",
            aws_secret_access_key="synthetic",
        )
        store = DynamoStore(client, {"catalog": "synthetic-catalog"})
        pk = "CAT#GLOBAL#ANY#DATE"
        start = {"PK": {"S": pk}, "SK": {"S": "2025-01-01#one#1"}}
        end = {"PK": {"S": pk}, "SK": {"S": "2026-01-01#two#1"}}
        with Stubber(client) as stub:
            stub.add_response(
                "query",
                {
                    "Items": [{**end, "editionId": {"S": "two"}, "version": {"N": "1"}}],
                    "LastEvaluatedKey": end,
                },
                {
                    "TableName": "synthetic-catalog",
                    "KeyConditionExpression": "PK = :pk AND SK BETWEEN :lo AND :hi",
                    "ExpressionAttributeValues": {
                        ":pk": {"S": pk},
                        ":lo": {"S": "2024"},
                        ":hi": {"S": "2027"},
                    },
                    "ConsistentRead": True,
                    "Limit": 1,
                    "ScanIndexForward": True,
                    "ExclusiveStartKey": start,
                },
            )
            rows, cursor = store.query(
                "catalog", pk, lower="2024", upper="2027", after="2025-01-01#one#1", limit=1
            )
            self.assertEqual(rows[0][1]["editionId"], "two")
            self.assertEqual(cursor, "2026-01-01#two#1")
            stub.assert_no_pending_responses()

    def test_synthetic_loader_cannot_target_dynamodb(self):
        identity = IdentityService(
            DynamoStore(Mock(), {"catalog": "test"}), b"synthetic-only-hmac-key-32-bytes!!"
        )
        with self.assertRaises(ValueError):
            seed_synthetic(CatalogService(identity, Fernet.generate_key()), FIXTURE)
