import io
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from PIL import Image
from PIL.PngImagePlugin import PngInfo
from runpass.erasure import ErasureProcessor
from runpass.identity import Principal
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore
from runpass.upload import MemoryBlobStore, UploadService

NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)


def jpeg(color="red", size=(40, 20), orientation=None):
    output = io.BytesIO()
    exif = Image.Exif()
    if orientation:
        exif[274] = orientation
    Image.new("RGB", size, color).save(output, "JPEG", exif=exif)
    return output.getvalue()


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"upload-test-hmac-key-at-least-32-bytes", lambda: self.now
        )
        self.blobs = MemoryBlobStore()
        self.service = UploadService(self.identity, self.blobs)
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

    def start_and_put(self, data, content_type="image/jpeg", key="start"):
        session = self.service.start(
            self.actor, key, {"contentType": content_type, "sizeBytes": len(data)}
        )
        expires = datetime.fromisoformat(session["expiresAt"].replace("Z", "+00:00"))
        version = self.blobs.put(
            session["uploadId"], self.actor.subject, expires, content_type, data, self.now
        )
        return session, version

    def seed_medal(self, origin="runner", state="completed"):
        pid = "p1"
        rows = {
            ("history", "PARTICIPATION#" + pid, "OWNER"): {"owner": "owner"},
            ("history", "USER#owner", "P#p1#PART"): {"state": state},
            ("history", "USER#owner", "P#p1#MEDAL"): {
                "imageReference": "ref1",
                "imageOrigin": origin,
            },
        }
        self.store.commit({k: None for k in rows}, rows)
        self.blobs.write_derived("ref1", b"bytes", "image/jpeg", "owner")
        return pid

    def test_owner_gets_a_short_lived_link_and_others_get_404(self):
        pid = self.seed_medal()
        link = self.service.medal_image(self.actor, pid)
        self.assertEqual(link["contentType"], "image/jpeg")
        self.assertTrue(link["url"].startswith("memory://private/derived/ref1"))
        self.assertEqual(link["expiresAt"], "2026-10-28T15:05:00Z")
        other = self.admit("other")
        with self.assertRaises(Problem) as denied:
            self.service.medal_image(other, pid)
        self.assertEqual(
            (denied.exception.status, denied.exception.code), (404, "IMAGE_NOT_AVAILABLE")
        )
        with self.assertRaises(Problem) as missing:
            self.service.medal_image(other, "does-not-exist")
        self.assertEqual(missing.exception.code, "IMAGE_NOT_AVAILABLE")

    def test_visibility_rule_can_be_injected_and_drafts_or_official_art_have_no_photo(self):
        pid = self.seed_medal()
        other = self.admit("other")
        shared = UploadService(
            self.identity, self.blobs, may_view=lambda read, actor, owner, part: True
        )
        self.assertIn("url", shared.medal_image(other, pid))
        with self.assertRaises(Problem):
            self.service.medal_image(self.actor, "p-draft")
        key = ("history", "USER#owner", "P#p1#MEDAL")
        self.store.commit(
            {key: self.store.get(key)}, {key: {"imageReference": "ref1", "imageOrigin": "official"}}
        )
        with self.assertRaises(Problem):
            self.service.medal_image(self.actor, pid)

    def test_valid_image_is_oriented_and_stripped_before_reference(self):
        source = jpeg(size=(40, 20), orientation=6)
        session, _ = self.start_and_put(source)
        result = self.service.finalize(self.actor, session["uploadId"], "finish")
        self.assertEqual(result["state"], "valid")
        reference = result["imageReference"]
        derived = Image.open(io.BytesIO(self.blobs.derived[reference]["data"]))
        self.assertEqual(derived.size, (20, 40))
        self.assertEqual(len(derived.getexif()), 0)
        self.assertLessEqual(len(self.blobs.derived[reference]["data"]), 1_000_000)
        image_item = self.store.get(("operations", "USER#owner", "IMAGE#" + reference))
        self.assertEqual((image_item["state"], image_item["refs"]), ("valid", 0))

    def test_account_erasure_removes_original_and_derived_personal_bytes(self):
        session, _ = self.start_and_put(jpeg())
        result = self.service.finalize(self.actor, session["uploadId"], "finish")
        self.assertIn(result["imageReference"], self.blobs.derived)
        self.assertIn(session["uploadId"], self.blobs.versions)
        receipt = self.identity.delete_account(self.actor, "erase")
        processor = ErasureProcessor(self.identity, self.blobs)
        for _ in range(20):
            outcome = processor.step("owner", receipt["operationId"], limit=3)
            if outcome["state"] == "completed":
                break
        self.assertEqual(outcome, {"state": "completed"})
        self.assertEqual(self.blobs.versions, {})
        self.assertEqual(self.blobs.derived, {})

    def test_finalize_pins_version_even_if_url_is_overwritten(self):
        original = jpeg("red")
        session, first_version = self.start_and_put(original)
        process = self.service.process
        self.service.process = lambda owner, upload_id: self.store.get(
            ("operations", "USER#" + owner, "UPLOAD#" + upload_id)
        )
        pending = self.service.finalize(self.actor, session["uploadId"], "finish")
        self.assertEqual(pending["state"], "pending")
        expires = datetime.fromisoformat(session["expiresAt"].replace("Z", "+00:00"))
        replacement = jpeg("blue")
        self.assertEqual(len(replacement), len(original))
        self.blobs.put(session["uploadId"], "owner", expires, "image/jpeg", replacement, self.now)
        self.service.process = process
        result = self.service.process("owner", session["uploadId"])
        self.assertEqual(result["sourceVersion"], first_version)
        derived = Image.open(io.BytesIO(self.blobs.derived[result["imageReference"]]["data"]))
        self.assertGreater(derived.getpixel((0, 0))[0], derived.getpixel((0, 0))[2])

    def test_invalid_bytes_mime_and_declared_size_fail_closed(self):
        invalid = b"not an image"
        session, _ = self.start_and_put(invalid)
        result = self.service.finalize(self.actor, session["uploadId"], "bad")
        self.assertEqual(
            result,
            {"uploadId": session["uploadId"], "state": "failed", "reasonCode": "INVALID_IMAGE"},
        )

        png = io.BytesIO()
        Image.new("RGB", (10, 10)).save(png, "PNG")
        session, _ = self.start_and_put(png.getvalue(), "image/jpeg", "mime")
        result = self.service.finalize(self.actor, session["uploadId"], "mime-finish")
        self.assertEqual(result["reasonCode"], "FORMAT_MISMATCH")

        session = self.service.start(
            self.actor, "wrong-size", {"contentType": "image/jpeg", "sizeBytes": len(jpeg()) + 1}
        )
        expires = datetime.fromisoformat(session["expiresAt"].replace("Z", "+00:00"))
        self.blobs.put(session["uploadId"], "owner", expires, "image/jpeg", jpeg(), self.now)
        with self.assertRaises(Problem) as error:
            self.service.finalize(self.actor, session["uploadId"], "wrong-finish")
        self.assertEqual(error.exception.code, "OBJECT_MISMATCH")

    def test_expiration_timeout_and_owner_authorization(self):
        source = jpeg()
        session, _ = self.start_and_put(source)
        other = self.admit("other")
        original_head = self.blobs.head
        head_calls = []
        self.blobs.head = lambda upload_id, owner: head_calls.append(upload_id) or original_head(
            upload_id, owner
        )
        with self.assertRaises(Problem) as error:
            self.service.get(other, session["uploadId"])
        self.assertEqual(error.exception.code, "UPLOAD_NOT_FOUND")
        with self.assertRaises(Problem) as error:
            self.service.finalize(other, session["uploadId"], "foreign-finalize")
        self.assertEqual(error.exception.code, "UPLOAD_NOT_FOUND")
        self.assertEqual(head_calls, [])

        self.now += timedelta(minutes=16)
        with self.assertRaises(Problem) as error:
            self.service.finalize(self.actor, session["uploadId"], "expired")
        self.assertEqual(error.exception.code, "SESSION_EXPIRED")

        self.now = NOW
        session, _ = self.start_and_put(source, key="timeout")
        process = self.service.process
        self.service.process = lambda owner, upload_id: self.store.get(
            ("operations", "USER#" + owner, "UPLOAD#" + upload_id)
        )
        self.service.finalize(self.actor, session["uploadId"], "pin")
        self.service.process = process
        self.now += timedelta(minutes=16)
        result = self.service.process("owner", session["uploadId"])
        self.assertEqual((result["state"], result["reasonCode"]), ("failed", "PROCESSING_TIMEOUT"))

    def test_pixel_limit_fails_without_creating_a_reference(self):
        output = io.BytesIO()
        Image.new("1", (5001, 5000)).save(output, "PNG")
        session, _ = self.start_and_put(output.getvalue(), "image/png", "pixels")
        result = self.service.finalize(self.actor, session["uploadId"], "pixels-finish")
        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["reasonCode"], "PIXEL_LIMIT_EXCEEDED")
        self.assertEqual(self.blobs.derived, {})

    def test_decompression_bomb_fails_closed_instead_of_crashing(self):
        output = io.BytesIO()
        Image.new("1", (14000, 14000)).save(output, "PNG")
        session, _ = self.start_and_put(output.getvalue(), "image/png", "bomb")
        result = self.service.finalize(self.actor, session["uploadId"], "bomb-finish")
        self.assertEqual(
            (result["state"], result["reasonCode"]), ("failed", "PIXEL_LIMIT_EXCEEDED")
        )

    def test_pixel_limit_is_checked_before_decoding(self):
        output = io.BytesIO()
        Image.new("1", (5001, 5000)).save(output, "PNG")
        with patch.object(Image.Image, "load", side_effect=AssertionError("decoded")):
            with self.assertRaises(Problem) as error:
                UploadService.sanitize(output.getvalue(), "image/png")
        self.assertEqual(error.exception.code, "PIXEL_LIMIT_EXCEEDED")

    def test_multi_picture_jpeg_is_accepted_as_jpeg(self):
        output = io.BytesIO()
        Image.new("RGB", (40, 20), "red").save(
            output, "MPO", save_all=True, append_images=[Image.new("RGB", (40, 20), "blue")]
        )
        data, content_type = UploadService.sanitize(output.getvalue(), "image/jpeg")
        derived = Image.open(io.BytesIO(data))
        self.assertEqual((content_type, derived.format), ("image/jpeg", "JPEG"))

    def test_free_text_metadata_is_not_preserved(self):
        output = io.BytesIO()
        Image.new("RGB", (40, 20), "red").save(output, "JPEG", comment=b"private-comment")
        data, _ = UploadService.sanitize(output.getvalue(), "image/jpeg")
        self.assertNotIn(b"private-comment", data)

        info = PngInfo()
        info.add_text("Location", "private-text")
        output = io.BytesIO()
        Image.new("RGB", (40, 20), "red").save(output, "PNG", pnginfo=info)
        data, _ = UploadService.sanitize(output.getvalue(), "image/png")
        self.assertNotIn(b"private-text", data)

    def test_transparent_palette_png_keeps_transparency(self):
        output = io.BytesIO()
        Image.new("P", (40, 20), 0).save(output, "PNG", transparency=0)
        data, _ = UploadService.sanitize(output.getvalue(), "image/png")
        self.assertIn("transparency", Image.open(io.BytesIO(data)).info)

    def test_start_is_idempotent_and_rejects_unadmitted(self):
        body = {"contentType": "image/jpeg", "sizeBytes": 10}
        first = self.service.start(self.actor, "same", body)
        self.assertEqual(self.service.start(self.actor, "same", body), first)
        with self.assertRaises(Problem):
            self.service.start(Principal("new", True), "new", body)
