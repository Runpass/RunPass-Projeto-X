import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.api import create_app
from runpass.catalog import CatalogFilters, CatalogService, seed_synthetic
from runpass.identity import Principal
from runpass.participation import ParticipationService
from runpass.service import IdentityService, Problem
from runpass.social import SocialService
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

    # ---- foto da publicacao no feed (separada da medalha) ----------------------------------------

    POST_REF = "img_" + "a" * 64
    POST_REF2 = "img_" + "b" * 64

    def runner_image(self, reference, owner="owner", **extra):
        key = ("operations", "USER#" + owner, "IMAGE#" + reference)
        self.store.commit(
            {key: None},
            {key: {"owner": owner, "origin": "runner", "state": "valid", "refs": 0, **extra}},
        )
        return key

    def test_publishing_on_completion_needs_a_separate_post_photo(self):
        draft = self.service.create(self.actor, "c1", self.payload())
        # publicar sem a foto da publicacao: recusado
        with self.assertRaises(Problem) as erro:
            self.service.complete(
                self.actor, draft["id"], "x1", self.completion(draft, publishToFeed=True)
            )
        self.assertEqual(erro.exception.code, "POST_IMAGE_REQUIRED")
        # foto da publicacao sem publicar: recusado
        self.runner_image(self.POST_REF)
        with self.assertRaises(Problem) as erro:
            self.service.complete(
                self.actor,
                draft["id"],
                "x2",
                self.completion(draft, postImageReference=self.POST_REF),
            )
        self.assertEqual(erro.exception.code, "POST_IMAGE_NOT_ALLOWED")
        # a mesma imagem nao pode ser a medalha e a publicacao
        self.completion(draft, medalImageReference=self.POST_REF)
        with self.assertRaises(Problem) as erro:
            self.service.complete(
                self.actor,
                draft["id"],
                "x3",
                self.completion(
                    draft,
                    medalImageReference=self.POST_REF,
                    publishToFeed=True,
                    postImageReference=self.POST_REF,
                ),
            )
        self.assertEqual(erro.exception.code, "POST_IMAGE_MUST_DIFFER")
        # imagem de outra pessoa ou inexistente: recusada
        other = self.admit("other")
        self.runner_image(self.POST_REF2, owner="other")
        for ref in (self.POST_REF2, "img_" + "c" * 64):
            with self.assertRaises(Problem) as erro:
                self.service.complete(
                    self.actor,
                    draft["id"],
                    "x4" + ref[-2:],
                    self.completion(draft, publishToFeed=True, postImageReference=ref),
                )
            self.assertEqual(erro.exception.code, "IMAGE_NOT_VALID")
        del other
        # certo: guarda as duas fotos e o texto; reserva as duas imagens
        done = self.service.complete(
            self.actor,
            draft["id"],
            "ok",
            self.completion(
                draft,
                publishToFeed=True,
                postImageReference=self.POST_REF,
                postText="Cheguei! Que prova linda.",
            ),
        )
        self.assertEqual(done["medalImageReference"], "img-valid")
        self.assertEqual(done["postImageReference"], self.POST_REF)
        self.assertEqual(done["postText"], "Cheguei! Que prova linda.")
        self.assertTrue(done["publishToFeed"])
        self.assertEqual(
            self.store.get(("operations", "USER#owner", "IMAGE#" + self.POST_REF))["refs"], 1
        )
        self.assertEqual(self.store.get(("operations", "USER#owner", "IMAGE#img-valid"))["refs"], 1)

    def test_publish_a_completed_participation_later_with_its_own_photo(self):
        draft = self.service.create(self.actor, "c2", self.payload())
        done = self.service.complete(self.actor, draft["id"], "d2", self.completion(draft))
        self.assertFalse(done["publishToFeed"])
        self.runner_image(self.POST_REF)
        stale = {"expectedVersion": done["version"] + 5, "postImageReference": self.POST_REF}
        with self.assertRaises(Problem) as erro:
            self.service.publish(self.actor, draft["id"], "p0", stale)
        self.assertEqual(erro.exception.code, "VERSION_CONFLICT")
        # a foto da medalha nao serve como foto da publicacao
        with self.assertRaises(Problem) as erro:
            self.service.publish(
                self.actor,
                draft["id"],
                "p1",
                {"expectedVersion": done["version"], "postImageReference": "img-valid"},
            )
        self.assertEqual(erro.exception.code, "POST_IMAGE_MUST_DIFFER")
        published = self.service.publish(
            self.actor,
            draft["id"],
            "p2",
            {
                "expectedVersion": done["version"],
                "postImageReference": self.POST_REF,
                "postText": "Minha corrida",
            },
        )
        self.assertTrue(published["publishToFeed"])
        self.assertEqual(published["postText"], "Minha corrida")
        self.assertEqual(published["version"], done["version"] + 1)
        feed = self.store.get(("history", "FEED#PUBLIC", f"T#{done['completedAt']}#{draft['id']}"))
        self.assertEqual(feed["owner"], "owner")
        # mesma chave repete o resultado; publicar de novo e recusado
        again = self.service.publish(
            self.actor,
            draft["id"],
            "p2",
            {
                "expectedVersion": done["version"],
                "postImageReference": self.POST_REF,
                "postText": "Minha corrida",
            },
        )
        self.assertEqual(again["version"], published["version"])
        with self.assertRaises(Problem) as erro:
            self.service.publish(
                self.actor,
                draft["id"],
                "p3",
                {"expectedVersion": published["version"], "postImageReference": self.POST_REF},
            )
        self.assertEqual(erro.exception.code, "ALREADY_PUBLISHED")

    def test_publish_needs_a_completed_participation_of_the_owner(self):
        draft = self.service.create(self.actor, "c3", self.payload())
        self.runner_image(self.POST_REF)
        body = {"expectedVersion": draft["version"], "postImageReference": self.POST_REF}
        with self.assertRaises(Problem) as erro:  # rascunho nao publica
            self.service.publish(self.actor, draft["id"], "q1", body)
        self.assertEqual(erro.exception.code, "PARTICIPATION_NOT_COMPLETED")
        other = self.admit("intruso")
        with self.assertRaises(Problem) as erro:  # de outra pessoa: mesma resposta de inexistente
            self.service.publish(other, draft["id"], "q2", body)
        self.assertEqual(erro.exception.code, "PARTICIPATION_NOT_FOUND")

    def test_patch_replaces_the_post_photo_and_text_of_a_published_participation(self):
        draft = self.service.create(self.actor, "c5", self.payload())
        self.runner_image(self.POST_REF)
        self.runner_image(self.POST_REF2)
        done = self.service.complete(
            self.actor,
            draft["id"],
            "d5",
            self.completion(
                draft, publishToFeed=True, postImageReference=self.POST_REF, postText="antes"
            ),
        )
        old_key = ("operations", "USER#owner", "IMAGE#" + self.POST_REF)
        new_key = ("operations", "USER#owner", "IMAGE#" + self.POST_REF2)
        changed = self.service.patch(
            self.actor,
            draft["id"],
            "p5",
            {
                "expectedVersion": done["version"],
                "postImageReference": self.POST_REF2,
                "postText": "depois",
            },
        )
        self.assertEqual(changed["postImageReference"], self.POST_REF2)
        self.assertEqual(changed["postText"], "depois")
        self.assertEqual(changed["medalImageReference"], "img-valid")  # a medalha nao mudou
        self.assertEqual((self.store.get(old_key)["refs"], self.store.get(new_key)["refs"]), (0, 1))
        # a foto da medalha nao serve; texto pode ser apagado; foto de outra pessoa e recusada
        with self.assertRaises(Problem) as erro:
            self.service.patch(
                self.actor,
                draft["id"],
                "p6",
                {"expectedVersion": changed["version"], "postImageReference": "img-valid"},
            )
        self.assertIn(erro.exception.code, {"POST_IMAGE_MUST_DIFFER", "INVALID_INPUT"})
        cleared = self.service.patch(
            self.actor,
            draft["id"],
            "p7",
            {"expectedVersion": changed["version"], "postText": None},
        )
        self.assertNotIn("postText", cleared)

    def test_replacing_the_medal_photo_drops_the_old_shelf_crop(self):
        draft = self.service.create(self.actor, "c7", self.payload())
        done = self.service.complete(self.actor, draft["id"], "d7", self.completion(draft))
        crop_ref = "img_" + "d" * 64
        new_ref = "img_" + "e" * 64
        crop_key = self.runner_image(crop_ref)
        new_key = self.runner_image(new_ref)
        # a pessoa reposicionou a foto na prateleira (recorte da foto atual)
        cropped = self.service.patch(
            self.actor,
            draft["id"],
            "p9",
            {"expectedVersion": done["version"], "medalDisplayImageReference": crop_ref},
        )
        self.assertEqual(cropped["medalDisplayImageReference"], crop_ref)
        self.assertEqual(self.store.get(crop_key)["refs"], 1)
        # trocar a foto da medalha: o recorte era da foto antiga e sai (senao a prateleira mostra a velha)
        swapped = self.service.patch(
            self.actor,
            draft["id"],
            "p10",
            {"expectedVersion": cropped["version"], "medalImageReference": new_ref},
        )
        self.assertEqual(swapped["medalImageReference"], new_ref)
        self.assertNotIn("medalDisplayImageReference", swapped)
        self.assertEqual(self.store.get(crop_key)["refs"], 0)
        self.assertEqual(self.store.get(new_key)["refs"], 1)

    def test_replacing_the_medal_photo_keeps_a_crop_sent_in_the_same_request(self):
        draft = self.service.create(self.actor, "c8", self.payload())
        done = self.service.complete(self.actor, draft["id"], "d8", self.completion(draft))
        new_ref = "img_" + "f" * 64
        crop_ref = "img_" + "9" * 64
        self.runner_image(new_ref)
        self.runner_image(crop_ref)
        swapped = self.service.patch(
            self.actor,
            draft["id"],
            "p11",
            {
                "expectedVersion": done["version"],
                "medalImageReference": new_ref,
                "medalDisplayImageReference": crop_ref,
            },
        )
        self.assertEqual(swapped["medalDisplayImageReference"], crop_ref)

    def test_marcar_pessoas_na_publicacao_com_as_regras_de_perfil(self):
        publico = self.admit("pub")
        privado = self.admit("priv")
        self.admit("seguido")
        profile = self.identity.profile(privado)
        self.identity.patch_profile(
            privado, "mk-priv", {"expectedVersion": profile["version"], "isPrivate": True}
        )
        draft = self.service.create(self.actor, "t1", self.payload())
        self.runner_image(self.POST_REF)
        done = self.service.complete(
            self.actor,
            draft["id"],
            "t2",
            self.completion(
                draft,
                publishToFeed=True,
                postImageReference=self.POST_REF,
                taggedUserIds=["pub"],
            ),
        )
        self.assertEqual(done["taggedUserIds"], ["pub"])  # perfil publico: nao precisa seguir
        # Perfil privado sem seguir, eu mesmo e conta inexistente: recusados.
        for bad in (["priv"], ["owner"], ["ninguem"]):
            with self.assertRaises(Problem) as erro:
                self.service.patch(
                    self.actor,
                    draft["id"],
                    "t3" + bad[0],
                    {"expectedVersion": done["version"], "taggedUserIds": bad},
                )
            self.assertEqual(erro.exception.code, "INVALID_TAG")
        # Depois de seguir, o privado pode ser marcado; lista vazia remove tudo.
        SocialService(self.identity).follow(self.actor, "priv", "t4")
        changed = self.service.patch(
            self.actor,
            draft["id"],
            "t5",
            {"expectedVersion": done["version"], "taggedUserIds": ["pub", "priv", "pub"]},
        )
        self.assertEqual(changed["taggedUserIds"], ["pub", "priv"])
        post = SocialService(self.identity).post(publico, draft["id"])
        self.assertEqual([p["username"] for p in post["tagged"]], ["pub", "priv"])
        # O Feed (Todos) tambem traz as marcacoes, nao so a leitura de uma publicacao.
        feed = SocialService(self.identity).feed(publico)["items"]
        self.assertEqual([p["username"] for p in feed[0]["tagged"]], ["pub", "priv"])
        cleared = self.service.patch(
            self.actor,
            draft["id"],
            "t6",
            {"expectedVersion": changed["version"], "taggedUserIds": []},
        )
        self.assertNotIn("taggedUserIds", cleared)

    def test_patch_post_photo_needs_a_published_participation(self):
        draft = self.service.create(self.actor, "c6", self.payload())
        done = self.service.complete(self.actor, draft["id"], "d6", self.completion(draft))
        self.runner_image(self.POST_REF)
        with self.assertRaises(Problem) as erro:  # concluida, mas nao publicada
            self.service.patch(
                self.actor,
                draft["id"],
                "p8",
                {"expectedVersion": done["version"], "postImageReference": self.POST_REF},
            )
        self.assertEqual(erro.exception.code, "NOT_PUBLISHED")

    def test_deleting_releases_the_post_photo_too(self):
        draft = self.service.create(self.actor, "c4", self.payload())
        self.runner_image(self.POST_REF)
        done = self.service.complete(
            self.actor,
            draft["id"],
            "d4",
            self.completion(draft, publishToFeed=True, postImageReference=self.POST_REF),
        )
        post_key = ("operations", "USER#owner", "IMAGE#" + self.POST_REF)
        self.assertEqual(self.store.get(post_key)["refs"], 1)
        self.service.delete(self.actor, draft["id"], "del4", done["version"])
        self.assertEqual(self.store.get(post_key)["refs"], 0)

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

    def test_pace_opcional_entra_no_cadastro_e_pode_ser_alterado_ou_apagado(self):
        draft = self.service.create(
            self.actor, "pace", self.payload(timeSeconds=3000, paceSecondsPerKm=300)
        )
        self.assertEqual(draft["paceSecondsPerKm"], 300)
        changed = self.service.patch(
            self.actor, draft["id"], "pace-2", {"expectedVersion": 1, "paceSecondsPerKm": 330}
        )
        self.assertEqual(changed["paceSecondsPerKm"], 330)
        cleared = self.service.patch(
            self.actor, draft["id"], "pace-3", {"expectedVersion": 2, "paceSecondsPerKm": None}
        )
        self.assertNotIn("paceSecondsPerKm", cleared)

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
                "medalFrameId": "hexagonal_bronze_verde",
                "medalDescription": "Minha prova especial",
                "medalCity": "Santos",
                "medalState": "SP",
                "medalYear": 2023,
            },
        )
        self.assertEqual(customized["medalFrameId"], "hexagonal_bronze_verde")
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
                "medalFrameId": None,
                "medalDescription": None,
                "medalCity": None,
                "medalState": None,
                "medalYear": None,
            },
        )
        for field in (
            "medalFrameId",
            "medalDescription",
            "medalCity",
            "medalState",
            "medalYear",
        ):
            self.assertNotIn(field, reset)

    def test_medal_customization_rejects_invalid_state_and_frame(self):
        from pydantic import ValidationError
        from runpass.models import PatchParticipation

        with self.assertRaises(ValidationError):
            PatchParticipation(expectedVersion=1, medalState="sp")
        with self.assertRaises(ValidationError):
            PatchParticipation(expectedVersion=1, medalFrameId="ouro_brilhante")

    def test_medal_display_image_is_separate_from_the_official_photo(self):
        draft = self.service.create(self.actor, "c", self.payload(timeSeconds=3600))
        done = self.service.complete(self.actor, draft["id"], "done", self.completion(draft))
        cropped = ("operations", "USER#owner", "IMAGE#img-cropped")
        self.store.commit(
            {cropped: None},
            {cropped: {"owner": "owner", "origin": "runner", "state": "valid", "refs": 0}},
        )
        with self.assertRaises(Problem) as missing:
            self.service.patch(
                self.actor,
                draft["id"],
                "bad",
                {"expectedVersion": done["version"], "medalDisplayImageReference": "unknown"},
            )
        self.assertEqual(missing.exception.code, "IMAGE_NOT_VALID")
        repositioned = self.service.patch(
            self.actor,
            draft["id"],
            "reposition",
            {"expectedVersion": done["version"], "medalDisplayImageReference": "img-cropped"},
        )
        self.assertEqual(repositioned["medalDisplayImageReference"], "img-cropped")
        # A foto oficial da medalha (usada no feed/historico) nao muda.
        self.assertEqual(repositioned["medalImageReference"], "img-valid")
        self.assertEqual(self.store.get(cropped)["refs"], 1)
        reset = self.service.patch(
            self.actor,
            draft["id"],
            "reset",
            {"expectedVersion": repositioned["version"], "medalDisplayImageReference": None},
        )
        self.assertNotIn("medalDisplayImageReference", reset)
        self.assertEqual(self.store.get(cropped)["refs"], 0)

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

    def finish(self, subject, stars, comment=None):
        actor = self.actor if subject == "owner" else self.admit(subject)
        draft = self.service.create(actor, "d-" + subject, self.payload(timeSeconds=3600))
        image = ("operations", "USER#" + subject, "IMAGE#img-" + subject)
        self.store.commit(
            {image: None},
            {image: {"owner": subject, "origin": "runner", "state": "valid", "refs": 0}},
        )
        body = self.completion(draft, medalImageReference="img-" + subject)
        body["ratings"] = {k: stars for k in body["ratings"]}
        if comment:
            body["comment"] = comment
        self.service.complete(actor, draft["id"], "c-" + subject, body)
        return actor, draft["id"]

    def test_public_edition_reviews_list_average_and_recommendation(self):
        social = SocialService(self.identity)
        reader = self.admit("reader")
        empty = social.edition_reviews(reader, "synthetic-sp-2024")
        self.assertEqual(empty["items"], [])
        self.assertEqual(empty["summary"]["reviewCount"], 0)
        self.assertIsNone(empty["summary"]["average"])
        self.finish("owner", 5, "Prova sensacional")
        other, other_id = self.finish("other", 2)
        page = social.edition_reviews(reader, "synthetic-sp-2024")
        self.assertEqual(len(page["items"]), 2)
        self.assertEqual({i["authorName"] for i in page["items"]}, {"owner", "other"})
        self.assertEqual(
            next(i for i in page["items"] if i["authorName"] == "owner")["comment"],
            "Prova sensacional",
        )
        summary = page["summary"]
        self.assertEqual(summary["reviewCount"], 2)
        self.assertEqual(summary["average"], 3.5)
        self.assertEqual(summary["recommendPercent"], 50)
        self.assertEqual(summary["byCriterion"]["kit"], 3.5)
        self.assertEqual(social.edition_reviews(reader, "synthetic-sp-2024", "5k")["items"], [])
        self.assertEqual(
            len(social.edition_reviews(reader, "synthetic-sp-2024", "10k")["items"]), 2
        )
        one = social.edition_reviews(reader, "synthetic-sp-2024", limit=1)
        self.assertEqual(len(one["items"]), 1)
        rest = social.edition_reviews(
            reader, "synthetic-sp-2024", limit=1, cursor=one["nextCursor"]
        )
        self.assertEqual(len(rest["items"]), 1)
        self.assertNotIn("nextCursor", rest)
        self.assertEqual(social.edition_reviews(reader, "synthetic-sp-2025")["items"], [])
        part = self.service.get(other, other_id)
        self.service.delete(other, other_id, "del", part["version"])
        after = social.edition_reviews(reader, "synthetic-sp-2024")
        self.assertEqual(after["summary"]["reviewCount"], 1)
        self.assertEqual(after["summary"]["recommendPercent"], 100)

    def test_edition_participants_respect_privacy_and_hide_time_unless_shown(self):
        social = SocialService(self.identity)
        reader = self.admit("reader")
        self.assertEqual(social.edition_participants(reader, "synthetic-sp-2024")["total"], 0)
        self.finish("owner", 5)
        private, _ = self.finish("secret", 4)
        # perfil privado: so o dono e amigos aceitos veem quem e
        profile_key = ("identity", "USER#secret", "PROFILE")
        self.store.commit(
            {profile_key: self.store.get(profile_key)},
            {profile_key: {**self.store.get(profile_key), "isPrivate": True}},
        )
        page = social.edition_participants(reader, "synthetic-sp-2024")
        self.assertEqual(page["total"], 2)  # contagem agregada, sem identificar
        self.assertEqual([i["author"]["username"] for i in page["items"]], ["owner"])
        mine = social.edition_participants(private, "synthetic-sp-2024")
        self.assertEqual({i["author"]["username"] for i in mine["items"]}, {"owner", "secret"})
        owner_row = page["items"][0]
        self.assertEqual(owner_row["timeSeconds"], 3600)  # padrao do app: mostrar o tempo
        self.assertEqual(owner_row["distanceId"], "10k")
        # quem escolheu esconder o tempo nao o expoe a outros (mas o proprio dono ainda ve)
        part_key = ("history", "USER#owner", "P#" + owner_row["participationId"] + "#PART")
        part = self.store.get(part_key)
        self.store.commit({part_key: part}, {part_key: {**part, "showTime": False}})
        hidden = social.edition_participants(reader, "synthetic-sp-2024")["items"][0]
        self.assertNotIn("timeSeconds", hidden)
        own = social.edition_participants(self.actor, "synthetic-sp-2024")["items"]
        self.assertTrue(any(i.get("timeSeconds") == 3600 for i in own))
        self.assertEqual(social.edition_participants(reader, "synthetic-sp-2025")["items"], [])
        self.assertEqual(social.edition_participants(reader, "synthetic-sp-2024", "5k")["total"], 0)

    def test_complete_without_ratings_then_rate_later(self):
        # Avaliacao opcional: conclui sem notas e avalia depois (expectedVersion 0 cria a avaliacao).
        social = SocialService(self.identity)
        reader = self.admit("reader")
        draft = self.service.create(self.actor, "d-opt", self.payload(timeSeconds=3600))
        body = self.completion(draft)
        body.pop("ratings")
        done = self.service.complete(self.actor, draft["id"], "c-opt", body)
        self.assertEqual(done["state"], "completed")
        pid = draft["id"]
        # Sem avaliacao: nao ha review, nem evento de nota, nem aparece na lista publica de avaliacoes.
        with self.assertRaises(Problem) as error:
            self.service.get_review(self.actor, pid)
        self.assertEqual(error.exception.code, "REVIEW_NOT_FOUND")
        self.assertIsNone(self.store.get(("history", "USER#owner", "P#" + pid + "#REVIEW")))
        self.assertEqual(social.edition_reviews(reader, "synthetic-sp-2024")["items"], [])
        # Versao diferente de 0 nao cria avaliacao.
        rating = {k: 4 for k in self.completion(draft)["ratings"]}
        with self.assertRaises(Problem) as error:
            self.service.replace_review(
                self.actor, pid, "r-bad", {"expectedVersion": 1, "ratings": rating}
            )
        self.assertEqual(error.exception.code, "REVIEW_NOT_FOUND")
        # Avaliar depois: expectedVersion 0 cria; aparece na lista publica e na leitura.
        created = self.service.replace_review(
            self.actor, pid, "r-new", {"expectedVersion": 0, "ratings": rating, "comment": "Depois"}
        )
        self.assertEqual(created["version"], 1)
        self.assertEqual(self.service.get_review(self.actor, pid)["comment"], "Depois")
        listed = social.edition_reviews(reader, "synthetic-sp-2024")
        self.assertEqual([i["participationId"] for i in listed["items"]], [pid])
        # Criar de novo com 0 e conflito; a versao certa substitui.
        with self.assertRaises(Problem) as error:
            self.service.replace_review(
                self.actor, pid, "r-dup", {"expectedVersion": 0, "ratings": rating}
            )
        self.assertEqual(error.exception.code, "VERSION_CONFLICT")
        again = self.service.replace_review(
            self.actor, pid, "r-up", {"expectedVersion": 1, "ratings": rating}
        )
        self.assertEqual(again["version"], 2)

    def _published_with_images(self):
        """Participacao concluida e publicada, com foto da medalha e da postagem (copias tratadas no blob store)."""
        from runpass.upload import MemoryBlobStore

        draft = self.service.create(self.actor, "d-erase", self.payload(timeSeconds=3600))
        post_ref = "img_" + "c" * 64
        for ref in ("img-erase-medal", post_ref):
            key = ("operations", "USER#owner", "IMAGE#" + ref)
            self.store.commit(
                {key: None},
                {key: {"owner": "owner", "origin": "runner", "state": "valid", "refs": 0}},
            )
        body = self.completion(draft, medalImageReference="img-erase-medal")
        body.update(publishToFeed=True, postImageReference=post_ref, postText="Texto do post")
        done = self.service.complete(self.actor, draft["id"], "c-erase", body)
        blobs = MemoryBlobStore()
        for ref in ("img-erase-medal", post_ref):
            blobs.derived[ref] = {"owner": "owner", "contentType": "image/png", "data": b"x"}
        return done, blobs, post_ref

    # ---- várias publicações da mesma corrida ----
    def _image(self, ref, owner="owner"):
        key = ("operations", "USER#" + owner, "IMAGE#" + ref)
        self.store.commit(
            {key: None}, {key: {"owner": owner, "origin": "runner", "state": "valid", "refs": 0}}
        )

    def test_varias_publicacoes_da_mesma_corrida_no_feed_com_curtida_comentario_e_foto(self):
        from runpass.social import SocialService
        from runpass.upload import MemoryBlobStore, UploadService

        social = SocialService(self.identity)
        done, _, _ = self._published_with_images()
        extra_ref = "img_" + "d" * 64
        self._image(extra_ref)
        extra = self.service.create_extra_post(
            self.actor,
            "xp-1",
            {
                "participationId": done["id"],
                "postImageReference": extra_ref,
                "postText": "Outra foto",
            },
        )
        self.assertTrue(extra["id"].startswith("x-"))
        # mesma chave: não cria outra
        again = self.service.create_extra_post(
            self.actor,
            "xp-1",
            {
                "participationId": done["id"],
                "postImageReference": extra_ref,
                "postText": "Outra foto",
            },
        )
        self.assertEqual(again["id"], extra["id"])
        mine = [p["id"] for p in social.my_posts(self.actor)["items"]]
        self.assertEqual(sorted(mine), sorted([done["id"], extra["id"]]))
        viewer = self.admit("viewer")
        feed = social.feed(viewer)["items"]
        ids = [p["id"] for p in feed]
        self.assertIn(done["id"], ids)
        self.assertIn(extra["id"], ids)
        post = social.post(viewer, extra["id"])
        self.assertTrue(post["extra"])
        self.assertEqual(post["participation"]["id"], done["id"])
        self.assertEqual(post["comment"], "Outra foto")
        self.assertTrue(post["hasPostImage"])
        social.like(viewer, extra["id"], "l1")
        social.comment(viewer, extra["id"], "c1", "Linda")
        post = social.post(self.actor, extra["id"])
        self.assertEqual((post["likeCount"], post["commentCount"]), (1, 1))
        blobs = MemoryBlobStore()
        blobs.derived[extra_ref] = {"owner": "owner", "contentType": "image/png", "data": b"x"}
        uploads = UploadService(self.identity, blobs, may_view=social.may_view_photo)
        self.assertIn("url", uploads.extra_post_image(viewer, extra["id"]))
        # editar e remover
        changed = self.service.update_extra_post(
            self.actor, extra["id"], "xp-e", {"expectedVersion": 1, "postText": ""}
        )
        self.assertNotIn("postText", changed)
        self.service.delete_extra_post(self.actor, extra["id"], "xp-d")
        self.assertNotIn(extra["id"], [p["id"] for p in social.feed(viewer)["items"]])
        with self.assertRaises(Problem):
            social.post(viewer, extra["id"])
        self.assertEqual(
            self.store.get(("operations", "USER#owner", "IMAGE#" + extra_ref))["refs"], 0
        )

    def test_publicacao_extra_so_de_corrida_minha_concluida_e_foto_diferente_da_medalha(self):
        done, _, _ = self._published_with_images()
        other = self.admit("other")
        ref = "img_" + "e" * 64
        self._image(ref, "other")
        with self.assertRaises(Problem) as caught:
            self.service.create_extra_post(
                other, "o1", {"participationId": done["id"], "postImageReference": ref}
            )
        self.assertEqual(caught.exception.code, "PARTICIPATION_NOT_FOUND")
        draft = self.service.create(self.actor, "d-x", self.payload(editionId="synthetic-sp-2025"))
        mine = "img_" + "f" * 64
        self._image(mine)
        with self.assertRaises(Problem) as caught:
            self.service.create_extra_post(
                self.actor, "o2", {"participationId": draft["id"], "postImageReference": mine}
            )
        self.assertEqual(caught.exception.code, "PARTICIPATION_NOT_COMPLETED")

    def test_publicacoes_extras_saem_com_a_participacao_e_com_a_conta(self):
        from runpass.erasure import ErasureProcessor

        done, blobs, _ = self._published_with_images()
        ref = "img_" + "a" * 64
        self._image(ref)
        extra = self.service.create_extra_post(
            self.actor, "xe", {"participationId": done["id"], "postImageReference": ref}
        )
        self.service.delete(self.actor, done["id"], "x-del", done["version"])
        ErasureProcessor(self.identity, blobs).run_pending_participations()
        self.assertIsNone(self.store.get(("history", "USER#owner", "XP#" + extra["id"])))
        self.assertIsNone(self.store.get(("history", "XPOST#" + extra["id"], "OWNER")))
        self.assertFalse(
            [k for k in self.store.items if k[1] == "FEED#PUBLIC" and extra["id"] in k[2]]
        )
        # pela conta: outra corrida com publicação extra some quando a conta é apagada
        d2 = self.service.create(self.actor, "d2", self.payload(editionId="synthetic-sp-2025"))
        medal = "img_" + "9" * 64
        self._image(medal)
        body = self.completion(d2, medalImageReference=medal)
        done2 = self.service.complete(self.actor, d2["id"], "c2", body)
        ref2 = "img_" + "8" * 64
        self._image(ref2)
        extra2 = self.service.create_extra_post(
            self.actor, "xe2", {"participationId": done2["id"], "postImageReference": ref2}
        )
        self.identity.delete_account(self.actor, "del-owner")
        ErasureProcessor(self.identity, blobs).run_pending()
        self.assertIsNone(self.store.get(("history", "XPOST#" + extra2["id"], "OWNER")))
        self.assertFalse(
            [k for k in self.store.items if k[1] == "FEED#PUBLIC" and extra2["id"] in k[2]]
        )

    def test_participation_erasure_executor_removes_data_and_completes_the_operation(self):
        from runpass.erasure import ErasureProcessor

        done, blobs, post_ref = self._published_with_images()
        pid = done["id"]
        out = self.service.delete(self.actor, pid, "x-erase", done["version"])
        self.assertEqual(out["state"], "pending")
        # Some da lista na hora, mesmo antes do executor.
        listed = [i["id"] for i in self.service.list(self.actor, None, 50, None)["items"]]
        self.assertNotIn(pid, listed)
        pk = "USER#owner"
        self.assertIsNotNone(self.store.get(("history", pk, "P#" + pid + "#PART")))
        # O executor roda: apaga participacao, avaliacao, medalha, imagens e conclui a operacao.
        erasure = ErasureProcessor(self.identity, blobs)
        self.assertEqual(erasure.run_pending_participations(), {"completed": 1, "pending": 0})
        for suffix in ("#PART", "#REVIEW", "#MEDAL"):
            self.assertIsNone(self.store.get(("history", pk, "P#" + pid + suffix)))
        self.assertIsNone(self.store.get(("history", "PARTICIPATION#" + pid, "OWNER")))
        self.assertIsNone(self.store.get(("operations", pk, "IMAGE#img-erase-medal")))
        self.assertIsNone(self.store.get(("operations", pk, "IMAGE#" + post_ref)))
        self.assertEqual(blobs.derived, {})  # as copias tratadas foram apagadas
        state = self.service.get_deletion(self.actor, out["operationId"])
        self.assertEqual(state["state"], "completed")
        # Rodar de novo nao faz nada.
        self.assertEqual(erasure.run_pending_participations(), {"completed": 0, "pending": 0})

    def test_participation_erasure_keeps_images_still_used_and_never_touches_official_art(self):
        from runpass.erasure import ErasureProcessor

        done, blobs, post_ref = self._published_with_images()
        # A foto da postagem tambem esta em uso por outra participacao: nao pode ser apagada.
        key = ("operations", "USER#owner", "IMAGE#" + post_ref)
        row = self.store.get(key)
        self.store.commit({key: row}, {key: {**row, "refs": row["refs"] + 1}})
        self.service.delete(self.actor, done["id"], "x-keep", done["version"])
        ErasureProcessor(self.identity, blobs).run_pending_participations()
        self.assertIsNotNone(self.store.get(key))
        self.assertIn(post_ref, blobs.derived)
        self.assertNotIn("img-erase-medal", blobs.derived)

    def test_participation_erasure_does_not_touch_other_participations(self):
        from runpass.erasure import ErasureProcessor

        done, blobs, _ = self._published_with_images()
        other = self.admit("other")
        draft = self.service.create(other, "d-other", self.payload(timeSeconds=1800))
        self.service.delete(self.actor, done["id"], "x-iso", done["version"])
        ErasureProcessor(self.identity, blobs).run_pending_participations()
        # O rascunho de outra pessoa continua la.
        self.assertEqual(self.service.get(other, draft["id"])["state"], "draft")

    def test_delete_completed_participation_without_review(self):
        draft = self.service.create(self.actor, "d-del", self.payload(timeSeconds=3600))
        body = self.completion(draft)
        body.pop("ratings")
        done = self.service.complete(self.actor, draft["id"], "c-del", body)
        out = self.service.delete(self.actor, draft["id"], "x-del", done["version"])
        self.assertTrue(out["publiclyHidden"])

    def test_edition_photos_only_post_photos_of_published_participations(self):
        social = SocialService(self.identity)
        reader = self.admit("reader")
        self.assertEqual(social.edition_photos(reader, "synthetic-sp-2024")["total"], 0)
        _, with_post = self.finish("owner", 5)
        _, medal_only = self.finish("plain", 4)  # publicada, mas so com a foto da medalha

        def change(subject, pid, **fields):
            key = ("history", "USER#" + subject, "P#" + pid + "#PART")
            part = self.store.get(key)
            self.store.commit({key: part}, {key: {**part, **fields}})

        post_ref = "img_" + "a" * 64
        # Foto de postagem sem publicar: nao entra.
        change("owner", with_post, postImageReference=post_ref)
        self.assertEqual(social.edition_photos(reader, "synthetic-sp-2024")["total"], 0)
        # Publicada com foto de postagem: entra, e so ela.
        change("owner", with_post, publishToFeed=True)
        change("plain", medal_only, publishToFeed=True)
        page = social.edition_photos(reader, "synthetic-sp-2024")
        self.assertEqual(page["total"], 1)
        self.assertEqual([i["participationId"] for i in page["items"]], [with_post])
        self.assertEqual(page["items"][0]["author"]["username"], "owner")
        self.assertEqual(page["items"][0]["distanceId"], "10k")
        self.assertEqual(social.edition_photos(reader, "synthetic-sp-2024", "5k")["total"], 0)
        self.assertEqual(social.edition_photos(reader, "synthetic-sp-2025")["items"], [])
        # A foto da medalha nunca vale: mesmo com origem do corredor, sem foto de postagem fica de fora.
        self.assertNotIn(medal_only, [i["participationId"] for i in page["items"]])
        # Despublicada: some para todos, inclusive para o dono.
        change("owner", with_post, publishToFeed=False)
        self.assertEqual(social.edition_photos(reader, "synthetic-sp-2024")["total"], 0)
        self.assertEqual(social.edition_photos(self.actor, "synthetic-sp-2024")["total"], 0)

    def test_review_summary_accepts_decimal_ratings_like_dynamodb_returns(self):
        # O DynamoDB devolve numeros como Decimal. Antes, Decimal + float quebrava a aba Avaliacoes (TypeError).
        from decimal import Decimal

        social = SocialService(self.identity)
        ratings = {c: Decimal(5) for c in SocialService.CRITERIA}
        poor = {c: Decimal(3) for c in SocialService.CRITERIA}
        summary = social._review_summary([{"ratings": ratings}, {"ratings": poor}])
        self.assertEqual(summary["reviewCount"], 2)
        self.assertEqual(summary["average"], 4.0)
        self.assertEqual(summary["byCriterion"]["kit"], 4.0)
        self.assertEqual(summary["recommendPercent"], 50)

    def test_edition_carries_the_public_score_only_when_there_are_reviews(self):
        reader = self.admit("reader")
        key = ("projections", "EDITION#synthetic-sp-2024", "SCORE#current")
        self.assertNotIn("runScore", self.catalog.detail(reader, "synthetic-sp-2024"))
        self.store.commit({key: None}, {key: {"reviewCount": 3, "ratingSum": 3 * 8 * 4 + 2}})
        score = self.catalog.detail(reader, "synthetic-sp-2024")["runScore"]
        self.assertEqual(score, {"value": 4.1, "reviewCount": 3})
        listed = self.catalog.list(reader, CatalogFilters())["items"]
        by_id = {e["id"]: e for e in listed}
        self.assertEqual(by_id["synthetic-sp-2024"]["runScore"]["reviewCount"], 3)
        self.assertNotIn("runScore", by_id["synthetic-sp-2025"])

    def test_unreadable_scores_never_break_the_catalog(self):
        from runpass.store import Unavailable

        reader = self.admit("reader")
        real = self.store.get

        def get(key):
            if key[0] == "projections":
                raise Unavailable()
            return real(key)

        self.store.get = get
        listed = self.catalog.list(reader, CatalogFilters())["items"]
        self.assertTrue(listed)
        self.assertTrue(all("runScore" not in e for e in listed))
        self.assertNotIn("runScore", self.catalog.detail(reader, "synthetic-sp-2024"))

    def test_race_plans_set_change_list_and_delete(self):
        other = self.admit("other")
        with self.assertRaises(Problem) as none:
            self.service.get_plan(self.actor, "synthetic-sp-2026")
        self.assertEqual(none.exception.code, "PLAN_NOT_FOUND")
        wanted = self.service.put_plan(self.actor, "synthetic-sp-2026", "wanted")
        self.assertEqual((wanted["status"], wanted["version"]), ("wanted", 1))
        again = self.service.put_plan(self.actor, "synthetic-sp-2026", "wanted")
        self.assertEqual(again["version"], 2)  # idempotente no efeito; so conta a revisao
        signed = self.service.put_plan(self.actor, "synthetic-sp-2026", "registered", "21k")
        self.assertEqual((signed["status"], signed["distanceId"]), ("registered", "21k"))
        self.service.put_plan(self.actor, "synthetic-sp-2025", "wanted")
        everything = self.service.list_plans(self.actor)["items"]
        self.assertEqual(
            [i["editionId"] for i in everything], ["synthetic-sp-2025", "synthetic-sp-2026"]
        )
        self.assertEqual(everything[1]["edition"]["name"], "Corrida Sintética São Paulo")
        only = self.service.list_plans(self.actor, "registered")["items"]
        self.assertEqual([i["editionId"] for i in only], ["synthetic-sp-2026"])
        self.assertEqual(self.service.list_plans(other)["items"], [])  # nunca de outra pessoa
        self.service.delete_plan(self.actor, "synthetic-sp-2026")
        self.service.delete_plan(self.actor, "synthetic-sp-2026")  # repetir e seguro
        with self.assertRaises(Problem):
            self.service.get_plan(self.actor, "synthetic-sp-2026")

    def test_edition_registrants_list_only_registered_plans_with_privacy(self):
        social = SocialService(self.identity)
        reader = self.admit("reader")
        other = self.admit("other")
        ed = "synthetic-sp-2026"
        self.assertEqual(social.edition_registrants(reader, ed), {"items": [], "total": 0})
        self.service.put_plan(self.actor, ed, "registered", "21k")
        self.service.put_plan(other, ed, "wanted")  # so quer correr: nao e inscrito
        page = social.edition_registrants(reader, ed)
        self.assertEqual(page["total"], 1)
        self.assertEqual([i["author"]["username"] for i in page["items"]], ["owner"])
        self.assertEqual(page["items"][0]["distanceId"], "21k")
        # Quem passa de "quero correr" para "inscrito" entra; quem volta, sai.
        self.service.put_plan(other, ed, "registered")
        self.assertEqual(social.edition_registrants(reader, ed)["total"], 2)
        self.service.put_plan(other, ed, "wanted")
        self.assertEqual(social.edition_registrants(reader, ed)["total"], 1)
        # Perfil privado: conta no total, mas nao aparece para quem nao e amigo.
        self.service.put_plan(other, ed, "registered")
        key = ("identity", "USER#other", "PROFILE")
        self.store.commit(
            {key: self.store.get(key)}, {key: {**self.store.get(key), "isPrivate": True}}
        )
        hidden = social.edition_registrants(reader, ed)
        self.assertEqual(hidden["total"], 2)
        self.assertEqual([i["author"]["username"] for i in hidden["items"]], ["owner"])
        self.store.commit(
            {key: self.store.get(key)}, {key: {**self.store.get(key), "isPrivate": False}}
        )
        # Apagar o plano tira da lista; paginacao por cursor.
        self.service.delete_plan(self.actor, ed)
        self.assertEqual(social.edition_registrants(reader, ed)["total"], 1)
        self.service.put_plan(self.actor, ed, "registered")
        one = social.edition_registrants(self.actor, ed, limit=1)
        self.assertEqual(len(one["items"]), 1)
        rest = social.edition_registrants(self.actor, ed, limit=1, cursor=one["nextCursor"])
        self.assertEqual(len(rest["items"]), 1)
        self.assertNotIn("nextCursor", rest)

    def test_old_registered_plans_get_their_pointer_when_the_owner_lists_the_agenda(self):
        social = SocialService(self.identity)
        reader = self.admit("reader")
        ed = "synthetic-sp-2026"
        # Plano antigo: gravado sem o ponteiro de inscritos.
        key = ("history", "USER#owner", "PLAN#" + ed)
        self.store.commit(
            {key: None},
            {key: {"editionId": ed, "status": "registered", "version": 1, "updatedAt": "x"}},
        )
        self.assertEqual(social.edition_registrants(reader, ed)["total"], 0)
        self.service.list_plans(self.actor)  # repara
        self.assertEqual(social.edition_registrants(reader, ed)["total"], 1)

    def test_race_plan_refuses_unknown_edition_bad_distance_and_archived(self):
        with self.assertRaises(Problem) as missing:
            self.service.put_plan(self.actor, "nao-existe", "wanted")
        self.assertEqual(missing.exception.code, "EDITION_NOT_FOUND")
        with self.assertRaises(Problem) as distance:
            self.service.put_plan(self.actor, "synthetic-sp-2026", "wanted", "42k")
        self.assertEqual(distance.exception.code, "DISTANCE_NOT_IN_EDITION")
        with self.assertRaises(Problem) as archived:
            self.service.put_plan(self.actor, "synthetic-archived", "wanted")
        self.assertEqual(archived.exception.code, "EDITION_ARCHIVED")

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
        # Comentario sem notas nao vale (a avaliacao e tudo ou nada).
        bad = client.post(
            f"/participations/{participation_id}/complete",
            headers={**headers, "Idempotency-Key": "c-bad"},
            json={
                "expectedVersion": 1,
                "declaredCompleted": True,
                "medalImageReference": "img-http",
                "publishToFeed": False,
                "comment": "sem notas",
            },
        )
        self.assertEqual(bad.status_code, 422)
        plain = client.get("/me/participations?state=draft", headers=headers).json()["items"][0]
        self.assertNotIn("edition", plain)
        expanded = client.get("/me/participations?state=draft&expand=edition", headers=headers)
        self.assertEqual(expanded.status_code, 200, expanded.text)
        self.assertEqual(expanded.json()["items"][0]["edition"]["id"], "synthetic-sp-2024")
        self.assertIn("distances", expanded.json()["items"][0]["edition"])
        self.assertEqual(
            client.get("/me/participations?expand=outra", headers=headers).status_code, 422
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
