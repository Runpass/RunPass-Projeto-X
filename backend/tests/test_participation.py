import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.api import create_app
from runpass.catalog import CatalogService, seed_synthetic
from runpass.identity import Principal
from runpass.participation import ParticipationService
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)


class ParticipationTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"participation-test-hmac-key-32-bytes", lambda: NOW
        )
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.service = ParticipationService(self.identity, self.catalog, Fernet.generate_key())
        self.actor = self.admit("owner")

    def admit(self, subject):
        actor = Principal(subject, True)
        self.identity.create_profile(
            actor, "profile-" + subject, {"displayName": subject, "username": subject}
        )
        self.identity.admit(
            actor,
            "admit-" + subject,
            {"birthDate": "1990-01-01", "declaresAdult": True},
        )
        return actor

    def payload(self, **changes):
        return {
            "editionId": "synthetic-sp-2024",
            "distanceId": "10k",
            **changes,
        }

    def completion(self, draft, **changes):
        reference = changes.pop("medalImageReference", "img-valid")
        image_key = ("operations", "USER#owner", "IMAGE#" + reference)
        if self.store.get(image_key) is None:
            self.store.commit(
                {image_key: None},
                {image_key: {"owner": "owner", "origin": "runner", "state": "valid", "refs": 0}},
            )
        return {
            "expectedVersion": draft["version"],
            "declaredCompleted": True,
            "ratings": {
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
            },
            "medalImageReference": reference,
            "publishToFeed": False,
            **changes,
        }

    def test_create_replay_reserves_edition_and_has_no_derived_effects(self):
        first = self.service.create(self.actor, "same-key", self.payload(timeSeconds=3600))
        replay = self.service.create(self.actor, "same-key", self.payload(timeSeconds=3600))
        self.assertEqual(first, replay)
        self.assertEqual(first["state"], "draft")
        self.assertEqual(first["version"], 1)
        with self.assertRaises(Problem) as error:
            self.service.create(self.actor, "other-key", self.payload())
        self.assertEqual(error.exception.code, "PARTICIPATION_EXISTS")
        self.assertFalse(
            any(
                key[2].endswith(("#REVIEW", "#MEDAL")) or key[2].startswith("EVENT#")
                for key in self.store.items
            )
        )

    def test_other_owner_cannot_read_or_patch_private_draft(self):
        draft = self.service.create(self.actor, "create", self.payload(bibNumber="ABC-1"))
        other = self.admit("other")
        for call in (
            lambda: self.service.get(other, draft["id"]),
            lambda: self.service.patch(
                other, draft["id"], "patch", {"expectedVersion": 1, "timeSeconds": 10}
            ),
        ):
            with self.assertRaises(Problem) as error:
                call()
            self.assertEqual(
                (error.exception.status, error.exception.code), (404, "PARTICIPATION_NOT_FOUND")
            )

    def test_patch_clears_optional_fields_and_rejects_stale_version(self):
        draft = self.service.create(
            self.actor, "create", self.payload(timeSeconds=3600, placement=5, bibNumber=" 42 ")
        )
        changed = self.service.patch(
            self.actor,
            draft["id"],
            "patch",
            {"expectedVersion": 1, "timeSeconds": None, "showPlacement": False},
        )
        self.assertEqual(changed["version"], 2)
        self.assertNotIn("timeSeconds", changed)
        self.assertFalse(changed["showPlacement"])
        with self.assertRaises(Problem) as error:
            self.service.patch(
                self.actor,
                draft["id"],
                "stale",
                {"expectedVersion": 1, "placement": 9},
            )
        self.assertEqual(error.exception.code, "VERSION_CONFLICT")

    def test_patch_sets_and_clears_medal_shelf_customization(self):
        draft = self.service.create(self.actor, "create", self.payload(timeSeconds=3600))
        done = self.service.complete(self.actor, draft["id"], "done", self.completion(draft))
        customized = self.service.patch(
            self.actor,
            draft["id"],
            "customize",
            {
                "expectedVersion": done["version"],
                "medalShape": "shield",
                "medalCordColor": "#ff5500",
                "medalDescription": "Minha prova especial",
                "medalCity": "Santos",
                "medalState": "SP",
                "medalYear": 2023,
            },
        )
        self.assertEqual(customized["medalShape"], "shield")
        self.assertEqual(customized["medalCordColor"], "#ff5500")
        self.assertEqual(customized["medalDescription"], "Minha prova especial")
        self.assertEqual(customized["medalCity"], "Santos")
        self.assertEqual(customized["medalState"], "SP")
        self.assertEqual(customized["medalYear"], 2023)
        reset = self.service.patch(
            self.actor,
            draft["id"],
            "reset",
            {
                "expectedVersion": customized["version"],
                "medalShape": None,
                "medalCordColor": None,
                "medalDescription": None,
                "medalCity": None,
                "medalState": None,
                "medalYear": None,
            },
        )
        for field in (
            "medalShape",
            "medalCordColor",
            "medalDescription",
            "medalCity",
            "medalState",
            "medalYear",
        ):
            self.assertNotIn(field, reset)

    def test_medal_customization_rejects_invalid_color_and_state(self):
        from pydantic import ValidationError

        from runpass.models import PatchParticipation

        with self.assertRaises(ValidationError):
            PatchParticipation(expectedVersion=1, medalCordColor="orange")
        with self.assertRaises(ValidationError):
            PatchParticipation(expectedVersion=1, medalState="sp")
        with self.assertRaises(ValidationError):
            PatchParticipation(expectedVersion=1, medalShape="triangle")

    def test_completed_race_can_swap_its_medal_photo_and_refs_follow(self):
        draft = self.service.create(self.actor, "c", self.payload(timeSeconds=3600))
        with self.assertRaises(Problem) as early:
            self.service.patch(
                self.actor, draft["id"], "early", {"expectedVersion": 1, "medalImageReference": "x"}
            )
        self.assertEqual(early.exception.code, "PARTICIPATION_NOT_COMPLETED")
        done = self.service.complete(self.actor, draft["id"], "done", self.completion(draft))
        second = ("operations", "USER#owner", "IMAGE#img-two")
        self.store.commit(
            {second: None},
            {second: {"owner": "owner", "origin": "runner", "state": "valid", "refs": 0}},
        )
        with self.assertRaises(Problem) as missing:
            self.service.patch(
                self.actor,
                draft["id"],
                "bad",
                {"expectedVersion": done["version"], "medalImageReference": "img-unknown"},
            )
        self.assertEqual(missing.exception.code, "IMAGE_NOT_VALID")
        swapped = self.service.patch(
            self.actor,
            draft["id"],
            "swap",
            {"expectedVersion": done["version"], "medalImageReference": "img-two"},
        )
        self.assertEqual(swapped["medalImageReference"], "img-two")
        self.assertEqual(self.store.get(second)["refs"], 1)
        first = self.store.get(("operations", "USER#owner", "IMAGE#img-valid"))
        self.assertEqual(first["refs"], 0)
        medal = self.store.get(("history", "USER#owner", "P#" + draft["id"] + "#MEDAL"))
        self.assertEqual(medal["imageReference"], "img-two")

    def test_invalid_archived_or_mismatched_catalog_is_rejected_without_mutation(self):
        before = dict(self.store.items)
        for payload, code in (
            ({"editionId": "synthetic-archived", "distanceId": "5k"}, "EDITION_ARCHIVED"),
            ({"editionId": "synthetic-sp-2024", "distanceId": "wrong"}, "DISTANCE_NOT_IN_EDITION"),
        ):
            with self.subTest(code=code), self.assertRaises(Problem) as error:
                self.service.create(self.actor, code, payload)
            self.assertEqual(error.exception.code, code)
        self.assertEqual(self.store.items, before)

    def test_concurrent_creation_for_same_edition_has_one_winner(self):
        def create(index):
            try:
                return self.service.create(self.actor, f"key-{index}", self.payload())["id"]
            except Problem as error:
                return error.code

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(create, range(8)))
        winners = [value for value in results if value != "PARTICIPATION_EXISTS"]
        self.assertEqual(len(winners), 1)
        self.assertEqual(results.count("PARTICIPATION_EXISTS"), 7)

    def test_completion_is_atomic_idempotent_and_pins_image(self):
        draft = self.service.create(self.actor, "create", self.payload(timeSeconds=3600))
        payload = self.completion(draft, comment="Ótima prova")
        completed = self.service.complete(self.actor, draft["id"], "complete", payload)
        self.assertEqual((completed["state"], completed["version"]), ("completed", 2))
        self.assertEqual(
            self.service.complete(self.actor, draft["id"], "complete", payload), completed
        )
        pk = "USER#owner"
        review = self.store.get(("history", pk, "P#" + draft["id"] + "#REVIEW"))
        medal = self.store.get(("history", pk, "P#" + draft["id"] + "#MEDAL"))
        image = self.store.get(("operations", pk, "IMAGE#img-valid"))
        events = [
            v
            for (t, p, sk), v in self.store.items.items()
            if t == "operations" and p == pk and sk.startswith("EVENT#")
        ]
        self.assertEqual((review["comment"], review["effectVersion"]), ("Ótima prova", 1))
        self.assertEqual((medal["imageReference"], medal["catalogVersion"]), ("img-valid", 1))
        self.assertEqual(image["refs"], 1)
        self.assertEqual(len(events), 1)

    def test_concurrent_completion_has_one_atomic_winner(self):
        draft = self.service.create(self.actor, "create", self.payload())
        payload = self.completion(draft)

        def complete(index):
            try:
                return self.service.complete(self.actor, draft["id"], f"finish-{index}", payload)[
                    "state"
                ]
            except Problem as error:
                return error.code

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(complete, range(8)))
        self.assertEqual(results.count("completed"), 1)
        self.assertEqual(results.count("PARTICIPATION_NOT_DRAFT"), 7)
        pk = "USER#owner"
        self.assertIsNotNone(self.store.get(("history", pk, "P#" + draft["id"] + "#REVIEW")))
        self.assertIsNotNone(self.store.get(("history", pk, "P#" + draft["id"] + "#MEDAL")))

    def test_invalid_image_and_future_edition_preserve_draft(self):
        draft = self.service.create(self.actor, "create", self.payload())
        payload = self.completion(draft, medalImageReference="img-failed")
        key = ("operations", "USER#owner", "IMAGE#img-failed")
        current = self.store.get(key)
        self.store.commit({key: current}, {key: {**current, "state": "failed"}})
        with self.assertRaises(Problem) as error:
            self.service.complete(self.actor, draft["id"], "invalid", payload)
        self.assertEqual(error.exception.code, "IMAGE_NOT_VALID")
        self.assertEqual(self.service.get(self.actor, draft["id"])["state"], "draft")

        future = self.service.create(
            self.actor,
            "future",
            {"editionId": "synthetic-sp-2026", "distanceId": "5k"},
        )
        with self.assertRaises(Problem) as error:
            self.service.complete(self.actor, future["id"], "future-done", self.completion(future))
        self.assertEqual(error.exception.code, "EDITION_NOT_COMPLETABLE")

    def test_list_cursor_is_owner_and_filter_bound(self):
        draft = self.service.create(self.actor, "create", self.payload())
        first = self.service.list(self.actor, "draft", 1, None)
        self.assertEqual([item["id"] for item in first["items"]], [draft["id"]])
        other = self.admit("other")
        if first.get("nextCursor"):
            with self.assertRaises(Problem):
                self.service.list(other, "draft", 1, first["nextCursor"])


