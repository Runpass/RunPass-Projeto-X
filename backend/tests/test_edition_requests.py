"""Pedidos de prova ausente. Dados sinteticos; MemoryStore local nao prova comportamento do DynamoDB."""

import json
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from jsonschema import RefResolver
from openapi_schema_validator import OAS30Validator
from runpass.api import create_app
from runpass.catalog import CatalogService, seed_synthetic
from runpass.edition_requests import (
    MAX_PENDING,
    QUEUE,
    EditionRequestReview,
    EditionRequestService,
)
from runpass.erasure import ErasureProcessor
from runpass.identity import AuthFailure, Principal
from runpass.models import ReviewRequestDecision
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 9, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True}
BODY = {
    "name": "Night Run Sintética",
    "date": "2027-03-14",
    "city": "São Paulo",
    "state": "SP",
    "distanceKm": 10,
}


class EditionRequestTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.identity = IdentityService(
            MemoryStore(), b"synthetic-only-hmac-key-32-bytes!!", lambda: self.now
        )
        self.store = self.identity.store
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.service = EditionRequestService(self.identity, Fernet.generate_key(), self.catalog)
        self.people = {}
        for name in ("ana", "bia"):
            actor = Principal(name, True)
            self.people[name] = actor
            self.identity.create_profile(actor, "p", {"displayName": name, "username": name + "_x"})
            self.identity.admit(actor, "a", ADULT)

        def verify(token):
            if token not in self.people:
                raise AuthFailure()
            return self.people[token]

        self.client = TestClient(
            create_app(self.identity, verify, self.catalog, edition_requests=self.service)
        )
        self.contract = json.loads((ROOT / "PDLC/M4/API-RunPass-v1.openapi.json").read_text())
        self.n = 0

    # --- ajudantes ---------------------------------------------------------------------------

    def headers(self, who="ana", key=None):
        self.n += 1
        return {"Authorization": f"Bearer {who}", "Idempotency-Key": key or f"k{self.n}"}

    def create(self, who="ana", body=None, key=None):
        return self.client.post(
            "/edition-requests", json=body or BODY, headers=self.headers(who, key)
        )

    def valid(self, schema, body):
        OAS30Validator(
            self.contract["components"]["schemas"][schema],
            resolver=RefResolver.from_schema(self.contract),
        ).validate(body)

    def operator(self):
        operator = Principal("op", True, "operator", "digest")
        access = ("identity", "OPERATOR#op", "ACCESS")
        session = ("operations", "OPERATOR#op", "SESSION#digest")
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
        return operator, EditionRequestReview(self.catalog, lambda: self.now)

    @staticmethod
    def decision(**data):
        return ReviewRequestDecision.model_validate(data)

    # --- criar -------------------------------------------------------------------------------

    def test_create_is_private_pending_and_matches_the_contract(self):
        response = self.create()
        self.assertEqual(response.status_code, 201, response.text)
        body = response.json()
        self.valid("EditionRequest", body)
        self.assertEqual((body["status"], body["version"]), ("pending", 1))
        self.assertEqual(body["details"]["name"], "Night Run Sintética")
        self.assertEqual(body["details"]["state"], "SP")
        self.assertNotIn("owner", body)
        self.assertNotIn("sharedKeys", body)
        # Nao vira edicao publica: o catalogo continua com as 5 sinteticas.
        listing = self.client.get("/editions", headers=self.headers()).json()
        self.assertEqual(len(listing["items"]), 5)

    def test_login_and_admission_required(self):
        self.assertEqual(self.client.post("/edition-requests", json=BODY).status_code, 401)
        stranger = Principal("novo", True)
        self.people["novo"] = stranger
        self.identity.create_profile(stranger, "p", {"displayName": "n", "username": "novo_x"})
        self.assertEqual(self.create("novo").status_code, 403)

    def test_invalid_input_is_rejected_without_writing(self):
        before = dict(self.store.items)
        far = (NOW + timedelta(days=800)).date().isoformat()
        for change in (
            {"name": ""},
            {"name": "   "},
            {"name": "a" * 161},
            {"date": "14/03/2027"},
            {"date": "1980-01-01"},
            {"date": far},
            {"distanceKm": 0},
            {"distanceKm": -5},
            {"distanceKm": 1001},
            {"distanceKm": True},
            {"distanceKm": "10"},
            {"state": "SPP"},
            {"officialUrl": "http://inseguro.example"},
            {"imageReference": "img_1"},
            {"extra": 1},
        ):
            response = self.create(body={**BODY, **change})
            self.assertEqual(response.status_code, 422, (change, response.text))
        for missing in ("name", "date", "city", "distanceKm"):
            body = {k: v for k, v in BODY.items() if k != missing}
            self.assertEqual(self.create(body=body).status_code, 422, missing)
        self.assertEqual(
            {k for k in self.store.items if k[2].startswith("EREQ") or k[1].startswith("EREQ")},
            {k for k in before if k[2].startswith("EREQ") or k[1].startswith("EREQ")},
        )

    def test_idempotent_replay_creates_one_request_and_changed_body_conflicts(self):
        first = self.create(key="same").json()
        again = self.create(key="same").json()
        self.assertEqual(first["id"], again["id"])
        mine = self.client.get("/me/edition-requests", headers=self.headers()).json()
        self.assertEqual(len(mine["items"]), 1)
        changed = self.create(body={**BODY, "name": "Outra"}, key="same")
        self.assertEqual(changed.status_code, 409)

    def test_pending_cap_per_person(self):
        for i in range(MAX_PENDING):
            self.assertEqual(self.create(body={**BODY, "name": f"Prova {i}"}).status_code, 201)
        over = self.create(body={**BODY, "name": "Mais uma"})
        self.assertEqual(
            (over.status_code, over.json()["code"]), (409, "TOO_MANY_PENDING_REQUESTS")
        )
        self.assertEqual(self.create("bia").status_code, 201)  # o limite e por pessoa

    # --- ler ---------------------------------------------------------------------------------

    def test_only_the_owner_sees_a_request(self):
        rid = self.create().json()["id"]
        own = self.client.get(f"/edition-requests/{rid}", headers=self.headers())
        self.assertEqual(own.status_code, 200)
        other = self.client.get(f"/edition-requests/{rid}", headers=self.headers("bia"))
        missing = self.client.get("/edition-requests/nao-existe", headers=self.headers("bia"))
        self.assertEqual((other.status_code, missing.status_code), (404, 404))
        self.assertEqual(other.json()["code"], missing.json()["code"])
        self.assertEqual(
            self.client.get("/me/edition-requests", headers=self.headers("bia")).json()["items"], []
        )

    def test_list_is_newest_first_paged_and_cursor_is_bound_to_person_and_limit(self):
        ids = []
        for i in range(3):
            self.now = NOW + timedelta(minutes=i)
            ids.append(self.create(body={**BODY, "name": f"Prova {i}"}).json()["id"])
        first = self.client.get("/me/edition-requests?limit=2", headers=self.headers()).json()
        self.valid("EditionRequestPage", first)
        self.assertEqual([i["id"] for i in first["items"]], [ids[2], ids[1]])
        cursor = first["nextCursor"]
        second = self.client.get(
            f"/me/edition-requests?limit=2&cursor={cursor}", headers=self.headers()
        ).json()
        self.assertEqual([i["id"] for i in second["items"]], [ids[0]])
        self.assertNotIn("nextCursor", second)
        for who, limit in (("bia", 2), ("ana", 3)):
            bad = self.client.get(
                f"/me/edition-requests?limit={limit}&cursor={cursor}", headers=self.headers(who)
            )
            self.assertEqual(bad.status_code, 422, (who, limit))

    # --- corrigir e reenviar -----------------------------------------------------------------

    def reject(self, rid, version=1, reason="Data nao confere com a fonte"):
        operator, review = self.operator()
        review.decide(
            operator, rid, self.decision(expectedVersion=version, decision="reject", reason=reason)
        )

    def test_patch_and_resubmit_only_after_rejection(self):
        rid = self.create().json()["id"]
        patch = {"expectedVersion": 1, "city": "Osasco"}
        early = self.client.patch(f"/edition-requests/{rid}", json=patch, headers=self.headers())
        self.assertEqual((early.status_code, early.json()["code"]), (409, "REQUEST_NOT_EDITABLE"))
        resub = {"expectedVersion": 1}
        early = self.client.post(
            f"/edition-requests/{rid}/resubmit", json=resub, headers=self.headers()
        )
        self.assertEqual((early.status_code, early.json()["code"]), (409, "REQUEST_NOT_REJECTED"))

        self.reject(rid)
        rejected = self.client.get(f"/edition-requests/{rid}", headers=self.headers()).json()
        self.valid("EditionRequest", rejected)
        self.assertEqual((rejected["status"], rejected["version"]), ("rejected", 2))
        self.assertEqual(rejected["reason"], "Data nao confere com a fonte")

        stale = self.client.patch(f"/edition-requests/{rid}", json=patch, headers=self.headers())
        self.assertEqual((stale.status_code, stale.json()["code"]), (409, "VERSION_CONFLICT"))
        invalid = self.client.patch(
            f"/edition-requests/{rid}",
            json={"expectedVersion": 2, "date": "1980-01-01"},
            headers=self.headers(),
        )
        self.assertEqual(invalid.status_code, 422)
        fixed = self.client.patch(
            f"/edition-requests/{rid}",
            json={"expectedVersion": 2, "date": "2027-03-21", "distanceKm": 5.5},
            headers=self.headers(),
        )
        self.assertEqual(fixed.status_code, 200, fixed.text)
        self.assertEqual((fixed.json()["status"], fixed.json()["version"]), ("rejected", 3))
        self.assertEqual(fixed.json()["details"]["date"], "2027-03-21")
        # Corrigir nao reenvia sozinho: a fila de revisao continua sem o pedido.
        self.assertEqual(self.queue(), [])

        back = self.client.post(
            f"/edition-requests/{rid}/resubmit", json={"expectedVersion": 3}, headers=self.headers()
        )
        self.assertEqual(back.status_code, 200, back.text)
        body = back.json()
        self.valid("EditionRequest", body)
        self.assertEqual((body["status"], body["version"]), ("pending", 4))
        self.assertNotIn("reason", body)
        self.assertEqual(len(self.queue()), 1)

    def test_other_person_cannot_patch_or_resubmit(self):
        rid = self.create().json()["id"]
        self.reject(rid)
        for method, path, body in (
            ("patch", f"/edition-requests/{rid}", {"expectedVersion": 2, "city": "X"}),
            ("post", f"/edition-requests/{rid}/resubmit", {"expectedVersion": 2}),
        ):
            response = getattr(self.client, method)(path, json=body, headers=self.headers("bia"))
            self.assertEqual(response.status_code, 404, path)

    def test_patch_rejects_empty_nulls_and_unknown_fields(self):
        rid = self.create().json()["id"]
        self.reject(rid)
        for body in (
            {"expectedVersion": 2},
            {"expectedVersion": 2, "city": None},
            {"expectedVersion": 2, "imageReference": "x"},
            {"expectedVersion": 2, "state": "SPP"},
        ):
            response = self.client.patch(
                f"/edition-requests/{rid}", json=body, headers=self.headers()
            )
            self.assertEqual(response.status_code, 422, body)

    # --- revisao pelo operador ---------------------------------------------------------------

    def queue(self):
        rows, _ = self.store.query("history", QUEUE, limit=100)
        return rows

    def test_review_needs_a_current_operator_session_with_catalog_admin(self):
        rid = self.create().json()["id"]
        review = EditionRequestReview(self.catalog, lambda: self.now)
        decision = self.decision(expectedVersion=1, decision="link", editionId="synthetic-sp-2026")
        with self.assertRaises(AuthFailure):
            review.pending(self.people["ana"])  # runner nao e operador
        with self.assertRaises((Problem, AuthFailure)):
            review.decide(None, rid, decision)
        with self.assertRaises((Problem, AuthFailure)):
            review.decide(Principal("op", True, "operator", "sem-sessao"), rid, decision)
        self.assertEqual(
            self.client.get(f"/edition-requests/{rid}", headers=self.headers()).json()["status"],
            "pending",
        )

    def test_queue_entry_carries_the_details_and_never_the_owner(self):
        """A rotina semanal do catalogo le so a fila: precisa dos dados, nunca de quem pediu."""
        rid = self.create().json()["id"]
        (entry,) = [item for _, item in self.queue()]
        self.assertEqual(entry["id"], rid)
        self.assertEqual(entry["details"]["name"], "Night Run Sintética")
        self.assertNotIn("ana", json.dumps(entry, default=str))
        self.reject(rid)
        self.client.patch(
            f"/edition-requests/{rid}",
            json={"expectedVersion": 2, "city": "Osasco"},
            headers=self.headers(),
        )
        self.client.post(
            f"/edition-requests/{rid}/resubmit", json={"expectedVersion": 3}, headers=self.headers()
        )
        (entry,) = [item for _, item in self.queue()]
        self.assertEqual(entry["details"]["city"], "Osasco")  # reenvio publica os dados corrigidos

    def test_pending_queue_for_the_operator_hides_the_owner(self):
        self.create()
        self.create("bia", body={**BODY, "name": "Outra"})
        operator, review = self.operator()
        items, _ = review.pending(operator)
        self.assertEqual({i["details"]["name"] for i in items}, {"Night Run Sintética", "Outra"})
        self.assertNotIn("owner", json.dumps(items, default=str))

    def test_approve_link_and_reject_close_the_request_and_audit_it(self):
        operator, review = self.operator()
        approved = self.create().json()["id"]
        linked = self.create(body={**BODY, "name": "Duplicada"}).json()["id"]
        rejected = self.create(body={**BODY, "name": "Invalida"}).json()["id"]

        a = review.decide(
            operator,
            approved,
            self.decision(expectedVersion=1, decision="approve", editionId="synthetic-sp-2026"),
        )
        lk = review.decide(
            operator,
            linked,
            self.decision(expectedVersion=1, decision="link", editionId="synthetic-sp-2025"),
        )
        r = review.decide(
            operator,
            rejected,
            self.decision(expectedVersion=1, decision="reject", reason="Prova inexistente"),
        )
        self.assertEqual(
            (a["status"], a["linkedEditionId"], a["version"]), ("approved", "synthetic-sp-2026", 2)
        )
        self.assertEqual((lk["status"], lk["linkedEditionId"]), ("linked", "synthetic-sp-2025"))
        self.assertEqual((r["status"], r["reason"]), ("rejected", "Prova inexistente"))
        for rid, status in ((approved, "approved"), (linked, "linked"), (rejected, "rejected")):
            body = self.client.get(f"/edition-requests/{rid}", headers=self.headers()).json()
            self.valid("EditionRequest", body)
            self.assertEqual(body["status"], status)
        self.assertEqual(self.queue(), [])
        audit = self.store.get(("operations", "EREQ#" + approved, "REV#2"))
        self.assertEqual((audit["operator"], audit["decision"]), ("op", "approve"))
        # Resolver o pedido nao cria participacao nem publica nova edicao.
        self.assertEqual(
            len(self.client.get("/editions", headers=self.headers()).json()["items"]), 5
        )

    def test_decisions_are_revalidated_against_current_state(self):
        operator, review = self.operator()
        rid = self.create().json()["id"]
        ok = self.decision(expectedVersion=1, decision="link", editionId="synthetic-sp-2026")
        with self.assertRaises(Problem) as stale:
            review.decide(
                operator,
                rid,
                self.decision(expectedVersion=9, decision="link", editionId="synthetic-sp-2026"),
            )
        self.assertEqual(stale.exception.code, "VERSION_CONFLICT")
        for edition in ("nao-existe", "synthetic-archived"):
            with self.assertRaises(Problem) as bad:
                review.decide(
                    operator,
                    rid,
                    self.decision(expectedVersion=1, decision="approve", editionId=edition),
                )
            self.assertEqual(
                (bad.exception.status, bad.exception.code), (422, "EDITION_NOT_LINKABLE"), edition
            )
        review.decide(operator, rid, ok)
        with self.assertRaises(Problem) as twice:
            review.decide(
                operator, rid, self.decision(expectedVersion=2, decision="reject", reason="x")
            )
        self.assertEqual(twice.exception.code, "REQUEST_NOT_PENDING")
        with self.assertRaises(Problem) as unknown:
            review.decide(operator, "inexistente", ok)
        self.assertEqual(unknown.exception.status, 404)

    def test_decision_model_requires_edition_or_reason_but_never_both(self):
        for bad in (
            {"expectedVersion": 1, "decision": "approve"},
            {"expectedVersion": 1, "decision": "link", "editionId": "e", "reason": "r"},
            {"expectedVersion": 1, "decision": "reject"},
            {"expectedVersion": 1, "decision": "reject", "reason": "  "},
            {"expectedVersion": 1, "decision": "reject", "reason": "r", "editionId": "e"},
            {"expectedVersion": 1, "decision": "outra"},
        ):
            with self.assertRaises(ValueError, msg=bad):
                ReviewRequestDecision.model_validate(bad)

    # --- apagamento de conta e disponibilidade -----------------------------------------------

    def test_account_erasure_removes_the_request_owner_map_and_queue_entry(self):
        rid = self.create().json()["id"]
        self.create("bia")
        self.identity.delete_account(self.people["ana"], "del")
        ErasureProcessor(self.identity).run_pending()
        leftovers = [k for k in self.store.items if rid in k[1] or rid in k[2]]
        self.assertEqual(leftovers, [])
        self.assertEqual(len(self.queue()), 1)  # o pedido da outra pessoa segue na fila

    def test_route_is_unavailable_when_not_configured(self):
        bare = TestClient(create_app(self.identity, lambda t: self.people[t], self.catalog))
        response = bare.post("/edition-requests", json=BODY, headers=self.headers())
        self.assertEqual(response.status_code, 503)


if __name__ == "__main__":
    unittest.main()
