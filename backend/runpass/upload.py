"""Private version-pinned uploads and sanitization; originals are never served."""

import hashlib
import io
import os
from copy import deepcopy
from datetime import datetime, timedelta
from uuid import uuid4

from PIL import Image, ImageOps, UnidentifiedImageError

from .service import Problem, stamp
from .store import Conflict

MAX_PIXELS = 25_000_000
TARGET_BYTES = 1_000_000
# MPO is the multi-frame JPEG container written by many phone cameras.
CONTENT_TYPES = {"JPEG": "image/jpeg", "MPO": "image/jpeg", "PNG": "image/png"}


class MemoryBlobStore:
    """Synthetic private/versioned object adapter for local execution."""

    def __init__(self):
        self.secret = os.urandom(32).hex()
        self.versions, self.derived = {}, {}

    def issue(self, upload_id, content_type, owner):
        return {
            "uploadUrl": f"memory://private/{upload_id}?capability={self.secret}",
            "uploadMethod": "PUT",
            "uploadHeaders": {"Content-Type": content_type},
        }

    def put(self, upload_id, owner, expires_at, content_type, data, now):
        if now >= expires_at:
            raise Problem(409, "SESSION_EXPIRED")
        version = str(uuid4())
        self.versions.setdefault(upload_id, []).append(
            {"version": version, "owner": owner, "contentType": content_type, "data": bytes(data)}
        )
        return version

    def head(self, upload_id, owner):
        rows = self.versions.get(upload_id, [])
        if not rows:
            raise Problem(409, "OBJECT_NOT_UPLOADED")
        row = rows[-1]
        return {
            "version": row["version"],
            "size": len(row["data"]),
            "contentType": row["contentType"],
        }

    def read(self, upload_id, version, owner):
        for row in self.versions.get(upload_id, []):
            if row["version"] == version:
                return row["data"]
        raise Problem(503, "SOURCE_VERSION_UNAVAILABLE")

    def write_derived(self, reference, data, content_type, owner):
        value = {"data": bytes(data), "contentType": content_type, "owner": owner}
        if reference in self.derived and self.derived[reference] != value:
            raise Problem(503, "DERIVED_COLLISION")
        self.derived[reference] = value

    def read_derived(self, owner, reference):
        """Bytes e tipo da copia tratada de uma pessoa (uso da equipe ao aprovar um banner enviado por ela)."""
        item = self.derived.get(reference)
        if not item or item["owner"] != owner:
            raise Problem(404, "IMAGE_NOT_AVAILABLE")
        return item["data"], item["contentType"]

    def view_url(self, owner, reference):
        item = self.derived.get(reference)
        if not item or item["owner"] != owner:
            raise Problem(404, "IMAGE_NOT_AVAILABLE")
        return {
            "url": f"memory://private/derived/{reference}?capability={self.secret}",
            "contentType": item["contentType"],
        }

    def delete_owner(self, owner):
        """Active local deletion of originals, versions and derived personal bytes."""
        removed = 0
        for upload_id, rows in list(self.versions.items()):
            kept = [row for row in rows if row["owner"] != owner]
            removed += len(rows) - len(kept)
            if kept:
                self.versions[upload_id] = kept
            else:
                self.versions.pop(upload_id, None)
        for reference, item in list(self.derived.items()):
            if item.get("owner") == owner:
                self.derived.pop(reference, None)
                removed += 1
        return removed


VIEW_SECONDS = 5 * 60
# Dono fixo das imagens do catalogo no bucket (`derived/catalog/...`); nunca colide com um sub de pessoa.
CATALOG_OWNER = "catalog"


