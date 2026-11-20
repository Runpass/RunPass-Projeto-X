"""Publicacao com ate 5 fotos (carrossel): capa em `postImageReference` e ate 4 extras em
`morePostImageReferences`. Dados [FICTICIOS]."""

import unittest
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.api import create_app
from runpass.catalog import CatalogService, seed_synthetic
from runpass.erasure import ErasureProcessor
from runpass.identity import Principal
from runpass.participation import ParticipationService
from runpass.service import IdentityService, Problem
from runpass.social import SocialService
from runpass.upload import MemoryBlobStore, UploadService

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)
MEDAL = "img_" + "0" * 64
COVER = "img_" + "1" * 64
E1, E2, E3, E4, E5 = ("img_" + c * 64 for c in "23456")
NOTES = {
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


class PostCarouselTests(unittest.TestCase):
    def setUp(self):
        from runpass.store import MemoryStore

        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"carousel-test-hmac-key-32-bytes-ok", lambda: NOW
        )
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.service = ParticipationService(self.identity, self.catalog, Fernet.generate_key())
        self.social = SocialService(self.identity)
        self.blobs = MemoryBlobStore()
        self.uploads = UploadService(self.identity, self.blobs, may_view=self.social.may_view_photo)
        self.actor = self.admit("owner")
        for ref in (MEDAL, COVER, E1, E2, E3, E4, E5):
            self.image(ref)

    def admit(self, subject):
        actor = Principal(subject, True)
        self.identity.create_profile(
            actor, "profile-" + subject, {"displayName": subject, "username": subject}
        )
        self.identity.admit(
            actor, "admit-" + subject, {"birthDate": "1990-01-01", "declaresAdult": True}
        )
        return actor

    def image(self, ref, owner="owner"):
        key = ("operations", "USER#" + owner, "IMAGE#" + ref)
        self.store.commit(
            {key: None}, {key: {"owner": owner, "origin": "runner", "state": "valid", "refs": 0}}
        )
        self.blobs.derived[ref] = {"owner": owner, "contentType": "image/png", "data": b"x"}

    def refs(self, ref, owner="owner"):
        row = self.store.get(("operations", "USER#" + owner, "IMAGE#" + ref))
        return None if row is None else row.get("refs", 0)

    def draft(self, key="d1", edition="synthetic-sp-2024"):
        return self.service.create(self.actor, key, {"editionId": edition, "distanceId": "10k"})

    def completion(self, draft, **changes):
        return {
            "expectedVersion": draft["version"],
            "declaredCompleted": True,
            "ratings": NOTES,
            "medalImageReference": MEDAL,
            "publishToFeed": True,
            "postImageReference": COVER,
            **changes,
        }

    def complete_with(self, more, key="c1"):
        draft = self.draft()
        return self.service.complete(
            self.actor, draft["id"], key, self.completion(draft, morePostImageReferences=more)
        )

    def assertProblem(self, code, call, *args, **kwargs):
        with self.assertRaises(Problem) as caught:
            call(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)

    # ---- concluir/publicar --------------------------------------------------------------------

    def test_concluir_com_tres_fotos_conta_e_mostra_cada_uma_pelo_indice(self):
        done = self.complete_with([E1, E2])
        self.assertEqual(done["morePostImageReferences"], [E1, E2])
        self.assertEqual(done["postImageCount"], 3)
        for ref in (COVER, E1, E2):
            self.assertEqual(self.refs(ref), 1)
        mine = self.service.get(self.actor, done["id"])
        self.assertEqual((mine["postImageCount"], mine["morePostImageReferences"]), (3, [E1, E2]))
        listed = self.service.list(self.actor, None, 50, None)["items"][0]
        self.assertEqual(listed["postImageCount"], 3)
        # terceiros: so a contagem, nunca as referencias
        viewer = self.admit("viewer")
        post = self.social.post(viewer, done["id"])
        self.assertEqual(post["postImageCount"], 3)
        self.assertNotIn("morePostImageReferences", post)
        self.assertNotIn("morePostImageReferences", post["participation"])
        feed = next(p for p in self.social.feed(viewer)["items"] if p["id"] == done["id"])
        self.assertEqual(feed["postImageCount"], 3)
        self.assertNotIn("morePostImageReferences", feed)
        # o dono ve as referencias em "minhas publicacoes"
        own = self.social.my_posts(self.actor)["items"][0]
        self.assertEqual(own["morePostImageReferences"], [E1, E2])
        photos = self.social.edition_photos(viewer, "synthetic-sp-2024")["items"]
        self.assertEqual(photos[0]["postImageCount"], 3)
        # imagens pelo indice, com a mesma regra de visibilidade da capa
        for index, ref in enumerate((COVER, E1, E2)):
            link = self.uploads.post_image(viewer, done["id"], index)
            self.assertIn(ref, link["url"])
        self.assertIn(COVER, self.uploads.post_image(viewer, done["id"])["url"])
        self.assertProblem("IMAGE_NOT_AVAILABLE", self.uploads.post_image, viewer, done["id"], 3)

    def test_sem_extras_a_contagem_e_um_e_sem_foto_e_zero(self):
        done = self.complete_with(None)
        self.assertEqual(done["postImageCount"], 1)
        self.assertNotIn("morePostImageReferences", done)
        draft = self.draft("d2", "synthetic-sp-2025")
        plain = self.service.complete(
            self.actor,
            draft["id"],
            "c2",
            self.completion(draft, publishToFeed=False, postImageReference=None),
        )
        self.assertEqual(plain["postImageCount"], 0)

    def test_recusa_extras_invalidas(self):
        draft = self.draft()
        complete = self.service.complete
        cases = [
            ("POST_IMAGE_DUPLICATE", {"morePostImageReferences": [E1, E1]}),
            ("POST_IMAGE_DUPLICATE", {"morePostImageReferences": [COVER]}),
            ("POST_IMAGE_MUST_DIFFER", {"morePostImageReferences": [MEDAL]}),
            ("TOO_MANY_POST_IMAGES", {"morePostImageReferences": [E1, E2, E3, E4, E5]}),
            (
                "POST_IMAGE_NOT_ALLOWED",
                {
                    "publishToFeed": False,
                    "postImageReference": None,
                    "morePostImageReferences": [E1],
                },
            ),
        ]
        for i, (code, changes) in enumerate(cases):
            self.assertProblem(
                code,
                complete,
                self.actor,
                draft["id"],
                f"bad{i}",
                self.completion(draft, **changes),
            )
        other = "img_" + "7" * 64
        self.admit("other")
        self.image(other, owner="other")
        for i, ref in enumerate((other, "img_" + "8" * 64)):
            body = self.completion(draft, morePostImageReferences=[E1, ref])
            self.assertProblem("IMAGE_NOT_VALID", complete, self.actor, draft["id"], f"x{i}", body)
        self.assertEqual(self.refs(E1), 0)  # nada reservado nas tentativas recusadas

    def test_http_recusa_mais_de_quatro_extras_e_indice_fora_da_faixa(self):
        client = TestClient(
            create_app(
                self.identity,
                lambda token: self.actor,
                self.catalog,
                self.service,
                self.uploads,
                self.social,
            )
        )
        headers = {"Authorization": "Bearer t", "Idempotency-Key": "k1"}
        draft = self.draft()
        body = self.completion(draft, morePostImageReferences=[E1, E2, E3, E4, E5])
        answer = client.post(f"/participations/{draft['id']}/complete", headers=headers, json=body)
        self.assertEqual(answer.status_code, 422)
        self.assertEqual(answer.json()["code"], "INVALID_INPUT")
        body = self.completion(draft, morePostImageReferences=[E1, E2])
        answer = client.post(f"/participations/{draft['id']}/complete", headers=headers, json=body)
        self.assertEqual(answer.status_code, 200, answer.text)
        self.assertEqual(answer.json()["postImageCount"], 3)
        path = f"/participations/{draft['id']}/post-image"
        for index in (0, 1, 2):
            got = client.get(path, params={"index": index}, headers=headers)
            self.assertEqual(got.status_code, 200, got.text)
        missing = client.get(path, params={"index": 3}, headers=headers)
        self.assertEqual(
            (missing.status_code, missing.json()["code"]), (404, "IMAGE_NOT_AVAILABLE")
        )
        self.assertEqual(client.get(path, params={"index": 5}, headers=headers).status_code, 422)

    def test_publicar_depois_com_fotos_extras(self):
        draft = self.draft()
        done = self.service.complete(
            self.actor,
            draft["id"],
            "c1",
            self.completion(draft, publishToFeed=False, postImageReference=None),
        )
        published = self.service.publish(
            self.actor,
            done["id"],
            "p1",
            {
                "expectedVersion": done["version"],
                "postImageReference": COVER,
                "morePostImageReferences": [E1, E2, E3, E4],
            },
        )
        self.assertEqual(published["postImageCount"], 5)
        self.assertEqual(self.refs(E4), 1)

    # ---- editar (PATCH) ---------------------------------------------------------------------

    def patch(self, done, key, **changes):
        return self.service.patch(
            self.actor, done["id"], key, {"expectedVersion": done["version"], **changes}
        )

    def test_patch_substitui_mantem_e_remove_as_extras(self):
        done = self.complete_with([E1, E2])
        # sem a lista: mantem (mesmo trocando a capa)
        changed = self.patch(done, "u1", postImageReference=E3)
        self.assertEqual(changed["morePostImageReferences"], [E1, E2])
        self.assertEqual((self.refs(COVER), self.refs(E3)), (0, 1))
        changed = self.patch(changed, "u2", postText="so o texto")
        self.assertEqual(changed["postImageCount"], 3)
        # com a lista: substitui inteira, libera a que saiu e reserva a nova
        changed = self.patch(changed, "u3", morePostImageReferences=[E2, E4])
        self.assertEqual(changed["morePostImageReferences"], [E2, E4])
        self.assertEqual((self.refs(E1), self.refs(E2), self.refs(E4)), (0, 1, 1))
        # extra vira capa e capa vira extra: a contagem de uso nao se perde
        changed = self.patch(changed, "u4", postImageReference=E2, morePostImageReferences=[E3, E4])
        self.assertEqual((changed["postImageReference"], changed["postImageCount"]), (E2, 3))
        self.assertEqual((self.refs(E2), self.refs(E3), self.refs(E4)), (1, 1, 1))
        # lista vazia: remove as extras
        changed = self.patch(changed, "u5", morePostImageReferences=[])
        self.assertNotIn("morePostImageReferences", changed)
        self.assertEqual(changed["postImageCount"], 1)
        self.assertEqual((self.refs(E2), self.refs(E3), self.refs(E4)), (1, 0, 0))

    def test_patch_recusa_extras_invalidas(self):
        done = self.complete_with([E1])
        for code, more in (
            ("POST_IMAGE_DUPLICATE", [COVER]),
            ("POST_IMAGE_DUPLICATE", [E2, E2]),
            ("POST_IMAGE_MUST_DIFFER", [MEDAL]),
        ):
            self.assertProblem(
                code,
                self.patch,
                done,
                "bad" + code + str(len(more)),
                **{"morePostImageReferences": more},
            )
        self.assertProblem(
            "POST_IMAGE_MUST_DIFFER", self.patch, done, "medal", medalImageReference=E1
        )
        self.assertEqual(self.refs(E2), 0)

    # ---- publicacao extra -----------------------------------------------------------------

    def test_publicacao_extra_com_fotos(self):
        done = self.complete_with(None)
        extra_cover = "img_" + "a" * 64
        self.image(extra_cover)
        extra = self.service.create_extra_post(
            self.actor,
            "x1",
            {
                "participationId": done["id"],
                "postImageReference": extra_cover,
                "morePostImageReferences": [E1, E2],
            },
        )
        self.assertEqual((extra["postImageCount"], extra["morePostImageReferences"]), (3, [E1, E2]))
        viewer = self.admit("viewer")
        post = self.social.post(viewer, extra["id"])
        self.assertEqual(post["postImageCount"], 3)
        self.assertNotIn("morePostImageReferences", post)
        own = next(p for p in self.social.my_posts(self.actor)["items"] if p["id"] == extra["id"])
        self.assertEqual(own["morePostImageReferences"], [E1, E2])
        # a publicacao da corrida (sem extras) nao herda as extras da publicacao extra e vice-versa
        self.assertEqual(self.social.post(viewer, done["id"])["postImageCount"], 1)
        self.assertIn(E2, self.uploads.extra_post_image(viewer, extra["id"], 2)["url"])
        self.assertProblem(
            "IMAGE_NOT_AVAILABLE", self.uploads.extra_post_image, viewer, extra["id"], 3
        )
        self.assertProblem(
            "POST_IMAGE_MUST_DIFFER",
            self.service.create_extra_post,
            self.actor,
            "x2",
            {
                "participationId": done["id"],
                "postImageReference": E3,
                "morePostImageReferences": [MEDAL],
            },
        )
        changed = self.service.update_extra_post(
            self.actor, extra["id"], "xu1", {"expectedVersion": 1, "postText": "texto"}
        )
        self.assertEqual(changed["morePostImageReferences"], [E1, E2])
        changed = self.service.update_extra_post(
            self.actor, extra["id"], "xu2", {"expectedVersion": 2, "morePostImageReferences": [E3]}
        )
        self.assertEqual(changed["postImageCount"], 2)
        self.assertEqual((self.refs(E1), self.refs(E2), self.refs(E3)), (0, 0, 1))
        self.service.delete_extra_post(self.actor, extra["id"], "xd")
        self.assertEqual((self.refs(extra_cover), self.refs(E3)), (0, 0))

    # ---- exclusao -----------------------------------------------------------------------

    def test_excluir_participacao_apaga_as_extras(self):
        done = self.complete_with([E1, E2])
        self.service.delete(self.actor, done["id"], "del", done["version"])
        self.assertEqual((self.refs(E1), self.refs(E2)), (0, 0))
        ErasureProcessor(self.identity, self.blobs).run_pending_participations()
        for ref in (COVER, E1, E2):
            self.assertIsNone(self.refs(ref))
            self.assertNotIn(ref, self.blobs.derived)

    def test_exclusao_de_conta_apaga_as_extras(self):
        done = self.complete_with([E1, E2])
        extra_cover = "img_" + "a" * 64
        self.image(extra_cover)
        self.service.create_extra_post(
            self.actor,
            "x1",
            {
                "participationId": done["id"],
                "postImageReference": extra_cover,
                "morePostImageReferences": [E3],
            },
        )
        self.identity.delete_account(self.actor, "del-owner")
        ErasureProcessor(self.identity, self.blobs).run_pending()
        for ref in (COVER, E1, E2, E3, extra_cover):
            self.assertIsNone(self.refs(ref))
            self.assertNotIn(ref, self.blobs.derived)


if __name__ == "__main__":
    unittest.main()
