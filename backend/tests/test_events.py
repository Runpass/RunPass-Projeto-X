import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from cryptography.fernet import Fernet
from dynamo_fake import SerializingDynamoStore
from runpass.catalog import CatalogService, seed_synthetic
from runpass.erasure import ErasureProcessor
from runpass.events import EventProcessor
from runpass.identity import Principal
from runpass.participation import ParticipationService
from runpass.service import IdentityService, Problem, stamp
from runpass.store import MemoryStore, Unavailable

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)
RATINGS = {
    name: 5
    for name in (
        "organization",
        "course",
        "kit",
        "medal",
        "hydration",
        "facilities",
        "safety",
        "valueForMoney",
    )
}


class EventFixture(unittest.TestCase):
    def make_store(self):
        return MemoryStore()

    def seed_catalog(self, catalog):
        seed_synthetic(catalog, ROOT / "backend/fixtures/catalog.synthetic.json")

    def setUp(self):
        self.now = NOW
        self.store = self.make_store()
        self.identity = IdentityService(
            self.store, b"events-test-hmac-key-at-least-32", lambda: self.now
        )
        catalog = CatalogService(self.identity, Fernet.generate_key())
        self.seed_catalog(catalog)
        self.participations = ParticipationService(self.identity, catalog, Fernet.generate_key())
        self.processor = EventProcessor(self.identity)
        self.actor = Principal("owner", True)
        self.identity.create_profile(
            self.actor, "profile", {"displayName": "Owner", "username": "owner"}
        )
        self.identity.admit(
            self.actor,
            "admit",
            {"birthDate": "1990-01-01", "declaresAdult": True, "gender": "undisclosed"},
        )

    def complete(self):
        draft = self.participations.create(
            self.actor,
            "create",
            {"editionId": "synthetic-sp-2024", "distanceId": "10k"},
        )
        image_key = ("operations", "USER#owner", "IMAGE#valid")
        self.store.commit(
            {image_key: None},
            {
                image_key: {
                    "owner": "owner",
                    "origin": "runner",
                    "state": "valid",
                    "refs": 0,
                }
            },
        )
        self.participations.complete(
            self.actor,
            draft["id"],
            "complete",
            {
                "expectedVersion": 1,
                "declaredCompleted": True,
                "ratings": RATINGS,
                "medalImageReference": "valid",
                "publishToFeed": False,
                "comment": "Comentário privado de auditoria",
            },
        )
        events = [
            item
            for (table, pk, sk), item in self.store.items.items()
            if table == "operations" and pk == "USER#owner" and sk.startswith("EVENT#")
        ]
        self.assertEqual(len(events), 1)
        return draft, events[0]