class ParticipationApiTests(unittest.TestCase):
    def test_http_models_reject_extra_request_drafts_and_expose_canonical_routes(self):
        store = MemoryStore()
        identity = IdentityService(store, b"participation-api-hmac-key-32-bytes")
        catalog = CatalogService(identity, Fernet.generate_key())
        seed_synthetic(catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        actor = Principal("runner", True)
        identity.create_profile(actor, "profile", {"displayName": "Runner", "username": "runner"})
        identity.admit(actor, "admit", {"birthDate": "1990-01-01", "declaresAdult": True})
        service = ParticipationService(identity, catalog, Fernet.generate_key())
        client = TestClient(create_app(identity, lambda token: actor, catalog, service))
        headers = {"Authorization": "Bearer token", "Idempotency-Key": "create"}
        invalid = client.post(
            "/participations",
            headers=headers,
            json={"editionRequestId": "not-enabled", "distanceKm": 10},
        )
        self.assertEqual(invalid.status_code, 422)
        created = client.post(
            "/participations",
            headers=headers,
            json={"editionId": "synthetic-sp-2024", "distanceId": "10k"},
        )
        self.assertEqual(created.status_code, 201, created.text)
        participation_id = created.json()["id"]
        self.assertEqual(
            client.get(f"/participations/{participation_id}", headers=headers).status_code, 200
        )
        self.assertEqual(
            client.get("/me/participations?state=draft", headers=headers).json()["items"][0]["id"],
            participation_id,
        )
        image_key = ("operations", "USER#runner", "IMAGE#img-http")
        store.commit(
            {image_key: None},
            {
                image_key: {
                    "owner": "runner",
                    "origin": "runner",
                    "state": "valid",
                    "refs": 0,
                }
            },
        )
        completed = client.post(
            f"/participations/{participation_id}/complete",
            headers={**headers, "Idempotency-Key": "complete"},
            json={
                "expectedVersion": 1,
                "declaredCompleted": True,
                "ratings": {
                    name: 4
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
                },
                "medalImageReference": "img-http",
                "publishToFeed": False,
            },
        )
        self.assertEqual(completed.status_code, 200, completed.text)
        self.assertEqual(completed.json()["state"], "completed")
