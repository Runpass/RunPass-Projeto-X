"""Owned participation drafts and atomic completion source records."""

import hashlib
import json
from copy import deepcopy
from datetime import date, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

from cryptography.fernet import Fernet, InvalidToken

from .service import Problem, stamp


def _write_review_pointer(read, write, pk, edition_id, participation_id, item, owner):
    """Ponteiro `EDREV#<edicao>` para a lista publica de avaliacoes (sem Scan).

    A leitura sempre reconfere participacao, avaliacao e conta; o ponteiro entra no `sharedKeys`
    do dono, entao o apagamento da conta o remove. Pontos antigos (troca de edicao) ficam na lista
    para o apagamento limpar tudo, mas nunca aparecem: a leitura exige a edicao atual."""
    pointer = ("history", "EDREV#" + edition_id, f"T#{item['completedAt']}#{participation_id}")
    ref = ("history", pk, "REVREF#" + participation_id)
    old = read(ref)
    read(pointer)
    write(
        pointer,
        {"owner": owner, "id": participation_id, "completedAt": item["completedAt"]},
    )
    kept = [k for k in (old or {}).get("sharedKeys", []) if tuple(k) != pointer]
    write(ref, {"sharedKeys": [list(pointer), *kept]})


def _sync_plan_pointer(read, write, pk, subject, edition_id, registered, now):
    """Ponteiro `EDPLAN#<edicao>` dos inscritos (status `registered`), para listar quem vai
    correr sem Scan. A leitura reconfere plano e conta; o ponteiro entra no `sharedKeys` do dono
    (linha `PLANREF#`), entao o apagamento da conta o remove."""
    pointer = ("history", "EDPLAN#" + edition_id, "U#" + subject)
    ref = ("history", pk, "PLANREF#" + edition_id)
    had_pointer, had_ref = read(pointer), read(ref)
    if registered:
        write(pointer, {"owner": subject, "editionId": edition_id, "updatedAt": stamp(now)})
        write(ref, {"sharedKeys": [list(pointer)]})
        return
    if had_pointer:
        write(pointer, None)
    if had_ref:
        write(ref, None)


MAX_MORE_POST_IMAGES = 4


def post_image_count(item):
    """Quantas fotos a publicacao tem: a capa (`postImageReference`) mais as extras do carrossel."""
    if not item.get("postImageReference"):
        return 0
    return 1 + len(item.get("morePostImageReferences") or [])


def _own_writes(read, write):
    """read/write que enxergam as escritas ja feitas nesta transacao. O `read` do servico devolve sempre
    o valor lido do banco; sem isto, duas mudancas na contagem de uso da mesma imagem (trocar a capa por
    uma extra, por exemplo) se sobrescreviam."""
    pending = {}

    def own_read(key):
        return deepcopy(pending[key]) if key in pending else read(key)

    def own_write(key, value):
        pending[key] = deepcopy(value)
        write(key, value)

    return own_read, own_write


def _bump_image(read, write, pk, reference, delta):
    key = ("operations", pk, "IMAGE#" + reference)
    image = read(key)
    if image:
        write(key, {**image, "refs": max(0, image.get("refs", 0) + delta)})


PLAN_STATES = ("wanted", "registered")
MAX_PLANS = 200


def plan_projection(item):
    out = {k: item[k] for k in ("editionId", "status", "version", "updatedAt") if k in item}
    if item.get("distanceId"):
        out["distanceId"] = item["distanceId"]
    return out