class EventProcessorTests(EventFixture):
    def test_duplicate_delivery_is_idempotent_and_score_uses_integer_sum(self):
        _, event = self.complete()
        first = self.processor.deliver("owner", event["id"], "score")
        self.assertEqual(self.processor.deliver("owner", event["id"], "score"), first)
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 1, "runScore": "5.0"},
        )
        contribution = self.store.get(
            ("projections", "USER#owner", "CONTRIBUTION#" + event["participationId"])
        )
        self.assertEqual((contribution["ratingSum"], contribution["effectVersion"]), (40, 1))

    def test_last_confirmation_sets_expiry_once_and_audit_is_separate(self):
        _, event = self.complete()
        self.processor.deliver("owner", event["id"], "audit")
        pending = self.store.get(("operations", "USER#owner", "EVENT#" + event["id"]))
        self.assertNotIn("allConfirmedAt", pending)
        lake = self.store.get(("operations", "USER#owner", "LAKE#" + event["id"]))
        self.assertEqual(lake["after"]["comment"], "Comentário privado de auditoria")
        self.assertNotIn("comment", event)

        self.processor.deliver("owner", event["id"], "score")
        confirmed = self.store.get(("operations", "USER#owner", "EVENT#" + event["id"]))
        expiry = confirmed["payloadExpiresAt"]
        self.now += timedelta(days=1)
        self.processor.deliver("owner", event["id"], "score")
        self.assertEqual(
            self.store.get(("operations", "USER#owner", "EVENT#" + event["id"]))[
                "payloadExpiresAt"
            ],
            expiry,
        )
        self.now += timedelta(days=7)
        with self.assertRaises(Problem) as error:
            self.processor.deliver("owner", event["id"], "score")
        self.assertEqual(error.exception.code, "EVENT_EXPIRED")

    def test_out_of_order_event_reconciles_current_source_without_double_count(self):
        draft, first = self.complete()
        review_key = ("history", "USER#owner", "P#" + draft["id"] + "#REVIEW")
        review = self.store.get(review_key)
        changed = {**review, "ratings": {**RATINGS, "course": 1}, "effectVersion": 2}
        self.store.commit({review_key: review}, {review_key: changed})
        second_id = str(uuid4())
        second_key = ("operations", "USER#owner", "EVENT#" + second_id)
        second = {
            **first,
            "id": second_id,
            "effectVersion": 2,
            "ratings": changed["ratings"],
            "occurredAt": stamp(self.now),
        }
        self.store.commit({second_key: None}, {second_key: second})

        self.processor.deliver("owner", second_id, "score")
        self.processor.deliver("owner", first["id"], "score")
        score = self.store.get(("projections", "EDITION#synthetic-sp-2024", "SCORE#current"))
        self.assertEqual((score["ratingSum"], score["reviewCount"]), (36, 1))

    def test_stale_epoch_and_unknown_event_fail_closed(self):
        _, event = self.complete()
        with self.assertRaises(Problem) as error:
            self.processor.deliver("owner", event["id"], "score", dispatch_epoch=0)
        self.assertEqual(error.exception.code, "STALE_DISPATCH_EPOCH")
        with self.assertRaises(Problem):
            self.processor.deliver("owner", "missing", "score")

    def test_reconciler_finds_durable_pending_marker_after_partial_delivery(self):
        _, event = self.complete()
        self.processor.deliver("owner", event["id"], "score")
        marker_key = (
            "operations",
            event["workPartition"],
            event["workSort"],
        )
        self.assertEqual(self.store.get(marker_key)["state"], "pending")
        self.assertEqual(self.processor.reconcile(), {"processed": 1, "failed": 0})
        self.assertEqual(self.store.get(marker_key)["state"], "completed")
        confirmed = self.store.get(("operations", "USER#owner", "EVENT#" + event["id"]))
        self.assertIn("allConfirmedAt", confirmed)

    def test_lease_fencing_rejects_stale_worker_and_renews_same_token(self):
        _, event = self.complete()
        first = self.processor.acquire_lease("score", "worker-a")
        renewed = self.processor.acquire_lease("score", "worker-a", first["fencingToken"])
        self.assertEqual(renewed["fencingToken"], first["fencingToken"])
        with self.assertRaises(Problem) as held:
            self.processor.acquire_lease("score", "worker-b")
        self.assertEqual(held.exception.code, "LEASE_HELD")

        self.now += timedelta(seconds=61)
        second = self.processor.acquire_lease("score", "worker-b")
        self.assertGreater(second["fencingToken"], first["fencingToken"])
        with self.assertRaises(Problem) as stale:
            self.processor.deliver(
                "owner",
                event["id"],
                "score",
                worker_id="worker-a",
                fencing_token=first["fencingToken"],
            )
        self.assertEqual(stale.exception.code, "STALE_FENCING_TOKEN")

    def test_reconciler_failure_uses_backoff_and_remains_discoverable(self):
        _, event = self.complete()
        review_key = ("history", "USER#owner", "P#" + event["participationId"] + "#REVIEW")
        review = self.store.get(review_key)
        self.store.commit({review_key: review}, {review_key: None})
        self.assertEqual(self.processor.reconcile(), {"processed": 0, "failed": 1})
        marker_key = ("operations", event["workPartition"], event["workSort"])
        marker = self.store.get(marker_key)
        self.assertEqual((marker["state"], marker["attempts"]), ("pending", 1))
        self.assertGreater(self.processor._parse(marker["nextAttemptAt"]), self.now)
        self.assertEqual(self.processor.reconcile(), {"processed": 0, "failed": 0})

    def test_expiration_removes_delivered_payload_and_keeps_minimal_marker(self):
        _, event = self.complete()
        self.processor.deliver("owner", event["id"], "score")
        self.processor.deliver("owner", event["id"], "audit")
        self.now += timedelta(days=7)
        self.assertEqual(self.processor.expire_payloads(), {"removed": 1, "auditExpired": 0})
        self.assertIsNone(self.store.get(("operations", "USER#owner", "EVENT#" + event["id"])))
        marker = self.store.get(("operations", event["workPartition"], event["workSort"]))
        self.assertEqual(marker["reason"], "DELIVERED_PAYLOAD_EXPIRED")
        self.assertNotIn("participationId", marker)
        self.now += timedelta(days=53)
        self.assertEqual(self.processor.expire_payloads(), {"removed": 1, "auditExpired": 0})
        self.assertIsNone(self.store.get(("operations", "USER#owner", "LAKE#" + event["id"])))
        self.assertIsNone(self.store.get(("operations", event["workPartition"], event["workSort"])))

    def test_pending_audit_expiry_does_not_create_false_confirmation(self):
        _, event = self.complete()
        self.now += timedelta(days=60)
        self.assertEqual(self.processor.expire_payloads(), {"removed": 0, "auditExpired": 1})
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 1, "runScore": "5.0"},
        )
        self.assertIsNone(
            self.store.get(("operations", "USER#owner", "DELIVERY#" + event["id"] + "#audit"))
        )
        marker = self.store.get(("operations", event["workPartition"], event["workSort"]))
        self.assertEqual(marker["reason"], "AUDIT_PAYLOAD_EXPIRED")

    def test_review_replacement_recomputes_score_and_audits_before_after(self):
        draft, completed = self.complete()
        self.processor.reconcile()
        changed = {**RATINGS, "course": 1}
        result = self.participations.replace_review(
            self.actor,
            draft["id"],
            "replace-review",
            {"expectedVersion": 1, "ratings": changed},
        )
        self.assertEqual(result["version"], 2)
        self.assertNotIn("comment", result)
        events = [
            item
            for (table, pk, sk), item in self.store.items.items()
            if table == "operations"
            and pk == "USER#owner"
            and sk.startswith("EVENT#")
            and item["type"] == "review_replaced"
        ]
        self.assertEqual(len(events), 1)
        event = events[0]
        self.processor.deliver("owner", event["id"], "score")
        self.processor.deliver("owner", event["id"], "audit")
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 1, "runScore": "4.5"},
        )
        lake = self.store.get(("operations", "USER#owner", "LAKE#" + event["id"]))
        self.assertEqual(lake["before"]["comment"], "Comentário privado de auditoria")
        self.assertNotIn("comment", lake["after"])
        self.assertIsNone(
            self.store.get(("operations", "USER#owner", "AUDIT_SOURCE#" + event["id"]))
        )

    def test_review_replacement_version_conflict_does_not_change_source(self):
        draft, _ = self.complete()
        before = self.participations.get_review(self.actor, draft["id"])
        with self.assertRaises(Problem) as error:
            self.participations.replace_review(
                self.actor,
                draft["id"],
                "stale-review",
                {"expectedVersion": 2, "ratings": {**RATINGS, "course": 1}},
            )
        self.assertEqual(error.exception.code, "VERSION_CONFLICT")
        self.assertEqual(self.participations.get_review(self.actor, draft["id"]), before)

    def test_participation_deletion_hides_immediately_and_removes_score(self):
        draft, _ = self.complete()
        self.processor.reconcile()
        receipt = self.participations.delete(self.actor, draft["id"], "delete-part", 2)
        self.assertTrue(receipt["publiclyHidden"])
        self.assertEqual(
            self.participations.get_deletion(self.actor, receipt["operationId"]), receipt
        )
        with self.assertRaises(Problem) as hidden:
            self.participations.get(self.actor, draft["id"])
        self.assertEqual(hidden.exception.status, 404)
        self.assertIsNone(
            self.store.get(("history", "USER#owner", "EDITION#synthetic-sp-2024#CLAIM"))
        )
        self.assertEqual(self.store.get(("operations", "USER#owner", "IMAGE#valid"))["refs"], 0)
        events = [
            item
            for (table, pk, sk), item in self.store.items.items()
            if table == "operations"
            and pk == "USER#owner"
            and sk.startswith("EVENT#")
            and item["type"] == "participation_deleted"
        ]
        self.assertEqual(len(events), 1)
        event = events[0]
        self.processor.deliver("owner", event["id"], "score")
        self.processor.deliver("owner", event["id"], "audit")
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 0, "runScore": None},
        )
        lake = self.store.get(("operations", "USER#owner", "LAKE#" + event["id"]))
        self.assertIsNotNone(lake["before"])
        self.assertIsNone(lake["after"])

    def test_participation_deletion_conflict_keeps_content_visible(self):
        draft, _ = self.complete()
        with self.assertRaises(Problem) as conflict:
            self.participations.delete(self.actor, draft["id"], "stale-delete", 1)
        self.assertEqual(conflict.exception.code, "VERSION_CONFLICT")
        self.assertEqual(self.participations.get(self.actor, draft["id"])["state"], "completed")

    def test_completed_participation_transfer_moves_score_between_editions(self):
        draft, _ = self.complete()
        self.processor.reconcile()
        changed = self.participations.patch(
            self.actor,
            draft["id"],
            "transfer",
            {
                "expectedVersion": 2,
                "editionId": "synthetic-rj-2026",
                "distanceId": "10k",
            },
        )
        self.assertEqual((changed["editionId"], changed["version"]), ("synthetic-rj-2026", 3))
        events = [
            item
            for (table, pk, sk), item in self.store.items.items()
            if table == "operations"
            and pk == "USER#owner"
            and sk.startswith("EVENT#")
            and item["type"] == "participation_transferred"
        ]
        self.assertEqual(len(events), 1)
        self.processor.deliver("owner", events[0]["id"], "score")
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 0, "runScore": None},
        )
        self.assertEqual(
            self.processor.get_score("synthetic-rj-2026"),
            {"reviewCount": 1, "runScore": "5.0"},
        )

    def test_completed_result_visibility_edit_does_not_emit_score_event(self):
        draft, _ = self.complete()
        before = len(
            [
                sk
                for table, pk, sk in self.store.items
                if table == "operations" and pk == "USER#owner" and sk.startswith("EVENT#")
            ]
        )
        changed = self.participations.patch(
            self.actor,
            draft["id"],
            "hide-time",
            {"expectedVersion": 2, "showTime": False},
        )
        self.assertFalse(changed["showTime"])
        after = len(
            [
                sk
                for table, pk, sk in self.store.items
                if table == "operations" and pk == "USER#owner" and sk.startswith("EVENT#")
            ]
        )
        self.assertEqual(after, before)

    def fill_shard_with_foreign_markers(self, partition, count):
        for index in range(count):
            key = ("operations", partition, f"0000-{index:04d}")
            self.store.commit(
                {key: None},
                {
                    key: {
                        "owner": "someone-else",
                        "eventId": f"foreign-{index}",
                        "state": "completed",
                        "nextAttemptAt": stamp(NOW),
                    }
                },
            )

    def test_reconcile_reaches_pending_marker_behind_completed_markers(self):
        _, event = self.complete()
        self.fill_shard_with_foreign_markers(event["workPartition"], 120)
        self.assertEqual(self.processor.reconcile(limit=100)["processed"], 1)
        self.assertEqual(self.processor.get_score("synthetic-sp-2024")["reviewCount"], 1)

    def test_erasure_removes_owner_marker_behind_a_full_page(self):
        _, event = self.complete()
        self.fill_shard_with_foreign_markers(event["workPartition"], 120)
        receipt = self.identity.delete_account(self.actor, "erase-account")
        erasure = ErasureProcessor(self.identity)
        for _ in range(30):
            if erasure.step("owner", receipt["operationId"], limit=50)["state"] == "completed":
                break
        self.assertFalse(
            [
                sk
                for (table, pk, sk), item in self.store.items.items()
                if table == "operations"
                and pk.startswith("WORK#event#pending#")
                and item.get("owner") == "owner"
            ]
        )

    def test_erasure_deletes_external_accounts_before_completing_and_retries_on_failure(self):
        class Directory:
            def __init__(self):
                self.calls, self.fail = [], True

            def delete_owner(self, owner):
                self.calls.append(owner)
                if self.fail:
                    raise Unavailable()

        directory = Directory()
        receipt = self.identity.delete_account(self.actor, "erase-account")
        erasure = ErasureProcessor(self.identity, external=(directory,))
        with self.assertRaises(Unavailable):
            for _ in range(10):
                erasure.step("owner", receipt["operationId"])
        self.assertIsNotNone(
            self.store.get(("operations", "USER#owner", "JOB#" + receipt["operationId"]))
        )
        directory.fail = False
        for _ in range(10):
            if erasure.step("owner", receipt["operationId"])["state"] == "completed":
                break
        self.assertIn("owner", directory.calls)
        self.assertIsNone(
            self.store.get(("operations", "USER#owner", "JOB#" + receipt["operationId"]))
        )

    def test_run_pending_finishes_accepted_erasures_and_is_quiet_when_empty(self):
        self.identity.delete_account(self.actor, "erase-account")
        erasure = ErasureProcessor(self.identity)
        self.assertEqual(erasure.run_pending(), {"completed": 1, "pending": 0})
        self.assertEqual(erasure.run_pending(), {"completed": 0, "pending": 0})
        self.assertFalse([key for key in self.store.items if key[1] == "USER#owner"])

    def test_account_erasure_retries_stages_and_removes_personal_destinations(self):
        draft, _ = self.complete()
        self.processor.reconcile()
        receipt = self.identity.delete_account(self.actor, "erase-account")
        erasure = ErasureProcessor(self.identity)
        states = []
        for _ in range(20):
            result = erasure.step("owner", receipt["operationId"], limit=3)
            states.append(result)
            if result["state"] == "completed":
                break
        self.assertEqual(states[-1], {"state": "completed"})
        self.assertGreater(len(states), 3)
        for table in ("identity", "history", "operations", "projections"):
            self.assertFalse(
                [key for key in self.store.items if key[0] == table and key[1] == "USER#owner"]
            )
        self.assertIsNone(self.store.get(("history", "PARTICIPATION#" + draft["id"], "OWNER")))
        self.assertFalse(
            [
                item
                for (table, pk, sk), item in self.store.items.items()
                if table == "operations"
                and pk.startswith("WORK#event#pending#")
                and item.get("owner") == "owner"
            ]
        )
        self.assertEqual(
            self.processor.get_score("synthetic-sp-2024"),
            {"reviewCount": 0, "runScore": None},
        )
        self.assertIsNotNone(self.store.get(self.identity.erasure("owner")))
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL"))["count"], 1)


