"""Comentarios na corrida: qualquer pessoa admitida comenta, so o autor apaga, a equipe remove."""

import json
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi.testclient import TestClient
from jsonschema import RefResolver
from openapi_schema_validator import OAS30Validator
from runpass.api import create_app
from runpass.identity import AuthFailure, Principal
from runpass.service import IdentityService, Problem
from runpass.social import (
    SocialService,
    list_edition_comments_for_team,
    remove_edition_comment_as_team,
)
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 14, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True, "gender": "undisclosed"}


class EditionCommentTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"comments-test-hmac-key-at-least-32-bytes", lambda: self.now
        )
        self.social = SocialService(self.identity)
        self.people = {}
        for sub in ("ana", "bia"):
            self.people[sub] = self.person(sub)
        self.head("E1")
        self.n = 0

    def person(self, sub):
        actor = Principal(sub, True)
        self.identity.create_profile(
            actor, "p-" + sub, {"displayName": sub.title(), "username": sub + "_runs"}
        )
        self.identity.admit(actor, "a-" + sub, ADULT)
        return actor

    def head(self, edition_id, **extra):
        key = ("catalog", "EDITION#" + edition_id, "HEAD")
        self.store.commit(
            {key: None},
            {key: {"publicationState": "approved", "archived": False, "version": 1, **extra}},
        )

    def post(self, who, text, edition="E1", key=None):
        self.n += 1
        return self.social.edition_comment(self.people[who], edition, key or f"k{self.n}", text)

    def test_anyone_admitted_comments_without_a_participation(self):
        made = self.post("ana", "  Percurso   bonito  e plano  ")
        self.assertEqual(made["text"], "Percurso bonito e plano")  # espacos normalizados
        self.assertTrue(made["mine"])
        self.assertEqual(made["author"]["username"], "ana_runs")
        # outra pessoa le o mesmo comentario, sem ser dona dele
        page = self.social.edition_comments(self.people["bia"], "E1")
        self.assertEqual([c["text"] for c in page["items"]], ["Percurso bonito e plano"])
        self.assertFalse(page["items"][0]["mine"])

    def test_newest_first_and_cursor_pages(self):
        for i in range(5):
            self.now = NOW + timedelta(minutes=i)
            self.post("ana" if i % 2 == 0 else "bia", f"comentario {i}")
        first = self.social.edition_comments(self.people["ana"], "E1", limit=2)
        self.assertEqual([c["text"] for c in first["items"]], ["comentario 4", "comentario 3"])
        second = self.social.edition_comments(
            self.people["ana"], "E1", limit=2, cursor=first["nextCursor"]
        )
        self.assertEqual([c["text"] for c in second["items"]], ["comentario 2", "comentario 1"])
        last = self.social.edition_comments(
            self.people["ana"], "E1", limit=2, cursor=second["nextCursor"]
        )
        self.assertEqual([c["text"] for c in last["items"]], ["comentario 0"])
        self.assertNotIn("nextCursor", last)
        with self.assertRaises(Problem) as erro:
            self.social.edition_comments(self.people["ana"], "E1", cursor="lixo")
        self.assertEqual(erro.exception.code, "INVALID_CURSOR")

    def test_invalid_text_unknown_archived_and_unapproved_editions(self):
        for ruim in ("", "   ", "x" * 1001, "linha\x00quebrada"):
            with self.assertRaises(Problem) as erro:
                self.post("ana", ruim)
            self.assertEqual(erro.exception.code, "INVALID_COMMENT", repr(ruim))
        with self.assertRaises(Problem) as erro:
            self.post("ana", "oi", edition="nao-existe")
        self.assertEqual(erro.exception.code, "EDITION_NOT_FOUND")
        self.head("ARQ", archived=True)
        with self.assertRaises(Problem) as erro:
            self.post("ana", "oi", edition="ARQ")
        self.assertEqual(erro.exception.code, "EDITION_ARCHIVED")
        # arquivada ainda pode ser lida
        self.assertEqual(self.social.edition_comments(self.people["ana"], "ARQ")["items"], [])
        key = ("catalog", "EDITION#PEND", "HEAD")
        self.store.commit({key: None}, {key: {"publicationState": "pending", "archived": False}})
        with self.assertRaises(Problem) as erro:
            self.post("ana", "oi", edition="PEND")
        self.assertEqual(erro.exception.code, "EDITION_NOT_FOUND")

    def test_same_key_does_not_duplicate_and_person_limit_per_edition(self):
        first = self.post("ana", "oi", key="mesma")
        again = self.post("ana", "oi", key="mesma")
        self.assertEqual(first["id"], again["id"])
        self.assertEqual(len(self.social.edition_comments(self.people["ana"], "E1")["items"]), 1)
        for i in range(self.social.EDITION_COMMENTS_PER_PERSON - 1):
            self.now = NOW + timedelta(seconds=i + 1)
            self.post("ana", f"c{i}")
        with self.assertRaises(Problem) as erro:
            self.post("ana", "demais")
        self.assertEqual(
            (erro.exception.status, erro.exception.code), (429, "COMMENT_LIMIT_REACHED")
        )
        # o limite e por pessoa e por corrida
        self.post("bia", "ainda posso")
        self.head("E2")
        self.post("ana", "outra corrida", edition="E2")

    def test_only_the_author_deletes_and_it_is_repeatable(self):
        made = self.post("ana", "meu comentario")
        with self.assertRaises(Problem) as erro:  # de outra pessoa: mesma resposta de inexistente
            self.social.delete_edition_comment(self.people["bia"], made["id"], "d1")
        self.assertEqual(erro.exception.code, "COMMENT_NOT_FOUND")
        done = self.social.delete_edition_comment(self.people["ana"], made["id"], "d2")
        self.assertEqual(done, {"id": made["id"], "deleted": True})
        self.assertEqual(self.social.edition_comments(self.people["ana"], "E1")["items"], [])
        # mesma chave: mesmo resultado; outra chave: o comentario ja nao existe
        self.assertTrue(
            self.social.delete_edition_comment(self.people["ana"], made["id"], "d2")["deleted"]
        )
        with self.assertRaises(Problem):
            self.social.delete_edition_comment(self.people["ana"], made["id"], "d3")
        # liberou a vaga do limite
        self.assertEqual(
            self.store.get(("identity", "USER#ana", "ECOMMENTREF#" + made["id"])), None
        )

    def test_team_can_list_and_remove_and_unknown_comment_is_404(self):
        a = self.post("ana", "texto da ana")
        self.now = NOW + timedelta(minutes=1)
        b = self.post("bia", "texto da bia")
        listed = list_edition_comments_for_team(self.store, "E1")
        self.assertEqual([c["id"] for c in listed], [b["id"], a["id"]])  # mais recente primeiro
        self.assertEqual(listed[0]["author"], "bia")
        removed = remove_edition_comment_as_team(self.store, a["id"])
        self.assertEqual(removed, {"id": a["id"], "editionId": "E1", "author": "ana"})
        self.assertEqual(
            [c["text"] for c in self.social.edition_comments(self.people["bia"], "E1")["items"]],
            ["texto da bia"],
        )
        with self.assertRaises(Problem) as erro:
            remove_edition_comment_as_team(self.store, a["id"])
        self.assertEqual(erro.exception.code, "COMMENT_NOT_FOUND")

    def test_comments_of_inactive_accounts_do_not_show(self):
        self.post("ana", "da ana")
        self.post("bia", "da bia")
        profile = self.store.get(("identity", "USER#ana", "PROFILE"))
        # conta da Ana some (apagamento): o comentario dela deixa de aparecer
        if profile:
            self.store.commit(
                {("identity", "USER#ana", "PROFILE"): profile},
                {("identity", "USER#ana", "PROFILE"): None},
            )
        texts = [c["text"] for c in self.social.edition_comments(self.people["bia"], "E1")["items"]]
        self.assertNotIn("da ana", texts)


class EditionCommentHttpTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"comments-http-hmac-key-at-least-32-bytes", lambda: NOW
        )
        self.social = SocialService(self.identity)
        self.people = {}
        for sub in ("ana", "bia"):
            actor = Principal(sub, True)
            self.people[sub] = actor
            self.identity.create_profile(
                actor, "p-" + sub, {"displayName": sub.title(), "username": sub + "_runs"}
            )
            self.identity.admit(actor, "a-" + sub, ADULT)
        key = ("catalog", "EDITION#E1", "HEAD")
        self.store.commit(
            {key: None}, {key: {"publicationState": "approved", "archived": False, "version": 1}}
        )

        def verify(token):
            if token not in self.people:
                raise AuthFailure()
            return self.people[token]

        self.client = TestClient(create_app(self.identity, verify, social=self.social))
        self.contract = json.loads((ROOT / "PDLC/M4/API-RunPass-v1.openapi.json").read_text())
        self.n = 0

    def headers(self, who="ana", key=None):
        self.n += 1
        return {"Authorization": f"Bearer {who}", "Idempotency-Key": key or f"h{self.n}"}

    def valid(self, schema, body):
        OAS30Validator(
            self.contract["components"]["schemas"][schema],
            resolver=RefResolver.from_schema(self.contract),
        ).validate(body)

    def test_create_list_and_delete_match_the_contract(self):
        created = self.client.post(
            "/editions/E1/comments", json={"text": "Muito bem organizada"}, headers=self.headers()
        )
        self.assertEqual(created.status_code, 201, created.text)
        self.valid("EditionComment", created.json())
        listed = self.client.get("/editions/E1/comments", headers=self.headers("bia")).json()
        self.valid("EditionCommentPage", listed)
        self.assertEqual([c["text"] for c in listed["items"]], ["Muito bem organizada"])
        cid = created.json()["id"]
        # outra pessoa nao apaga
        self.assertEqual(
            self.client.delete(f"/edition-comments/{cid}", headers=self.headers("bia")).status_code,
            404,
        )
        done = self.client.delete(f"/edition-comments/{cid}", headers=self.headers("ana"))
        self.assertEqual(done.status_code, 200, done.text)
        self.assertEqual(
            self.client.get("/editions/E1/comments", headers=self.headers("bia")).json()["items"],
            [],
        )

    def test_needs_login_and_rejects_blank_text(self):
        self.assertEqual(self.client.get("/editions/E1/comments").status_code, 401)
        blank = self.client.post(
            "/editions/E1/comments", json={"text": "   "}, headers=self.headers()
        )
        self.assertEqual(blank.status_code, 422)
        self.assertEqual(
            self.client.post("/editions/E1/comments", json={"text": "oi"}).status_code, 401
        )


if __name__ == "__main__":
    unittest.main()
