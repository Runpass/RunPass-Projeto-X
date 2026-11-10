"""Owned participation drafts and atomic completion source records."""

import hashlib
import json
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
        return {
            key: item[key]
            for key in (
                "id",
                "editionId",
                "distanceId",
                "state",
                "version",
                "timeSeconds",
                "placement",
                "bibNumber",
                "showTime",
                "showPlacement",
                "completedAt",
                "medalImageReference",
                "publishToFeed",
                "medalShape",
                "medalCordColor",
                "medalDescription",
                "medalCity",
                "medalState",
                "medalYear",
            )
            if key in item
        }

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
            for field in ("timeSeconds", "placement", "bibNumber"):
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
            review_key = ("history", pk, "P#" + participation_id + "#REVIEW")
            medal_key = ("history", pk, "P#" + participation_id + "#MEDAL")
            if read(review_key) or read(medal_key):
                raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
            claim_key = ("history", pk, "EDITION#" + item["editionId"] + "#CLAIM")
            claim = read(claim_key)
            if not claim or claim.get("participationId") != participation_id:
                raise Problem(503, "PARTICIPATION_INTEGRITY_FAILURE")
            event_id = str(uuid4())
            event_key = ("operations", pk, "EVENT#" + event_id)
            shard = int(hashlib.sha256(event_id.encode()).hexdigest(), 16) % 16
            work_key = (
                "operations",
                f"WORK#event#pending#{shard:02d}",
                stamp(now) + "#" + event_id,
            )
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
            review = {
                "participationId": participation_id,
                "reviewVersion": 1,
                "effectVersion": 1,
                "ratings": payload["ratings"],
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
            event = {
                "id": event_id,
                "type": "participation_completed",
                "state": "pending",
                "participationId": participation_id,
                "effectVersion": 1,
                "editionId": item["editionId"],
                "distanceId": item["distanceId"],
                "ratings": payload["ratings"],
                "occurredAt": stamp(now),
                "dispatchEpoch": 1,
                "workPartition": work_key[1],
                "workSort": work_key[2],
            }
            write(part_key, item)
            write(review_key, review)
            write(medal_key, medal)
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
            write(claim_key, {"participationId": participation_id, "version": item["version"]})
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
            return None, {}

        self.identity.transact(actor, "deleteRacePlan", None, {}, work, admitted=True)

    def list_plans(self, actor, status=None):
        """Planos da propria pessoa com um resumo da edicao, por data (agenda)."""
        self.identity.authorize(actor, admitted=True)
        rows, _ = self.store.query(
            "history", "USER#" + actor.subject, prefix="PLAN#", limit=MAX_PLANS
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
                or not review
            ):
                raise Problem(404, "REVIEW_NOT_FOUND")
            if replay is not None:
                return self.review_projection(review), replay
            if review["reviewVersion"] != payload["expectedVersion"]:
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
                "type": "review_replaced",
                "state": "pending",
                "participationId": participation_id,
                "effectVersion": updated["effectVersion"],
                "editionId": part["editionId"],
                "distanceId": part["distanceId"],
                "occurredAt": stamp(now),
                "dispatchEpoch": 1,
                "workPartition": work_key[1],
                "workSort": work_key[2],
            }
            write(review_key, updated)
            write(event_key, event)
            write(
                audit_key,
                {
                    "eventId": event_id,
                    "participationId": participation_id,
                    "occurredAt": stamp(now),
                    "before": self.review_projection(review),
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
                "placement",
                "bibNumber",
                "showTime",
                "showPlacement",
                "medalShape",
                "medalCordColor",
                "medalDescription",
                "medalCity",
                "medalState",
                "medalYear",
            ):
                if field not in payload:
                    continue
                if payload[field] is None:
                    item.pop(field, None)
                else:
                    item[field] = payload[field]
            if observed:
                item["catalogVersion"] = observed["version"]
            if "medalImageReference" in payload:
                self._replace_medal_image(
                    read, write, pk, participation_id, item, payload["medalImageReference"]
                )
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
            if sk.endswith("#PART") and (state is None or item.get("state") == state)
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
