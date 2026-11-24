import unittest
from datetime import datetime, timezone
from decimal import Decimal

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
        self.identity.admit(
            actor,
            "a-" + sub,
            {"birthDate": "1990-01-01", "declaresAdult": True, "gender": "undisclosed"},
        )
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
        if publish:
            # Espelha o ponteiro que ParticipationService.complete() grava de verdade, para que
            # o feed "Todos" (social.py:_public_feed) enxergue estas publicações sintéticas.
            feed_key = ("history", "FEED#PUBLIC", f"T#{at}#{pid}")
            rows[feed_key] = {"owner": actor.subject, "id": pid, "completedAt": at}
            rows[("history", pk, "FEEDREF#" + pid)] = {"sharedKeys": [list(feed_key)]}
        self.store.commit({k: None for k in rows}, rows)

    def private(self, actor):
        profile = self.identity.profile(actor)
        self.identity.patch_profile(
            actor,
            "priv-" + actor.subject,
            {"expectedVersion": profile["version"], "isPrivate": True},
        )

    def test_post_view_flags_its_own_photo_and_prefers_the_text_written_when_publishing(self):
        self.complete(self.ana, "pf1", "2026-11-05T10:00:00Z", comment="avaliacao da corrida")
        part_key = ("history", "USER#ana", "P#pf1#PART")
        post = self.social.post(self.bia, "pf1")
        self.assertNotIn("hasPostImage", post)  # sem foto propria, vale a da medalha
        self.assertEqual(post["comment"], "avaliacao da corrida")
        part = self.store.get(part_key)
        self.store.commit(
            {part_key: part},
            {part_key: {**part, "postImageReference": "img_" + "a" * 64, "postText": "Que dia!"}},
        )
        post = self.social.post(self.bia, "pf1")
        self.assertTrue(post["hasPostImage"])
        self.assertEqual(
            post["comment"], "Que dia!"
        )  # o texto do post vale mais que o da avaliacao

    # ---- suggestions ----
    def test_suggestions_without_query_exclude_self_and_people_already_followed(self):
        names = lambda a: sorted(p["username"] for p in self.social.suggestions(a)["items"])  # noqa: E731
        self.assertEqual(names(self.bia), ["ana_runs", "caio"])
        self.social.follow(self.bia, "ana", "s1")
        self.assertEqual(names(self.bia), ["caio"])

    def test_suggestions_never_query_with_an_empty_prefix(self):
        # O DynamoDB recusa begins_with com texto vazio; o MemoryStore aceitaria.
        real = self.store.query

        def strict(table, pk, **kw):
            if kw.get("prefix") == "":
                raise AssertionError("begins_with vazio")
            return real(table, pk, **kw)

        self.store.query = strict
        self.assertTrue(self.social.suggestions(self.bia)["items"])

    def test_suggestions_find_profiles_in_any_index_partition(self):
        self.person("zeca", "Zeca Quintanilha", "zq_runs")
        found = [p["username"] for p in self.social.suggestions(self.bia)["items"]]
        self.assertIn("zq_runs", found)

    def test_suggestions_prefer_people_followed_by_the_ones_i_follow(self):
        self.social.follow(self.bia, "ana", "s2")
        self.social.follow(self.ana, "caio", "s3")
        first = self.social.suggestions(self.bia)["items"][0]
        self.assertEqual(first["username"], "caio")

    def befriend(self, a, b, key):
        self.social.add_friend(a, b.subject, "fa-" + key)
        self.social.decide_friend(b, a.subject, True, "fd-" + key)

    def test_suggestions_put_friends_of_friends_first_and_tell_how_many_in_common(self):
        dani = self.person("dani", "Daniela Rocha", "dani_r")
        edu = self.person("edu", "Eduardo Reis", "edu_r")
        self.befriend(self.bia, self.ana, "1")
        self.befriend(self.bia, dani, "2")
        self.befriend(self.ana, self.caio, "3")
        self.befriend(dani, self.caio, "4")
        self.befriend(dani, edu, "5")
        items = self.social.suggestions(self.bia)["items"]
        self.assertEqual([p["username"] for p in items[:2]], ["caio", "edu_r"])
        self.assertEqual(items[0]["mutualFriends"], 2)  # amigo da Ana e da Dani
        self.assertEqual(items[1]["mutualFriends"], 1)

    def test_suggestions_and_search_prefer_people_nearby(self):
        here = {
            "city": "Campinas",
            "state": "SP",
            "latitude": Decimal("-22.9"),
            "longitude": Decimal("-47.06"),
        }
        far = {
            "city": "Recife",
            "state": "PE",
            "latitude": Decimal("-8.05"),
            "longitude": Decimal("-34.9"),
        }
        self.identity.patch_profile(self.bia, "u-bia", {**here, "expectedVersion": 1})
        self.person("anna", "Ana Longe", "ana_longe")
        self.identity.patch_profile(
            Principal("anna", True), "u-anna", {**far, "expectedVersion": 1}
        )
        self.identity.patch_profile(self.ana, "u-ana", {**here, "expectedVersion": 1})
        found = self.social.search(self.bia, "ana")["items"]
        self.assertEqual([p["username"] for p in found], ["ana_runs", "ana_longe"])
        self.assertTrue(found[0]["nearby"])
        self.assertNotIn("nearby", found[1])
        first = self.social.suggestions(self.bia)["items"][0]
        self.assertEqual(first["username"], "ana_runs")

    def test_search_puts_friends_of_friends_before_strangers(self):
        self.person("caio2", "Caio Alves", "caio_alves")
        self.befriend(self.bia, self.ana, "1")
        self.befriend(self.ana, self.caio, "2")
        found = [p["username"] for p in self.social.search(self.bia, "caio")["items"]]
        self.assertEqual(found, ["caio", "caio_alves"])

    # ---- feedback ----
    def test_feedback_is_stored_for_the_team_and_limited_per_day(self):
        from runpass.social import list_feedback_for_team

        out = self.social.send_feedback(
            self.bia, "f1", "suggestion", "  Quero ver o pace medio  ", "1.0"
        )
        self.assertTrue(out["received"])
        again = self.social.send_feedback(
            self.bia, "f1", "suggestion", "  Quero ver o pace medio  ", "1.0"
        )
        self.assertEqual(again["id"], out["id"])  # mesma chave: nao duplica
        self.social.send_feedback(self.ana, "f2", "problem", "A foto nao abriu")
        items = list_feedback_for_team(self.store)
        self.assertEqual(len(items), 2)
        mine = next(i for i in items if i["id"] == out["id"])
        self.assertEqual(mine["text"], "Quero ver o pace medio")
        self.assertEqual(mine["authorUsername"], "bia_lima")
        self.assertEqual(mine["appVersion"], "1.0")
        # A linha da fila fica registrada na particao da pessoa, para o apagamento da conta.
        refs = self.store.query("identity", "USER#bia", prefix="FEEDBACKREF#", limit=10)[0]
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0][1]["sharedKeys"][0][1], "FEEDBACK#ALL")
        for n in range(self.social.FEEDBACK_PER_DAY - 1):
            self.social.send_feedback(self.bia, f"more-{n}", "praise", f"Gostei {n}")
        with self.assertRaises(Problem) as error:
            self.social.send_feedback(self.bia, "over", "praise", "Mais um")
        self.assertEqual(error.exception.code, "FEEDBACK_LIMIT_REACHED")

    # ---- bloquear e denunciar ----
    def test_block_hides_both_ways_ends_relations_and_can_be_undone(self):
        self.complete(self.ana, "b1", "2026-11-05T10:00:00Z")
        self.complete(self.bia, "b2", "2026-11-05T11:00:00Z")
        self.befriend(self.bia, self.ana, "bf")
        self.social.follow(self.bia, "ana", "bfol")
        comment = self.social.comment(self.ana, "b2", "bc", "oi bia")
        self.assertEqual(len(self.social.comments(self.bia, "b2")["items"]), 1)

        self.social.block(self.bia, "ana", "blk")
        self.social.block(self.bia, "ana", "blk2")  # repetir nao quebra

        feed_ids = [p["id"] for p in self.social.feed(self.bia)["items"]]
        self.assertNotIn("b1", feed_ids)
        self.assertEqual(
            [p["id"] for p in self.social.feed(self.ana)["items"]].count("b2"), 0
        )  # nos dois sentidos
        self.assertEqual(self.social.comments(self.bia, "b2")["items"], [])
        self.assertEqual(comment["author"]["id"], "ana")
        for who, other in ((self.bia, "ana"), (self.ana, "bia")):
            with self.assertRaises(Problem) as error:
                self.social.profile_view(who, other)
            self.assertEqual(error.exception.code, "PROFILE_NOT_FOUND")
        with self.assertRaises(Problem):
            self.social.post(self.bia, "b1")
        with self.assertRaises(Problem):
            self.social.like(self.bia, "b1", "blike")
        with self.assertRaises(Problem):
            self.social.follow(self.ana, "bia", "again")
        with self.assertRaises(Problem):
            self.social.add_friend(self.ana, "bia", "again2")
        self.assertNotIn(
            "ana_runs", [p["username"] for p in self.social.search(self.bia, "ana")["items"]]
        )
        self.assertEqual(
            [b["username"] for b in self.social.blocks(self.bia)["items"]], ["ana_runs"]
        )
        self.assertEqual(self.social.blocks(self.ana)["items"], [])
        # amizade e seguir acabaram nos dois lados
        self.assertIsNone(self.store.get(("identity", "USER#ana", "FRIEND#bia")))
        self.assertIsNone(self.store.get(("identity", "USER#bia", "FOLLOWING#ana")))

        self.social.unblock(self.bia, "ana", "unb")
        self.assertIn("b1", [p["id"] for p in self.social.feed(self.bia)["items"]])
        self.assertEqual(self.social.profile_view(self.bia, "ana")["username"], "ana_runs")

    def test_cannot_block_yourself_or_a_missing_profile(self):
        with self.assertRaises(Problem) as error:
            self.social.block(self.bia, "bia", "k1")
        self.assertEqual(error.exception.code, "CANNOT_BLOCK_SELF")
        with self.assertRaises(Problem) as error:
            self.social.block(self.bia, "ninguem", "k2")
        self.assertEqual(error.exception.code, "PROFILE_NOT_FOUND")

    def test_report_is_stored_for_the_team_with_reasons_and_a_daily_limit(self):
        from runpass.social import list_reports_for_team

        out = self.social.report(self.bia, "r1", "post", "b1", "offensive", "  texto ofensivo  ")
        again = self.social.report(self.bia, "r1", "post", "b1", "offensive", "  texto ofensivo  ")
        self.assertEqual(again["id"], out["id"])
        self.social.report(self.caio, "r2", "user", "ana", "spam")
        items = list_reports_for_team(self.store)
        self.assertEqual(len(items), 2)
        mine = next(i for i in items if i["id"] == out["id"])
        self.assertEqual(mine["text"], "texto ofensivo")
        self.assertEqual(mine["reporterUsername"], "bia_lima")
        user = next(i for i in items if i["targetType"] == "user")
        self.assertEqual(user["targetUsername"], "ana_runs")
        with self.assertRaises(Problem) as error:
            self.social.report(self.bia, "r3", "post", "b1", "inventado")
        self.assertEqual(error.exception.code, "INVALID_REPORT")
        for n in range(self.social.REPORT_PER_DAY - 1):
            self.social.report(self.bia, f"more-{n}", "post", f"p{n}", "spam")
        with self.assertRaises(Problem) as error:
            self.social.report(self.bia, "over", "post", "px", "spam")
        self.assertEqual(error.exception.code, "REPORT_LIMIT_REACHED")

    # ---- conta excluida: anonima no app, registrada para auditoria ----
    def test_deleted_account_is_anonymous_in_the_app_but_kept_for_audit(self):
        from runpass.social import list_deleted_accounts

        self.complete(self.bia, "d1", "2026-11-05T10:00:00Z")
        self.social.comment(self.ana, "d1", "dc", "oi")
        self.identity.delete_account(self.ana, "del-ana")
        ErasureProcessor(self.identity).run_pending()

        # No app: o comentario dela some e o perfil nao abre.
        self.assertEqual(self.social.comments(self.bia, "d1")["items"], [])
        with self.assertRaises(Problem):
            self.social.profile_view(self.bia, "ana")
        self.assertEqual(
            SocialService.removed_author("ana"),
            {"id": "ana", "displayName": "Usuário removido", "removed": True},
        )
        # No back: o registro de auditoria sobrevive a limpeza, so com o minimo.
        audit = list_deleted_accounts(self.store)
        self.assertEqual(len(audit), 1)
        self.assertEqual(audit[0]["subject"], "ana")
        self.assertEqual(audit[0]["username"], "ana_runs")
        self.assertEqual(audit[0]["displayName"], "Ana Paula Souza")
        self.assertTrue(audit[0]["deletedAt"])
        tomb = self.store.get(("identity", "DELETEDUSER#ana", "TOMBSTONE"))
        self.assertEqual(
            sorted(k for k in tomb if k != "_rev"),
            ["deletedAt", "displayName", "operationId", "subject", "username"],
        )

    # ---- desempenho: idas ao banco ----
    def reads(self):
        """Liga um registro das chaves lidas uma a uma no banco de verdade (por baixo da memoria de leituras)."""
        seen = []
        real = self.store.get
        self.store.get = lambda key: (seen.append(key), real(key))[1]
        self.addCleanup(setattr, self.store, "get", real)
        return seen

    def test_feed_reads_only_the_posts_it_returns_not_every_post(self):
        for n in range(60):
            self.complete(
                self.ana if n % 2 else self.caio,
                f"p{n:02d}",
                f"2026-10-{n % 28 + 1:02d}T10:{n:02d}:00Z",
            )
        expected = [p["id"] for p in self.social.feed(self.bia, limit=5)["items"]]
        seen = self.reads()
        page = self.social.feed(self.bia, limit=5)
        self.assertEqual([p["id"] for p in page["items"]], expected)
        self.assertEqual(len(page["items"]), 5)
        self.assertIn("nextCursor", page)
        parts = {k for k in seen if k[2].endswith("#PART")}
        # Antes lia as 60 participacoes para devolver 5; agora so o primeiro lote (pagina + folga).
        self.assertLessEqual(len(parts), 12)
        # E cada item e lido uma vez so, mesmo com o mesmo autor em varias publicacoes.
        self.assertEqual(len(seen), len(set(seen)))

    def test_feed_pages_cover_every_post_once_in_order(self):
        for n in range(23):
            self.complete(self.ana, f"q{n:02d}", f"2026-10-{n + 1:02d}T10:00:00Z")
        ids, cursor = [], None
        for _ in range(10):
            page = self.social.feed(self.bia, limit=5, cursor=cursor)
            ids += [p["id"] for p in page["items"]]
            cursor = page.get("nextCursor")
            if not cursor:
                break
        self.assertEqual(ids, [f"q{n:02d}" for n in range(22, -1, -1)])

    def test_read_scope_reads_each_item_once_and_only_inside_the_scope(self):
        store = self.social.store
        key = ("identity", "USER#ana", "PROFILE")
        seen = self.reads()
        store.get(key)
        store.get(key)
        self.assertEqual(len(seen), 2)  # fora do scope: sempre o banco
        del seen[:]
        with store.scope():
            first = store.get(key)
            first["displayName"] = "mexido"  # quem recebe pode alterar: a memoria nao muda
            self.assertEqual(store.get(key)["displayName"], "Ana Paula Souza")
            store.warm([key, ("identity", "USER#bia", "PROFILE")])
            store.get(("identity", "USER#bia", "PROFILE"))
            self.assertEqual(len(seen), 2)  # ana e bia, uma vez cada
        store.get(key)
        self.assertEqual(len(seen), 3)  # saiu do scope: volta a ler

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

    def test_notifications_cover_friend_requests_follows_likes_comments_and_followed_posts(self):
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-05T10:00:00Z")
        self.social.follow(self.bia, "ana", "f1")
        self.social.add_friend(self.bia, "ana", "a1")
        self.social.decide_friend(self.ana, "bia", True, "d1")
        self.social.add_friend(self.caio, "ana", "a2")
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
                ("friend", "bia_lima"),
                ("friend_request", "caio"),
                ("like", "bia_lima"),
                ("post", "bia_lima"),
            ],
        )
        self.assertEqual(mine["unreadCount"], 6)
        self.social.mark_notifications_read(self.ana, "r1")
        self.assertEqual(self.social.notifications(self.ana)["unreadCount"], 0)
        self.assertEqual(self.social.notifications(self.caio)["items"], [])

    def test_friends_count_is_always_public_like_followers_and_following(self):
        self.private(self.ana)
        self.assertEqual(self.social.profile_view(self.bia, "ana")["friendsCount"], 0)
        self.social.add_friend(self.bia, "ana", "f1")
        self.social.decide_friend(self.ana, "bia", True, "d1")
        self.assertEqual(self.social.profile_view(self.caio, "ana")["friendsCount"], 1)
        self.assertEqual(self.social.profile_view(self.caio, "bia")["friendsCount"], 1)

    # ---- listas de amigos/seguidores/seguindo (toque nos numeros do Perfil) ----
    def test_followers_following_and_friends_lists_are_always_public_with_context(self):
        self.private(self.caio)
        self.social.follow(self.ana, "caio", "f1")
        self.social.follow(self.bia, "caio", "f2")
        self.social.add_friend(self.ana, "caio", "af1")
        self.social.decide_friend(self.caio, "ana", True, "d1")

        followers = self.social.list_followers(self.caio, "caio")["items"]
        self.assertEqual({p["username"] for p in followers}, {"ana_runs", "bia_lima"})
        # Do ponto de vista de quem pediu (caio), o followState de cada item reflete caio, nao
        # a propria pessoa listada: caio nao segue nenhum dos dois de volta ainda.
        self.assertEqual(
            {p["username"]: p["followState"] for p in followers},
            {"ana_runs": "none", "bia_lima": "none"},
        )

        following = self.social.list_following(self.bia, "ana")["items"]
        self.assertEqual([p["username"] for p in following], ["caio"])

        friends = self.social.list_friends(self.bia, "caio")["items"]
        self.assertEqual([p["username"] for p in friends], ["ana_runs"])
        self.assertEqual(friends[0]["friendState"], "none")

    def test_followers_following_and_friends_lists_paginate_and_reject_unknown_profile(self):
        self.social.follow(self.ana, "caio", "f1")
        self.social.follow(self.bia, "caio", "f2")
        page = self.social.list_followers(self.ana, "caio", limit=1)
        self.assertEqual(len(page["items"]), 1)
        self.assertIn("nextCursor", page)
        rest = self.social.list_followers(self.ana, "caio", limit=1, cursor=page["nextCursor"])
        self.assertEqual(len(rest["items"]), 1)
        self.assertNotIn("nextCursor", rest)
        self.assertNotEqual(page["items"][0]["id"], rest["items"][0]["id"])
        with self.assertRaises(Problem) as missing:
            self.social.list_followers(self.ana, "ghost")
        self.assertEqual(missing.exception.status, 404)

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

    def test_birth_date_never_appears_on_a_public_profile(self):
        # Decisao 06/11/2026: data de nascimento so em GET /me, nunca no cartao publico.
        self.assertEqual(self.identity.profile(self.ana)["birthDate"], "1990-01-01")
        self.assertNotIn("birthDate", self.social.profile_view(self.bia, "ana"))

    def test_cannot_follow_self_or_unknown(self):
        with self.assertRaises(Problem) as me:
            self.social.follow(self.ana, "ana", "f")
        self.assertEqual(me.exception.code, "CANNOT_FOLLOW_SELF")
        with self.assertRaises(Problem) as unknown:
            self.social.follow(self.ana, "ghost", "f2")
        self.assertEqual(unknown.exception.status, 404)

    def test_follow_never_needs_approval_even_for_a_private_profile(self):
        self.private(self.ana)
        self.assertEqual(self.social.follow(self.bia, "ana", "f1")["state"], "active")
        view = self.social.profile_view(self.bia, "ana")
        # Seguir nao desbloqueia perfil privado: so amizade aceita faz isso.
        self.assertEqual((view["followState"], view["canView"]), ("active", False))

    def test_private_profile_restricts_only_the_race_summary_not_the_post(self):
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z", comment="Foi lindo")
        self.assertEqual(self.social.add_friend(self.bia, "ana", "a1")["state"], "pending_out")
        hidden = self.social.profile_view(self.bia, "ana")
        self.assertEqual((hidden["friendState"], hidden["canView"]), ("pending_out", False))
        # Decisao de 08/11/2026: posts, seguidores e seguindo sao sempre publicos; so o resumo
        # de corridas (contagem e lista) fica atras da amizade.
        self.assertEqual((hidden["followersCount"], hidden["followingCount"]), (0, 0))
        self.assertNotIn("participationCount", hidden)
        self.assertEqual(self.social.post(self.bia, "p1")["comment"], "Foi lindo")
        with self.assertRaises(Problem):
            self.social.public_participations(self.bia, "ana")
        self.assertEqual(
            [r["profile"]["id"] for r in self.social.friend_requests(self.ana)["items"]], ["bia"]
        )
        self.social.decide_friend(self.ana, "bia", True, "d1")
        self.assertEqual(self.social.friend_requests(self.ana)["items"], [])
        after = self.social.profile_view(self.bia, "ana")
        self.assertEqual(after["friendState"], "friends")
        self.assertEqual(after["participationCount"], 1)
        self.assertEqual(
            [p["id"] for p in self.social.public_participations(self.bia, "ana")["items"]], ["p1"]
        )

    def test_decline_removes_the_friend_request_and_nobody_else_can_decide(self):
        self.private(self.ana)
        self.social.add_friend(self.bia, "ana", "f1")
        with self.assertRaises(Problem) as other:
            self.social.decide_friend(self.caio, "bia", True, "x")
        self.assertEqual(other.exception.status, 404)
        self.social.decide_friend(self.ana, "bia", False, "d1")
        self.assertEqual(self.social.profile_view(self.bia, "ana")["friendState"], "none")

    def test_a_mutual_friend_request_is_accepted_right_away(self):
        self.social.add_friend(self.caio, "ana", "f1")
        self.assertEqual(self.social.add_friend(self.ana, "caio", "f2")["state"], "friends")
        self.assertEqual(self.social.profile_view(self.ana, "caio")["friendState"], "friends")
        self.assertEqual(self.social.friend_requests(self.caio)["items"], [])

    # ---- feed ----
    def test_feed_scope_all_shows_public_posts_from_anyone_newest_first(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.complete(self.ana, "p2", "2026-11-03T10:00:00Z", publish=False)
        self.complete(self.bia, "p3", "2026-11-02T10:00:00Z")
        self.complete(self.caio, "p4", "2026-11-04T10:00:00Z")
        self.assertEqual([p["id"] for p in self.social.feed(self.ana)["items"]], ["p4", "p3", "p1"])
        page = self.social.feed(self.ana, limit=2)
        self.assertEqual([p["id"] for p in page["items"]], ["p4", "p3"])
        more = self.social.feed(self.ana, limit=2, cursor=page["nextCursor"])
        self.assertEqual([p["id"] for p in more["items"]], ["p1"])
        self.assertNotIn("nextCursor", more)
        # time is hidden from others unless the owner allows it
        self.assertNotIn("timeSeconds", page["items"][0]["participation"])

    def test_feed_scope_network_only_has_followed_posts_not_mine(self):
        # Decisao de 08/11/2026: "Seguindo" nao mostra minhas proprias publicacoes.
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.complete(self.bia, "p3", "2026-11-02T10:00:00Z")
        self.complete(self.caio, "p4", "2026-11-04T10:00:00Z")
        self.assertEqual(self.social.feed(self.ana, scope="network")["items"], [])
        self.social.follow(self.ana, "bia", "f")
        self.assertEqual(
            [p["id"] for p in self.social.feed(self.ana, scope="network")["items"]], ["p3"]
        )

    def test_feed_scope_friends_only_has_accepted_friends_posts_not_mine(self):
        # Decisao de 08/11/2026: "Amigos" nao mostra minhas proprias publicacoes.
        self.private(self.bia)
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.complete(self.bia, "p3", "2026-11-02T10:00:00Z")
        self.assertEqual(self.social.feed(self.ana, scope="friends")["items"], [])
        self.social.add_friend(self.ana, "bia", "f1")
        self.social.decide_friend(self.bia, "ana", True, "d1")
        self.assertEqual(
            [p["id"] for p in self.social.feed(self.ana, scope="friends")["items"]], ["p3"]
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

    def test_only_the_author_edits_a_comment_and_edits_are_marked(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        made = self.social.comment(self.bia, "p1", "c1", "Parabens!")
        self.assertEqual((made["version"], made["edited"]), (1, False))
        edited = self.social.edit_comment(self.bia, made["id"], "e1", "  Parabens, campea!  ")
        self.assertEqual(edited["text"], "Parabens, campea!")
        self.assertEqual((edited["version"], edited["edited"]), (2, True))
        self.assertIn("editedAt", edited)
        listed = self.social.comments(self.ana, "p1")["items"]
        self.assertEqual([c["text"] for c in listed], ["Parabens, campea!"])
        # O dono da publicacao pode apagar, mas nao editar o comentario dos outros.
        for outsider in (self.ana, self.caio):
            with self.assertRaises(Problem) as denied:
                self.social.edit_comment(outsider, made["id"], "x-" + outsider.subject, "hack")
            self.assertEqual(denied.exception.status, 404)
        with self.assertRaises(Problem) as stale:
            self.social.edit_comment(self.bia, made["id"], "e2", "outra", expected_version=1)
        self.assertEqual(stale.exception.code, "VERSION_CONFLICT")
        self.assertEqual(
            self.social.comments(self.ana, "p1")["items"][0]["text"], "Parabens, campea!"
        )
        # Repetir o mesmo pedido (mesma chave) devolve o mesmo resultado.
        again = self.social.edit_comment(self.bia, made["id"], "e1", "  Parabens, campea!  ")
        self.assertEqual(again["version"], 2)

    def test_mentions_tag_existing_active_people_only(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        made = self.social.comment(
            self.bia, "p1", "m1", "Oi @ana_runs e @caio, tambem @ana_runs e @naoexiste e a@b.com"
        )
        self.assertEqual(
            made["mentions"],
            [{"id": "ana", "username": "ana_runs"}, {"id": "caio", "username": "caio"}],
        )
        plain = self.social.comment(self.bia, "p1", "m2", "sem marcacao")
        self.assertNotIn("mentions", plain)
        # Editar recalcula as marcacoes (e remove quando nao ha mais nenhuma).
        edited = self.social.edit_comment(self.bia, made["id"], "m3", "agora so @CAIO")
        self.assertEqual(edited["mentions"], [{"id": "caio", "username": "caio"}])
        cleared = self.social.edit_comment(self.bia, made["id"], "m4", "ninguem")
        self.assertNotIn("mentions", cleared)
        listed = self.social.comments(self.ana, "p1")["items"]
        self.assertTrue(any(c.get("mentions") == [] or "mentions" not in c for c in listed))

    def test_private_post_can_still_be_commented_by_anyone(self):
        # Decisao de 08/11/2026: publicacoes sao sempre publicas, perfil privado ou nao.
        self.private(self.ana)
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        made = self.social.comment(self.bia, "p1", "c", "oi")
        self.assertEqual(
            [c["id"] for c in self.social.comments(self.bia, "p1")["items"]], [made["id"]]
        )

    def test_photo_rule_allows_owner_and_anyone_on_a_published_post(self):
        self.private(self.ana)
        part = {"publishToFeed": True}
        read = self.store.get
        self.assertTrue(self.social.may_view_photo(read, self.ana, "ana", part))
        # Sem amizade alguma: a foto do post continua visivel, pois publicacoes sao publicas.
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

    def test_banner_is_separate_from_photo_and_always_public(self):
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
        # Decisao de 08/11/2026: avatar e banner sao sempre publicos, mesmo sem amizade.
        self.assertIn("url", uploads.profile_photo(self.caio, "ana", "bannerReference"))
        current = self.identity.profile(self.ana)
        cleared = self.identity.patch_profile(
            self.ana, "b2", {"expectedVersion": current["version"], "bannerReference": None}
        )
        self.assertNotIn("bannerReference", cleared)
        self.assertEqual(self.store.get(("operations", "USER#ana", "IMAGE#ban1"))["refs"], 0)

    def test_friend_requests_stay_first_and_old_ones_never_expire(self):
        self.private(self.ana)
        self.social.add_friend(self.caio, "ana", "f1")
        # Pedido antigo (mais de 30 dias) continua aparecendo.
        row_key = ("identity", "USER#ana", "FRIEND#caio")
        row = self.store.get(row_key)
        self.store.commit({row_key: row}, {row_key: {**row, "at": "2026-01-01T00:00:00Z"}})
        self.complete(self.bia, "p2", "2026-11-06T09:00:00Z")
        self.social.follow(self.ana, "bia", "f2")
        items = self.social.notifications(self.ana)["items"]
        self.assertEqual([i["kind"] for i in items], ["friend_request", "post"])

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
        self.social.add_friend(self.caio, "bia", "f9")
        with self.assertRaises(Problem) as nope:
            self.social.dismiss_notification(self.bia, "friend_request:caio::x", "d2")
        self.assertEqual(nope.exception.code, "NOTIFICATION_NOT_DISMISSIBLE")
        # marcar como lido nao apaga a lista de apagados
        self.social.mark_notifications_read(self.ana, "r1")
        self.assertEqual(
            sorted(i["kind"] for i in self.social.notifications(self.ana)["items"]), ["follow"]
        )

    def test_profile_photo_needs_my_valid_image_and_is_always_public(self):
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
        # Decisao de 08/11/2026: avatar e sempre publico, mesmo sem amizade.
        self.assertIn("url", uploads.profile_photo(self.caio, "ana"))
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

    def test_erasing_the_post_owner_removes_the_public_feed_pointer(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        self.assertEqual([p["id"] for p in self.social.feed(self.bia)["items"]], ["p1"])
        self.identity.delete_account(self.ana, "del-ana")
        ErasureProcessor(self.identity).run_pending()
        self.assertEqual(self.social.feed(self.bia)["items"], [])
        self.assertIsNone(self.store.get(("history", "FEED#PUBLIC", "T#2026-11-01T10:00:00Z#p1")))

    # ---- curtir e responder comentarios ----
    def test_comment_likes_count_once(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        made = self.social.comment(self.bia, "p1", "c1", "Show")
        cid = made["id"]
        self.assertEqual(self.social.like_comment(self.caio, cid, "l1")["likedByMe"], True)
        self.social.like_comment(self.caio, cid, "l2")
        self.social.like_comment(self.ana, cid, "l3")
        top = self.social.comments(self.caio, "p1")["items"][0]
        self.assertEqual((top["likeCount"], top["likedByMe"]), (2, True))
        self.assertEqual(self.social.comments(self.bia, "p1")["items"][0]["likedByMe"], False)
        self.assertEqual(
            self.social.like_comment(self.caio, cid, "l4", liked=False)["likedByMe"], False
        )
        self.assertEqual(self.social.comments(self.caio, "p1")["items"][0]["likeCount"], 1)
        with self.assertRaises(Problem) as missing:
            self.social.like_comment(self.caio, "nao-existe", "l5")
        self.assertEqual(missing.exception.code, "COMMENT_NOT_FOUND")
        self.private(self.ana)
        # Decisao de 08/11/2026: perfil privado nao impede curtir comentario de um post publico.
        self.assertEqual(self.social.like_comment(self.caio, cid, "l6")["likedByMe"], True)

    def test_replies_nest_under_the_main_comment_and_go_with_it(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        root = self.social.comment(self.bia, "p1", "c1", "Principal")
        first = self.social.comment(self.caio, "p1", "c2", "Resposta 1", root["id"])
        # responder a uma resposta vira resposta ao principal
        second = self.social.comment(self.ana, "p1", "c3", "Resposta 2", first["id"])
        self.assertEqual((first["parentId"], second["parentId"]), (root["id"], root["id"]))
        page = self.social.comments(self.ana, "p1")
        self.assertEqual(len(page["items"]), 1)
        self.assertEqual(page["items"][0]["replyCount"], 2)
        self.assertEqual(
            sorted(r["text"] for r in page["items"][0]["replies"]), ["Resposta 1", "Resposta 2"]
        )
        with self.assertRaises(Problem) as bad:
            self.social.comment(self.caio, "p1", "c4", "x", "nao-existe")
        self.assertEqual(bad.exception.code, "INVALID_PARENT_COMMENT")
        self.complete(self.bia, "p2", "2026-11-02T10:00:00Z")
        with self.assertRaises(Problem):
            self.social.comment(self.caio, "p2", "c5", "x", root["id"])  # pai de outra publicacao
        self.social.delete_comment(self.bia, root["id"], "d1")
        self.assertEqual(self.social.comments(self.ana, "p1")["items"], [])
        self.assertEqual(self.social.post(self.ana, "p1")["commentCount"], 0)
        for made in (first, second):
            self.assertIsNone(self.store.get(("history", "COMMENT#" + made["id"], "LOC")))

    def test_reply_limit(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        root = self.social.comment(self.bia, "p1", "c0", "Principal")
        for n in range(self.social.MAX_REPLIES):
            self.social.comment(self.caio, "p1", f"r{n}", f"r{n}", root["id"])
        with self.assertRaises(Problem) as limit:
            self.social.comment(self.caio, "p1", "rx", "demais", root["id"])
        self.assertEqual(limit.exception.code, "REPLY_LIMIT_REACHED")

    def test_notifications_for_comment_likes_and_replies(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        root = self.social.comment(self.bia, "p1", "c1", "Meu comentario")
        self.social.like_comment(self.caio, root["id"], "l1")
        self.social.comment(self.caio, "p1", "c2", "Respondendo", root["id"])
        mine = self.social.notifications(self.bia)["items"]
        kinds = sorted((i["kind"], i["actor"]["username"]) for i in mine)
        self.assertEqual(kinds, [("comment_like", "caio"), ("reply", "caio")])
        # quem e dono da publicacao recebe aviso de comentario, nao duplica com "resposta"
        owner_kinds = sorted(i["kind"] for i in self.social.notifications(self.ana)["items"])
        self.assertEqual(owner_kinds, ["comment", "comment"])

    def test_erasing_a_commenter_removes_comment_likes_and_replies(self):
        self.complete(self.ana, "p1", "2026-11-01T10:00:00Z")
        root = self.social.comment(self.ana, "p1", "c1", "Principal")
        self.social.comment(self.bia, "p1", "c2", "Resposta", root["id"])
        self.social.like_comment(self.bia, root["id"], "l1")
        self.identity.delete_account(self.bia, "del-bia")
        ErasureProcessor(self.identity).run_pending()
        item = self.social.comments(self.ana, "p1")["items"][0]
        self.assertEqual((item["replyCount"], item["likeCount"]), (0, 0))


if __name__ == "__main__":
    unittest.main()
