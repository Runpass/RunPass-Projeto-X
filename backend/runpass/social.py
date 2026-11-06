"""Friends: profile search, follow (immediate for public profiles, approval for private ones),
feed of completed races and comments.

Visibility rule used everywhere: a profile is public unless its owner turned `isPrivate` on; a
private profile is seen in full only by its owner and by accepted followers. Rows that belong to
an account but live in a shared partition (follower side, comments, search index) are listed in
a `sharedKeys` pointer in the owner's partition so account erasure removes them too.
"""

import base64
import json
from uuid import uuid4

from .profile_index import MIN_TOKEN, fold, profile_tokens, tokens
from .service import IdentityService, Problem, stamp
from .store import Unavailable

MAX_FOLLOWING = 500
MAX_FEED_AUTHORS = 100
SEARCH_SCAN = 200


def _cursor_encode(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode()


def _cursor_decode(text):
    try:
        value = json.loads(base64.urlsafe_b64decode(text.encode()))
        if isinstance(value, list) and len(value) == 2 and all(isinstance(v, str) for v in value):
            return value
    except ValueError:
        pass
    raise Problem(422, "INVALID_CURSOR")


class SocialService:
    def __init__(self, identity):
        self.identity, self.store = identity, identity.store

    # ---- reads shared by every operation -------------------------------------------------

    def _active_profile(self, read, subject):
        account = read(("identity", "USER#" + subject, "ACCOUNT"))
        profile = read(("identity", "USER#" + subject, "PROFILE"))
        if not profile or not account or account.get("state") != "active":
            return None
        return profile

    def _follow_state(self, read, viewer, target):
        if viewer == target:
            return "self"
        row = read(("identity", "USER#" + target, "FOLLOWER#" + viewer))
        return row["state"] if row else "none"

    def can_view(self, read, viewer, author):
        """Whether `viewer` may see the posts, photos and counts of `author`."""
        profile = self._active_profile(read, author)
        if not profile:
            return False
        if viewer == author or not profile.get("isPrivate", False):
            return True
        return self._follow_state(read, viewer, author) == "active"

    def may_view_photo(self, read, actor, owner, part):
        """Photo rule for UploadService: owner always; others only for published, visible posts."""
        if owner == actor.subject:
            return True
        return bool(part.get("publishToFeed")) and self.can_view(read, actor.subject, owner)

    def may_view_profile_photo(self, read, actor, owner):
        return owner == actor.subject or self.can_view(read, actor.subject, owner)

    def _list(self, table, pk, prefix, limit=1000):
        rows, after = [], None
        while len(rows) < limit:
            page, after = self.store.query(table, pk, prefix=prefix, after=after, limit=100)
            rows.extend(page)
            if after is None:
                break
        return rows[:limit]

    def _completed(self, author):
        """Completed participations of one author, newest first (small per runner in the beta)."""
        parts = [
            item
            for sk, item in self._list("history", "USER#" + author, "P#")
            if sk.endswith("#PART") and item.get("state") == "completed"
        ]
        return sorted(parts, key=lambda i: (i.get("completedAt", ""), i["id"]), reverse=True)

    def _card(self, profile, viewer):
        card = IdentityService.public_profile(profile)
        card["isPrivate"] = bool(profile.get("isPrivate", False))
        card["followState"] = self._follow_state(self.store.get, viewer, profile["id"])
        return card

    # ---- search and profiles -------------------------------------------------------------

    def search(self, actor, query, limit=20):
        self.identity.authorize(actor, admitted=True)
        words = tokens(query)
        seeds = [w for w in words if len(w) >= MIN_TOKEN]
        if not seeds:
            raise Problem(422, "QUERY_TOO_SHORT")
        lead = max(seeds, key=len)
        rows = self._list("identity", "PIDX#" + lead[:MIN_TOKEN], lead, SEARCH_SCAN)
        found, seen = [], set()
        for sk, _ in rows:
            subject = sk.split("#", 1)[1]
            if subject in seen or subject == actor.subject:
                continue
            seen.add(subject)
            profile = self._active_profile(self.store.get, subject)
            if not profile:
                continue
            have = profile_tokens(profile["username"], profile["displayName"])
            if all(any(t.startswith(w) for t in have) for w in words if w):
                found.append(profile)
        found.sort(key=lambda p: (fold(p["displayName"]), p["username"]))
        return {"items": [self._card(p, actor.subject) for p in found[:limit]]}

    def profile_view(self, actor, subject):
        self.identity.authorize(actor, admitted=True)
        profile = self._active_profile(self.store.get, subject)
        if not profile:
            raise Problem(404, "PROFILE_NOT_FOUND")
        card = self._card(profile, actor.subject)
        card["canView"] = self.can_view(self.store.get, actor.subject, subject)
        if card["canView"]:
            card["followersCount"] = sum(
                1
                for _, row in self._list("identity", "USER#" + subject, "FOLLOWER#")
                if row["state"] == "active"
            )
            card["followingCount"] = sum(
                1
                for _, row in self._list("identity", "USER#" + subject, "FOLLOWING#")
                if row["state"] == "active"
            )
            card["participationCount"] = len(self._completed(subject))
        return card

    def public_participations(self, actor, subject, limit=20, cursor=None):
        self.identity.authorize(actor, admitted=True)
        if not self.can_view(self.store.get, actor.subject, subject):
            raise Problem(404, "PROFILE_NOT_FOUND")
        after = _cursor_decode(cursor) if cursor else None
        items = [
            p
            for p in self._completed(subject)
            if after is None or (p.get("completedAt", ""), p["id"]) < tuple(after)
        ]
        page = items[:limit]
        result = {"items": [self._public_participation(p, actor.subject) for p in page]}
        if len(items) > limit:
            last = page[-1]
            result["nextCursor"] = _cursor_encode([last.get("completedAt", ""), last["id"]])
        return result

    @staticmethod
    def _public_participation(part, viewer):
        mine = part.get("owner") == viewer
        item = {
            k: part[k]
            for k in ("id", "editionId", "distanceId", "state", "version", "completedAt")
            if k in part
        }
        if "timeSeconds" in part and (mine or part.get("showTime")):
            item["timeSeconds"] = part["timeSeconds"]
        if "placement" in part and (mine or part.get("showPlacement")):
            item["placement"] = part["placement"]
        return item

    # ---- follow --------------------------------------------------------------------------

    @staticmethod
    def _relation(target, state):
        return {"profileId": target, "active": state == "active", "state": state}

    def follow(self, actor, target, key):
        if target == actor.subject:
            raise Problem(422, "CANNOT_FOLLOW_SELF")

        def work(read, write, account, now, replay):
            profile = self._active_profile(read, target)
            if not profile:
                raise Problem(404, "PROFILE_NOT_FOUND")
            mine = ("identity", "USER#" + actor.subject, "FOLLOWING#" + target)
            theirs = ("identity", "USER#" + target, "FOLLOWER#" + actor.subject)
            existing = read(mine)
            if existing:
                return self._relation(target, existing["state"]), {}
            if len(
                self._list("identity", "USER#" + actor.subject, "FOLLOWING#", MAX_FOLLOWING)
            ) >= (MAX_FOLLOWING):
                raise Problem(409, "FOLLOW_LIMIT_REACHED")
            state = "pending" if profile.get("isPrivate", False) else "active"
            at = stamp(now)
            write(mine, {"state": state, "at": at, "sharedKeys": [list(theirs)]})
            write(theirs, {"state": state, "at": at, "sharedKeys": [list(mine)]})
            return self._relation(target, state), {}

        return self.identity.transact(actor, "putFollow", key, {"id": target}, work, admitted=True)

    def unfollow(self, actor, target, key):
        def work(read, write, account, now, replay):
            mine = ("identity", "USER#" + actor.subject, "FOLLOWING#" + target)
            theirs = ("identity", "USER#" + target, "FOLLOWER#" + actor.subject)
            if read(mine):
                write(mine, None)
            if read(theirs):
                write(theirs, None)
            return self._relation(target, "none"), {}

        return self.identity.transact(
            actor, "deleteFollow", key, {"id": target}, work, admitted=True
        )

    def requests(self, actor):
        self.identity.authorize(actor, admitted=True)
        items = []
        for sk, row in self._list("identity", "USER#" + actor.subject, "FOLLOWER#"):
            if row["state"] != "pending":
                continue
            profile = self._active_profile(self.store.get, sk.split("#", 1)[1])
            if profile:
                items.append(
                    {"profile": self._card(profile, actor.subject), "requestedAt": row["at"]}
                )
        items.sort(key=lambda i: i["requestedAt"])
        return {"items": items}

    def decide(self, actor, requester, approve, key):
        def work(read, write, account, now, replay):
            theirs = ("identity", "USER#" + requester, "FOLLOWING#" + actor.subject)
            mine = ("identity", "USER#" + actor.subject, "FOLLOWER#" + requester)
            row = read(mine)
            if not row:
                raise Problem(404, "FOLLOW_REQUEST_NOT_FOUND")
            if approve:
                if row["state"] == "pending":
                    other = read(theirs)
                    if not other:
                        raise Problem(503, "FOLLOW_INTEGRITY_FAILURE")
                    write(mine, {**row, "state": "active"})
                    write(theirs, {**other, "state": "active"})
                return self._relation(requester, "active"), {}
            write(mine, None)
            if read(theirs):
                write(theirs, None)
            return self._relation(requester, "none"), {}

        return self.identity.transact(
            actor,
            "approveFollow" if approve else "declineFollow",
            key,
            {"id": requester},
            work,
            admitted=True,
        )

    # ---- posts, feed, comments -----------------------------------------------------------

    def _comment_count(self, post_id):
        return len(self._list("history", "POST#" + post_id, "COMMENT#", 1000))

    def _post_view(self, part, viewer):
        author = self._active_profile(self.store.get, part["owner"])
        review = self.store.get(("history", "USER#" + part["owner"], "P#" + part["id"] + "#REVIEW"))
        post = {
            "id": part["id"],
            "author": self._card(author, viewer),
            "participation": self._public_participation(part, viewer),
            "publishedAt": part.get("completedAt", ""),
            "version": part["version"],
            "commentCount": self._comment_count(part["id"]),
        }
        if review and review.get("comment") and review.get("moderationState") != "invalidated":
            post["comment"] = review["comment"]
        return post

    def _authorized_post(self, read, viewer, post_id):
        owner = read(("history", "PARTICIPATION#" + post_id, "OWNER"))
        if not owner:
            raise Problem(404, "POST_NOT_FOUND")
        part = read(("history", "USER#" + owner["owner"], "P#" + post_id + "#PART"))
        if (
            not part
            or part.get("state") != "completed"
            or not part.get("publishToFeed")
            or not self.can_view(read, viewer, owner["owner"])
        ):
            raise Problem(404, "POST_NOT_FOUND")
        return {**part, "owner": owner["owner"]}

    def post(self, actor, post_id):
        self.identity.authorize(actor, admitted=True)
        return self._post_view(
            self._authorized_post(self.store.get, actor.subject, post_id), actor.subject
        )

    def feed(self, actor, limit=20, cursor=None):
        """My posts plus those of people I follow, newest first."""
        self.identity.authorize(actor, admitted=True)
        authors = [actor.subject] + [
            sk.split("#", 1)[1]
            for sk, row in self._list("identity", "USER#" + actor.subject, "FOLLOWING#")
            if row["state"] == "active"
        ][: MAX_FEED_AUTHORS - 1]
        after = _cursor_decode(cursor) if cursor else None
        posts = []
        for author in authors:
            if not self.can_view(self.store.get, actor.subject, author):
                continue
            for part in self._completed(author):
                if part.get("publishToFeed"):
                    key = (part.get("completedAt", ""), part["id"])
                    if after is None or key < tuple(after):
                        posts.append({**part, "owner": author})
        posts.sort(key=lambda p: (p.get("completedAt", ""), p["id"]), reverse=True)
        page = posts[:limit]
        result = {"items": [self._post_view(p, actor.subject) for p in page]}
        if len(posts) > limit:
            result["nextCursor"] = _cursor_encode([page[-1].get("completedAt", ""), page[-1]["id"]])
        return result

    def comments(self, actor, post_id, limit=20, cursor=None):
        self.identity.authorize(actor, admitted=True)
        self._authorized_post(self.store.get, actor.subject, post_id)
        rows, after = self.store.query(
            "history",
            "POST#" + post_id,
            prefix="COMMENT#",
            after=cursor,
            limit=limit,
        )
        items = []
        for _, row in rows:
            author = self._active_profile(self.store.get, row["author"])
            if author:
                items.append(
                    {
                        **{k: v for k, v in row.items() if k != "author"},
                        "author": self._card(author, actor.subject),
                    }
                )
        result = {"items": items}
        if after:
            result["nextCursor"] = after
        return result

    def comment(self, actor, post_id, key, text):
        text = text.strip()
        if not text or len(text) > 1000:
            raise Problem(422, "INVALID_COMMENT")

        def work(read, write, account, now, replay):
            self._authorized_post(read, actor.subject, post_id)
            if replay is not None:
                loc = read(("history", "COMMENT#" + replay["id"], "LOC"))
                if not loc:
                    raise Problem(404, "COMMENT_NOT_FOUND")
                return self._comment_out(
                    read(("history", "POST#" + post_id, loc["sk"])), actor
                ), replay
            comment_id, created = str(uuid4()), stamp(now)
            sk = f"COMMENT#{created}#{comment_id}"
            row = {
                "id": comment_id,
                "postId": post_id,
                "author": actor.subject,
                "text": text,
                "createdAt": created,
                "version": 1,
                "edited": False,
            }
            comment_key = ("history", "POST#" + post_id, sk)
            loc_key = ("history", "COMMENT#" + comment_id, "LOC")
            write(comment_key, row)
            write(loc_key, {"postId": post_id, "sk": sk, "author": actor.subject})
            write(
                ("identity", "USER#" + actor.subject, "COMMENTREF#" + comment_id),
                {"sharedKeys": [list(comment_key), list(loc_key)]},
            )
            return self._comment_out(row, actor), {"id": comment_id}

        return self.identity.transact(
            actor, "createPostComment", key, {"postId": post_id, "text": text}, work, admitted=True
        )

    def _comment_out(self, row, actor):
        profile = self._active_profile(self.store.get, row["author"]) or {}
        return {
            **{k: v for k, v in row.items() if k != "author"},
            "author": self._card(profile, actor.subject) if profile else {"id": row["author"]},
        }

    def delete_comment(self, actor, comment_id, key):
        def work(read, write, account, now, replay):
            loc_key = ("history", "COMMENT#" + comment_id, "LOC")
            loc = read(loc_key)
            if not loc:
                return {"id": comment_id, "deleted": True}, {}
            owner = read(("history", "PARTICIPATION#" + loc["postId"], "OWNER"))
            post_owner = owner["owner"] if owner else None
            if actor.subject not in (loc["author"], post_owner):
                raise Problem(404, "COMMENT_NOT_FOUND")
            write(("history", "POST#" + loc["postId"], loc["sk"]), None)
            write(loc_key, None)
            write(("identity", "USER#" + loc["author"], "COMMENTREF#" + comment_id), None)
            return {"id": comment_id, "deleted": True}, {}

        return self.identity.transact(
            actor, "deleteOwnComment", key, {"id": comment_id}, work, admitted=True
        )


__all__ = ["SocialService", "Unavailable"]
