import unittest
from datetime import datetime, timezone

from runpass.erasure import ErasureProcessor
from runpass.identity import Principal
from runpass.service import IdentityService, Problem
from runpass.social import SocialService
from runpass.store import MemoryStore
from runpass.upload import MemoryBlobStore, UploadService

NOW = datetime(2026, 11, 6, 15, tzinfo=timezone.utc)


class SocialTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"social-test-hmac-key-at-least-32-bytes", lambda: NOW
        )
        self.social = SocialService(self.identity)
        self.ana = self.person("ana", "Ana Paula Souza", "ana_runs")
        self.bia = self.person("bia", "Beatriz Lima", "bia_lima")
        self.caio = self.person("caio", "Caio João", "caio")

    def person(self, sub, name, username):
        actor = Principal(sub, True)
        self.identity.create_profile(actor, "p-" + sub, {"displayName": name, "username": username})
        self.identity.admit(actor, "a-" + sub, {"birthDate": "1990-01-01", "declaresAdult": True})
        return actor

    def complete(self, actor, pid, at, publish=True, comment=None):
        pk = "USER#" + actor.subject
        rows = {
            ("history", "PARTICIPATION#" + pid, "OWNER"): {"owner": actor.subject},
            ("history", pk, f"P#{pid}#PART"): {
                "id": pid,
                "owner": actor.subject,
                "editionId": "E1",
                "distanceId": "10k",
                "state": "completed",
                "version": 2,
                "completedAt": at,
                "timeSeconds": 3000,
                "showTime": False,
                "publishToFeed": publish,
            },
            ("history", pk, f"P#{pid}#REVIEW"): {
                "moderationState": "valid",
                **({"comment": comment} if comment else {}),
            },
        }
        self.store.commit({k: None for k in rows}, rows)

    def private(self, actor):
        profile = self.identity.profile(actor)
        self.identity.patch_profile(
            actor,
            "priv-" + actor.subject,
            {"expectedVersion": profile["version"], "isPrivate": True},
        )

    # ---- search ----
    def test_search_by_username_and_by_name_ignoring_accents_and_excluding_self(self):
        self.assertEqual(
            [p["username"] for p in self.social.search(self.bia, "ana")["items"]], ["ana_runs"]
        )
        self.assertEqual(
            [p["username"] for p in self.social.search(self.bia, "paula sou")["items"]],
            ["ana_runs"],
        )
        self.assertEqual(
            [p["username"] for p in self.social.search(self.ana, "joao")["items"]], ["caio"]
        )
        self.assertEqual(self.social.search(self.ana, "ana")["items"], [])
        with self.assertRaises(Problem) as short:
            self.social.search(self.ana, "a")
        self.assertEqual(short.exception.code, "QUERY_TOO_SHORT")

    def test_search_follows_profile_changes_and_old_profiles_are_indexed_when_opened(self):
        profile = self.identity.profile(self.ana)
        self.identity.patch_profile(
            self.ana, "k1", {"expectedVersion": profile["version"], "displayName": "Marina Alves"}
        )
        self.assertEqual(self.social.search(self.bia, "paula")["items"], [])
        self.assertEqual(
            [p["displayName"] for p in self.social.search(self.bia, "marina")["items"]],
            ["Marina Alves"],
        )
        # Simulate a profile created before search existed.
        for key in list(self.store.items):
            if key[1].startswith("PIDX#") or key[2] == "SEARCHIDX":
                self.store.items.pop(key)
        self.assertEqual(self.social.search(self.bia, "marina")["items"], [])
        self.identity.profile(self.ana)
        self.assertEqual(len(self.social.search(self.bia, "marina")["items"]), 1)

    def test_status_at_sign_in_makes_old_profiles_without_photo_searchable(self):
        for key in list(self.store.items):
            if key[1].startswith("PIDX#") or key[2] == "SEARCHIDX":
                self.store.items.pop(key)
        self.assertEqual(self.social.search(self.bia, "marina")["items"], [])
        self.identity.status(self.ana)
        self.assertEqual(
            [p["username"] for p in self.social.search(self.bia, "paula")["items"]], ["ana_runs"]
        )

    # ---- likes, last comment, notifications ----
    def test_likes_count_once_and_last_comment_is_shown_on_the_post(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.assertEqual(self.social.like(self.bia, "p1", "l1")["likedByMe"], True)
        self.social.like(self.bia, "p1", "l2")
        self.social.like(self.caio, "p1", "l3")
        post = self.social.post(self.bia, "p1")
        self.assertEqual((post["likeCount"], post["likedByMe"]), (2, True))
        self.assertNotIn("lastComment", post)
        self.social.comment(self.bia, "p1", "c1", "Parabéns! 🎉 ção")
        self.social.comment(self.caio, "p1", "c2", "Muito bom")
        post = self.social.post(self.bia, "p1")
        listed = self.social.comments(self.ana, "p1")["items"]
        self.assertEqual((post["commentCount"], post["lastComment"]["id"]), (2, listed[-1]["id"]))
        self.assertEqual(self.social.like(self.bia, "p1", "l4", liked=False)["likedByMe"], False)
        self.assertEqual(self.social.post(self.bia, "p1")["likeCount"], 1)
        self.assertIn("Parabéns! 🎉 ção", [c["text"] for c in listed])

    def test_notifications_cover_follow_requests_likes_comments_and_friend_posts(self):
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-05T10:00:00Z")
        self.social.follow(self.bia, "ana", "f1")
        self.social.decide(self.ana, "bia", True, "d1")
        self.social.follow(self.caio, "ana", "f2")
        self.social.like(self.bia, "p1", "l1")
        self.social.comment(self.bia, "p1", "c1", "Show")
        self.social.like(self.ana, "p1", "l2")
        self.complete(self.bia, "p2", "2026-11-06T09:00:00Z")
        self.social.follow(self.ana, "bia", "f3")
        mine = self.social.notifications(self.ana)
        kinds = sorted((i["kind"], i["actor"]["username"]) for i in mine["items"])
        self.assertEqual(
            kinds,
            [
                ("comment", "bia_lima"),
                ("follow", "bia_lima"),
                ("follow_request", "caio"),
                ("like", "bia_lima"),
                ("post", "bia_lima"),
            ],
        )
        self.assertEqual(mine["unreadCount"], 5)
        self.social.mark_notifications_read(self.ana, "r1")
        self.assertEqual(self.social.notifications(self.ana)["unreadCount"], 0)
        self.assertEqual(self.social.notifications(self.caio)["items"], [])

    # ---- follow ----
    def test_public_profile_is_followed_immediately_and_unfollowed(self):
        self.assertEqual(self.social.follow(self.bia, "ana", "f1")["state"], "active")
        self.assertEqual(self.social.follow(self.bia, "ana", "f1")["state"], "active")
        view = self.social.profile_view(self.bia, "ana")
        self.assertEqual(
            (view["followState"], view["followersCount"], view["canView"]), ("active", 1, True)
        )
        self.assertEqual(self.social.profile_view(self.ana, "bia")["followState"], "none")
        self.assertEqual(self.social.unfollow(self.bia, "ana", "u1")["state"], "none")
        self.assertEqual(self.social.profile_view(self.bia, "ana")["followersCount"], 0)

    def test_cannot_follow_self_or_unknown(self):
        with self.assertRaises(Problem) as me:
            self.social.follow(self.ana, "ana", "f")
        self.assertEqual(me.exception.code, "CANNOT_FOLLOW_SELF")
        with self.assertRaises(Problem) as unknown:
            self.social.follow(self.ana, "ghost", "f2")
        self.assertEqual(unknown.exception.status, 404)

    def test_private_profile_needs_approval_and_hides_content_until_then(self):
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z", comment="Foi lindo")
        self.assertEqual(self.social.follow(self.bia, "ana", "f1")["state"], "pending")
        hidden = self.social.profile_view(self.bia, "ana")
        self.assertEqual((hidden["followState"], hidden["canView"]), ("pending", False))
        self.assertNotIn("followersCount", hidden)
        with self.assertRaises(Problem):
            self.social.post(self.bia, "p1")
        with self.assertRaises(Problem):
            self.social.public_participations(self.bia, "ana")
        self.assertEqual(
            [r["profile"]["id"] for r in self.social.requests(self.ana)["items"]], ["bia"]
        )
        self.social.decide(self.ana, "bia", True, "d1")
        self.assertEqual(self.social.post(self.bia, "p1")["comment"], "Foi lindo")
        self.assertEqual(self.social.requests(self.ana)["items"], [])
        self.assertEqual(self.social.profile_view(self.bia, "ana")["followersCount"], 1)

    def test_decline_removes_the_request_and_nobody_else_can_decide(self):
        self.private(self.ana)
        self.social.follow(self.bia, "ana", "f1")
        with self.assertRaises(Problem) as other:
            self.social.decide(self.caio, "bia", True, "x")
        self.assertEqual(other.exception.status, 404)
        self.social.decide(self.ana, "bia", False, "d1")
        self.assertEqual(self.social.profile_view(self.bia, "ana")["followState"], "none")

    # ---- feed ----
    def test_feed_has_mine_and_followed_posts_newest_first_and_skips_unpublished(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.complete(self.ana, "p2", "2026-11-03T10:00:00Z", publish=False)
        self.complete(self.bia, "p3", "2026-11-02T10:00:00Z")
        self.complete(self.caio, "p4", "2026-11-04T10:00:00Z")
        self.assertEqual([p["id"] for p in self.social.feed(self.ana)["items"]], ["p1"])
        self.social.follow(self.ana, "bia", "f")
        page = self.social.feed(self.ana, limit=1)
        self.assertEqual([p["id"] for p in page["items"]], ["p3"])
        more = self.social.feed(self.ana, limit=1, cursor=page["nextCursor"])
        self.assertEqual([p["id"] for p in more["items"]], ["p1"])
        self.assertNotIn("nextCursor", more)
        # time is hidden from others unless the owner allows it
        self.assertNotIn("timeSeconds", page["items"][0]["participation"])
        self.assertEqual(
            self.social.feed(self.bia)["items"][0]["participation"]["timeSeconds"], 3000
        )

    # ---- comments ----
    def test_comments_follow_post_visibility_and_owner_can_remove_them(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        made = self.social.comment(self.bia, "p1", "c1", "  Parabéns!  ")
        self.assertEqual(made["text"], "Parabéns!")
        self.assertEqual(
            self.social.comment(self.bia, "p1", "c1", "  Parabéns!  ")["id"], made["id"]
        )
        listed = self.social.comments(self.caio, "p1")["items"]
        self.assertEqual([c["author"]["username"] for c in listed], ["bia_lima"])
        self.assertEqual(self.social.post(self.ana, "p1")["commentCount"], 1)
        with self.assertRaises(Problem) as stranger:
            self.social.delete_comment(self.caio, made["id"], "d0")
        self.assertEqual(stranger.exception.status, 404)
        self.social.delete_comment(self.ana, made["id"], "d1")
        self.assertEqual(self.social.comments(self.ana, "p1")["items"], [])

    def test_private_post_cannot_be_commented_by_non_followers(self):
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        with self.assertRaises(Problem):
            self.social.comment(self.bia, "p1", "c", "oi")
        with self.assertRaises(Problem):
            self.social.comments(self.bia, "p1")

    def test_photo_rule_allows_owner_and_authorized_viewers_of_published_posts_only(self):
        self.private(self.ana)
        part = {"publishToFeed": True}
        read = self.store.get
        self.assertTrue(self.social.may_view_photo(read, self.ana, "ana", part))
        self.assertFalse(self.social.may_view_photo(read, self.bia, "ana", part))
        self.social.follow(self.bia, "ana", "f")
        self.social.decide(self.ana, "bia", True, "d")
        self.assertTrue(self.social.may_view_photo(read, self.bia, "ana", part))
        self.assertFalse(
            self.social.may_view_photo(read, self.bia, "ana", {"publishToFeed": False})
        )

    # ---- profile photo ----
    def valid_image(self, actor, reference, blobs):
        key = ("operations", "USER#" + actor.subject, "IMAGE#" + reference)
        self.store.commit(
            {key: None},
            {key: {"owner": actor.subject, "origin": "runner", "state": "valid", "refs": 0}},
        )
        blobs.write_derived(reference, b"jpg", "image/jpeg", actor.subject)

    def test_banner_is_separate_from_photo_and_follows_visibility(self):
        blobs = MemoryBlobStore()
        uploads = UploadService(
            self.identity, blobs, may_view_profile=self.social.may_view_profile_photo
        )
        self.valid_image(self.ana, "ban1", blobs)
        profile = self.identity.profile(self.ana)
        saved = self.identity.patch_profile(
            self.ana, "b1", {"expectedVersion": profile["version"], "bannerReference": "ban1"}
        )
        self.assertEqual(saved["bannerReference"], "ban1")
        self.assertNotIn("photoReference", saved)
        self.assertEqual(self.store.get(("operations", "USER#ana", "IMAGE#ban1"))["refs"], 1)
        self.assertIn("url", uploads.profile_photo(self.bia, "ana", "bannerReference"))
        with self.assertRaises(Problem):
            uploads.profile_photo(self.bia, "ana")  # sem foto de perfil
        self.private(self.ana)
        with self.assertRaises(Problem):
            uploads.profile_photo(self.caio, "ana", "bannerReference")
        current = self.identity.profile(self.ana)
        cleared = self.identity.patch_profile(
            self.ana, "b2", {"expectedVersion": current["version"], "bannerReference": None}
        )
        self.assertNotIn("bannerReference", cleared)
        self.assertEqual(self.store.get(("operations", "USER#ana", "IMAGE#ban1"))["refs"], 0)

    def test_follow_requests_stay_first_and_old_ones_never_expire(self):
        self.private(self.ana)
        self.social.follow(self.caio, "ana", "f1")
        # Pedido antigo (mais de 30 dias) continua aparecendo.
        row_key = ("identity", "USER#ana", "FOLLOWER#caio")
        row = self.store.get(row_key)
        self.store.commit({row_key: row}, {row_key: {**row, "at": "2026-01-01T00:00:00Z"}})
        self.complete(self.bia, "p2", "2026-11-06T09:00:00Z")
        self.social.follow(self.ana, "bia", "f2")
        items = self.social.notifications(self.ana)["items"]
        self.assertEqual([i["kind"] for i in items], ["follow_request", "post"])

    def test_notification_can_be_dismissed_but_requests_cannot(self):
        self.complete(self.ana, "p1", "2026-11-05T10:00:00Z")
        self.social.like(self.bia, "p1", "l1")
        self.social.follow(self.caio, "ana", "f1")
        first = self.social.notifications(self.ana)["items"]
        like = next(i for i in first if i["kind"] == "like")
        self.assertEqual(
            self.social.dismiss_notification(self.ana, like["id"], "d1")["dismissed"], True
        )
        after = self.social.notifications(self.ana)["items"]
        self.assertEqual(sorted(i["kind"] for i in after), ["follow"])
        self.private(self.bia)
        self.social.follow(self.caio, "bia", "f9")
        with self.assertRaises(Problem) as nope:
            self.social.dismiss_notification(self.bia, "follow_request:caio::x", "d2")
        self.assertEqual(nope.exception.code, "NOTIFICATION_NOT_DISMISSIBLE")
        # marcar como lido nao apaga a lista de apagados
        self.social.mark_notifications_read(self.ana, "r1")
        self.assertEqual(
            sorted(i["kind"] for i in self.social.notifications(self.ana)["items"]), ["follow"]
        )

    def test_profile_photo_needs_my_valid_image_and_follows_visibility(self):
        blobs = MemoryBlobStore()
        uploads = UploadService(
            self.identity, blobs, may_view_profile=self.social.may_view_profile_photo
        )
        profile = self.identity.profile(self.ana)
        with self.assertRaises(Problem) as bad:
            self.identity.patch_profile(
                self.ana, "ph0", {"expectedVersion": profile["version"], "photoReference": "nope"}
            )
        self.assertEqual(bad.exception.code, "IMAGE_NOT_VALID")
        self.valid_image(self.ana, "img1", blobs)
        self.valid_image(self.bia, "img-bia", blobs)
        with self.assertRaises(Problem) as theirs:
            self.identity.patch_profile(
                self.ana,
                "ph1",
                {"expectedVersion": profile["version"], "photoReference": "img-bia"},
            )
        self.assertEqual(theirs.exception.code, "IMAGE_NOT_VALID")
        saved = self.identity.patch_profile(
            self.ana, "ph2", {"expectedVersion": profile["version"], "photoReference": "img1"}
        )
        self.assertEqual(saved["photoReference"], "img1")
        self.assertEqual(self.store.get(("operations", "USER#ana", "IMAGE#img1"))["refs"], 1)
        self.assertIn("url", uploads.profile_photo(self.bia, "ana"))
        self.private(self.ana)
        with self.assertRaises(Problem):
            uploads.profile_photo(self.caio, "ana")
        self.assertIn("url", uploads.profile_photo(self.ana, "ana"))
        # clearing releases the image
        current = self.identity.profile(self.ana)
        cleared = self.identity.patch_profile(
            self.ana, "ph3", {"expectedVersion": current["version"], "photoReference": None}
        )
        self.assertNotIn("photoReference", cleared)
        self.assertEqual(self.store.get(("operations", "USER#ana", "IMAGE#img1"))["refs"], 0)
        with self.assertRaises(Problem):
            uploads.profile_photo(self.bia, "ana")

    # ---- erasure ----
    def test_erasing_an_account_removes_index_follows_and_comments(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.social.follow(self.bia, "ana", "f1")
        self.social.follow(self.ana, "caio", "f2")
        made = self.social.comment(self.bia, "p1", "c1", "oi")
        self.identity.delete_account(self.bia, "del-bia")
        processor = ErasureProcessor(self.identity)
        self.assertEqual(processor.run_pending()["completed"], 1)
        self.assertEqual(self.social.search(self.caio, "beatriz")["items"], [])
        self.assertEqual(self.social.profile_view(self.caio, "ana")["followersCount"], 0)
        self.assertEqual(self.social.comments(self.ana, "p1")["items"], [])
        self.assertIsNone(self.store.get(("history", "COMMENT#" + made["id"], "LOC")))
        self.assertTrue(self.social.search(self.caio, "ana")["items"])
        leftovers = [
            k for k in self.store.items if "bia" in k[1] and k[1].startswith(("USER#", "PIDX#"))
        ]
        self.assertEqual(leftovers, [])
        self.assertEqual(self.social.profile_view(self.caio, "ana")["followingCount"], 1)


if __name__ == "__main__":
    unittest.main()