class ParticipationService:
    def __init__(self, identity, catalog, cursor_key):
        self.identity, self.catalog = identity, catalog
        self.store = identity.store
        self.cipher = Fernet(cursor_key)

    @staticmethod
    def projection(item):
        """Visao do DONO (inclui as referencias das fotos; terceiros so veem `postImageCount`)."""
        out = {
            key: item[key]
            for key in (
                "id",
                "editionId",
                "distanceId",
                "state",
                "version",
                "timeSeconds",
                "paceSecondsPerKm",
                "placement",
                "bibNumber",
                "showTime",
                "showPlacement",
                "completedAt",
                "medalImageReference",
                "publishToFeed",
                "postImageReference",
                "morePostImageReferences",
                "postText",
                "taggedUserIds",
                "medalFrameId",
                "medalDescription",
                "medalCity",
                "medalState",
                "medalYear",
                "medalDisplayImageReference",
            )
            if key in item
        }
        out["postImageCount"] = post_image_count(item)
        return out

    @staticmethod
    def _post_image(read, subject, reference, medal_reference=None):
        """(chave, registro) da foto da publicacao: imagem valida do proprio dono, diferente da foto da medalha."""
        if reference == medal_reference:
            raise Problem(422, "POST_IMAGE_MUST_DIFFER")
        key = ("operations", "USER#" + subject, "IMAGE#" + reference)
        image = read(key)
        if (
            not image
            or image.get("state") != "valid"
            or image.get("owner") != subject
            or image.get("origin") != "runner"
        ):
            raise Problem(422, "IMAGE_NOT_VALID")
        return key, image

    @classmethod
    def _more_post_images(cls, read, subject, cover, more, medal_reference):
        """Fotos extras da publicacao (carrossel): ate 4, sem repetir, nenhuma igual a capa nem a medalha,
        cada uma com as mesmas regras da capa (imagem valida e da propria pessoa). Devolve (chave, registro)."""
        more = list(more or [])
        if more and not cover:
            raise Problem(422, "POST_IMAGE_REQUIRED")
        if len(more) > MAX_MORE_POST_IMAGES:
            raise Problem(422, "TOO_MANY_POST_IMAGES")
        if len(set(more)) != len(more) or cover in more:
            raise Problem(422, "POST_IMAGE_DUPLICATE")
        return [cls._post_image(read, subject, ref, medal_reference) for ref in more]

    @classmethod
    def _replace_post_images(cls, read, write, subject, old, new, medal_reference):
        """Troca capa e extras de uma publicacao. `old`/`new` sao (capa, [extras]). Valida so as fotos que
        entram (as que ficam ja foram validadas), soma uso nas novas e libera as que sairam. Use com
        `_own_writes`: a mesma imagem pode mudar de posicao (extra vira capa) sem perder a contagem."""
        new_cover, new_more = new[0], list(new[1] or [])
        if len(set(new_more)) != len(new_more) or new_cover in new_more:
            raise Problem(422, "POST_IMAGE_DUPLICATE")
        if len(new_more) > MAX_MORE_POST_IMAGES:
            raise Problem(422, "TOO_MANY_POST_IMAGES")
        old_refs = [r for r in (old[0], *(old[1] or [])) if r]
        new_refs = [r for r in (new_cover, *new_more) if r]
        added = [r for r in new_refs if r not in old_refs]
        checked = [cls._post_image(read, subject, ref, medal_reference) for ref in added]
        pk = "USER#" + subject
        for key, image in checked:
            write(key, {**image, "refs": image.get("refs", 0) + 1})
        for ref in old_refs:
            if ref not in new_refs:
                _bump_image(read, write, pk, ref, -1)

    def _catalog_guard(self, read, edition_id, expected_catalog_version):
        head = read(("catalog", "EDITION#" + edition_id, "HEAD"))
        if (
            not head
            or head.get("publicationState") != "approved"
            or head.get("archived")
            or head.get("version") != expected_catalog_version
        ):
            raise Problem(409, "EDITION_CHANGED")

    def create(self, actor, key, payload):
        observed = self.catalog.require_draftable(
            actor, payload["editionId"], payload["distanceId"]
        )
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            self._catalog_guard(read, payload["editionId"], observed["version"])
            claim_key = ("history", pk, "EDITION#" + payload["editionId"] + "#CLAIM")
            claim = read(claim_key)
            if replay is not None:
                item = read(("history", pk, "P#" + replay["id"] + "#PART"))
                if not item:
                    raise Problem(404, "PARTICIPATION_NOT_FOUND")
                return self.projection(item), replay
            if claim:
                raise Problem(409, "PARTICIPATION_EXISTS")
            participation_id = str(uuid4())
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            owner_key = ("history", "PARTICIPATION#" + participation_id, "OWNER")
            item = {
                "id": participation_id,
                "owner": actor.subject,
                "editionId": payload["editionId"],
                "distanceId": payload["distanceId"],
                "catalogVersion": observed["version"],
                "state": "draft",
                "version": 1,
                "showTime": True,
                "showPlacement": True,
                "createdAt": stamp(now),
                "updatedAt": stamp(now),
            }
            for field in ("timeSeconds", "paceSecondsPerKm", "placement", "bibNumber"):
                if payload.get(field) is not None:
                    item[field] = payload[field]
            write(part_key, item)
            write(owner_key, {"owner": actor.subject})
            write(claim_key, {"participationId": participation_id, "version": 1})
            receipt = {"id": participation_id}
            return self.projection(item), receipt

        return self.identity.transact(
            actor, "createParticipationDraft", key, payload, work, admitted=True
        )

    def get(self, actor, participation_id):
        def work(read, write, account, now, replay):
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            if not owner or owner.get("owner") != actor.subject:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            item = read(("history", "USER#" + actor.subject, "P#" + participation_id + "#PART"))
            if not item or item.get("state") not in {"draft", "completed"}:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            return self.projection(item), {}

        return self.identity.transact(actor, "getParticipation", None, {}, work, admitted=True)

    def complete(self, actor, participation_id, key, payload):
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            item = read(part_key)
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            if not item or not owner or owner.get("owner") != actor.subject:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if replay is not None:
                if item.get("state") != "completed":
                    raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
                return self.projection(item), replay
            if item.get("state") != "draft":
                raise Problem(409, "PARTICIPATION_NOT_DRAFT")
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            self._catalog_guard(read, item["editionId"], item["catalogVersion"])
            manifest_key = (
                "catalog",
                "EDITION#" + item["editionId"],
                "V#" + str(item["catalogVersion"]),
            )
            manifest = read(manifest_key)
            if not manifest:
                raise Problem(503, "CATALOG_INTEGRITY_FAILURE")
            edition = manifest["edition"]
            today = now.astimezone(ZoneInfo("America/Sao_Paulo")).date()
            if date.fromisoformat(edition["date"]) > today:
                raise Problem(409, "EDITION_NOT_COMPLETABLE")
            distance = next(
                (d for d in edition["distances"] if d["id"] == item["distanceId"]), None
            )
            if distance is None:
                raise Problem(409, "EDITION_CHANGED")
            reference = payload["medalImageReference"]
            image_key = ("operations", pk, "IMAGE#" + reference)
            image = read(image_key)
            origin = "runner"
            if not image:
                official = distance.get("medalImageReference") or edition.get("medalImageReference")
                if official != reference:
                    raise Problem(422, "IMAGE_NOT_VALID")
                image_key = (
                    "operations",
                    "EDITION#" + item["editionId"],
                    "IMAGE#" + reference,
                )
                image = read(image_key)
                origin = "official"
            if not image or image.get("state") != "valid":
                raise Problem(422, "IMAGE_NOT_VALID")
            if origin == "runner" and (
                image.get("owner") != actor.subject or image.get("origin") != "runner"
            ):
                raise Problem(422, "IMAGE_NOT_VALID")
            if origin == "official" and image.get("origin") != "admin":
                raise Problem(422, "IMAGE_NOT_VALID")
            post_ref = payload.get("postImageReference")
            if payload["publishToFeed"] and not post_ref:
                raise Problem(422, "POST_IMAGE_REQUIRED")
            if post_ref and not payload["publishToFeed"]:
                raise Problem(422, "POST_IMAGE_NOT_ALLOWED")
            more_refs = payload.get("morePostImageReferences") or []
            if more_refs and not payload["publishToFeed"]:
                raise Problem(422, "POST_IMAGE_NOT_ALLOWED")
            post_image = (
                self._post_image(read, actor.subject, post_ref, reference) if post_ref else None
            )
            more_images = self._more_post_images(
                read, actor.subject, post_ref, more_refs, reference
            )
            review_key = ("history", pk, "P#" + participation_id + "#REVIEW")
            medal_key = ("history", pk, "P#" + participation_id + "#MEDAL")
            if read(review_key) or read(medal_key):
                raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
            claim_key = ("history", pk, "EDITION#" + item["editionId"] + "#CLAIM")
            claim = read(claim_key)
            if not claim or claim.get("participationId") != participation_id:
                raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
            # Avaliacao opcional: sem notas a participacao conclui sem avaliacao, sem evento de nota e sem
            # ponteiro de avaliacao publica; a pessoa avalia depois (PUT .../review com expectedVersion 0).
            ratings = payload.get("ratings")
            event_id = str(uuid4())
            event_key = ("operations", pk, "EVENT#" + event_id)
            shard = int(hashlib.sha256(event_id.encode()).hexdigest(), 16) % 16
            work_key = (
                "operations",
                f"WORK#event#pending#{shard:02d}",
                stamp(now) + "#" + event_id,
            )
            if ratings is not None:
                read(event_key)
                read(work_key)
            item.update(
                state="completed",
                version=item["version"] + 1,
                completedAt=stamp(now),
                updatedAt=stamp(now),
                medalImageReference=reference,
                publishToFeed=payload["publishToFeed"],
            )
            if post_image:
                item["postImageReference"] = post_ref
                if more_refs:
                    item["morePostImageReferences"] = more_refs
                if payload.get("postText"):
                    item["postText"] = payload["postText"]
                if payload.get("taggedUserIds"):
                    item["taggedUserIds"] = self._tags(read, actor, payload["taggedUserIds"])
            review = None
            if ratings is not None:
                review = {
                    "participationId": participation_id,
                    "reviewVersion": 1,
                    "effectVersion": 1,
                    "ratings": ratings,
                    "moderationState": "valid",
                    "editionId": item["editionId"],
                    "distanceId": item["distanceId"],
                }
                if payload.get("comment") is not None:
                    review["comment"] = payload["comment"]
            medal = {
                "participationId": participation_id,
                "imageReference": reference,
                "imageOrigin": origin,
                "catalogVersion": item["catalogVersion"],
            }
            write(part_key, item)
            write(medal_key, medal)
            if review is not None:
                event = {
                    "id": event_id,
                    "type": "participation_completed",
                    "state": "pending",
                    "participationId": participation_id,
                    "effectVersion": 1,
                    "editionId": item["editionId"],
                    "distanceId": item["distanceId"],
                    "ratings": ratings,
                    "occurredAt": stamp(now),
                    "dispatchEpoch": 1,
                    "workPartition": work_key[1],
                    "workSort": work_key[2],
                }
                write(review_key, review)
                write(event_key, event)
                write(
                    work_key,
                    {
                        "owner": actor.subject,
                        "eventId": event_id,
                        "state": "pending",
                        "nextAttemptAt": stamp(now),
                        "workPartition": work_key[1],
                        "workSort": work_key[2],
                    },
                )
            write(image_key, {**image, "refs": image.get("refs", 0) + 1})
            if post_image:
                write(post_image[0], {**post_image[1], "refs": post_image[1].get("refs", 0) + 1})
            for more_key, more_image in more_images:
                write(more_key, {**more_image, "refs": more_image.get("refs", 0) + 1})
            write(claim_key, {"participationId": participation_id, "version": item["version"]})
            if review is not None:
                _write_review_pointer(
                    read, write, pk, item["editionId"], participation_id, item, actor.subject
                )
            if payload["publishToFeed"]:
                # Ponteiro global para o feed "Todos" (social.py:_public_feed), sem Scan: a
                # visibilidade de verdade é sempre reconferida na leitura via can_view.
                feed_key = (
                    "history",
                    "FEED#PUBLIC",
                    f"T#{item['completedAt']}#{participation_id}",
                )
                feed_ref_key = ("history", pk, "FEEDREF#" + participation_id)
                write(
                    feed_key,
                    {
                        "owner": actor.subject,
                        "id": participation_id,
                        "completedAt": item["completedAt"],
                    },
                )
                write(feed_ref_key, {"sharedKeys": [list(feed_key)]})
            return self.projection(item), {"id": participation_id}

        return self.identity.transact(
            actor, "completeParticipation", key, payload, work, admitted=True
        )

    # ---- publicações extras (várias por corrida) -------------------------------------------------------

    @staticmethod
    def _extra_view(item):
        return {
            k: item[k]
            for k in (
                "id",
                "participationId",
                "postText",
                "taggedUserIds",
                "publishedAt",
                "version",
            )
            if k in item
        } | {
            "hasPostImage": True,
            # So o dono recebe esta visao (criar/editar/abrir a propria publicacao extra).
            "morePostImageReferences": list(item.get("morePostImageReferences") or []),
            "postImageCount": post_image_count(item),
        }

    def create_extra_post(self, actor, key, payload):
        """Outra publicação de uma corrida que eu já concluí (além da que nasce ao concluir). Foto própria
        obrigatória (diferente da medalha), texto e marcações opcionais. Não pede medalha nem mexe na
        participação. Fica no feed como as outras e sai junto com a participação ou a conta."""
        pk = "USER#" + actor.subject
        participation_id = payload["participationId"]

        def work(read, write, account, now, replay):
            if replay is not None:
                item = read(("history", pk, "XP#" + replay["id"]))
                if not item:
                    raise Problem(404, "POST_NOT_FOUND")
                return self._extra_view(item), replay
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            part = read(("history", pk, "P#" + participation_id + "#PART"))
            if not owner or owner.get("owner") != actor.subject or not part:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if part.get("state") != "completed":
                raise Problem(409, "PARTICIPATION_NOT_COMPLETED")
            image_key, image = self._post_image(
                read, actor.subject, payload["postImageReference"], part.get("medalImageReference")
            )
            more_refs = payload.get("morePostImageReferences") or []
            more_images = self._more_post_images(
                read,
                actor.subject,
                payload["postImageReference"],
                more_refs,
                part.get("medalImageReference"),
            )
            post_id = "x-" + uuid4().hex[:24]
            published = stamp(now)
            owner_key = ("history", "XPOST#" + post_id, "OWNER")
            feed_key = ("history", "FEED#PUBLIC", f"T#{published}#{post_id}")
            item = {
                "id": post_id,
                "participationId": participation_id,
                "postImageReference": payload["postImageReference"],
                "publishedAt": published,
                "version": 1,
                # Linhas da conta guardadas fora da partição dela: a exclusão da conta apaga junto.
                "sharedKeys": [list(owner_key), list(feed_key)],
            }
            if more_refs:
                item["morePostImageReferences"] = more_refs
            if payload.get("postText"):
                item["postText"] = payload["postText"]
            if payload.get("taggedUserIds"):
                item["taggedUserIds"] = self._tags(read, actor, payload["taggedUserIds"])
            for k in (owner_key, feed_key):
                read(k)
            write(("history", pk, "XP#" + post_id), item)
            write(owner_key, {"owner": actor.subject, "participationId": participation_id})
            write(
                feed_key,
                {"owner": actor.subject, "id": post_id, "completedAt": published, "extra": True},
            )
            write(image_key, {**image, "refs": image.get("refs", 0) + 1})
            for more_key, more_image in more_images:
                write(more_key, {**more_image, "refs": more_image.get("refs", 0) + 1})
            return self._extra_view(item), {"id": post_id}

        return self.identity.transact(actor, "createExtraPost", key, payload, work, admitted=True)

    def _my_extra(self, read, actor, post_id):
        item = read(("history", "USER#" + actor.subject, "XP#" + post_id))
        pointer = read(("history", "XPOST#" + post_id, "OWNER"))
        if not item or not pointer or pointer.get("owner") != actor.subject:
            raise Problem(404, "POST_NOT_FOUND")
        return item

    def update_extra_post(self, actor, post_id, key, payload):
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            item = self._my_extra(read, actor, post_id)
            if replay is not None:
                return self._extra_view(item), replay
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            new = dict(item)
            if "postText" in payload:
                if payload["postText"]:
                    new["postText"] = payload["postText"]
                else:
                    new.pop("postText", None)
            if "taggedUserIds" in payload:
                tags = self._tags(read, actor, payload["taggedUserIds"] or [])
                if tags:
                    new["taggedUserIds"] = tags
                else:
                    new.pop("taggedUserIds", None)
            old_images = (item["postImageReference"], item.get("morePostImageReferences") or [])
            new_images = (
                payload.get("postImageReference") or old_images[0],
                (payload.get("morePostImageReferences") or [])
                if "morePostImageReferences" in payload
                else old_images[1],
            )
            if new_images != old_images:
                part = read(("history", pk, "P#" + item["participationId"] + "#PART")) or {}
                own_read, own_write = _own_writes(read, write)
                self._replace_post_images(
                    own_read,
                    own_write,
                    actor.subject,
                    old_images,
                    new_images,
                    part.get("medalImageReference"),
                )
                new["postImageReference"] = new_images[0]
                if new_images[1]:
                    new["morePostImageReferences"] = list(new_images[1])
                else:
                    new.pop("morePostImageReferences", None)
            new["version"] = item["version"] + 1
            write(("history", pk, "XP#" + post_id), new)
            return self._extra_view(new), {"id": post_id}

        return self.identity.transact(actor, "updateExtraPost", key, payload, work, admitted=True)

    def delete_extra_post(self, actor, post_id, key):
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            if replay is not None:
                return {"deleted": post_id}, replay
            item = self._my_extra(read, actor, post_id)
            for shared in map(tuple, item.get("sharedKeys", [])):
                read(shared)
                write(shared, None)
            write(("history", pk, "XP#" + post_id), None)
            for ref in (item["postImageReference"], *(item.get("morePostImageReferences") or [])):
                _bump_image(read, write, pk, ref, -1)
            return {"deleted": post_id}, {"id": post_id}

        return self.identity.transact(actor, "deleteExtraPost", key, {}, work, admitted=True)

    def publish(self, actor, participation_id, key, payload):
        """Publica no feed uma participacao ja concluida e ainda nao publicada, com uma foto propria (a da medalha
        nao entra). Mesmo ponteiro do feed que a conclusao grava; a leitura reconfere a visibilidade."""
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            item = read(part_key)
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            if not item or not owner or owner.get("owner") != actor.subject:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if replay is not None:
                return self.projection(item), replay
            if item.get("state") != "completed":
                raise Problem(409, "PARTICIPATION_NOT_COMPLETED")
            if item.get("publishToFeed"):
                raise Problem(409, "ALREADY_PUBLISHED")
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            post_ref = payload["postImageReference"]
            image_key, image = self._post_image(
                read, actor.subject, post_ref, item.get("medalImageReference")
            )
            more_refs = payload.get("morePostImageReferences") or []
            more_images = self._more_post_images(
                read, actor.subject, post_ref, more_refs, item.get("medalImageReference")
            )
            item.update(
                publishToFeed=True,
                postImageReference=post_ref,
                version=item["version"] + 1,
                updatedAt=stamp(now),
            )
            if more_refs:
                item["morePostImageReferences"] = more_refs
            else:
                item.pop("morePostImageReferences", None)
            if payload.get("postText"):
                item["postText"] = payload["postText"]
            else:
                item.pop("postText", None)
            if payload.get("taggedUserIds"):
                item["taggedUserIds"] = self._tags(read, actor, payload["taggedUserIds"])
            feed_key = ("history", "FEED#PUBLIC", f"T#{item['completedAt']}#{participation_id}")
            feed_ref_key = ("history", pk, "FEEDREF#" + participation_id)
            read(feed_key)
            read(feed_ref_key)
            write(part_key, item)
            write(
                feed_key,
                {
                    "owner": actor.subject,
                    "id": participation_id,
                    "completedAt": item["completedAt"],
                },
            )
            write(feed_ref_key, {"sharedKeys": [list(feed_key)]})
            write(image_key, {**image, "refs": image.get("refs", 0) + 1})
            for more_key, more_image in more_images:
                write(more_key, {**more_image, "refs": more_image.get("refs", 0) + 1})
            return self.projection(item), {"id": participation_id}

        return self.identity.transact(
            actor, "publishParticipation", key, payload, work, admitted=True
        )

    # ---- planos de corrida: "quero correr" (wanted) e "vou correr / inscrito" (registered) ----

    def put_plan(self, actor, edition_id, status, distance_id=None):
        """Define a situacao da pessoa numa corrida futura ou do catalogo. Idempotente (PUT)."""
        edition = self.catalog.detail(actor, edition_id)  # 404 se nao existe
        if edition["status"] == "archived":
            raise Problem(409, "EDITION_ARCHIVED")
        if distance_id is not None and not any(
            d["id"] == distance_id for d in edition["distances"]
        ):
            raise Problem(422, "DISTANCE_NOT_IN_EDITION")
        key = ("history", "USER#" + actor.subject, "PLAN#" + edition_id)

        def work(read, write, account, now, replay):
            old = read(key)
            item = {
                "editionId": edition_id,
                "status": status,
                "version": (old["version"] + 1) if old else 1,
                "createdAt": old["createdAt"] if old else stamp(now),
                "updatedAt": stamp(now),
            }
            if distance_id:
                item["distanceId"] = distance_id
            write(key, item)
            _sync_plan_pointer(
                read,
                write,
                "USER#" + actor.subject,
                actor.subject,
                edition_id,
                status == "registered",
                now,
            )
            return plan_projection(item), {}

        return self.identity.transact(actor, "putRacePlan", None, {}, work, admitted=True)

    def get_plan(self, actor, edition_id):
        key = ("history", "USER#" + actor.subject, "PLAN#" + edition_id)

        def work(read, write, account, now, replay):
            item = read(key)
            if not item:
                raise Problem(404, "PLAN_NOT_FOUND")
            return plan_projection(item), {}

        return self.identity.transact(actor, "getRacePlan", None, {}, work, admitted=True)

    def delete_plan(self, actor, edition_id):
        key = ("history", "USER#" + actor.subject, "PLAN#" + edition_id)

        def work(read, write, account, now, replay):
            if read(key):
                write(key, None)
            _sync_plan_pointer(
                read, write, "USER#" + actor.subject, actor.subject, edition_id, False, now
            )
            return None, {}

        self.identity.transact(actor, "deleteRacePlan", None, {}, work, admitted=True)

    def _repair_plan_pointers(self, actor, registered):
        """Planos `registered` criados antes do indice de inscritos ganham o ponteiro na primeira
        vez que o dono abre a propria agenda. Idempotente; so escreve o que falta e nunca
        atrapalha a listagem (melhor esforco)."""
        subject = actor.subject
        missing = [
            item["editionId"]
            for item in registered
            if self.store.get(("history", "EDPLAN#" + item["editionId"], "U#" + subject)) is None
        ]
        if not missing:
            return

        def work(read, write, account, now, replay):
            for edition_id in missing:
                current = read(("history", "USER#" + subject, "PLAN#" + edition_id))
                if current and current.get("status") == "registered":
                    _sync_plan_pointer(
                        read, write, "USER#" + subject, subject, edition_id, True, now
                    )
            return None, {}

        try:
            self.identity.transact(actor, "repairPlanIndex", None, {}, work, admitted=True)
        except Exception:  # noqa: BLE001 - reparo e opcional: a agenda abre mesmo assim
            return

    def list_plans(self, actor, status=None):
        """Planos da propria pessoa com um resumo da edicao, por data (agenda)."""
        self.identity.authorize(actor, admitted=True)
        rows, _ = self.store.query(
            "history", "USER#" + actor.subject, prefix="PLAN#", limit=MAX_PLANS
        )
        self._repair_plan_pointers(
            actor, [item for _, item in rows if item.get("status") == "registered"]
        )
        items = []
        for _, item in rows:
            if status and item.get("status") != status:
                continue
            edition = self.catalog._edition(item["editionId"])
            if edition is None:
                continue
            summary = {
                k: edition[k]
                for k in ("id", "name", "date", "city", "state", "status", "distances")
                if k in edition
            }
            items.append({**plan_projection(item), "edition": summary})
        items.sort(key=lambda i: (i["edition"]["date"], i["editionId"]))
        return {"items": items}

    @staticmethod
    def review_projection(item):
        return {
            "participationId": item["participationId"],
            "version": item["reviewVersion"],
            "ratings": item["ratings"],
            "moderationState": item["moderationState"],
            **({"comment": item["comment"]} if "comment" in item else {}),
        }

    def get_review(self, actor, participation_id):
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            part = read(("history", pk, "P#" + participation_id + "#PART"))
            review = read(("history", pk, "P#" + participation_id + "#REVIEW"))
            if (
                not owner
                or owner.get("owner") != actor.subject
                or not part
                or part.get("state") != "completed"
                or not review
            ):
                raise Problem(404, "REVIEW_NOT_FOUND")
            return self.review_projection(review), {}

        return self.identity.transact(
            actor, "getParticipationReview", None, {}, work, admitted=True
        )

    def replace_review(self, actor, participation_id, key, payload):
        """Substitui a avaliacao (expectedVersion >= 1) ou a CRIA para uma participacao concluida sem avaliacao
        (expectedVersion 0): a pessoa pode avaliar depois de concluir."""
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            review_key = ("history", pk, "P#" + participation_id + "#REVIEW")
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            part, review = read(part_key), read(review_key)
            if (
                not owner
                or owner.get("owner") != actor.subject
                or not part
                or part.get("state") != "completed"
            ):
                raise Problem(404, "REVIEW_NOT_FOUND")
            creating = review is None
            if creating and payload["expectedVersion"] != 0:
                raise Problem(404, "REVIEW_NOT_FOUND")
            if replay is not None:
                if creating:
                    raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
                return self.review_projection(review), replay
            if not creating and review["reviewVersion"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            event_id = str(uuid4())
            event_key = ("operations", pk, "EVENT#" + event_id)
            audit_key = ("operations", pk, "AUDIT_SOURCE#" + event_id)
            shard = int(hashlib.sha256(event_id.encode()).hexdigest(), 16) % 16
            work_key = (
                "operations",
                f"WORK#event#pending#{shard:02d}",
                stamp(now) + "#" + event_id,
            )
            read(event_key)
            read(audit_key)
            read(work_key)
            if creating:
                updated = {
                    "participationId": participation_id,
                    "reviewVersion": 1,
                    "effectVersion": 1,
                    "ratings": payload["ratings"],
                    "moderationState": "valid",
                    "editionId": part["editionId"],
                    "distanceId": part["distanceId"],
                }
            else:
                updated = {
                    **review,
                    "reviewVersion": review["reviewVersion"] + 1,
                    "effectVersion": review["effectVersion"] + 1,
                    "ratings": payload["ratings"],
                    "moderationState": (
                        "pending_review" if review["moderationState"] == "invalidated" else "valid"
                    ),
                }
            if "comment" in payload and payload["comment"] is not None:
                updated["comment"] = payload["comment"]
            else:
                updated.pop("comment", None)
            event = {
                "id": event_id,
                "type": "participation_completed" if creating else "review_replaced",
                "state": "pending",
                "participationId": participation_id,
                "effectVersion": updated["effectVersion"],
                "editionId": part["editionId"],
                "distanceId": part["distanceId"],
                "occurredAt": stamp(now),
                "dispatchEpoch": 1,
                "workPartition": work_key[1],
                "workSort": work_key[2],
                **({"ratings": payload["ratings"]} if creating else {}),
            }
            write(review_key, updated)
            write(event_key, event)
            if creating:
                _write_review_pointer(
                    read, write, pk, part["editionId"], participation_id, part, actor.subject
                )
            write(
                audit_key,
                {
                    "eventId": event_id,
                    "participationId": participation_id,
                    "occurredAt": stamp(now),
                    "before": self.review_projection(review) if review else None,
                    "after": self.review_projection(updated),
                },
            )
            write(
                work_key,
                {
                    "owner": actor.subject,
                    "eventId": event_id,
                    "state": "pending",
                    "nextAttemptAt": stamp(now),
                    "workPartition": work_key[1],
                    "workSort": work_key[2],
                },
            )
            return self.review_projection(updated), {"id": participation_id}

        return self.identity.transact(
            actor, "replaceParticipationReview", key, payload, work, admitted=True
        )

    def delete(self, actor, participation_id, key, expected_version):
        pk = "USER#" + actor.subject
        payload = {"expectedVersion": expected_version}

        def work(read, write, account, now, replay):
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            review_key = ("history", pk, "P#" + participation_id + "#REVIEW")
            medal_key = ("history", pk, "P#" + participation_id + "#MEDAL")
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            part, review, medal = read(part_key), read(review_key), read(medal_key)
            if not owner or owner.get("owner") != actor.subject or not part:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if replay is not None:
                return {
                    "operationId": replay["operationId"],
                    "state": "pending",
                    "publiclyHidden": True,
                }, replay
            if part.get("state") not in {"draft", "completed"}:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if part["version"] != expected_version:
                raise Problem(409, "VERSION_CONFLICT")
            operation_id, event_id = str(uuid4()), str(uuid4())
            job_key = ("operations", pk, "JOB#" + operation_id)
            event_key = ("operations", pk, "EVENT#" + event_id)
            audit_key = ("operations", pk, "AUDIT_SOURCE#" + event_id)
            shard = int(hashlib.sha256(event_id.encode()).hexdigest(), 16) % 16
            work_key = (
                "operations",
                f"WORK#event#pending#{shard:02d}",
                stamp(now) + "#" + event_id,
            )
            for item_key in (job_key, event_key, audit_key, work_key):
                read(item_key)
            claim_key = ("history", pk, "EDITION#" + part["editionId"] + "#CLAIM")
            claim = read(claim_key)
            if not claim or claim.get("participationId") != participation_id:
                raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
            deleted = {
                **part,
                "state": "deleted",
                "version": part["version"] + 1,
                "deletedAt": stamp(now),
                "updatedAt": stamp(now),
                "publishToFeed": False,
            }
            write(part_key, deleted)
            write(claim_key, None)
            if review:
                write(
                    review_key,
                    {
                        **review,
                        "reviewVersion": review["reviewVersion"] + 1,
                        "effectVersion": review["effectVersion"] + 1,
                        "moderationState": "invalidated",
                    },
                )
            if medal:
                image_key = (
                    (
                        "operations",
                        pk,
                        "IMAGE#" + medal["imageReference"],
                    )
                    if medal["imageOrigin"] == "runner"
                    else (
                        "operations",
                        "EDITION#" + part["editionId"],
                        "IMAGE#" + medal["imageReference"],
                    )
                )
                image = read(image_key)
                if image:
                    write(image_key, {**image, "refs": max(0, image.get("refs", 0) - 1)})
            post_ref = part.get("postImageReference")
            if post_ref:
                post_key = ("operations", pk, "IMAGE#" + post_ref)
                post_image = read(post_key)
                if post_image:
                    write(post_key, {**post_image, "refs": max(0, post_image.get("refs", 0) - 1)})
            for more_ref in part.get("morePostImageReferences") or []:
                _bump_image(read, write, pk, more_ref, -1)
            event = {
                "id": event_id,
                "type": "participation_deleted",
                "state": "pending",
                "participationId": participation_id,
                "effectVersion": (review or {}).get("effectVersion", 0) + 1,
                "editionId": part["editionId"],
                "distanceId": part["distanceId"],
                "occurredAt": stamp(now),
                "dispatchEpoch": 1,
                "workPartition": work_key[1],
                "workSort": work_key[2],
            }
            write(event_key, event)
            write(
                audit_key,
                {
                    "eventId": event_id,
                    "participationId": participation_id,
                    "occurredAt": stamp(now),
                    "before": self.review_projection(review) if review else None,
                    "after": None,
                },
            )
            write(
                work_key,
                {
                    "owner": actor.subject,
                    "eventId": event_id,
                    "state": "pending",
                    "nextAttemptAt": stamp(now),
                    "workPartition": work_key[1],
                    "workSort": work_key[2],
                },
            )
            write(
                job_key,
                {
                    "operationId": operation_id,
                    "participationId": participation_id,
                    "state": "pending",
                    "type": "erase_participation",
                    "publiclyHidden": True,
                    "acceptedAt": stamp(now),
                    "dueAt": stamp(now + timedelta(days=7)),
                },
            )
            # Marcador que o executor da exclusao (ErasureProcessor.run_pending) encontra sem Scan.
            erase_shard = int(hashlib.sha256(operation_id.encode()).hexdigest(), 16) % 16
            marker_key = (
                "operations",
                f"WORK#erase_participation#pending#{erase_shard:02d}",
                stamp(now) + "#" + operation_id,
            )
            read(marker_key)
            write(
                marker_key,
                {
                    "owner": actor.subject,
                    "operationId": operation_id,
                    "participationId": participation_id,
                    "workPartition": marker_key[1],
                    "workSort": marker_key[2],
                },
            )
            receipt = {"operationId": operation_id}
            return {
                "operationId": operation_id,
                "state": "pending",
                "publiclyHidden": True,
            }, receipt

        return self.identity.transact(
            actor, "deleteParticipation", key, payload, work, admitted=True
        )

    def get_deletion(self, actor, operation_id):
        def work(read, write, account, now, replay):
            job = read(("operations", "USER#" + actor.subject, "JOB#" + operation_id))
            if not job or job.get("type") != "erase_participation":
                raise Problem(404, "DELETION_OPERATION_NOT_FOUND")
            return {
                "operationId": operation_id,
                "state": job["state"],
                "publiclyHidden": True,
            }, {}

        return self.identity.transact(actor, "getDeletionOperation", None, {}, work, admitted=True)

    @staticmethod
    def _tags(read, actor, ids):
        """Valida quem pode ser marcado: conta ativa, nao eu mesmo, e (perfil publico OU eu ja sigo/sou amigo).
        Perfil privado so recebe marcacao de quem ele aceitou seguir ou e amigo. Sem repetir, ordem mantida."""
        out = []
        for subject in dict.fromkeys(ids or []):
            if subject == actor.subject:
                raise Problem(422, "INVALID_TAG")
            account = read(("identity", "USER#" + subject, "ACCOUNT"))
            profile = read(("identity", "USER#" + subject, "PROFILE"))
            if not account or not profile or account.get("state") != "active":
                raise Problem(422, "INVALID_TAG")
            if profile.get("isPrivate", False):
                follow = read(("identity", "USER#" + subject, "FOLLOWER#" + actor.subject))
                friend = read(("identity", "USER#" + actor.subject, "FRIEND#" + subject))
                if not (
                    (follow and follow.get("state") == "active")
                    or (friend and friend.get("state") == "active")
                ):
                    raise Problem(422, "INVALID_TAG")
            out.append(subject)
        return out

    def patch(self, actor, participation_id, key, payload):
        current = self.get(actor, participation_id)
        edition_id = payload.get("editionId", current["editionId"])
        distance_id = payload.get("distanceId", current["distanceId"])
        catalog_changed = (edition_id, distance_id) != (
            current["editionId"],
            current["distanceId"],
        )
        observed = (
            self.catalog.require_draftable(actor, edition_id, distance_id)
            if catalog_changed
            else None
        )
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            read, write = _own_writes(read, write)
            part_key = ("history", pk, "P#" + participation_id + "#PART")
            item = read(part_key)
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            if not item or not owner or owner.get("owner") != actor.subject:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if replay is not None:
                return self.projection(item), replay
            if item.get("state") not in {"draft", "completed"}:
                raise Problem(404, "PARTICIPATION_NOT_FOUND")
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            if observed:
                self._catalog_guard(read, edition_id, observed["version"])
            old_edition = item["editionId"]
            if edition_id != old_edition:
                new_claim = ("history", pk, "EDITION#" + edition_id + "#CLAIM")
                if read(new_claim):
                    raise Problem(409, "PARTICIPATION_EXISTS")
                old_claim = ("history", pk, "EDITION#" + old_edition + "#CLAIM")
                existing = read(old_claim)
                if not existing or existing.get("participationId") != participation_id:
                    raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
                write(old_claim, None)
                write(
                    new_claim, {"participationId": participation_id, "version": item["version"] + 1}
                )
            else:
                claim_key = ("history", pk, "EDITION#" + old_edition + "#CLAIM")
                existing = read(claim_key)
                if not existing or existing.get("participationId") != participation_id:
                    raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
                write(
                    claim_key,
                    {"participationId": participation_id, "version": item["version"] + 1},
                )
            for field in (
                "editionId",
                "distanceId",
                "timeSeconds",
                "paceSecondsPerKm",
                "placement",
                "bibNumber",
                "showTime",
                "showPlacement",
                "medalFrameId",
                "medalDescription",
                "medalCity",
                "medalState",
                "medalYear",
                "postText",
            ):
                if field not in payload:
                    continue
                if payload[field] is None:
                    item.pop(field, None)
                else:
                    item[field] = payload[field]
            if observed:
                item["catalogVersion"] = observed["version"]
            if payload.get("taggedUserIds") is not None:
                if item.get("state") != "completed" or not item.get("publishToFeed"):
                    raise Problem(409, "NOT_PUBLISHED")
                tags = self._tags(read, actor, payload["taggedUserIds"])
                if tags:
                    item["taggedUserIds"] = tags
                else:
                    item.pop("taggedUserIds", None)
            # Capa e extras do carrossel: `morePostImageReferences` substitui a lista inteira quando vem
            # ([] ou null removem as extras); quando nao vem, as extras ficam (mesmo trocando a capa).
            more_given = "morePostImageReferences" in payload
            new_more = (payload.get("morePostImageReferences") or []) if more_given else None
            if payload.get("postImageReference") is not None or new_more:
                if item.get("state") != "completed" or not item.get("publishToFeed"):
                    raise Problem(409, "NOT_PUBLISHED")
            old_images = (
                item.get("postImageReference"),
                item.get("morePostImageReferences") or [],
            )
            new_images = (
                payload.get("postImageReference") or old_images[0],
                new_more if more_given else old_images[1],
            )
            if new_images[1] and not new_images[0]:
                raise Problem(422, "POST_IMAGE_REQUIRED")
            medal_after = payload.get("medalImageReference") or item.get("medalImageReference")
            if medal_after != item.get("medalImageReference") and medal_after in new_images[1]:
                # Medalha nova igual a uma foto extra que fica na publicacao.
                raise Problem(422, "POST_IMAGE_MUST_DIFFER")
            if new_images != old_images:
                self._replace_post_images(
                    read,
                    write,
                    actor.subject,
                    old_images,
                    new_images,
                    item.get("medalImageReference"),
                )
                item["postImageReference"] = new_images[0]
                if new_images[1]:
                    item["morePostImageReferences"] = list(new_images[1])
                else:
                    item.pop("morePostImageReferences", None)
            if "medalImageReference" in payload:
                before = item.get("medalImageReference")
                self._replace_medal_image(
                    read, write, pk, participation_id, item, payload["medalImageReference"]
                )
                if (
                    item.get("medalImageReference") != before
                    and "medalDisplayImageReference" not in payload
                ):
                    # O recorte da prateleira era da foto ANTIGA: sem limpar, a prateleira seguia
                    # mostrando a foto velha depois de trocar a foto da medalha.
                    self._clear_medal_display_image(read, write, pk, item)
            if "medalDisplayImageReference" in payload:
                reference = payload["medalDisplayImageReference"]
                if reference is None:
                    self._clear_medal_display_image(read, write, pk, item)
                else:
                    self._set_medal_display_image(read, write, pk, item, reference)
            item["version"] += 1
            item["updatedAt"] = stamp(now)
            write(part_key, item)
            if item["state"] == "completed" and catalog_changed:
                review_key = ("history", pk, "P#" + participation_id + "#REVIEW")
                review = read(review_key)
                if not review:
                    raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
                updated_review = {
                    **review,
                    "editionId": edition_id,
                    "distanceId": distance_id,
                    "effectVersion": review["effectVersion"] + 1,
                }
                event_id = str(uuid4())
                event_key = ("operations", pk, "EVENT#" + event_id)
                audit_key = ("operations", pk, "AUDIT_SOURCE#" + event_id)
                shard = int(hashlib.sha256(event_id.encode()).hexdigest(), 16) % 16
                work_key = (
                    "operations",
                    f"WORK#event#pending#{shard:02d}",
                    stamp(now) + "#" + event_id,
                )
                for event_item_key in (event_key, audit_key, work_key):
                    read(event_item_key)
                write(review_key, updated_review)
                _write_review_pointer(
                    read, write, pk, edition_id, participation_id, item, actor.subject
                )
                write(
                    event_key,
                    {
                        "id": event_id,
                        "type": "participation_transferred",
                        "state": "pending",
                        "participationId": participation_id,
                        "effectVersion": updated_review["effectVersion"],
                        "editionId": edition_id,
                        "distanceId": distance_id,
                        "occurredAt": stamp(now),
                        "dispatchEpoch": 1,
                        "workPartition": work_key[1],
                        "workSort": work_key[2],
                    },
                )
                write(
                    audit_key,
                    {
                        "eventId": event_id,
                        "participationId": participation_id,
                        "occurredAt": stamp(now),
                        "before": self.review_projection(review),
                        "after": self.review_projection(updated_review),
                    },
                )
                write(
                    work_key,
                    {
                        "owner": actor.subject,
                        "eventId": event_id,
                        "state": "pending",
                        "nextAttemptAt": stamp(now),
                        "workPartition": work_key[1],
                        "workSort": work_key[2],
                    },
                )
            return self.projection(item), {"id": participation_id}

        return self.identity.transact(
            actor, "patchParticipation", key, payload, work, admitted=True
        )

    @staticmethod
    def _replace_medal_image(read, write, pk, participation_id, item, reference):
        """Swap the runner's medal photo of a completed race; the new image must be mine and valid."""
        if item["state"] != "completed":
            raise Problem(409, "PARTICIPATION_NOT_COMPLETED")
        medal_key = ("history", pk, "P#" + participation_id + "#MEDAL")
        medal = read(medal_key)
        if not medal:
            raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
        if reference == medal["imageReference"]:
            return
        new_key = ("operations", pk, "IMAGE#" + reference)
        new = read(new_key)
        if not new or new.get("state") != "valid":
            raise Problem(422, "IMAGE_NOT_VALID")
        old_key = (
            ("operations", pk, "IMAGE#" + medal["imageReference"])
            if medal["imageOrigin"] == "runner"
            else (
                "operations",
                "EDITION#" + item["editionId"],
                "IMAGE#" + medal["imageReference"],
            )
        )
        old = read(old_key)
        if old:
            write(old_key, {**old, "refs": max(0, old.get("refs", 0) - 1)})
        write(new_key, {**new, "refs": new.get("refs", 0) + 1})
        write(medal_key, {**medal, "imageReference": reference, "imageOrigin": "runner"})
        item["medalImageReference"] = reference

    @staticmethod
    def _set_medal_display_image(read, write, pk, item, reference):
        """Recorte opcional so para a prateleira; nunca troca a foto oficial da medalha."""
        if item["state"] != "completed":
            raise Problem(409, "PARTICIPATION_NOT_COMPLETED")
        previous = item.get("medalDisplayImageReference")
        if reference == previous:
            return
        new_key = ("operations", pk, "IMAGE#" + reference)
        new = read(new_key)
        if not new or new.get("state") != "valid":
            raise Problem(422, "IMAGE_NOT_VALID")
        write(new_key, {**new, "refs": new.get("refs", 0) + 1})
        if previous:
            old_key = ("operations", pk, "IMAGE#" + previous)
            old = read(old_key)
            if old:
                write(old_key, {**old, "refs": max(0, old.get("refs", 0) - 1)})
        item["medalDisplayImageReference"] = reference

    @staticmethod
    def _clear_medal_display_image(read, write, pk, item):
        previous = item.get("medalDisplayImageReference")
        if not previous:
            return
        old_key = ("operations", pk, "IMAGE#" + previous)
        old = read(old_key)
        if old:
            write(old_key, {**old, "refs": max(0, old.get("refs", 0) - 1)})
        item.pop("medalDisplayImageReference", None)

    def _binding(self, actor, state, limit):
        return hashlib.sha256(
            json.dumps(
                {
                    "actor": actor.subject,
                    "env": self.identity.environment,
                    "state": state,
                    "limit": limit,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()

    def list(self, actor, state, limit, cursor):
        self.identity.authorize(actor, admitted=True)
        after = None
        if cursor:
            try:
                data = json.loads(self.cipher.decrypt(cursor.encode(), ttl=899))
                if data["binding"] != self._binding(actor, state, limit):
                    raise ValueError()
                after = data["after"]
            except (InvalidToken, ValueError, KeyError, TypeError) as error:
                raise Problem(422, "INVALID_CURSOR") from error
        rows, next_key = self.store.query(
            "history", "USER#" + actor.subject, prefix="P#", after=after, limit=limit
        )
        items = [
            self.projection(item)
            for sk, item in rows
            # Participacao excluida nao volta na lista (some na hora; o executor apaga os dados depois).
            if sk.endswith("#PART")
            and item.get("state") != "deleted"
            and (state is None or item.get("state") == state)
        ]
        self.identity.authorize(actor, admitted=True)
        result = {"items": items}
        if next_key:
            result["nextCursor"] = self.cipher.encrypt(
                json.dumps(
                    {"binding": self._binding(actor, state, limit), "after": next_key}
                ).encode()
            ).decode()
        return result
