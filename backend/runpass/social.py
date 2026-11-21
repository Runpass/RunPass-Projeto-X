"""Friends: profile search, follow (unidirectional, always immediate), friend requests
(bidirectional, require approval), feed of completed races and comments.

Visibility rule (decision of 08/11/2026): publications (posts, likes, comments, post photos,
avatar, banner) and follower/following counts are always public, `isPrivate` or not. A private
profile only restricts its consolidated race summary — participation count and the list of
completed races — to its owner and accepted friends; following alone never unlocks it. See
`can_view` (restricted summary) vs. `_author_active` (everything else). Rows that belong to an
account but live in a shared partition (follower/friend side, comments, search index, the
global public-feed pointer) are listed in a `sharedKeys` pointer in the owner's partition so
account erasure removes them too.
"""

import base64
import json
import re
import string
import time
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

from .catalog import haversine_km
from .participation import post_image_count
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

    def _friend_row(self, read, viewer, target):
        return read(("identity", "USER#" + viewer, "FRIEND#" + target))

    def _friend_state(self, read, viewer, target):
        """none | pending_out | pending_in | friends | self, from `viewer`'s point of view."""
        if viewer == target:
            return "self"
        row = self._friend_row(read, viewer, target)
        if not row:
            return "none"
        if row["state"] == "active":
            return "friends"
        return "pending_out" if row.get("requestedBy") == viewer else "pending_in"

    def _author_active(self, read, author):
        """Whether `author` has an active, admitted account — the only gate on publications
        (feed posts, likes, comments, post photos, avatar, banner): these are always public,
        decisão de produto de 08/11/2026, independente de `isPrivate`."""
        return bool(self._active_profile(read, author))

    def can_view(self, read, viewer, author):
        """Whether `viewer` may see `author`'s consolidated race summary (participation count
        and the list of completed races) on the profile screen.

        A public profile is open to anyone admitted. A private profile opens this summary only
        to its owner and to accepted friends (not mere followers: following never grants
        access). Posts, likes, comments, photos, avatar, banner and the follower/following
        counts are never gated by this — see `_author_active`.
        """
        profile = self._active_profile(read, author)
        if not profile:
            return False
        if viewer == author or not profile.get("isPrivate", False):
            return True
        row = self._friend_row(read, viewer, author)
        return bool(row and row["state"] == "active")

    def may_view_photo(self, read, actor, owner, part):
        """Photo rule for UploadService: owner always; others for any published post of an
        active account (publications are always public)."""
        if owner == actor.subject:
            return True
        return bool(part.get("publishToFeed")) and self._author_active(read, owner)

    def may_view_profile_photo(self, read, actor, owner):
        """Avatar and banner are always public for an active account (same rule as posts)."""
        return owner == actor.subject or self._author_active(read, owner)

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

    # ---- publicações extras (várias por corrida) ------------------------------------------------------
    # Uma publicação extra é um item próprio (`XP#<id>` na partição do autor) ligado a uma participação
    # concluída. Na leitura vira uma "participação virtual" (os dados da corrida vêm da participação e a foto,
    # o texto e as marcações vêm da publicação), assim o feed, as curtidas e os comentários tratam as duas
    # do mesmo jeito. O id começa com "x-" para não colidir com o id da participação.

    @staticmethod
    def _extra_part(read, owner, item):
        if not item:
            return None
        parent = read(("history", "USER#" + owner, "P#" + item["participationId"] + "#PART"))
        if not parent or parent.get("state") != "completed":
            return None
        part = {
            **parent,
            "id": item["id"],
            "owner": owner,
            "completedAt": item["publishedAt"],
            "publishToFeed": True,
            "postImageReference": item["postImageReference"],
            # As extras do carrossel sao as da publicacao extra, nunca as da publicacao da corrida.
            "morePostImageReferences": list(item.get("morePostImageReferences") or []),
            "taggedUserIds": item.get("taggedUserIds") or [],
            "version": item["version"],
            "extra": True,
            "participationId": parent["id"],
        }
        part.pop("postText", None)
        if item.get("postText"):
            part["postText"] = item["postText"]
        return part

    def _extra_posts(self, author):
        return [
            part
            for part in (
                self._extra_part(self.store.get, author, item)
                for _, item in self._list("history", "USER#" + author, "XP#")
            )
            if part
        ]

    def _card(self, profile, viewer):
        card = IdentityService.public_profile(profile)
        card["isPrivate"] = bool(profile.get("isPrivate", False))
        card["followState"] = self._follow_state(self.store.get, viewer, profile["id"])
        card["friendState"] = self._friend_state(self.store.get, viewer, profile["id"])
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
        subjects = []
        for sk, _ in rows:
            subject = sk.split("#", 1)[1]
            if subject != actor.subject and subject not in subjects:
                subjects.append(subject)
        found = []
        for profile in self._profiles(subjects).values():
            have = profile_tokens(profile["username"], profile["displayName"])
            if all(any(t.startswith(w) for t in have) for w in words if w):
                found.append(profile)
        # Amigos, amigos dos meus amigos e gente perto primeiro; depois por nome.
        ctx = self._closeness(actor.subject)
        found.sort(key=lambda p: (*self._affinity(p, ctx), fold(p["displayName"]), p["username"]))
        return {"items": self._cards(found[:limit], actor.subject, ctx)}

    # ---- leituras em lote e afinidade (busca e sugestoes) ---------------------------------

    NEARBY_KM = 50

    def _profiles(self, subjects):
        """Perfis ativos de varios ids, lidos em paralelo (na ordem pedida)."""
        keys = []
        for subject in subjects:
            keys += [
                ("identity", "USER#" + subject, "ACCOUNT"),
                ("identity", "USER#" + subject, "PROFILE"),
            ]
        got = self.store.batch_get(keys) if keys else {}
        out = {}
        for subject in subjects:
            profile = self._active_profile(got.get, subject)
            if profile:
                out[subject] = profile
        return out

    def _cards(self, profiles, viewer, ctx=None):
        """O mesmo que `_card` para varios perfis, com as relacoes lidas em paralelo. Com `ctx`, diz
        quantos amigos em comum e se a pessoa e de perto (motivo da indicacao no app)."""
        keys = []
        for p in profiles:
            keys += [
                ("identity", "USER#" + p["id"], "FOLLOWER#" + viewer),
                ("identity", "USER#" + viewer, "FRIEND#" + p["id"]),
            ]
        got = self.store.batch_get(keys) if keys else {}
        cards = []
        for p in profiles:
            card = IdentityService.public_profile(p)
            card["isPrivate"] = bool(p.get("isPrivate", False))
            card["followState"] = self._follow_state(got.get, viewer, p["id"])
            card["friendState"] = self._friend_state(got.get, viewer, p["id"])
            if ctx is not None:
                mutual = ctx["mutual"].get(p["id"], 0)
                if mutual:
                    card["mutualFriends"] = mutual
                if self._distance_tier(p, ctx) == 0:
                    card["nearby"] = True
            cards.append(card)
        return cards

    def _closeness(self, me):
        """Quem esta perto de mim na rede: meus amigos, os amigos deles (com quantos em comum) e quem
        as pessoas que eu sigo seguem; e onde eu moro (do meu perfil)."""
        friends = set(self._friend_ids(me))
        following = self._relation_subjects(me, "FOLLOWING#", "active")
        vias = sorted(friends)[:30]
        with ThreadPoolExecutor(max_workers=8) as pool:
            their_friends = list(pool.map(self._friend_ids, vias))
            their_follows = list(
                pool.map(
                    lambda v: self._relation_subjects(v, "FOLLOWING#", "active"), following[:20]
                )
            )
        mutual = {}
        for ids in their_friends:
            for subject in ids:
                if subject != me:
                    mutual[subject] = mutual.get(subject, 0) + 1
        second = {s for ids in their_follows for s in ids[:20] if s != me}
        return {
            "me": self.store.get(("identity", "USER#" + me, "PROFILE")) or {},
            "friends": friends,
            "mutual": mutual,
            "second": second,
        }

    def _distance_tier(self, profile, ctx):
        """0 perto (ate NEARBY_KM ou mesma cidade), 1 mesmo estado, 2 longe ou sem local."""
        me = ctx["me"]
        coords = [me.get("latitude"), me.get("longitude")]
        coords += [profile.get("latitude"), profile.get("longitude")]
        if all(v is not None for v in coords):
            km = haversine_km(*(float(v) for v in coords))
            if km <= self.NEARBY_KM:
                return 0
        elif (
            me.get("city")
            and fold(me.get("city", "")) == fold(profile.get("city", ""))
            and (me.get("state") == profile.get("state"))
        ):
            return 0
        if me.get("state") and me.get("state") == profile.get("state"):
            return 1
        return 2

    def _affinity(self, profile, ctx):
        """Chave de ordem: amigo, amigo de amigo (mais em comum antes), quem meus seguidos seguem,
        e dentro de cada grupo quem esta perto."""
        subject = profile["id"]
        if subject in ctx["friends"]:
            group = 0
        elif ctx["mutual"].get(subject):
            group = 1
        elif subject in ctx["second"]:
            group = 2
        else:
            group = 3
        return (group, -ctx["mutual"].get(subject, 0), self._distance_tier(profile, ctx))

    # O indice de busca e por prefixo de duas letras (`PIDX#xx`): para "listar" gente sem
    # consulta, descobrimos quais particoes existem (uma varredura paralela, guardada por
    # alguns minutos) e so entao lemos as que tem perfis. Adequado ao beta pequeno.
    PARTITION_TTL = 3600

    def _index_partitions(self):
        cached = getattr(self, "_pidx_cache", None)
        now = time.monotonic()
        if cached and cached[0] > now:
            return cached[1]
        first = string.ascii_lowercase + string.digits
        candidates = [a + b for a in first for b in first + "_"]

        def has_rows(prefix):
            rows, _ = self.store.query("identity", "PIDX#" + prefix, limit=1)
            return prefix if rows else None

        with ThreadPoolExecutor(max_workers=16) as pool:
            found = [p for p in pool.map(has_rows, candidates) if p]
        self._pidx_cache = (now + self.PARTITION_TTL, found)
        return found

    SUGGESTION_POOL = 60

    def suggestions(self, actor, limit=12):
        """Sugestoes de gente para seguir, sem consulta. Primeiro amigos dos meus amigos (mais amigos
        em comum antes), depois quem as pessoas que eu sigo seguem, e dentro de cada grupo quem mora
        perto; completa com quem me segue e com perfis do indice de busca (perto antes). Nunca inclui
        o proprio usuario nem quem ja e seguido ou amigo."""
        self.identity.authorize(actor, admitted=True)
        me = actor.subject
        ctx = self._closeness(me)
        known = {me} | ctx["friends"]
        known.update(self._relation_subjects(me, "FOLLOWING#", "active"))
        known.update(self._relation_subjects(me, "FOLLOWING#", "pending"))
        order, seen = [], set()

        def consider(subject):
            if subject not in known and subject not in seen:
                seen.add(subject)
                order.append(subject)

        for subject in sorted(ctx["mutual"]):
            consider(subject)
        for subject in sorted(ctx["second"]):
            consider(subject)
        for subject in self._relation_subjects(me, "FOLLOWER#", "active"):
            consider(subject)
        if len(order) < self.SUGGESTION_POOL:
            for prefix in self._index_partitions():
                for sk, _ in self._list("identity", "PIDX#" + prefix, None, 20):
                    consider(sk.split("#", 1)[1])
                if len(order) >= self.SUGGESTION_POOL:
                    break
        profiles = list(self._profiles(order[: self.SUGGESTION_POOL * 2]).values())
        profiles.sort(
            key=lambda p: (*self._affinity(p, ctx), fold(p["displayName"]), p["username"])
        )
        return {"items": self._cards(profiles[:limit], me, ctx)}

    def profile_view(self, actor, subject):
        self.identity.authorize(actor, admitted=True)
        profile = self._active_profile(self.store.get, subject)
        if not profile:
            raise Problem(404, "PROFILE_NOT_FOUND")
        card = self._card(profile, actor.subject)
        # Seguidores/seguindo sao sempre publicos (decisao de produto de 08/11/2026); so o
        # resumo de corridas (contagem e lista) fica atras de canView.
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
        card["friendsCount"] = len(self._friend_ids(subject))
        card["canView"] = self.can_view(self.store.get, actor.subject, subject)
        if card["canView"]:
            card["participationCount"] = len(self._completed(subject))
        return card

    def _relation_subjects(self, subject, prefix, state="active"):
        """Ids under `prefix` (FOLLOWER#/FOLLOWING#/FRIEND#) in `state`, sorted for stable
        pagination (cursor is just the last id returned, not a ciphered token: this data is
        always public, same as the counts)."""
        return sorted(
            sk.split("#", 1)[1]
            for sk, row in self._list("identity", "USER#" + subject, prefix)
            if row["state"] == state
        )

    def _relation_page(self, actor, ids, limit, cursor):
        after = next((i for i, v in enumerate(ids) if v == cursor), -1) + 1 if cursor else 0
        page = ids[after : after + limit]
        items = []
        for target in page:
            profile = self._active_profile(self.store.get, target)
            if profile:
                items.append(self._card(profile, actor.subject))
        result = {"items": items}
        if after + limit < len(ids):
            result["nextCursor"] = page[-1]
        return result

    def list_followers(self, actor, subject, limit=20, cursor=None):
        """Quem segue `subject`. Sempre publico, como o contador (decisao de 08/11/2026)."""
        self.identity.authorize(actor, admitted=True)
        if not self._active_profile(self.store.get, subject):
            raise Problem(404, "PROFILE_NOT_FOUND")
        return self._relation_page(
            actor, self._relation_subjects(subject, "FOLLOWER#"), limit, cursor
        )

    def list_following(self, actor, subject, limit=20, cursor=None):
        """Quem `subject` segue. Sempre publico, como o contador (decisao de 08/11/2026)."""
        self.identity.authorize(actor, admitted=True)
        if not self._active_profile(self.store.get, subject):
            raise Problem(404, "PROFILE_NOT_FOUND")
        return self._relation_page(
            actor, self._relation_subjects(subject, "FOLLOWING#"), limit, cursor
        )

    def list_friends(self, actor, subject, limit=20, cursor=None):
        """Amigos aceitos de `subject`. Sempre publico, como o contador (decisao de 08/11/2026)."""
        self.identity.authorize(actor, admitted=True)
        if not self._active_profile(self.store.get, subject):
            raise Problem(404, "PROFILE_NOT_FOUND")
        return self._relation_page(
            actor, self._relation_subjects(subject, "FRIEND#"), limit, cursor
        )

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
        # O pace segue a mesma escolha de mostrar o tempo.
        if "paceSecondsPerKm" in part and (mine or part.get("showTime")):
            item["paceSecondsPerKm"] = part["paceSecondsPerKm"]
        if "placement" in part and (mine or part.get("showPlacement")):
            item["placement"] = part["placement"]
        return item

    # ---- follow (unidirecional, sempre imediato, sem aprovação) --------------------------

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
            at = stamp(now)
            write(mine, {"state": "active", "at": at, "sharedKeys": [list(theirs)]})
            write(theirs, {"state": "active", "at": at, "sharedKeys": [list(mine)]})
            return self._relation(target, "active"), {}

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

    # ---- friend (bidirecional, com pedido e aprovação) ------------------------------------

    @staticmethod
    def _friend_relation(target, state):
        return {"profileId": target, "state": state}

    def add_friend(self, actor, target, key):
        if target == actor.subject:
            raise Problem(422, "CANNOT_FRIEND_SELF")

        def work(read, write, account, now, replay):
            profile = self._active_profile(read, target)
            if not profile:
                raise Problem(404, "PROFILE_NOT_FOUND")
            mine = ("identity", "USER#" + actor.subject, "FRIEND#" + target)
            theirs = ("identity", "USER#" + target, "FRIEND#" + actor.subject)
            existing = read(mine)
            if existing:
                if existing["state"] == "active":
                    return self._friend_relation(target, "friends"), {}
                if existing.get("requestedBy") == actor.subject:
                    return self._friend_relation(target, "pending_out"), {}
                # O outro já tinha me pedido amizade: aceitar direto em vez de duplicar o pedido.
                other = read(theirs)
                if not other:
                    raise Problem(503, "FRIEND_INTEGRITY_FAILURE")
                write(mine, {**existing, "state": "active"})
                write(theirs, {**other, "state": "active"})
                return self._friend_relation(target, "friends"), {}
            at = stamp(now)
            write(
                mine,
                {
                    "state": "pending",
                    "requestedBy": actor.subject,
                    "at": at,
                    "sharedKeys": [list(theirs)],
                },
            )
            write(
                theirs,
                {
                    "state": "pending",
                    "requestedBy": actor.subject,
                    "at": at,
                    "sharedKeys": [list(mine)],
                },
            )
            return self._friend_relation(target, "pending_out"), {}

        return self.identity.transact(
            actor, "putFriendRequest", key, {"id": target}, work, admitted=True
        )

    def remove_friend(self, actor, target, key):
        """Cancela um pedido enviado ou desfaz uma amizade existente."""

        def work(read, write, account, now, replay):
            mine = ("identity", "USER#" + actor.subject, "FRIEND#" + target)
            theirs = ("identity", "USER#" + target, "FRIEND#" + actor.subject)
            if read(mine):
                write(mine, None)
            if read(theirs):
                write(theirs, None)
            return self._friend_relation(target, "none"), {}

        return self.identity.transact(
            actor, "deleteFriend", key, {"id": target}, work, admitted=True
        )

    def friend_requests(self, actor):
        """Pedidos de amizade recebidos, ainda não respondidos."""
        self.identity.authorize(actor, admitted=True)
        items = []
        for sk, row in self._list("identity", "USER#" + actor.subject, "FRIEND#"):
            if row["state"] != "pending" or row.get("requestedBy") == actor.subject:
                continue
            profile = self._active_profile(self.store.get, sk.split("#", 1)[1])
            if profile:
                items.append(
                    {"profile": self._card(profile, actor.subject), "requestedAt": row["at"]}
                )
        items.sort(key=lambda i: i["requestedAt"])
        return {"items": items}

    def decide_friend(self, actor, requester, approve, key):
        def work(read, write, account, now, replay):
            theirs = ("identity", "USER#" + requester, "FRIEND#" + actor.subject)
            mine = ("identity", "USER#" + actor.subject, "FRIEND#" + requester)
            row = read(mine)
            if not row or row["state"] != "pending" or row.get("requestedBy") != requester:
                raise Problem(404, "FRIEND_REQUEST_NOT_FOUND")
            if approve:
                other = read(theirs)
                if not other:
                    raise Problem(503, "FRIEND_INTEGRITY_FAILURE")
                write(mine, {**row, "state": "active"})
                write(theirs, {**other, "state": "active"})
                return self._friend_relation(requester, "friends"), {}
            write(mine, None)
            if read(theirs):
                write(theirs, None)
            return self._friend_relation(requester, "none"), {}

        return self.identity.transact(
            actor,
            "approveFriend" if approve else "declineFriend",
            key,
            {"id": requester},
            work,
            admitted=True,
        )

    # ---- posts, feed, comments -----------------------------------------------------------

    def _comment_rows(self, post_id):
        return self._list("history", "POST#" + post_id, "COMMENT#", 1000)

    def _like_rows(self, post_id):
        return self._list("history", "POST#" + post_id, "LIKE#", 1000)

    def _post_view(self, part, viewer):
        author = self._active_profile(self.store.get, part["owner"])
        review = (
            None  # publicação extra: só o texto escrito nela
            if part.get("extra")
            else self.store.get(("history", "USER#" + part["owner"], "P#" + part["id"] + "#REVIEW"))
        )
        post = {
            "id": part["id"],
            "author": self._card(author, viewer),
            "participation": self._public_participation(part, viewer),
            "publishedAt": part.get("completedAt", ""),
            "version": part["version"],
        }
        comments = self._comment_rows(part["id"])
        post["commentCount"] = len(comments)
        if comments:
            post["lastComment"] = self._comment_out(comments[-1][1], viewer)
        likes = self._like_rows(part["id"])
        post["likeCount"] = len(likes)
        post["likedByMe"] = any(sk == "LIKE#" + viewer for sk, _ in likes)
        if review and review.get("comment") and review.get("moderationState") != "invalidated":
            post["comment"] = review["comment"]
        if part.get("postImageReference"):
            post["hasPostImage"] = True  # a publicacao tem foto propria, separada da medalha
        # Quantas fotos o carrossel tem (cada uma em .../post-image?index=N ou /posts/{id}/image?index=N).
        # As referencias em si so vao para o dono, que precisa delas para editar o carrossel.
        post["postImageCount"] = post_image_count(part)
        if part.get("owner") == viewer and part.get("postImageReference"):
            post["morePostImageReferences"] = list(part.get("morePostImageReferences") or [])
        tagged = []
        for subject in part.get("taggedUserIds") or []:
            profile = self._active_profile(self.store.get, subject)
            if profile:
                tagged.append(self._card(profile, viewer))
        if tagged:
            post["tagged"] = tagged
        if part.get("postText"):
            post["comment"] = part[
                "postText"
            ]  # o texto escrito ao publicar vale mais que o da avaliacao
        if part.get("extra"):
            post["extra"] = True
            post["participation"]["id"] = part["participationId"]
        return post

    def _authorized_post(self, read, viewer, post_id):
        """`viewer` is kept in the signature even though posts are always public (same shape
        as before, and the parameter documents intent at call sites)."""
        if post_id.startswith("x-"):
            pointer = read(("history", "XPOST#" + post_id, "OWNER"))
            item = pointer and read(("history", "USER#" + pointer["owner"], "XP#" + post_id))
            part = item and self._extra_part(read, pointer["owner"], item)
            if not part or not self._author_active(read, pointer["owner"]):
                raise Problem(404, "POST_NOT_FOUND")
            return part
        owner = read(("history", "PARTICIPATION#" + post_id, "OWNER"))
        if not owner:
            raise Problem(404, "POST_NOT_FOUND")
        part = read(("history", "USER#" + owner["owner"], "P#" + post_id + "#PART"))
        if (
            not part
            or part.get("state") != "completed"
            or not part.get("publishToFeed")
            or not self._author_active(read, owner["owner"])
        ):
            raise Problem(404, "POST_NOT_FOUND")
        return {**part, "owner": owner["owner"]}

    def post(self, actor, post_id):
        self.identity.authorize(actor, admitted=True)
        return self._post_view(
            self._authorized_post(self.store.get, actor.subject, post_id), actor.subject
        )

    def my_posts(self, actor):
        """Todas as minhas publicações (a de cada corrida e as extras), mais recentes primeiro."""
        self.identity.authorize(actor, admitted=True)
        me = actor.subject
        parts = [
            {**p, "owner": me} for p in self._completed(me) if p.get("publishToFeed")
        ] + self._extra_posts(me)
        parts.sort(key=lambda p: (p.get("completedAt", ""), p["id"]), reverse=True)
        return {"items": [self._post_view(p, me) for p in parts]}

    def _friend_ids(self, subject):
        return [
            sk.split("#", 1)[1]
            for sk, row in self._list("identity", "USER#" + subject, "FRIEND#")
            if row["state"] == "active"
        ]

    def _friends_of(self, actor):
        return self._friend_ids(actor.subject)

    def _authors_feed(self, actor, after, authors):
        """Posts publicados pelos `authors` indicados (decisão de 08/11/2026: não inclui o
        próprio ator — "Amigos" e "Seguindo" mostram só quem está na lista; as minhas
        publicações aparecem em "Todos")."""
        posts = []
        for author in authors[:MAX_FEED_AUTHORS]:
            if not self._author_active(self.store.get, author):
                continue
            for part in self._completed(author):
                if part.get("publishToFeed"):
                    key = (part.get("completedAt", ""), part["id"])
                    if after is None or key < tuple(after):
                        posts.append({**part, "owner": author})
            for part in self._extra_posts(author):
                key = (part.get("completedAt", ""), part["id"])
                if after is None or key < tuple(after):
                    posts.append(part)
        posts.sort(key=lambda p: (p.get("completedAt", ""), p["id"]), reverse=True)
        return posts

    PUBLIC_FEED_SCAN = 2000

    def _public_feed(self, actor, after, limit):
        """Publicações de qualquer autor com conta ativa, mais recentes primeiro — posts são
        sempre públicos, perfil privado ou não (decisão de produto de 08/11/2026). Usa o
        ponteiro global `FEED#PUBLIC` (sem Scan: é uma Query por PK fixa); a conta do autor é
        sempre reconferida na leitura, então uma conta apagada some do feed de todo mundo.
        Como `_completed`, assume volume pequeno de publicações na beta (sem paginação reversa
        no Store); crescer além disso pede um índice por tempo de verdade."""
        posts, seen_owners = [], {}
        for _, pointer in self._list("history", "FEED#PUBLIC", "T#", self.PUBLIC_FEED_SCAN):
            key = (pointer.get("completedAt", ""), pointer["id"])
            if after is not None and key >= tuple(after):
                continue
            owner = pointer["owner"]
            if owner not in seen_owners:
                seen_owners[owner] = self._author_active(self.store.get, owner)
            if not seen_owners[owner]:
                continue
            if pointer.get("extra"):
                item = self.store.get(("history", "USER#" + owner, "XP#" + pointer["id"]))
                part = self._extra_part(self.store.get, owner, item)
                if part:
                    posts.append(part)
                continue
            part = self.store.get(("history", "USER#" + owner, "P#" + pointer["id"] + "#PART"))
            if part and part.get("state") == "completed" and part.get("publishToFeed"):
                posts.append({**part, "owner": owner})
        posts.sort(key=lambda p: (p.get("completedAt", ""), p["id"]), reverse=True)
        return posts

    def feed(self, actor, limit=20, cursor=None, scope="all"):
        """Feed de publicações, mais recentes primeiro.

        `scope`: "all" (padrão) traz publicações de qualquer autor com conta ativa — posts são
        sempre públicos, perfil privado ou não; "friends" só de amigos aceitos; "network" só de
        quem eu sigo (nos três casos, as publicações em si nunca ficam restritas por privacidade;
        só o resumo de corridas na tela de perfil fica, ver `can_view`).
        """
        self.identity.authorize(actor, admitted=True)
        after = _cursor_decode(cursor) if cursor else None
        if scope == "friends":
            posts = self._authors_feed(actor, after, self._friends_of(actor))
        elif scope == "network":
            following = [
                sk.split("#", 1)[1]
                for sk, row in self._list("identity", "USER#" + actor.subject, "FOLLOWING#")
                if row["state"] == "active"
            ]
            posts = self._authors_feed(actor, after, following)
        else:
            posts = self._public_feed(actor, after, limit)
        page = posts[:limit]
        result = {"items": [self._post_view(p, actor.subject) for p in page]}
        if len(posts) > limit:
            result["nextCursor"] = _cursor_encode([page[-1].get("completedAt", ""), page[-1]["id"]])
        return result

    REVIEW_SCAN = 2000
    CRITERIA = (
        "organization",
        "course",
        "kit",
        "medal",
        "hydration",
        "facilities",
        "safety",
        "valueForMoney",
    )
    RECOMMEND_FROM = 4.0  # "recomendaria" = media dos oito criterios >= 4 (nao ha pergunta propria)

    def _edition_completions(self, edition_id, distance_id=None):
        """(participacao, avaliacao, perfil) de quem concluiu a edicao, pelo ponteiro `EDREV#<edicao>`.

        Reconfere na leitura: conta ativa e participacao concluida na edicao atual. Assume volume
        pequeno na beta (como o feed publico)."""
        found, active = [], {}
        for _, pointer in self._list("history", "EDREV#" + edition_id, "T#", self.REVIEW_SCAN):
            owner = pointer["owner"]
            if owner not in active:
                active[owner] = self._active_profile(self.store.get, owner)
            if not active[owner]:
                continue
            base = "P#" + pointer["id"]
            part = self.store.get(("history", "USER#" + owner, base + "#PART"))
            review = self.store.get(("history", "USER#" + owner, base + "#REVIEW"))
            if (
                not part
                or part.get("state") != "completed"
                or part.get("editionId") != edition_id
                or not review
                or (distance_id and part.get("distanceId") != distance_id)
            ):
                continue
            found.append((part, review, active[owner]))
        return found

    def edition_participants(self, actor, edition_id, distance_id=None, limit=20, cursor=None):
        """Quem concluiu a edicao, mais recentes primeiro.

        A lista traz so perfis que o leitor pode ver (publico, o proprio ou amigo de perfil privado,
        mesma regra de `can_view`). `total` e a contagem de todas as conclusoes validas, sem
        identificar ninguem. Tempo e colocacao so aparecem quando a pessoa escolheu mostrar."""
        self.identity.authorize(actor, admitted=True)
        after = _cursor_decode(cursor) if cursor else None
        done = self._edition_completions(edition_id, distance_id)
        done.sort(key=lambda r: (r[0].get("completedAt", ""), r[0]["id"]), reverse=True)
        visible = [
            (part, profile)
            for part, _, profile in done
            if self.can_view(self.store.get, actor.subject, part["owner"])
        ]
        window = [
            r
            for r in visible
            if after is None or (r[0].get("completedAt", ""), r[0]["id"]) < tuple(after)
        ]
        page = window[:limit]
        items = [
            {
                "participationId": part["id"],
                "author": self._card(profile, actor.subject),
                **{
                    k: v
                    for k, v in self._public_participation(part, actor.subject).items()
                    if k
                    in ("distanceId", "completedAt", "timeSeconds", "paceSecondsPerKm", "placement")
                },
            }
            for part, profile in page
        ]
        result = {"items": items, "total": len(done)}
        if len(window) > limit:
            last = page[-1][0]
            result["nextCursor"] = _cursor_encode([last.get("completedAt", ""), last["id"]])
        return result

    def edition_registrants(self, actor, edition_id, limit=30, cursor=None):
        """Quem marcou "inscrito" nesta edicao (plano `registered`), mais recentes primeiro.

        Le o ponteiro `EDPLAN#<edicao>` e reconfere plano e conta na leitura. So lista perfis
        que o leitor pode ver (mesma regra de `can_view` dos participantes); `total` conta todos
        os inscritos validos, sem identificar ninguem."""
        self.identity.authorize(actor, admitted=True)
        after = _cursor_decode(cursor) if cursor else None
        valid = []
        for sk, pointer in self._list("history", "EDPLAN#" + edition_id, "U#", self.REVIEW_SCAN):
            owner = pointer["owner"]
            plan = self.store.get(("history", "USER#" + owner, "PLAN#" + edition_id))
            profile = self._active_profile(self.store.get, owner)
            if not plan or plan.get("status") != "registered" or not profile:
                continue
            valid.append((plan.get("updatedAt", ""), owner, plan, profile))
        valid.sort(key=lambda r: (r[0], r[1]), reverse=True)
        visible = [r for r in valid if self.can_view(self.store.get, actor.subject, r[1])]
        window = [r for r in visible if after is None or (r[0], r[1]) < tuple(after)]
        page = window[:limit]
        items = [
            {
                "author": self._card(profile, actor.subject),
                **({"distanceId": plan["distanceId"]} if plan.get("distanceId") else {}),
                "registeredAt": updated,
            }
            for updated, _, plan, profile in page
        ]
        result = {"items": items, "total": len(valid)}
        if len(window) > limit:
            result["nextCursor"] = _cursor_encode([page[-1][0], page[-1][1]])
        return result

    def edition_photos(self, actor, edition_id, distance_id=None, limit=30, cursor=None):
        """Fotos de POSTAGEM que os corredores publicaram para a edicao, mais recentes primeiro.

        So entra participacao publicada no feed (conta ativa) que tem foto de postagem propria
        (`postImageReference`): nunca a foto da medalha nem a arte padrao do catalogo. A imagem de cada
        item e `GET /participations/{id}/post-image`. `total` conta as fotos visiveis para o leitor.
        Assume volume pequeno na beta (como o feed publico)."""
        self.identity.authorize(actor, admitted=True)
        after = _cursor_decode(cursor) if cursor else None
        done = self._edition_completions(edition_id, distance_id)
        done.sort(key=lambda r: (r[0].get("completedAt", ""), r[0]["id"]), reverse=True)
        visible = []
        for part, _, profile in done:
            if not part.get("publishToFeed") or not part.get("postImageReference"):
                continue
            if not self.may_view_photo(self.store.get, actor, part["owner"], part):
                continue
            visible.append((part, profile))
        window = [
            r
            for r in visible
            if after is None or (r[0].get("completedAt", ""), r[0]["id"]) < tuple(after)
        ]
        page = window[:limit]
        items = [
            {
                "participationId": part["id"],
                "author": self._card(profile, actor.subject),
                "postImageCount": post_image_count(part),
                **{k: part[k] for k in ("distanceId", "completedAt") if k in part},
            }
            for part, profile in page
        ]
        result = {"items": items, "total": len(visible)}
        if len(window) > limit:
            last = page[-1][0]
            result["nextCursor"] = _cursor_encode([last.get("completedAt", ""), last["id"]])
        return result

    def edition_reviews(self, actor, edition_id, distance_id=None, limit=20, cursor=None):
        """Avaliacoes publicas validas da edicao, mais recentes primeiro, com o resumo do conjunto.

        Le o ponteiro `EDREV#<edicao>` e reconfere tudo na leitura: participacao concluida na
        edicao atual, avaliacao valida e conta ativa. O resumo (`summary`) cobre todas as avaliacoes
        validas do filtro, nao so a pagina. Assume volume pequeno na beta (como o feed publico)."""
        self.identity.authorize(actor, admitted=True)
        after = _cursor_decode(cursor) if cursor else None
        valid = [
            (part, review, profile)
            for part, review, profile in self._edition_completions(edition_id, distance_id)
            if review.get("moderationState") == "valid"
        ]
        valid.sort(key=lambda r: (r[0].get("completedAt", ""), r[0]["id"]), reverse=True)
        summary = self._review_summary([r for _, r, _ in valid])
        window = [
            r
            for r in valid
            if after is None or (r[0].get("completedAt", ""), r[0]["id"]) < tuple(after)
        ]
        page = window[:limit]
        items = [
            {
                "participationId": part["id"],
                "version": review["reviewVersion"],
                "ratings": review["ratings"],
                "moderationState": review["moderationState"],
                **({"comment": review["comment"]} if review.get("comment") else {}),
                "authorName": profile.get("displayName") or "Corredor RunPass",
                # Cartao publico de quem avaliou (o app mostra a foto do perfil), como nos comentarios.
                **({"author": self._card(profile, actor.subject)} if profile.get("id") else {}),
                "createdAt": part.get("completedAt", ""),
            }
            for part, review, profile in page
        ]
        result = {"items": items, "summary": summary}
        if len(window) > limit:
            last = page[-1][0]
            result["nextCursor"] = _cursor_encode([last.get("completedAt", ""), last["id"]])
        return result

    def _review_summary(self, reviews):
        count = len(reviews)
        if not count:
            return {"reviewCount": 0, "average": None, "recommendPercent": None, "byCriterion": {}}

        # O DynamoDB devolve numeros como Decimal; as notas sao inteiras de 1 a 5. Somar Decimal com o
        # float de arredondamento (1e-9) derrubava a aba Avaliacoes da corrida (500 em producao do DEV).
        def grade(review, criterion):
            return int(review["ratings"][criterion])

        sums = {c: sum(grade(r, c) for r in reviews) for c in self.CRITERIA}
        total = sum(sums.values())
        liked = sum(
            1 for r in reviews if sum(grade(r, c) for c in self.CRITERIA) / 8 >= self.RECOMMEND_FROM
        )
        return {
            "reviewCount": count,
            "average": round(total / (8 * count) + 1e-9, 1),
            "recommendPercent": round(100 * liked / count),
            "byCriterion": {c: round(sums[c] / count + 1e-9, 1) for c in self.CRITERIA},
        }

    def _comment_likes(self, post_id):
        """{comment id: [liker subject, ...]} de uma publicacao."""
        likes = {}
        for sk, row in self._list("history", "POST#" + post_id, "CLIKE#", 5000):
            _, comment_id, who = sk.split("#", 2)
            likes.setdefault(comment_id, []).append((who, row.get("createdAt", "")))
        return likes

    def _decorated(self, row, viewer, likes):
        out = self._comment_out(row, viewer)
        who = [w for w, _ in likes.get(row["id"], [])]
        out["likeCount"] = len(who)
        out["likedByMe"] = viewer in who
        return out

    def comments(self, actor, post_id, limit=20, cursor=None):
        """Comentarios principais (paginados) com as respostas de cada um embutidas."""
        self.identity.authorize(actor, admitted=True)
        self._authorized_post(self.store.get, actor.subject, post_id)
        rows = [r for _, r in self._comment_rows(post_id)]
        likes = self._comment_likes(post_id)
        replies = {}
        for row in rows:
            if row.get("parentId"):
                replies.setdefault(row["parentId"], []).append(row)
        roots = [r for r in rows if not r.get("parentId")]
        if cursor:
            roots = [r for r in roots if f"COMMENT#{r['createdAt']}#{r['id']}" > cursor]
        page = roots[:limit]
        items = []
        for row in page:
            if not self._active_profile(self.store.get, row["author"]):
                continue
            item = self._decorated(row, actor.subject, likes)
            mine = [
                self._decorated(r, actor.subject, likes)
                for r in replies.get(row["id"], [])
                if self._active_profile(self.store.get, r["author"])
            ]
            item["replies"] = mine
            item["replyCount"] = len(mine)
            items.append(item)
        result = {"items": items}
        if len(roots) > limit and page:
            last = page[-1]
            result["nextCursor"] = f"COMMENT#{last['createdAt']}#{last['id']}"
        return result

    def like_comment(self, actor, comment_id, key, liked=True):
        def work(read, write, account, now, replay):
            loc = read(("history", "COMMENT#" + comment_id, "LOC"))
            if not loc:
                raise Problem(404, "COMMENT_NOT_FOUND")
            self._authorized_post(read, actor.subject, loc["postId"])
            like_key = (
                "history",
                "POST#" + loc["postId"],
                f"CLIKE#{comment_id}#{actor.subject}",
            )
            ref_key = ("identity", "USER#" + actor.subject, "CLIKEREF#" + comment_id)
            exists = read(like_key) is not None
            if liked and not exists:
                write(like_key, {"author": actor.subject, "createdAt": stamp(now)})
                write(ref_key, {"sharedKeys": [list(like_key)]})
            elif not liked and exists:
                write(like_key, None)
                write(ref_key, None)
            return {"commentId": comment_id, "likedByMe": liked}, {}

        return self.identity.transact(
            actor,
            "likeComment" if liked else "unlikeComment",
            key,
            {"commentId": comment_id},
            work,
            admitted=True,
        )

    def like(self, actor, post_id, key, liked=True):
        def work(read, write, account, now, replay):
            self._authorized_post(read, actor.subject, post_id)
            like_key = ("history", "POST#" + post_id, "LIKE#" + actor.subject)
            ref_key = ("identity", "USER#" + actor.subject, "LIKEREF#" + post_id)
            exists = read(like_key) is not None
            if liked and not exists:
                write(like_key, {"author": actor.subject, "createdAt": stamp(now)})
                write(ref_key, {"sharedKeys": [list(like_key)]})
            elif not liked and exists:
                write(like_key, None)
                write(ref_key, None)
            return {"postId": post_id, "likedByMe": liked}, {}

        return self.identity.transact(
            actor,
            "putPostLike" if liked else "deletePostLike",
            key,
            {"postId": post_id},
            work,
            admitted=True,
        )

    # ---- notifications (derived from what already exists; nothing extra to erase) ---------

    NOTIFICATION_DAYS = 30
    NOTIFICATION_LIMIT = 50
    NOTIFICATION_POSTS = 20

    def _notification_items(self, actor, since, dismissed=()):
        me = actor.subject
        items = []

        def add(kind, at, who, post=None, extra=None, pinned=False):
            if at < since and not pinned:
                return
            profile = self._active_profile(self.store.get, who)
            if not profile:
                return
            item = {
                "id": ":".join([kind, who, (post or {}).get("id", ""), at]),
                "kind": kind,
                "createdAt": at,
                "actor": self._card(profile, me),
            }
            if post:
                item["postId"] = post["id"]
                item["editionId"] = post.get("editionId")
            if extra:
                item.update(extra)
            items.append(item)

        for sk, row in self._list("identity", "USER#" + me, "FOLLOWER#"):
            add("follow", row["at"], sk.split("#", 1)[1])
        for sk, row in self._list("identity", "USER#" + me, "FRIEND#"):
            who = sk.split("#", 1)[1]
            pending = row["state"] == "pending" and row.get("requestedBy") != me
            if row["state"] == "active" or pending:
                add("friend_request" if pending else "friend", row["at"], who, pinned=pending)
        mine = [p for p in self._completed(me) if p.get("publishToFeed")] + self._extra_posts(me)
        mine.sort(key=lambda p: (p.get("completedAt", ""), p["id"]), reverse=True)
        for part in mine[: self.NOTIFICATION_POSTS]:
            for sk, row in self._like_rows(part["id"]):
                if row["author"] != me:
                    add("like", row["createdAt"], row["author"], part)
            for _, row in self._comment_rows(part["id"]):
                if row["author"] != me:
                    add(
                        "comment",
                        row["createdAt"],
                        row["author"],
                        part,
                        {"text": row["text"][:140]},
                    )
        self._comment_notifications(actor, add)
        following = [
            sk.split("#", 1)[1]
            for sk, row in self._list("identity", "USER#" + me, "FOLLOWING#")
            if row["state"] == "active"
        ]
        for part in self._authors_feed(actor, None, following)[: self.NOTIFICATION_POSTS]:
            if part["owner"] != me:
                add("post", part.get("completedAt", ""), part["owner"], part)
        self._request_result_notifications(me, since, items)
        # Pedidos de amizade sempre primeiro (e nunca saem por idade ou limite); o resto, novo primeiro.
        items = [i for i in items if i["id"] not in dismissed]
        items.sort(key=lambda i: i["createdAt"], reverse=True)
        requests = [i for i in items if i["kind"] == "friend_request"]
        others = [i for i in items if i["kind"] != "friend_request"]
        return requests + others[: self.NOTIFICATION_LIMIT]

    def _request_result_notifications(self, me, since, items):
        """Avisos de sugestao nao aprovada (corrida ou banner): dizem o que aconteceu e o motivo. Derivados dos
        proprios pedidos da pessoa; nao tem autor (sao da equipe), so texto."""
        for sk, row in self._list("history", "USER#" + me, "EREQ#", 100):
            request_id = sk.split("#", 1)[1]
            name = (row.get("details") or {}).get("name") or "sua sugestao"
            at = row.get("updatedAt", "")
            if at < since:
                continue
            if row.get("status") == "rejected":
                reason = (row.get("reason") or "").strip()
                kind, text = (
                    "request_rejected",
                    f'Sua sugestão da corrida "{name}" não foi aprovada pela equipe'
                    + (f": {reason}" if reason else ".")
                    + " As informações enviadas deixam de aparecer para você. Você pode corrigir e reenviar em Minhas solicitações.",
                )
            elif row.get("bannerState") == "dismissed":
                kind, text = (
                    "banner_dismissed",
                    f'O banner que você sugeriu para "{name}" não foi aprovado pela equipe e não será publicado. A imagem deixa de aparecer para você.',
                )
            else:
                continue
            items.append(
                {
                    "id": f"{kind}:{request_id}:{at}",
                    "kind": kind,
                    "createdAt": at,
                    "text": text,
                    "requestId": request_id,
                }
            )

    def _comment_notifications(self, actor, add):
        """Curtidas e respostas nos meus comentarios (dos ultimos que fiz)."""
        me = actor.subject
        by_post = {}
        for sk, ref in self._list("identity", "USER#" + me, "COMMENTREF#", 100):
            keys = ref.get("sharedKeys") or []
            row = self.store.get(tuple(keys[0])) if keys else None
            if row:
                by_post.setdefault(row["postId"], []).append(row)
        for post_id, mine in by_post.items():
            try:
                part = self._authorized_post(self.store.get, me, post_id)
            except Problem:
                continue
            likes = self._comment_likes(post_id)
            rows = [r for _, r in self._comment_rows(post_id)]
            for comment in mine:
                for who, at in likes.get(comment["id"], []):
                    if who != me:
                        add("comment_like", at, who, part, {"commentId": comment["id"]})
                if comment.get("parentId") or part["owner"] == me:
                    continue  # quem e dono da publicacao ja recebe aviso de cada comentario
                for reply in rows:
                    if reply.get("parentId") == comment["id"] and reply["author"] != me:
                        add(
                            "reply",
                            reply["createdAt"],
                            reply["author"],
                            part,
                            {"text": reply["text"][:140], "commentId": comment["id"]},
                        )

    def notifications(self, actor):
        self.identity.authorize(actor, admitted=True)
        from datetime import timedelta

        now = self.identity.clock()
        since = stamp(now - timedelta(days=self.NOTIFICATION_DAYS))
        state = self.store.get(("identity", "USER#" + actor.subject, "NOTIFSTATE")) or {}
        read_at = state.get("readAt", "")
        items = self._notification_items(actor, since, set(state.get("dismissed", [])))
        for item in items:
            item["unread"] = item["createdAt"] > read_at
        return {"items": items, "unreadCount": sum(1 for i in items if i["unread"])}

    def mark_notifications_read(self, actor, key):
        def work(read, write, account, now, replay):
            row_key = ("identity", "USER#" + actor.subject, "NOTIFSTATE")
            write(row_key, {**(read(row_key) or {}), "readAt": stamp(now)})
            return {"readAt": stamp(now)}, {}

        return self.identity.transact(actor, "markNotificationsRead", key, {}, work, admitted=True)

    MAX_DISMISSED = 300
    MAX_REPLIES = 20

    def dismiss_notification(self, actor, notification_id, key):
        """Apagar um aviso (deslizar na tela). Pedidos de amizade se resolvem aceitando ou recusando."""
        if notification_id.startswith("friend_request:"):
            raise Problem(422, "NOTIFICATION_NOT_DISMISSIBLE")

        def work(read, write, account, now, replay):
            row_key = ("identity", "USER#" + actor.subject, "NOTIFSTATE")
            row = read(row_key) or {}
            dismissed = [i for i in row.get("dismissed", []) if i != notification_id]
            dismissed.append(notification_id)
            write(row_key, {**row, "dismissed": dismissed[-self.MAX_DISMISSED :]})
            return {"id": notification_id, "dismissed": True}, {}

        return self.identity.transact(
            actor, "deleteMyNotification", key, {"id": notification_id}, work, admitted=True
        )

    MENTION = re.compile(r"(?<![\w@])@([A-Za-z0-9_]{3,30})")
    MAX_MENTIONS = 5

    def _mentions(self, read, text):
        """Pessoas marcadas com @usuario no texto: so contas ativas que existem, sem repetir e
        sem o proprio texto livre (guardamos id + usuario para a tela abrir o perfil)."""
        found, seen = [], set()
        for match in self.MENTION.finditer(text):
            name = match.group(1).lower()
            if name in seen:
                continue
            seen.add(name)
            claim = read(("identity", "USERNAME#" + name, "CLAIM"))
            profile = self._active_profile(read, claim["owner"]) if claim else None
            if profile:
                found.append({"id": profile["id"], "username": profile["username"]})
            if len(found) >= self.MAX_MENTIONS:
                break
        return found

    def comment(self, actor, post_id, key, text, parent_id=None):
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
            root = None
            if parent_id:
                parent_loc = read(("history", "COMMENT#" + parent_id, "LOC"))
                if not parent_loc or parent_loc["postId"] != post_id:
                    raise Problem(422, "INVALID_PARENT_COMMENT")
                parent = read(("history", "POST#" + post_id, parent_loc["sk"]))
                if not parent:
                    raise Problem(422, "INVALID_PARENT_COMMENT")
                # Um nivel so: responder a uma resposta vira resposta ao comentario principal.
                root = parent.get("parentId") or parent["id"]
                siblings = [r for _, r in self._comment_rows(post_id) if r.get("parentId") == root]
                if len(siblings) >= self.MAX_REPLIES:
                    raise Problem(422, "REPLY_LIMIT_REACHED")
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
            if root:
                row["parentId"] = root
            mentions = self._mentions(read, text)
            if mentions:
                row["mentions"] = mentions
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
            actor,
            "createPostComment",
            key,
            {"postId": post_id, "text": text, "parentId": parent_id},
            work,
            admitted=True,
        )

    def _comment_out(self, row, actor):
        viewer = actor if isinstance(actor, str) else actor.subject
        profile = self._active_profile(self.store.get, row["author"]) or {}
        return {
            "likeCount": 0,
            "likedByMe": False,
            **{k: v for k, v in row.items() if k != "author"},
            "author": self._card(profile, viewer) if profile else {"id": row["author"]},
        }

    def edit_comment(self, actor, comment_id, key, text, expected_version=None):
        """So o autor edita o proprio comentario (o dono da publicacao pode apagar, nao editar).
        Marca `edited`, sobe a versao e recalcula as pessoas marcadas."""
        text = text.strip()
        if not text or len(text) > 1000:
            raise Problem(422, "INVALID_COMMENT")

        def work(read, write, account, now, replay):
            loc = read(("history", "COMMENT#" + comment_id, "LOC"))
            if not loc or loc["author"] != actor.subject:
                raise Problem(404, "COMMENT_NOT_FOUND")
            row_key = ("history", "POST#" + loc["postId"], loc["sk"])
            row = read(row_key)
            if not row:
                raise Problem(404, "COMMENT_NOT_FOUND")
            if replay is not None:  # mesmo pedido repetido: devolve o estado atual, sem reeditar
                return self._comment_out(row, actor), replay
            if expected_version is not None and row.get("version") != expected_version:
                raise Problem(409, "VERSION_CONFLICT")
            self._authorized_post(read, actor.subject, loc["postId"])
            new = {
                **row,
                "text": text,
                "edited": True,
                "editedAt": stamp(now),
                "version": row.get("version", 1) + 1,
            }
            mentions = self._mentions(read, text)
            if mentions:
                new["mentions"] = mentions
            else:
                new.pop("mentions", None)
            write(row_key, new)
            return self._comment_out(new, actor), {"id": comment_id}

        return self.identity.transact(
            actor,
            "editOwnComment",
            key,
            {"id": comment_id, "text": text, "expectedVersion": expected_version},
            work,
            admitted=True,
        )

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
            self._erase_comment(read, write, loc["postId"], comment_id, loc)
            # Apagar um comentario principal leva as respostas (no maximo MAX_REPLIES).
            for _, reply in self._comment_rows(loc["postId"]):
                if reply.get("parentId") == comment_id:
                    reply_loc = read(("history", "COMMENT#" + reply["id"], "LOC"))
                    if reply_loc:
                        self._erase_comment(read, write, loc["postId"], reply["id"], reply_loc)
            return {"id": comment_id, "deleted": True}, {}

        return self.identity.transact(
            actor, "deleteOwnComment", key, {"id": comment_id}, work, admitted=True
        )

    @staticmethod
    def _erase_comment(read, write, post_id, comment_id, loc):
        write(("history", "POST#" + post_id, loc["sk"]), None)
        write(("history", "COMMENT#" + comment_id, "LOC"), None)
        write(("identity", "USER#" + loc["author"], "COMMENTREF#" + comment_id), None)

    # ---- comentarios na corrida (qualquer pessoa admitida comenta; independe de participacao) ---------------

    # ---- feedback sobre o app ---------------------------------------------------------------
    FEEDBACK_QUEUE = "FEEDBACK#ALL"
    FEEDBACK_PER_DAY = 10

    def send_feedback(self, actor, key, kind, text, app_version=None):
        """Guarda um feedback sobre o app. So a equipe le (fila unica, mais recentes por ultimo na chave).
        A linha da fila entra em `sharedKeys` na particao da pessoa, para o apagamento da conta leva-la junto."""
        text = text.strip()
        if not text or len(text) > 2000:
            raise Problem(422, "INVALID_FEEDBACK")
        self.identity.authorize(actor, admitted=True)
        pk = "USER#" + actor.subject

        def work(read, write, account, now, replay):
            if replay is not None:
                return {"id": replay["id"], "received": True}, replay
            created = stamp(now)
            today = [sk for sk, _ in self._list("identity", pk, "FEEDBACKREF#" + created[:10])]
            if len(today) >= self.FEEDBACK_PER_DAY:
                raise Problem(429, "FEEDBACK_LIMIT_REACHED")
            feedback_id = str(uuid4())
            row_key = ("history", self.FEEDBACK_QUEUE, f"F#{created}#{feedback_id}")
            row = {
                "id": feedback_id,
                "author": actor.subject,
                "kind": kind,
                "text": text,
                "createdAt": created,
            }
            if app_version:
                row["appVersion"] = app_version
            write(row_key, row)
            write(
                ("identity", pk, f"FEEDBACKREF#{created}#{feedback_id}"),
                {"sharedKeys": [list(row_key)]},
            )
            return {"id": feedback_id, "received": True}, {"id": feedback_id}

        return self.identity.transact(
            actor,
            "sendFeedback",
            key,
            {"kind": kind, "text": text, "appVersion": app_version},
            work,
            admitted=True,
        )

    EDITION_COMMENT_MAX = 1000
    EDITION_COMMENTS_PER_PERSON = 10  # por corrida
    EDITION_COMMENT_SCAN = 500

    def _edition_comment_rows(self, edition_id):
        return self._list("history", "ECOMMENTS#" + edition_id, "C#", self.EDITION_COMMENT_SCAN)

    def _edition_commentable(self, edition_id):
        head = self.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
        if not head or head.get("publicationState") != "approved":
            raise Problem(404, "EDITION_NOT_FOUND")
        return head

    def _edition_comment_out(self, row, viewer):
        profile = self._active_profile(self.store.get, row["author"]) or {}
        return {
            "id": row["id"],
            "editionId": row["editionId"],
            "text": row["text"],
            "createdAt": row["createdAt"],
            "mine": row["author"] == viewer,
            "author": self._card(profile, viewer) if profile else {"id": row["author"]},
        }

    def edition_comment(self, actor, edition_id, key, text):
        """Comentario na corrida, visivel para quem esta na beta. Sem participacao, avaliacao ou nota: so texto."""
        text = " ".join(text.split()) if text else ""
        if not text or len(text) > self.EDITION_COMMENT_MAX or any(ord(c) < 32 for c in text):
            raise Problem(422, "INVALID_COMMENT")
        self.identity.authorize(actor, admitted=True)
        head = self._edition_commentable(edition_id)
        if head.get("archived"):
            raise Problem(409, "EDITION_ARCHIVED")

        def work(read, write, account, now, replay):
            if replay is not None:
                loc = read(("history", "ECOMMENT#" + replay["id"], "LOC"))
                row = loc and read(("history", "ECOMMENTS#" + edition_id, loc["sk"]))
                if not row:
                    raise Problem(404, "COMMENT_NOT_FOUND")
                return self._edition_comment_out(row, actor.subject), replay
            mine = [
                r for _, r in self._edition_comment_rows(edition_id) if r["author"] == actor.subject
            ]
            if len(mine) >= self.EDITION_COMMENTS_PER_PERSON:
                raise Problem(429, "COMMENT_LIMIT_REACHED")
            comment_id, created = str(uuid4()), stamp(now)
            sk = f"C#{created}#{comment_id}"
            row = {
                "id": comment_id,
                "editionId": edition_id,
                "author": actor.subject,
                "text": text,
                "createdAt": created,
            }
            row_key = ("history", "ECOMMENTS#" + edition_id, sk)
            loc_key = ("history", "ECOMMENT#" + comment_id, "LOC")
            write(row_key, row)
            write(loc_key, {"editionId": edition_id, "sk": sk, "author": actor.subject})
            write(
                ("identity", "USER#" + actor.subject, "ECOMMENTREF#" + comment_id),
                {"sharedKeys": [list(row_key), list(loc_key)]},
            )
            return self._edition_comment_out(row, actor.subject), {"id": comment_id}

        return self.identity.transact(
            actor,
            "createEditionComment",
            key,
            {"editionId": edition_id, "text": text},
            work,
            admitted=True,
        )

    def edition_comments(self, actor, edition_id, limit=20, cursor=None):
        """Mais recentes primeiro. `cursor` e a chave do ultimo item da pagina anterior."""
        self.identity.authorize(actor, admitted=True)
        self._edition_commentable(edition_id)
        rows = [r for _, r in self._edition_comment_rows(edition_id)]
        rows.sort(key=lambda r: (r["createdAt"], r["id"]), reverse=True)
        rows = [r for r in rows if self._active_profile(self.store.get, r["author"])]
        if cursor:
            before = _cursor_decode(cursor)
            rows = [r for r in rows if (r["createdAt"], r["id"]) < tuple(before)]
        page = rows[:limit]
        result = {"items": [self._edition_comment_out(r, actor.subject) for r in page]}
        if len(rows) > limit and page:
            result["nextCursor"] = _cursor_encode([page[-1]["createdAt"], page[-1]["id"]])
        return result

    def delete_edition_comment(self, actor, comment_id, key):
        """So o autor apaga o proprio comentario (a equipe remove pelo portal, com outro caminho)."""

        def work(read, write, account, now, replay):
            loc = read(("history", "ECOMMENT#" + comment_id, "LOC"))
            if not loc:
                if replay is not None:
                    return {"id": comment_id, "deleted": True}, replay
                raise Problem(404, "COMMENT_NOT_FOUND")
            if loc["author"] != actor.subject:
                raise Problem(404, "COMMENT_NOT_FOUND")  # de outra pessoa = mesma resposta
            self._erase_edition_comment(write, comment_id, loc)
            return {"id": comment_id, "deleted": True}, {"id": comment_id}

        return self.identity.transact(
            actor, "deleteEditionComment", key, {"id": comment_id}, work, admitted=True
        )

    @staticmethod
    def _erase_edition_comment(write, comment_id, loc):
        write(("history", "ECOMMENTS#" + loc["editionId"], loc["sk"]), None)
        write(("history", "ECOMMENT#" + comment_id, "LOC"), None)
        write(("identity", "USER#" + loc["author"], "ECOMMENTREF#" + comment_id), None)


