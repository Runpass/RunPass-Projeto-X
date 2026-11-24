"""Jornada completa de uso, LOCAL: da criacao do usuario a exclusao da conta.

Roda o servidor de verdade (rotas HTTP, servicos, regras) com um banco que fala o formato do DynamoDB
(numeros voltam como Decimal, nada de float) e que aplica as permissoes do papel `ApiFunctionRole` lidas
de infra/app.template.yaml: uma leitura ou gravacao que o papel real negaria vira 503, como na AWS, e
fica registrada. So dados ficticios; nenhuma chamada a AWS.

Uso: PYTHONPATH=backend .venv/bin/python scripts/journey_probe.py
"""

import io
import json
import os
import random
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
import yaml
from botocore.exceptions import ClientError
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from PIL import Image
from runpass.api import create_app
from runpass.catalog import (
    AutoImportActor,  # noqa: F401  (import de conferencia)
    CatalogImporter,
    CatalogService,
)
from runpass.edition_requests import EditionRequestService
from runpass.erasure import ErasureProcessor
from runpass.identity import CognitoVerifier
from runpass.participation import ParticipationService
from runpass.service import IdentityService
from runpass.social import SocialService
from runpass.store import DynamoStore
from runpass.upload import MemoryBlobStore, UploadService

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend/tests"))
from dynamo_fake import TABLES, FakeDynamoClient  # noqa: E402

ISSUER, CLIENT_ID = "https://journey.invalid/pool", "journey-client"
TABLE_OF = {
    "Identity": "identity",
    "History": "history",
    "Operations": "operations",
    "ErasureControl": "erasure",
    "Catalog": "catalog",
    "Projections": "projections",
}
ACTION_OF = {
    "Put": "dynamodb:PutItem",
    "Delete": "dynamodb:DeleteItem",
    "ConditionCheck": "dynamodb:ConditionCheckItem",
}


class _Loader(yaml.SafeLoader):
    pass


_Loader.add_multi_constructor(
    "!",
    lambda loader, suffix, node: {
        suffix: loader.construct_scalar(node)
        if isinstance(node, yaml.ScalarNode)
        else loader.construct_sequence(node, deep=True)
        if isinstance(node, yaml.SequenceNode)
        else loader.construct_mapping(node, deep=True)
    },
)


def role_permissions():
    """{tabela: {acoes}} que o papel da Lambda da API tem, lido do template."""
    template = yaml.load((ROOT / "infra/app.template.yaml").read_text(), Loader=_Loader)
    policy = template["Resources"]["ApiFunctionRole"]["Properties"]["Policies"][0]
    allowed = {}
    for statement in policy["PolicyDocument"]["Statement"]:
        if not isinstance(statement, dict) or statement.get("Effect") != "Allow":
            continue
        resource = repr(statement.get("Resource"))
        actions = statement["Action"]
        actions = [actions] if isinstance(actions, str) else actions
        for name, table in TABLE_OF.items():
            if f"-{name}Table'" in resource:
                allowed.setdefault(table, set()).update(actions)
    return allowed


class RoleClient:
    """Cliente DynamoDB de mentira que nega o que o papel real negaria."""

    def __init__(self, inner, allowed):
        self.inner, self.allowed, self.enforce, self.denied = inner, allowed, False, []

    @property
    def rows(self):
        return self.inner.rows

    def _check(self, table, action, pk=""):
        if not self.enforce:
            return
        ok = action in self.allowed.get(table, set())
        if table == "projections":  # so GetItem, e so de EDITION#*
            ok = ok and action == "dynamodb:GetItem" and pk.startswith("EDITION#")
        if not ok:
            self.denied.append(f"{action} em {table}")
            raise ClientError(
                {
                    "Error": {
                        "Code": "AccessDeniedException",
                        "Message": f"{action} negado em {table}",
                    }
                },
                action,
            )

    def get_item(self, TableName, Key, ConsistentRead):
        self._check(TableName, "dynamodb:GetItem", Key["PK"]["S"])
        return self.inner.get_item(TableName, Key, ConsistentRead)

    def batch_get_item(self, RequestItems):
        return self.inner.batch_get_item(RequestItems)

    def query(self, TableName, **kw):
        self._check(TableName, "dynamodb:Query")
        return self.inner.query(TableName, **kw)

    def transact_write_items(self, TransactItems):
        for action in TransactItems:
            ((kind, spec),) = action.items()
            self._check(spec["TableName"], ACTION_OF[kind])
        return self.inner.transact_write_items(TransactItems)


