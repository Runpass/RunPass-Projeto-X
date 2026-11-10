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
        review = self.store.get(("history", "USER#" + part["owner"], "P#" + part["id"] + "#REVIEW"))
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
        return post

    def _authorized_post(self, read, viewer, post_id):
        """`viewer` is kept in the signature even though posts are always public (same shape
        as before, and the parameter documents intent at call sites)."""
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
                    if k in ("distanceId", "completedAt", "timeSeconds", "placement")
                },
            }
            for part, profile in page
        ]
        result = {"items": items, "total": len(done)}
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
        sums = {c: sum(r["ratings"][c] for r in reviews) for c in self.CRITERIA}
        total = sum(sums.values())
        liked = sum(
            1
            for r in reviews
            if sum(r["ratings"][c] for c in self.CRITERIA) / 8 >= self.RECOMMEND_FROM
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
        mine = [p for p in self._completed(me) if p.get("publishToFeed")]
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
        # Pedidos de amizade sempre primeiro (e nunca saem por idade ou limite); o resto, novo primeiro.
        items = [i for i in items if i["id"] not in dismissed]
        items.sort(key=lambda i: i["createdAt"], reverse=True)
        requests = [i for i in items if i["kind"] == "friend_request"]
        others = [i for i in items if i["kind"] != "friend_request"]
        return requests + others[: self.NOTIFICATION_LIMIT]

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


__all__ = ["SocialService", "Unavailable"]