def remove_edition_comment_as_team(store, comment_id):
    """Remocao pela equipe (portal): sem checar o autor. Devolve a corrida e o autor, para a auditoria."""
    loc_key = ("history", "ECOMMENT#" + comment_id, "LOC")
    loc = store.get(loc_key)
    if not loc:
        raise Problem(404, "COMMENT_NOT_FOUND")
    keys = {
        ("history", "ECOMMENTS#" + loc["editionId"], loc["sk"]): None,
        loc_key: None,
        ("identity", "USER#" + loc["author"], "ECOMMENTREF#" + comment_id): None,
    }
    store.commit({k: store.get(k) for k in keys}, keys)
    return {"id": comment_id, "editionId": loc["editionId"], "author": loc["author"]}


def list_edition_comments_for_team(store, edition_id, limit=100):
    """Comentarios da corrida para a equipe conferir (mais recentes primeiro), com o id de quem escreveu."""
    rows, after = [], None
    while len(rows) < limit:
        page, after = store.query(
            "history", "ECOMMENTS#" + edition_id, prefix="C#", after=after, limit=100
        )
        rows.extend(r for _, r in page)
        if after is None:
            break
    rows.sort(key=lambda r: (r["createdAt"], r["id"]), reverse=True)
    return [
        {k: r[k] for k in ("id", "editionId", "author", "text", "createdAt")} for r in rows[:limit]
    ]


def list_feedback_for_team(store, limit=100):
    """Feedbacks sobre o app para a equipe ler, do mais novo para o mais antigo, com quem enviou."""
    rows, after = [], None
    while len(rows) < 1000:
        page, after = store.query(
            "history", SocialService.FEEDBACK_QUEUE, prefix="F#", after=after, limit=100
        )
        rows.extend(r for _, r in page)
        if after is None:
            break
    rows.sort(key=lambda r: (r["createdAt"], r["id"]), reverse=True)
    items = []
    for row in rows[:limit]:
        profile = store.get(("identity", "USER#" + row["author"], "PROFILE")) or {}
        items.append(
            {
                **{
                    k: row[k] for k in ("id", "kind", "text", "createdAt", "appVersion") if k in row
                },
                "authorName": profile.get("displayName") or "Corredor RunPass",
                "authorUsername": profile.get("username"),
            }
        )
    return items


__all__ = ["SocialService", "Unavailable"]