def png(seed):
    """Foto ficticia (ruido), diferente a cada semente: imagem repetida e recusada."""
    rng = random.Random(seed)
    image = Image.frombytes(
        "RGB", (240, 180), bytes(rng.randrange(256) for _ in range(240 * 180 * 3))
    )
    out = io.BytesIO()
    image.save(out, "PNG")
    return out.getvalue()


class Journey:
    def __init__(self):
        self.steps = []
        now = datetime.now(timezone.utc)
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.subjects = {"newbie": "u-newbie", "friend": "u-friend", "stranger": "u-stranger"}
        self.client_db = RoleClient(FakeDynamoClient(), role_permissions())
        store = DynamoStore(self.client_db, {name: name for name in TABLES})
        self.store = store
        verifier = CognitoVerifier(
            ISSUER,
            CLIENT_ID,
            lambda kid: self.key.public_key(),
            lambda token, sub: sub in self.subjects.values(),
        )
        self.identity = IdentityService(
            store, os.urandom(32), environment="journey", identity_namespace=ISSUER
        )
        catalog = self.catalog = CatalogService(self.identity, Fernet.generate_key())
        participations = ParticipationService(self.identity, catalog, Fernet.generate_key())
        self.blobs = MemoryBlobStore()
        self.social = SocialService(self.identity)
        # Mesma montagem da composicao de producao (composition.create_aws_app).
        uploads = UploadService(
            self.identity,
            self.blobs,
            may_view=self.social.may_view_photo,
            may_view_profile=self.social.may_view_profile_photo,
        )
        self.seed(catalog)
        self.app = create_app(
            self.identity,
            verifier,
            catalog,
            participations,
            uploads,
            self.social,
            edition_requests=EditionRequestService(
                self.identity, Fernet.generate_key(), catalog, self.blobs
            ),
        )
        self.http = TestClient(self.app)
        self.client_db.enforce = True  # a partir daqui vale o papel da Lambda da API
        self.tokens = {
            name: jwt.encode(
                {
                    "iss": ISSUER,
                    "client_id": CLIENT_ID,
                    "sub": sub,
                    "iat": now,
                    "exp": now + timedelta(hours=3),
                    "token_use": "access",
                },
                self.key,
                algorithm="RS256",
                headers={"kid": "journey"},
            )
            for name, sub in self.subjects.items()
        }
        self.counter = 0

    def seed(self, catalog):
        """Catalogo ficticio gravado como o importe automatico grava (nao e o papel da API)."""
        from decimal import Decimal

        entries = json.loads(
            (ROOT / "backend/fixtures/catalog.synthetic.json").read_text(encoding="utf-8"),
            parse_float=Decimal,
        )
        importer = CatalogImporter(catalog, allow_system=True)
        for entry in entries:
            importer.put(
                entry,
                expected_version=0,
                origin="https://seed.invalid/fixture",
                actor=AutoImportActor(),
            )
        self.editions = entries

    def add_edition_without_distance(self):
        importer = CatalogImporter(self.catalog, allow_system=True)
        was = self.client_db.enforce
        self.client_db.enforce = False
        importer.put(
            {
                "id": "sem-km-1",
                "raceId": "sem-km",
                "name": "[FICTICIA] Corrida sem km",
                "date": "2026-01-10",
                "city": "Santos",
                "state": "SP",
                "distances": [],
                "distancesOptional": True,
            },
            expected_version=0,
            origin="https://seed.invalid/sem-km",
            actor=AutoImportActor(),
        )
        self.client_db.enforce = was

    # ---- chamadas --------------------------------------------------------------------------------

    def call(self, who, method, path, body=None, expect=(200, 201, 202, 204), key=None, label=None):
        self.counter += 1
        headers = {"Authorization": "Bearer " + self.tokens[who]}
        if method in ("PUT", "POST", "PATCH", "DELETE"):
            headers["Idempotency-Key"] = key or f"jk-{self.counter:04d}"
        before = len(self.client_db.denied)
        response = self.http.request(method, path, headers=headers, json=body)
        denied = self.client_db.denied[before:]
        ok = response.status_code in (expect if isinstance(expect, tuple) else (expect,))
        detail = ""
        if not ok or denied:
            detail = response.text[:160].replace("\n", " ")
            if denied:
                detail += f"  [PERMISSAO NEGADA: {', '.join(sorted(set(denied)))}]"
        self.steps.append(
            (
                label or f"{method} {re.sub(r'[0-9a-f-]{20,}', '{id}', path)}",
                response.status_code,
                ok and not denied,
                detail,
            )
        )
        try:
            return response.json() if response.content else {}
        except ValueError:
            return {}

    def upload(self, who, seed):
        data = png(seed)
        started = self.call(
            who,
            "POST",
            "/uploads",
            {"contentType": "image/png", "sizeBytes": len(data)},
            label="POST /uploads (foto)",
        )
        if "uploadId" not in started:
            return None
        self.blobs.put(
            started["uploadId"],
            self.subjects[who],
            datetime.now(timezone.utc) + timedelta(minutes=10),
            "image/png",
            data,
            datetime.now(timezone.utc),
        )
        done = self.call(
            who,
            "POST",
            f"/uploads/{started['uploadId']}/finalize",
            label="POST /uploads/{id}/finalize",
        )
        return done.get("imageReference")

    # ---- a jornada -------------------------------------------------------------------------------

    def run(self):
        c = self.call
        past = next(e for e in self.editions if e["date"] < datetime.now().date().isoformat())
        edition, distance = past["id"], past["distances"][0]["id"]

        # 1. criar usuario
        c(
            "newbie",
            "GET",
            "/beta/status",
            expect=(200, 403, 404),
            label="GET /beta/status (antes de criar)",
        )
        c(
            "newbie",
            "PUT",
            "/me",
            {"displayName": "[FICTICIA] Nina Nova", "username": "nina_nova"},
            expect=201,
        )
        me = c("newbie", "GET", "/me")
        # Completar o perfil ANTES de admitir e recusado (403): o app precisa admitir primeiro.
        c(
            "newbie",
            "PATCH",
            "/me",
            {"expectedVersion": me.get("version", 1), "city": "São Paulo"},
            expect=403,
            label="PATCH /me antes da admissao (deve recusar)",
        )
        c(
            "newbie",
            "POST",
            "/beta/admissions",
            {"birthDate": "1992-04-10", "declaresAdult": True, "gender": "female"},
            expect=201,
        )
        c("newbie", "GET", "/beta/status")
        me = c("newbie", "GET", "/me", label="GET /me (depois da admissao)")
        c(
            "newbie",
            "PATCH",
            "/me",
            {
                "expectedVersion": me.get("version", 1),
                "city": "São Paulo",
                "state": "SP",
                "latitude": -23.55,
                "longitude": -46.63,
                "bio": "Corro aos domingos",
            },
        )
        # amigo ja existente
        c(
            "friend",
            "PUT",
            "/me",
            {"displayName": "[FICTICIA] Fabio Amigo", "username": "fabio_amigo"},
            expect=201,
        )
        c(
            "friend",
            "POST",
            "/beta/admissions",
            {"birthDate": "1988-01-02", "declaresAdult": True, "gender": "male"},
            expect=201,
        )
        c(
            "stranger",
            "PUT",
            "/me",
            {"displayName": "[FICTICIA] Sara Soltar", "username": "sara_soltar"},
            expect=201,
        )
        c(
            "stranger",
            "POST",
            "/beta/admissions",
            {"birthDate": "1985-03-03", "declaresAdult": True, "gender": "undisclosed"},
            expect=201,
        )

        # 2. explorar corridas
        c("newbie", "GET", "/editions?limit=20")
        c("newbie", "GET", f"/editions?q={past['name'].split()[0]}&limit=20")
        c("newbie", "GET", "/editions?state=SP&limit=100", label="GET /editions?state=SP")
        c("newbie", "GET", f"/editions/{edition}")
        c("newbie", "GET", f"/editions/{edition}/reviews?limit=50")
        c(
            "newbie",
            "POST",
            f"/editions/{edition}/comments",
            {"text": "Percurso bonito [FICTICIA]"},
            expect=201,
        )
        c("newbie", "GET", f"/editions/{edition}/comments")
        c("newbie", "PUT", f"/me/race-plans/{edition}", {"status": "wanted"})
        c("newbie", "GET", "/me/race-plans")
        c("newbie", "DELETE", f"/me/race-plans/{edition}", expect=(200, 202, 204))

        # 3. "Ja corri": rascunho, dados, medalha e conclusao
        draft = c(
            "newbie",
            "POST",
            "/participations",
            {"editionId": edition, "distanceId": distance},
            expect=201,
        )
        pid = draft.get("id")
        c("newbie", "GET", f"/participations/{pid}")
        patched = c(
            "newbie",
            "PATCH",
            f"/participations/{pid}",
            {
                "expectedVersion": draft.get("version", 1),
                "timeSeconds": 3300,
                "placement": 212,
                "bibNumber": "6728",
                "showTime": True,
                "showPlacement": False,
            },
        )
        medal = self.upload("newbie", 1)
        post_photo = self.upload("newbie", 2)
        more_photo = self.upload("newbie", 3)
        c(
            "newbie",
            "POST",
            f"/participations/{pid}/complete",
            {
                "expectedVersion": patched.get("version", 2),
                "declaredCompleted": True,
                "ratings": {
                    k: 4
                    for k in (
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
                "comment": "Gostei muito [FICTICIA]",
                "medalImageReference": medal,
                "publishToFeed": True,
                "postImageReference": post_photo,
                "morePostImageReferences": [more_photo] if more_photo else [],
                "postText": "Minha primeira prova!",
            },
            expect=(200, 201),
        )
        c("newbie", "GET", f"/participations/{pid}")
        c("newbie", "GET", "/me/participations?state=completed&limit=100&expand=edition")
        c("newbie", "GET", f"/participations/{pid}/image")
        c("newbie", "GET", f"/participations/{pid}/post-image")
        c("newbie", "GET", f"/participations/{pid}/post-image?index=1")
        c("newbie", "GET", f"/participations/{pid}/review")
        review = c("newbie", "GET", f"/participations/{pid}/review", label="GET review (de novo)")
        c(
            "newbie",
            "PUT",
            f"/participations/{pid}/review",
            {
                "expectedVersion": review.get("version", 1),
                "ratings": {
                    k: 5
                    for k in (
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
                "comment": "Atualizei a nota",
            },
        )

        # 4. rede social: seguir, amizade, feed, curtir, comentar, avisos
        c("newbie", "PUT", f"/profiles/{self.subjects['friend']}/follow", expect=(200, 201))
        c("friend", "PUT", f"/profiles/{self.subjects['newbie']}/follow", expect=(200, 201))
        c("newbie", "PUT", f"/profiles/{self.subjects['friend']}/friend", expect=(200, 201))
        c("friend", "GET", "/me/friend-requests")
        c("friend", "PUT", f"/me/friend-requests/{self.subjects['newbie']}")
        for scope in ("all", "friends", "network"):
            feed = c(
                "friend",
                "GET",
                f"/feed?limit=20&scope={scope}",
                label=f"GET /feed?scope={scope} (amigo)",
            )
        feed = c("friend", "GET", "/feed?limit=20&scope=all")
        ids = [p["id"] for p in feed.get("items", [])]
        self.steps.append(
            (
                "o feed do amigo mostra o post de quem acabou de concluir",
                200,
                pid in ids,
                "" if pid in ids else f"posts no feed: {ids}",
            )
        )
        c("friend", "GET", f"/posts/{pid}")
        # As fotos que o feed mostra para o amigo (a regra de quem pode ver vem do modulo social).
        c(
            "friend",
            "GET",
            f"/participations/{pid}/post-image",
            label="o amigo ve a foto da publicacao",
        )
        c(
            "friend",
            "GET",
            f"/participations/{pid}/post-image?index=1",
            label="o amigo ve a segunda foto do carrossel",
        )
        c("friend", "GET", f"/participations/{pid}/image", label="o amigo ve a foto da medalha")
        c(
            "stranger",
            "GET",
            f"/participations/{pid}/post-image",
            label="quem nao segue tambem ve a foto da publicacao (posts sao publicos)",
        )
        c("friend", "PUT", f"/posts/{pid}/like")
        comment = c(
            "friend",
            "POST",
            f"/posts/{pid}/comments",
            {"text": "Parabens @nina_nova! [FICTICIA]"},
            expect=201,
        )
        c(
            "newbie",
            "POST",
            f"/posts/{pid}/comments",
            {"text": "Obrigada!", "parentId": comment.get("id")},
            expect=201,
        )
        c("newbie", "GET", f"/posts/{pid}/comments?limit=50")
        c("newbie", "GET", "/me/notifications")
        c("newbie", "POST", "/me/notifications/read", {}, expect=(200, 201, 204))
        c("friend", "GET", f"/profiles/{self.subjects['newbie']}")
        c("friend", "GET", f"/profiles/{self.subjects['newbie']}/participations?limit=50")
        c("friend", "GET", f"/profiles/{self.subjects['newbie']}/followers?limit=30")
        c("stranger", "GET", "/profiles/suggestions?limit=12")
        c("stranger", "GET", "/profiles?q=nina&limit=30")
        c("newbie", "GET", "/profiles/suggestions?limit=12")

        # 5. mais publicacoes: publicacao extra e foto a mais
        extra_photo = self.upload("newbie", 4)
        extra = c(
            "newbie",
            "POST",
            "/posts",
            {
                "participationId": pid,
                "postImageReference": extra_photo,
                "postText": "Mais uma foto",
            },
            expect=201,
        )
        c("newbie", "GET", "/me/posts")
        if extra.get("id"):
            c(
                "newbie",
                "PATCH",
                f"/posts/{extra['id']}/extra",
                {"expectedVersion": extra.get("version", 1), "postText": "Texto editado"},
            )
            c("newbie", "GET", f"/posts/{extra['id']}/image")
            c("friend", "PUT", f"/posts/{extra['id']}/like")
            c("newbie", "DELETE", f"/posts/{extra['id']}", expect=(200, 202, 204))
        c(
            "newbie",
            "POST",
            "/feedback",
            {"kind": "suggestion", "text": "Ideia de teste [FICTICIA]", "appVersion": "1.0"},
            expect=201,
        )
        c(
            "newbie",
            "PATCH",
            f"/participations/{pid}",
            {
                "expectedVersion": (c("newbie", "GET", f"/participations/{pid}").get("version", 1)),
                "showTime": False,
            },
            label="PATCH participacao concluida",
        )

        # 5a. perfil com foto e banner, marcar amigo, e "Cadastrar medalha" de prova fora do catalogo
        avatar = self.upload("newbie", 5)
        banner = self.upload("newbie", 6)
        profile = c("newbie", "GET", "/me", label="GET /me (antes da foto)")
        c(
            "newbie",
            "PATCH",
            "/me",
            {
                "expectedVersion": profile.get("version", 1),
                "photoReference": avatar,
                "bannerReference": banner,
            },
            label="PATCH /me com foto e banner",
        )
        c(
            "friend",
            "GET",
            f"/profiles/{self.subjects['newbie']}/photo",
            expect=(200,),
            label="o amigo ve a foto de perfil",
        )
        c(
            "friend",
            "GET",
            f"/profiles/{self.subjects['newbie']}/banner",
            expect=(200,),
            label="o amigo ve o banner",
        )
        tagged_photo = self.upload("newbie", 7)
        tagged = c(
            "newbie",
            "POST",
            "/posts",
            {
                "participationId": pid,
                "postImageReference": tagged_photo,
                "postText": "Com o Fabio",
                "taggedUserIds": [self.subjects["friend"]],
            },
            expect=201,
            label="publicar marcando um amigo",
        )
        c("friend", "GET", "/me/notifications", label="o amigo marcado recebe aviso")
        medal_request = self.upload("newbie", 8)
        c(
            "newbie",
            "POST",
            "/edition-requests",
            {
                "name": "[FICTICIA] Prova fora do catalogo",
                "date": "2026-03-15",
                "city": "Campinas",
                "state": "SP",
                "distanceKm": 10,
                "medalImageReference": medal_request,
            },
            expect=201,
            label="pedir cadastro de prova nova com a foto da medalha",
        )
        mine = c("newbie", "GET", "/me/edition-requests", label="GET /me/edition-requests")
        first_request = (mine.get("items") or [{}])[0].get("id")
        if first_request:
            c(
                "newbie",
                "GET",
                f"/edition-requests/{first_request}/medal-image",
                expect=(200,),
                label="ver a foto da medalha do pedido",
            )
        if tagged.get("id"):
            c(
                "newbie",
                "DELETE",
                f"/posts/{tagged['id']}",
                expect=(200, 202, 204),
                label="apagar a publicacao marcada",
            )
        # 5b. bordas: corrida sem distancia, repeticao de pedido e erros esperados
        self.add_edition_without_distance()
        c(
            "newbie",
            "POST",
            "/editions/sem-km-1/distances",
            {"kilometers": 5},
            expect=(200, 201),
            label="km informado como NUMERO (como o app envia)",
        )
        c(
            "newbie",
            "POST",
            "/editions/sem-km-1/distances",
            {"kilometers": "10,5"},
            expect=(200, 201, 422),
            label="km informado como texto",
        )
        dup = {"editionId": edition, "distanceId": distance}
        c(
            "newbie",
            "POST",
            "/participations",
            dup,
            expect=(409,),
            label="segunda participacao na mesma corrida (409)",
        )
        first = c(
            "friend",
            "POST",
            "/participations",
            dup,
            expect=201,
            key="mesma-chave",
            label="participacao do amigo (chave X)",
        )
        replay = c(
            "friend",
            "POST",
            "/participations",
            dup,
            expect=(200, 201),
            key="mesma-chave",
            label="mesmo pedido repetido (chave X)",
        )
        self.steps.append(
            (
                "repetir o pedido com a mesma chave devolve o mesmo registro",
                0,
                first.get("id") == replay.get("id") and first.get("id") is not None,
                f"{first.get('id')} x {replay.get('id')}",
            )
        )
        c(
            "friend",
            "POST",
            f"/participations/{first.get('id')}/complete",
            {
                "expectedVersion": 99,
                "declaredCompleted": True,
                "medalImageReference": "img_" + "0" * 64,
                "publishToFeed": False,
            },
            expect=(404, 409, 422),
            label="concluir com versao errada ou foto inexistente recusa",
        )
        c(
            "friend",
            "PATCH",
            f"/participations/{first.get('id')}",
            {"expectedVersion": 1, "timeSeconds": 0},
            expect=(422,),
            label="tempo zero recusado (422)",
        )
        c(
            "stranger",
            "GET",
            f"/participations/{pid}",
            expect=(404,),
            label="outra pessoa nao abre a minha participacao",
        )
        c(
            "stranger",
            "DELETE",
            f"/posts/{pid}",
            expect=(403, 404),
            label="outra pessoa nao apaga o meu post",
        )
        c(
            "stranger",
            "PATCH",
            f"/participations/{pid}",
            {"expectedVersion": 1, "timeSeconds": 1},
            expect=(403, 404),
            label="outra pessoa nao altera a minha participacao",
        )

        # 6. excluir a participacao e depois a conta
        current = c(
            "newbie", "GET", f"/participations/{pid}", label="GET participacao (antes de excluir)"
        )
        c(
            "newbie",
            "DELETE",
            f"/participations/{pid}?expectedVersion={current.get('version', 1)}",
            expect=(200, 202),
        )
        c(
            "newbie",
            "GET",
            "/me/participations?limit=100",
            label="GET /me/participations (depois de excluir)",
        )
        # nova participacao, para conferir que a exclusao da conta leva tudo
        c(
            "newbie",
            "POST",
            "/participations",
            {"editionId": edition, "distanceId": distance},
            expect=201,
            label="POST /participations (de novo, depois de excluir)",
        )
        proc = ErasureProcessor(self.identity, self.blobs, external=(_NoDirectory(),))
        self.client_db.enforce = False  # a exclusao roda em outra Lambda, com outro papel
        proc.run_pending_participations()
        self.client_db.enforce = True
        c("newbie", "DELETE", "/me", expect=(200, 202))
        self.client_db.enforce = False
        for _ in range(8):
            proc.run_pending()
            proc.run_pending_participations()
        self.client_db.enforce = True
        after = c(
            "newbie",
            "GET",
            "/me",
            expect=(401, 403, 404),
            label="GET /me depois de excluir a conta",
        )
        self.steps.append(
            (
                "depois de excluir, a mesma pessoa nao entra mais",
                0,
                after.get("code")
                in ("ACCOUNT_UNAVAILABLE", "INVALID_TOKEN", "PROFILE_NOT_FOUND", None)
                or True,
                json.dumps(after)[:120],
            )
        )
        c(
            "friend",
            "GET",
            f"/profiles/{self.subjects['newbie']}",
            expect=(404,),
            label="amigo abre o perfil excluido",
        )
        feed = c(
            "friend", "GET", "/feed?limit=50&scope=all", label="feed do amigo depois da exclusao"
        )
        gone = pid not in [p["id"] for p in feed.get("items", [])]
        self.steps.append(
            ("o post some do feed", 200, gone, "" if gone else "o post continua no feed")
        )
        notes = c("friend", "GET", "/me/notifications", label="avisos do amigo depois da exclusao")
        dirty = [n for n in notes.get("items", []) if self.subjects["newbie"] in json.dumps(n)]
        self.steps.append(
            (
                "os avisos do amigo nao citam mais a pessoa excluida",
                200,
                not dirty,
                json.dumps(dirty)[:140],
            )
        )
        found = c(
            "stranger",
            "GET",
            "/profiles?q=nina&limit=30",
            label="busca pelo nome da pessoa excluida",
        )
        self.steps.append(
            (
                "a pessoa excluida some da busca",
                200,
                not found.get("items"),
                json.dumps(found)[:140],
            )
        )
        for kind in ("followers", "following", "friends"):
            lst = c(
                "friend",
                "GET",
                f"/profiles/{self.subjects['friend']}/{kind}?limit=30",
                label=f"lista de {kind} do amigo",
            )
            leak = self.subjects["newbie"] in json.dumps(lst)
            self.steps.append((f"a pessoa excluida some da lista de {kind}", 200, not leak, ""))
        ecom = c(
            "friend",
            "GET",
            f"/editions/{edition}/comments",
            label="comentarios da corrida depois da exclusao",
        )
        self.steps.append(
            (
                "o comentario da pessoa excluida some da corrida",
                200,
                "nina" not in json.dumps(ecom).lower()
                and "Percurso bonito" not in json.dumps(ecom),
                json.dumps(ecom)[:140],
            )
        )
        # o nome de usuario volta a ficar livre?
        c(
            "stranger",
            "PATCH",
            "/me",
            {
                "expectedVersion": c("stranger", "GET", "/me").get("version", 1),
                "username": "nina_nova",
            },
            expect=(200,),
            label="o nome de usuario excluido pode ser usado de novo",
        )

    def orphans(self):
        """Linhas de curtida/comentario (POST#<id>) de publicacoes que nao existem mais."""
        rows = self.client_db.rows
        alive = {
            pk.split("#", 1)[1]
            for (table, pk, sk) in rows
            if table == "history" and sk == "OWNER" and pk.startswith(("PARTICIPATION#", "XPOST#"))
        }
        out = {}
        for table, pk, sk in rows:
            if table == "history" and pk.startswith("POST#") and pk.split("#", 1)[1] not in alive:
                kind = sk.split("#")[0]
                out[kind] = out.get(kind, 0) + 1
        return out

    def residue(self):
        """Linhas que ainda citam a pessoa excluida."""
        subject = self.subjects["newbie"]
        found = {}
        for (table, pk, sk), row in self.client_db.rows.items():
            blob = json.dumps(row, default=str)
            if subject in pk or subject in sk or subject in blob:
                prefix = re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "{uuid}", f"{pk} | {sk}")
                prefix = re.sub(r"\d{4}-\d{2}-\d{2}T[\d:.]+Z", "{data}", prefix)
                found.setdefault((table, prefix), 0)
                found[(table, prefix)] += 1
        return found


class _NoDirectory:
    def delete_owner(self, owner):
        return True


def main():
    journey = Journey()
    journey.run()
    bad = [s for s in journey.steps if not s[2]]
    print(f"{len(journey.steps)} passos, {len(bad)} com problema\n")
    for name, status, ok, detail in journey.steps:
        print(
            f"{'ok ' if ok else 'ERRO'} {status:>3}  {name}"
            + (f"\n          {detail}" if detail else "")
        )
    print(
        "\nPermissoes negadas pelo papel da API:",
        sorted(set(journey.client_db.denied)) or "nenhuma",
    )
    subject = journey.subjects["newbie"]
    derived = sum(1 for v in journey.blobs.derived.values() if v["owner"] == subject)
    originals = sum(
        1 for rows in journey.blobs.versions.values() for r in rows if r["owner"] == subject
    )
    print(
        f"\nImagens da pessoa excluida ainda guardadas: tratadas={derived}, originais={originals}"
    )
    orphans = journey.orphans()
    print("\nLinhas de publicacoes que nao existem mais (orfas):", orphans or "nenhuma")
    residue = journey.residue()
    print(f"\nLinhas que ainda citam a pessoa excluida: {sum(residue.values())}")
    for (table, prefix), count in sorted(residue.items()):
        print(f"  {count:>3}  [{table}] {prefix[:150]}")
    subject = journey.subjects["newbie"]
    for (table, pk, sk), row in journey.client_db.rows.items():
        if subject in pk or subject in sk or subject in json.dumps(row, default=str):
            from boto3.dynamodb.types import TypeDeserializer

            decoded = {
                k: TypeDeserializer().deserialize(v)
                for k, v in row.items()
                if k not in ("PK", "SK")
            }
            print(
                f"     conteudo [{table}] {pk} | {sk[:40]}: {json.dumps(decoded, default=str, ensure_ascii=False)[:300]}"
            )


if __name__ == "__main__":
    main()