class AuditSinkFlowTests(EventFixture):
    class Sink:
        def __init__(self):
            self.objects = {}

        def key_for(self, event_id, occurred_at):
            return f"dev/{occurred_at[:10]}/{event_id}.json"

        def put(self, event_id, occurred_at, payload):
            key = self.key_for(event_id, occurred_at)
            self.objects[key] = payload
            return key

        def delete(self, key):
            self.objects.pop(key, None)

    def setUp(self):
        super().setUp()
        self.sink = self.Sink()
        self.processor = EventProcessor(self.identity, self.sink)

    def lake_row(self, event):
        return self.store.get(("operations", "USER#owner", "LAKE#" + event["id"]))

    def test_comment_lives_only_in_the_object_and_the_row_is_a_locator(self):
        _, event = self.complete()
        self.processor.deliver("owner", event["id"], "audit")
        row = self.lake_row(event)
        self.assertNotIn("after", row)
        self.assertEqual(
            self.sink.objects[row["objectKey"]]["after"]["comment"],
            "Comentário privado de auditoria",
        )

    def test_account_erasure_removes_delivered_and_orphaned_audit_objects(self):
        _, event = self.complete()
        self.processor.deliver("owner", event["id"], "audit")
        orphan_id = str(uuid4())
        orphan = self.sink.put(orphan_id, event["occurredAt"], {"after": {"comment": "orfao"}})
        self.assertIn(orphan, self.sink.objects)
        event_key = ("operations", "USER#owner", "EVENT#" + orphan_id)
        self.store.commit(
            {event_key: None},
            {event_key: {"id": orphan_id, "occurredAt": event["occurredAt"]}},
        )
        receipt = self.identity.delete_account(self.actor, "erase-account")
        erasure = ErasureProcessor(self.identity, audit=self.sink)
        for _ in range(30):
            if erasure.step("owner", receipt["operationId"])["state"] == "completed":
                break
        self.assertEqual(self.sink.objects, {})

    def test_audit_locator_expiry_removes_the_object(self):
        _, event = self.complete()
        self.processor.reconcile()
        self.assertEqual(len(self.sink.objects), 1)
        self.now += timedelta(days=8)
        self.processor.expire_payloads()
        self.assertEqual(len(self.sink.objects), 1)
        self.now = NOW + timedelta(days=61)
        self.processor.expire_payloads()
        self.assertEqual(self.sink.objects, {})
        self.assertIsNone(self.lake_row(event))


class EventProcessorOnSerializedDynamoShapeTests(EventProcessorTests):
    """Same rules through DynamoStore, where numbers come back as Decimal and floats are rejected."""

    def make_store(self):
        return SerializingDynamoStore()

    def seed_catalog(self, catalog):
        # seed_synthetic refuses non-memory stores on purpose, so its rows are copied over.
        source = IdentityService(MemoryStore(), b"events-test-hmac-key-at-least-32", lambda: NOW)
        seed_synthetic(
            CatalogService(source, Fernet.generate_key()),
            ROOT / "backend/fixtures/catalog.synthetic.json",
        )
        for key, item in source.store.items.items():
            self.store.commit({key: None}, {key: item})