class UploadService:
    def __init__(self, identity, blobs, may_view=None, may_view_profile=None):
        self.identity, self.store, self.blobs = identity, identity.store, blobs
        # may_view(read, actor, owner_subject, participation) -> bool. Default: only the owner.
        # The social module injects follow/visibility rules here without touching this service.
        self.may_view = may_view or (lambda read, actor, owner, part: owner == actor.subject)
        self.may_view_profile = may_view_profile or (
            lambda read, actor, owner: owner == actor.subject
        )

    def profile_photo(self, actor, subject, field="photoReference"):
        """Short-lived signed link to a runner's profile photo or banner, when the viewer may."""

        def work(read, write, account, now, replay):
            profile = read(("identity", "USER#" + subject, "PROFILE"))
            if not profile or not profile.get(field):
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            if not self.may_view_profile(read, actor, subject):
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            return {"reference": profile[field], "now": now}, {}

        found = self.identity.transact(actor, "getProfilePhoto", None, {}, work, admitted=True)
        link = self.blobs.view_url(subject, found["reference"])
        return {
            "url": link["url"],
            "contentType": link["contentType"],
            "expiresAt": stamp(found["now"] + timedelta(seconds=VIEW_SECONDS)),
        }

    def medal_image(self, actor, participation_id):
        """Short-lived signed link to the sanitized medal photo; never the original."""

        def work(read, write, account, now, replay):
            owner = read(("history", "PARTICIPATION#" + participation_id, "OWNER"))
            if not owner:
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            subject = owner["owner"]
            part = read(("history", "USER#" + subject, "P#" + participation_id + "#PART"))
            if not part or not self.may_view(read, actor, subject, part):
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            medal = read(("history", "USER#" + subject, "P#" + participation_id + "#MEDAL"))
            if not part or part.get("state") != "completed" or not medal:
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            if medal.get("imageOrigin") != "runner":
                raise Problem(404, "IMAGE_NOT_AVAILABLE")
            return {"owner": subject, "reference": medal["imageReference"], "now": now}, {}

        found = self.identity.transact(actor, "getMedalImage", None, {}, work, admitted=True)
        link = self.blobs.view_url(found["owner"], found["reference"])
        return {
            "url": link["url"],
            "contentType": link["contentType"],
            "expiresAt": stamp(found["now"] + timedelta(seconds=VIEW_SECONDS)),
        }

    def edition_banner(self, actor, edition):
        """Link temporario do banner aprovado da edicao (copia sanitizada guardada pelo operador)."""
        self.identity.authorize(actor, admitted=True)
        reference = edition.get("imageReference")
        if not reference:
            raise Problem(404, "IMAGE_NOT_AVAILABLE")
        link = self.blobs.view_url(CATALOG_OWNER, reference)
        result = {
            "url": link["url"],
            "contentType": link["contentType"],
            "expiresAt": stamp(self.identity.clock() + timedelta(seconds=VIEW_SECONDS)),
        }
        if edition.get("imageCredit"):
            result["credit"] = edition["imageCredit"]
        return result

    @staticmethod
    def status(item):
        result = {"uploadId": item["uploadId"], "state": item["state"]}
        if item["state"] == "valid":
            result["imageReference"] = item["imageReference"]
        if item["state"] == "failed":
            result["reasonCode"] = item["reasonCode"]
        return result

    def start(self, actor, key, payload):
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            if replay is not None:
                item = read(("operations", pk, "UPLOAD#" + replay["id"]))
                if not item:
                    raise Problem(404, "UPLOAD_NOT_FOUND")
                return item, replay
            upload_id, expires_at = str(uuid4()), now + timedelta(minutes=15)
            item = {
                "uploadId": upload_id,
                "owner": actor.subject,
                "contentType": payload["contentType"],
                "sizeBytes": payload["sizeBytes"],
                "state": "pending",
                "issuedAt": stamp(now),
                "expiresAt": stamp(expires_at),
            }
            write(("operations", pk, "UPLOAD#" + upload_id), item)
            return item, {"id": upload_id}

        item = self.identity.transact(actor, "startUpload", key, payload, work, admitted=True)
        return {
            "uploadId": item["uploadId"],
            "expiresAt": item["expiresAt"],
            **self.blobs.issue(item["uploadId"], item["contentType"], actor.subject),
        }

    def finalize(self, actor, upload_id, key):
        # Authorize the owner before consulting blob metadata. An opaque upload id
        # is not authorization and must not allow probing another user's object.
        self.get(actor, upload_id)
        head, pk = self.blobs.head(upload_id, actor.subject), "USER#" + actor.subject

        def work(read, write, account, now, replay):
            ukey = ("operations", pk, "UPLOAD#" + upload_id)
            item = read(ukey)
            if not item or item.get("owner") != actor.subject:
                raise Problem(404, "UPLOAD_NOT_FOUND")
            if replay is not None or item.get("sourceVersion"):
                return item, {"id": upload_id}
            expires_at = datetime.fromisoformat(item["expiresAt"].replace("Z", "+00:00"))
            if now >= expires_at:
                raise Problem(409, "SESSION_EXPIRED")
            if head["size"] != item["sizeBytes"] or head["contentType"] != item["contentType"]:
                raise Problem(409, "OBJECT_MISMATCH")
            item.update(
                sourceVersion=head["version"],
                finalizedAt=stamp(now),
                processingExpiresAt=stamp(now + timedelta(minutes=15)),
            )
            write(ukey, item)
            write(
                ("operations", pk, "JOB#IMAGE#" + upload_id),
                {"type": "image_validation", "state": "pending", "uploadId": upload_id},
            )
            return item, {"id": upload_id}

        item = self.identity.transact(actor, "finalizeUpload", key, {}, work, admitted=True)
        if item["state"] == "pending":
            item = self.process(actor.subject, upload_id)
        return self.status(item)

    def get(self, actor, upload_id):
        def work(read, write, account, now, replay):
            item = read(("operations", "USER#" + actor.subject, "UPLOAD#" + upload_id))
            if not item or item.get("owner") != actor.subject:
                raise Problem(404, "UPLOAD_NOT_FOUND")
            return self.status(item), {}

        return self.identity.transact(actor, "getUploadStatus", None, {}, work, admitted=True)

    @staticmethod
    def sanitize(source, declared_type):
        try:
            image = Image.open(io.BytesIO(source))
            actual_type = CONTENT_TYPES.get(image.format)
            if actual_type != declared_type:
                raise Problem(422, "FORMAT_MISMATCH")
            # A tiny file can declare huge dimensions, so check before decoding allocates memory.
            if image.width * image.height > MAX_PIXELS:
                raise Problem(422, "PIXEL_LIMIT_EXCEEDED")
            image.load()
        except Image.DecompressionBombError as error:
            raise Problem(422, "PIXEL_LIMIT_EXCEEDED") from error
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError) as error:
            raise Problem(422, "INVALID_IMAGE") from error
        image = ImageOps.exif_transpose(image)
        # Pillow re-saves some info entries, such as the JPEG comment, unless they are removed.
        image.info = {k: v for k, v in image.info.items() if k == "transparency"}
        image.thumbnail((5000, 5000))
        if actual_type == "image/jpeg":
            image = image.convert("RGB")
        output = io.BytesIO()
        image.save(
            output,
            format="JPEG" if actual_type == "image/jpeg" else "PNG",
            optimize=True,
            quality=85,
        )
        while output.tell() > TARGET_BYTES and min(image.size) > 640:
            image.thumbnail((int(image.width * 0.8), int(image.height * 0.8)))
            output = io.BytesIO()
            image.save(
                output,
                format="JPEG" if actual_type == "image/jpeg" else "PNG",
                optimize=True,
                quality=75,
            )
        return output.getvalue(), actual_type

    def process(self, owner, upload_id):
        pk, ukey = "USER#" + owner, ("operations", "USER#" + owner, "UPLOAD#" + upload_id)
        for _ in range(10):
            item = self.store.get(ukey)
            if not item or not item.get("sourceVersion"):
                raise Problem(503, "UPLOAD_INTEGRITY_FAILURE")
            if item["state"] != "pending":
                return item
            now = self.identity.clock()
            reason, derived, actual_type = None, None, None
            if now >= datetime.fromisoformat(item["processingExpiresAt"].replace("Z", "+00:00")):
                reason = "PROCESSING_TIMEOUT"
            else:
                try:
                    derived, actual_type = self.sanitize(
                        self.blobs.read(upload_id, item["sourceVersion"], owner),
                        item["contentType"],
                    )
                except Problem as error:
                    if error.status != 422:
                        raise
                    reason = error.code
            updated, job_key = deepcopy(item), ("operations", pk, "JOB#IMAGE#" + upload_id)
            job = self.store.get(job_key)
            expected, writes = {ukey: item, job_key: job}, {}
            if reason:
                updated.update(state="failed", reasonCode=reason, resolvedAt=stamp(now))
                writes.update(
                    {
                        ukey: updated,
                        job_key: {**(job or {}), "state": "failed", "reasonCode": reason},
                    }
                )
            else:
                reference = "img_" + hashlib.sha256((owner + ":" + upload_id).encode()).hexdigest()
                self.blobs.write_derived(reference, derived, actual_type, owner)
                image_key = ("operations", pk, "IMAGE#" + reference)
                expected[image_key] = self.store.get(image_key)
                if expected[image_key] is not None:
                    raise Problem(503, "IMAGE_REFERENCE_COLLISION")
                updated.update(state="valid", imageReference=reference, resolvedAt=stamp(now))
                writes.update(
                    {
                        ukey: updated,
                        image_key: {
                            "owner": owner,
                            "origin": "runner",
                            "state": "valid",
                            "refs": 0,
                            "validatedAt": stamp(now),
                            "contentType": actual_type,
                        },
                        job_key: {**(job or {}), "state": "completed"},
                    }
                )
            try:
                self.store.commit(expected, writes)
                return updated
            except Conflict:
                continue
        raise Problem(503, "CONCURRENT_RETRY_REQUIRED")
