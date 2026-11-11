"""API do portal de administracao. Dados sinteticos; MemoryStore nao prova comportamento do DynamoDB."""

import hashlib
import io
import unittest
from datetime import datetime, timezone
from pathlib import Path

import jwt
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.admin_api import MfaPolicy, admit_operator, create_admin_app
from runpass.admin_banners import BannerAdmin
from runpass.admin_users import AdminUsers, CatalogRunner, CatalogSchedules, next_run
from runpass.catalog import CatalogService, seed_synthetic
from runpass.edition_requests import EditionRequestService
from runpass.identity import AuthFailure, Principal
from runpass.models import EditionRequestFields
from runpass.operator_admin import grant_access
from runpass.service import IdentityService
from runpass.store import MemoryStore, Unavailable
from runpass.upload import MemoryBlobStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 10, 15, tzinfo=timezone.utc)
ORIGIN = "https://portal.exemplo.invalid"


def token(sub="op", auth_age=60, exp_in=3000, now=NOW):
    t = int(now.timestamp())
    return jwt.encode(
        {
            "sub": sub,
            "iss": "https://cognito-idp.exemplo/pool",
            "client_id": "cid",
            "token_use": "access",
            "auth_time": t - auth_age,
            "iat": t - auth_age,
            "exp": t + exp_in,
        },
        "segredo-de-teste-com-32-bytes-ok!!",
        algorithm="HS256",
    )


class FakeCognito:
    def __init__(self, config):
        self.config, self.calls = config, 0

    def describe_user_pool(self, UserPoolId):
        self.calls += 1
        return {"UserPool": self.config}


class FakeUsers:
    """Cognito falso: pool dos corredores (so leitura) e pool de operadores (criar, listar, desativar, apagar)."""

    def __init__(self):
        self.created, self.exists, self.calls = [], False, []
        self.operators = {}  # email -> {"sub", "enabled"}

    def list_users(self, **args):
        if args["UserPoolId"] == "pool-op":
            return {
                "Users": [
                    {
                        "Username": o["sub"],
                        "UserStatus": "CONFIRMED",
                        "Enabled": o["enabled"],
                        "UserCreateDate": datetime(2026, 11, 1, tzinfo=timezone.utc),
                        "Attributes": [
                            {"Name": "sub", "Value": o["sub"]},
                            {"Name": "email", "Value": email},
                        ],
                    }
                    for email, o in self.operators.items()
                ]
            }
        self.args = args
        if args.get("PaginationToken") == "p2":
            return {"Users": [self.user("u3333333-x", "carlos@exemplo.invalid", "UNCONFIRMED", 3)]}
        return {
            "Users": [
                self.user("u1111111-x", "ana@exemplo.invalid", "CONFIRMED", 1),
                self.user("u2222222-x", "bia@exemplo.invalid", "CONFIRMED", 2),
            ],
            "PaginationToken": "p2",
        }

    @staticmethod
    def user(name, email, status, day):
        return {
            "Username": name,
            "UserStatus": status,
            "Enabled": True,
            "UserCreateDate": datetime(2026, 11, day, 12, tzinfo=timezone.utc),
            "Attributes": [{"Name": "email", "Value": email}],
        }

    def admin_create_user(self, **args):
        if self.exists or args["Username"] in self.operators:
            raise type("UsernameExistsException", (Exception,), {})()
        self.created.append(args)
        sub = f"novo-sub-{len(self.created)}"
        self.operators[args["Username"]] = {"sub": sub, "enabled": True}
        return {"User": {"Username": sub, "Attributes": [{"Name": "sub", "Value": sub}]}}

    def admin_disable_user(self, **args):
        self.calls.append(("disable", args["Username"]))
        self.operators[args["Username"]]["enabled"] = False

    def admin_enable_user(self, **args):
        self.calls.append(("enable", args["Username"]))
        self.operators[args["Username"]]["enabled"] = True

    def admin_user_global_sign_out(self, **args):
        self.calls.append(("signout", args["Username"]))

    def admin_delete_user(self, **args):
        self.calls.append(("delete", args["Username"]))
        del self.operators[args["Username"]]


class FakeLogs:
    def __init__(self):
        self.events, self.fail, self.args = [], False, None

    def filter_log_events(self, **args):
        if self.fail:
            raise RuntimeError("sem acesso")
        self.args = args
        return {"events": self.events}


class ConflictException(Exception):
    """Mesmo nome da excecao do boto3 (o codigo reconhece pelo nome da classe)."""


class ResourceNotFoundException(Exception):
    pass


class FakeScheduler:
    def __init__(self):
        self.fail = False
        self.created, self.updated, self.deleted = [], [], []
        self.items = {
            "runpass-dev-catalogo-enriquecimento-1": (
                "cron(30 7 ? * MON *)",
                "ENABLED",
                "Enriquecimento",
                '{"enriquecer": {"relatorio": "latest", "rodada": 1, "max": 25, "csv_semanal": "latest"}}',
            ),
            "runpass-dev-catalogo-calendario": (
                "cron(0 7 ? * MON *)",
                "ENABLED",
                "Calendario",
                '{"calendario": "https://prefeitura.sp.gov.br/web/esportes/w/corridas_de_rua/8722", "meses": 3}',
            ),
            "runpass-dev-catalogo-imagens": (
                "cron(30 9 ? * MON *)",
                "DISABLED",
                "Imagens",
                '{"imagens": {"csv": "latest"}}',
            ),
            "runpass-dev-catalogo-estranho": ("rate(1 day)", "ENABLED", "Rate", '{"outra": 1}'),
        }

    def list_schedules(self, **args):
        if self.fail:
            raise RuntimeError("negado")
        self.args = args
        prefix = args.get("NamePrefix", "")
        return {"Schedules": [{"Name": n} for n in self.items if n.startswith(prefix)]}

    def get_schedule(self, Name):
        if Name not in self.items:
            raise ResourceNotFoundException(Name)
        e, st, d, entry = self.items[Name]
        return {
            "Name": Name,
            "ScheduleExpression": e,
            "State": st,
            "Description": d,
            "ScheduleExpressionTimezone": "America/Sao_Paulo",
            "FlexibleTimeWindow": {"Mode": "OFF"},
            "Target": {
                "Arn": "arn:aws:lambda:sa-east-1:111122223333:function:runpass-dev-catalogo-semanal",
                "RoleArn": "arn:aws:iam::111122223333:role/runpass-dev-catalogo-semanal-SchedulerRole-X",
                "Input": entry,
                "RetryPolicy": {"MaximumRetryAttempts": 0},
            },
        }

    def create_schedule(self, **args):
        if self.fail:
            raise RuntimeError("negado")
        if args["Name"] in self.items:
            raise ConflictException(args["Name"])
        self.created.append(args)
        self.items[args["Name"]] = (
            args["ScheduleExpression"],
            args["State"],
            args["Description"],
            args["Target"]["Input"],
        )

    def update_schedule(self, **args):
        if self.fail:
            raise RuntimeError("negado")
        self.updated.append(args)
        self.items[args["Name"]] = (
            args["ScheduleExpression"],
            args["State"],
            args.get("Description", ""),
            args["Target"]["Input"],
        )

    def delete_schedule(self, Name):
        if self.fail:
            raise RuntimeError("negado")
        self.deleted.append(Name)
        del self.items[Name]


class FakeCosts:
    configured = True

    def __init__(self, value=None):
        self.value = value

    def report(self):
        if self.value is None:
            raise Unavailable()
        return self.value


class FakeS3:
    def __init__(self):
        self.objects = {}

    def list_objects_v2(self, **args):
        keys = [{"Key": k} for k in sorted(self.objects) if k.startswith(args["Prefix"])]
        return {"Contents": keys}

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key].encode())}


class FakeLambda:
    def __init__(self):
        self.calls, self.fail = [], False

    def invoke(self, **args):
        if self.fail:
            raise RuntimeError("boom")
        self.calls.append(args)


class AdminApiTests(unittest.TestCase):
    def setUp(self):
        self.identity = IdentityService(
            MemoryStore(), b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW
        )
        self.store = self.identity.store
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.requests = EditionRequestService(self.identity, Fernet.generate_key())
        self.mfa_on = True
        self.now = NOW.timestamp()
        self.cognito, self.lam, self.logs = FakeUsers(), FakeLambda(), FakeLogs()
        self.sched = FakeScheduler()
        self.s3, self.blobs = FakeS3(), MemoryBlobStore()
        self.pages = {}
        self.openai_org = FakeCosts({})
        self.openai_org.configured = False
        self.aws_costs, self.openai_costs = (
            FakeCosts({"totalUsd": 5}),
            FakeCosts({"month": "2026-11"}),
        )

        def verify(tok):
            try:
                claims = jwt.decode(tok, options={"verify_signature": False})
            except jwt.DecodeError as error:
                raise AuthFailure() from error
            audience = "runner" if claims["sub"] == "runner" else "operator"
            return Principal(
                claims["sub"], True, audience, hashlib.sha256(tok.encode()).hexdigest()
            )

        self.policy = type("P", (), {"enforced": lambda _: self.mfa_on})()
        self.portal_dir = ROOT / "portal"
        self.client = TestClient(
            create_admin_app(
                self.store,
                self.catalog,
                verify,
                self.policy,
                ORIGIN,
                clock=lambda: self.now,
                users=AdminUsers(
                    self.store, self.cognito, "pool-corredores", "pool-op", lambda: self.now
                ),
                runner=CatalogRunner(
                    self.store,
                    self.lam,
                    "runpass-dev-catalogo-semanal",
                    lambda: self.now,
                    self.logs,
                ),
                schedules=CatalogSchedules(
                    self.sched,
                    "runpass-dev-catalogo-semanal",
                    lambda: self.now,
                    "arn:aws:iam::111122223333:role/runpass-dev-catalogo-semanal-SchedulerRole-X",
                    "arn:aws:lambda:sa-east-1:111122223333:function:runpass-dev-catalogo-semanal",
                    self.store,
                ),
                banners=BannerAdmin(
                    self.store,
                    self.catalog,
                    self.blobs,
                    self.s3,
                    "relatorios",
                    lambda: self.now,
                    self.fetch,
                ),
                aws_costs=self.aws_costs,
                openai_usage=self.openai_costs,
                openai_org=self.openai_org,
                site={
                    "directory": self.portal_dir,
                    "region": "sa-east-1",
                    "client_id": "cliente-publico",
                },
            )
        )
        grant_access(self.store, "op", ["catalog_admin"], "outro", NOW)
        grant_access(self.store, "adm", ["user_admin"], "outro", NOW)
        grant_access(self.store, "fin", ["cost_read"], "outro", NOW)
        grant_access(self.store, "mod", ["moderation"], "outro", NOW)

    def fetch(self, url):
        """Transporte falso: so as paginas combinadas respondem."""
        return self.pages[url]

    def auth(self, tok=None):
        return {"Authorization": "Bearer " + (tok or token())}

    def make_request(self):
        person = Principal("ana", True)
        self.identity.create_profile(person, "p", {"displayName": "Ana", "username": "ana_x"})
        self.identity.admit(person, "a", {"birthDate": "1990-01-01", "declaresAdult": True})
        fields = EditionRequestFields(
            name="Night Run Sintética",
            date="2027-03-14",
            city="São Paulo",
            state="SP",
            distanceKm=10,
        )
        return self.requests.create(person, "k1", fields)

    def test_sem_token_ou_com_token_de_corredor_ou_sem_mfa_ou_antigo_nao_entra(self):
        for headers in ({}, {"Authorization": "Basic x"}, {"Authorization": "Bearer lixo"}):
            self.assertEqual(self.client.get("/admin/session", headers=headers).status_code, 401)
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("runner"))).status_code, 401
        )
        self.mfa_on = False
        self.assertEqual(self.client.get("/admin/session", headers=self.auth()).status_code, 401)
        self.mfa_on = True
        stale = token(auth_age=3601)
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(stale)).status_code, 401
        )
        future = token(auth_age=-600)
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(future)).status_code, 401
        )
        nobody = token("sem-acesso")
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(nobody)).status_code, 401
        )

    def test_acesso_revogado_deixa_de_valer(self):
        self.assertEqual(self.client.get("/admin/session", headers=self.auth()).status_code, 200)
        key = ("identity", "OPERATOR#op", "ACCESS")
        access = self.store.get(key)
        self.store.commit({key: access}, {key: {**access, "state": "revoked"}})
        self.assertEqual(self.client.get("/admin/session", headers=self.auth()).status_code, 401)

    def test_sessao_grava_o_registro_de_mfa_e_a_permissao_e_conferida_por_rota(self):
        ok = self.client.get("/admin/session", headers=self.auth())
        self.assertEqual(ok.json(), {"subject": "op", "permissions": ["catalog_admin"]})
        digest = hashlib.sha256(token().encode()).hexdigest()
        session = self.store.get(("operations", "OPERATOR#op", "SESSION#" + digest))
        self.assertEqual(session["factor"], "SOFTWARE_TOKEN_MFA")
        self.assertEqual(session["via"], "portal")
        # Permissao errada: autenticado, mas sem acesso a esta rota.
        forbidden = self.client.get("/admin/edition-requests", headers=self.auth(token("mod")))
        self.assertEqual(forbidden.status_code, 403)
        self.assertEqual(forbidden.json()["code"], "PERMISSION_REQUIRED")

    def test_lista_e_decide_pedido_de_corrida(self):
        request = self.make_request()
        listed = self.client.get("/admin/edition-requests", headers=self.auth()).json()["items"]
        self.assertEqual([i["id"] for i in listed], [request["id"]])
        body = {
            "expectedVersion": request["version"],
            "decision": "link",
            "editionId": "synthetic-sp-2026",
        }
        done = self.client.post(
            f"/admin/edition-requests/{request['id']}/decision", json=body, headers=self.auth()
        )
        self.assertEqual(done.status_code, 200)
        self.assertEqual(done.json()["status"], "linked")
        again = self.client.post(
            f"/admin/edition-requests/{request['id']}/decision", json=body, headers=self.auth()
        )
        self.assertEqual(again.status_code, 409)
        self.assertEqual(
            self.client.get("/admin/edition-requests", headers=self.auth()).json()["items"], []
        )

    def test_decisao_invalida_e_recusada_sem_ecoar_dados(self):
        request = self.make_request()
        bad = self.client.post(
            f"/admin/edition-requests/{request['id']}/decision",
            json={"expectedVersion": 1, "decision": "reject"},  # rejeitar exige motivo
            headers=self.auth(),
        )
        self.assertEqual(bad.status_code, 422)
        self.assertNotIn("Night Run", bad.text)
        missing = self.client.post(
            "/admin/edition-requests/nao-existe/decision",
            json={"expectedVersion": 1, "decision": "reject", "reason": "duplicada"},
            headers=self.auth(),
        )
        self.assertEqual(missing.status_code, 404)

    def test_busca_de_corridas_por_nome_para_vincular(self):
        found = self.client.get("/admin/editions?q=sintetica", headers=self.auth()).json()["items"]
        ids = [e["id"] for e in found]
        self.assertIn("synthetic-sp-2026", ids)
        self.assertNotIn("synthetic-archived", ids)  # arquivada nao e alvo de vinculo
        self.assertEqual(
            ids,
            sorted(ids, key=lambda i: next(e["date"] for e in found if e["id"] == i), reverse=True),
        )
        none = self.client.get("/admin/editions?q=zzzz", headers=self.auth()).json()["items"]
        self.assertEqual(none, [])

    def test_a_pagina_e_servida_pela_api_com_cabecalhos_de_seguranca_e_sem_login(self):
        home = self.client.get("/")
        self.assertEqual(home.status_code, 200)
        self.assertIn("text/html", home.headers["content-type"])
        self.assertIn("RunPass", home.text)
        csp = home.headers["content-security-policy"]
        self.assertIn("script-src 'self'", csp)
        self.assertIn("frame-ancestors 'none'", csp)
        self.assertIn("https://cognito-idp.sa-east-1.amazonaws.com", csp)
        self.assertNotIn("unsafe-inline", csp)
        self.assertEqual(home.headers["x-frame-options"], "DENY")
        self.assertEqual(home.headers["x-content-type-options"], "nosniff")
        self.assertIn("max-age=", home.headers["strict-transport-security"])
        for caminho, tipo in (
            ("/app.js", "javascript"),
            ("/lib.js", "javascript"),
            ("/cognito.js", "javascript"),
            ("/style.css", "css"),
        ):
            resposta = self.client.get(caminho)
            self.assertEqual(resposta.status_code, 200, caminho)
            self.assertIn(tipo, resposta.headers["content-type"])
        config = self.client.get("/config.js")
        self.assertEqual(config.status_code, 200)
        self.assertIn('"clientId": "cliente-publico"', config.text)
        self.assertIn('"apiUrl": ""', config.text)  # mesma origem: sem URL da API
        # Os cabecalhos tambem valem para as respostas da API (inclusive erros).
        erro = self.client.get("/admin/session")
        self.assertEqual(erro.status_code, 401)
        self.assertEqual(erro.headers["x-frame-options"], "DENY")

    def test_so_a_lista_fechada_de_arquivos_e_servida(self):
        for caminho in (
            "/config.py",
            "/../backend/runpass/admin_api.py",
            "/lib.test.js",
            "/config.example.js",
            "/%2e%2e/Makefile",
            "/portal/index.html",
        ):
            self.assertEqual(self.client.get(caminho).status_code, 404, caminho)
        # nenhum parametro de consulta muda o arquivo servido
        self.assertEqual(self.client.get("/?c=/lib.js").text, self.client.get("/").text)
        # as rotas de administracao continuam exigindo login
        for caminho in ("/admin/session", "/admin/edition-requests", "/admin/editions?q=x"):
            self.assertEqual(self.client.get(caminho).status_code, 401, caminho)

    def test_cors_so_para_a_origem_do_portal(self):
        ok = self.client.options(
            "/admin/session",
            headers={
                "Origin": ORIGIN,
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "Authorization",
            },
        )
        self.assertEqual(ok.headers.get("access-control-allow-origin"), ORIGIN)
        other = self.client.options(
            "/admin/session",
            headers={"Origin": "https://malicioso.invalid", "Access-Control-Request-Method": "GET"},
        )
        self.assertNotIn("access-control-allow-origin", other.headers)

    def test_cadastros_do_app_exigem_user_admin_e_mascaram_email(self):
        self.assertEqual(
            self.client.get("/admin/users/runners", headers=self.auth(token("op"))).status_code, 403
        )
        r = self.client.get("/admin/users/runners", headers=self.auth(token("adm")))
        self.assertEqual(r.status_code, 200)
        dados = r.json()
        self.assertEqual(dados["total"], 3)  # leu as duas paginas
        self.assertFalse(dados["partial"])
        self.assertEqual(dados["byStatus"], {"CONFIRMED": 2, "UNCONFIRMED": 1})
        self.assertEqual(
            dados["items"][0]["email"], "c***@exemplo.invalid"
        )  # mais recente primeiro
        self.assertNotIn("ana@exemplo.invalid", r.text)
        self.assertNotIn("u1111111-x", r.text)  # so o prefixo do id
        trilha = self.store.query("operations", "OPERATOR#adm", prefix="AUDIT#")
        self.assertEqual(len(trilha[0] if isinstance(trilha, tuple) else trilha), 1)

    def test_criar_operador_concede_acesso_e_audita(self):
        corpo = {"email": " Novo@Exemplo.invalid ", "permissions": ["catalog_admin"]}
        self.assertEqual(
            self.client.post(
                "/admin/operators", json=corpo, headers=self.auth(token("op"))
            ).status_code,
            403,
        )
        r = self.client.post("/admin/operators", json=corpo, headers=self.auth(token("adm")))
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(self.cognito.created[0]["Username"], "novo@exemplo.invalid")
        self.assertEqual(self.cognito.created[0]["DesiredDeliveryMediums"], ["EMAIL"])
        acesso = self.store.get(("identity", "OPERATOR#novo-sub-1", "ACCESS"))
        self.assertEqual(acesso["permissions"], ["catalog_admin"])
        self.assertEqual(acesso["grantedBy"], "adm")
        self.assertEqual(acesso["state"], "active")
        for ruim in (
            {"email": "sem-arroba", "permissions": ["catalog_admin"]},
            {"email": "a@b.invalid", "permissions": []},
            {"email": "a@b.invalid", "permissions": ["root"]},
            {"email": "a@b.invalid", "permissions": ["catalog_admin"], "extra": 1},
        ):
            self.assertEqual(
                self.client.post(
                    "/admin/operators", json=ruim, headers=self.auth(token("adm"))
                ).status_code,
                422,
            )
        self.cognito.exists = True
        r = self.client.post("/admin/operators", json=corpo, headers=self.auth(token("adm")))
        self.assertEqual((r.status_code, r.json()["code"]), (409, "OPERATOR_EXISTS"))

    def test_disparar_catalogo_so_modos_da_lista_com_intervalo(self):
        h = self.auth(token("op"))
        self.assertEqual(
            self.client.post("/admin/catalog/run", json={"mode": "x"}, headers=h).status_code, 422
        )
        self.assertEqual(
            self.client.post(
                "/admin/catalog/run", json={"mode": "semanal"}, headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        r = self.client.post("/admin/catalog/run", json={"mode": "enriquecer"}, headers=h)
        self.assertEqual(r.status_code, 202, r.text)
        chamada = self.lam.calls[0]
        self.assertEqual(chamada["InvocationType"], "Event")
        self.assertEqual(chamada["FunctionName"], "runpass-dev-catalogo-semanal")
        self.assertIn(b"enriquecer", chamada["Payload"])
        r = self.client.post("/admin/catalog/run", json={"mode": "semanal"}, headers=h)
        self.assertEqual((r.status_code, r.json()["code"]), (429, "RUN_TOO_SOON"))
        self.assertEqual(len(self.lam.calls), 1)
        self.assertEqual(
            self.client.get("/admin/catalog/run", headers=h).json()["last"]["mode"], "enriquecer"
        )
        self.now += 601
        self.assertEqual(
            self.client.post(
                "/admin/catalog/run",
                json={"mode": "simulacao"},
                headers=self.auth(token("op", now=NOW)),
            ).status_code,
            202,
        )

    def test_execucoes_do_catalogo_mostram_disparos_e_agendadas(self):
        h = self.auth(token("op"))
        self.assertEqual(
            self.client.get("/admin/catalog/runs", headers=self.auth(token("adm"))).status_code, 403
        )
        # disparo recente, ainda sem registro da Lambda
        self.assertEqual(
            self.client.post(
                "/admin/catalog/run", json={"mode": "enriquecer"}, headers=h
            ).status_code,
            202,
        )
        item = self.client.get("/admin/catalog/runs", headers=h).json()["items"][0]
        self.assertEqual(
            (item["origin"], item["mode"], item["status"], item["by"]),
            ("portal", "enriquecer", "waiting", "op"),
        )
        # a Lambda comecou e terminou; ha tambem uma execucao agendada antiga
        inicio = int(self.now * 1000) + 2000
        antigo = inicio - 3 * 86400 * 1000
        self.logs.events = [
            {"timestamp": antigo, "message": "START RequestId: a1 Version: $LATEST"},
            {
                "timestamp": antigo + 9000,
                "message": "REPORT RequestId: a1\tDuration: 9000.5 ms\tBilled Duration: 9001 ms",
            },
            {"timestamp": inicio, "message": "START RequestId: b2 Version: $LATEST"},
            {
                "timestamp": inicio + 150000,
                "message": "REPORT RequestId: b2\tDuration: 150000.1 ms\tStatus: timeout",
            },
        ]
        dados = self.client.get("/admin/catalog/runs", headers=h).json()
        self.assertTrue(dados["logsAvailable"])
        portal, agendada = dados["items"]
        self.assertEqual(
            (portal["origin"], portal["status"], portal["durationMs"]),
            ("portal", "timeout", 150000),
        )
        self.assertEqual((agendada["origin"], agendada["status"]), ("scheduled", "done"))
        self.assertEqual(self.logs.args["logGroupName"], "/aws/lambda/runpass-dev-catalogo-semanal")
        # sem permissao de ler os registros: mostra so o disparo, sem inventar situacao
        self.logs.fail = True
        dados = self.client.get("/admin/catalog/runs", headers=h).json()
        self.assertFalse(dados["logsAvailable"])
        self.assertEqual(dados["items"][0]["status"], "unknown")

    def test_disparo_que_falhou_aparece_como_nao_disparado(self):
        h = self.auth(token("op"))
        self.lam.fail = True
        self.client.post("/admin/catalog/run", json={"mode": "semanal"}, headers=h)
        item = self.client.get("/admin/catalog/runs", headers=h).json()["items"][0]
        self.assertEqual(item["status"], "dispatch_failed")

    def test_proximos_agendamentos_calculam_a_data_no_fuso_de_sao_paulo(self):
        h = self.auth(token("op"))
        self.assertEqual(
            self.client.get(
                "/admin/catalog/schedules", headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        r = self.client.get("/admin/catalog/schedules", headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        itens = r.json()["items"]
        self.assertEqual(self.sched.args["NamePrefix"], "runpass-dev-catalogo-")
        # NOW = terca 10/11/2026 12:00 em SP (15:00Z): a proxima segunda e 16/11
        self.assertEqual(
            [i["name"] for i in itens], ["calendario", "enriquecimento-1", "estranho", "imagens"]
        )
        self.assertEqual(itens[0]["nextRun"], "2026-11-16T10:00:00Z")  # 07:00 -03
        self.assertEqual(itens[1]["nextRun"], "2026-11-16T10:30:00Z")
        self.assertIsNone(itens[2]["nextRun"])  # rate(): nao calcula, sem inventar
        self.assertFalse(itens[3]["enabled"])
        self.assertIsNone(itens[3]["nextRun"])
        self.sched.fail = True
        self.assertEqual(self.client.get("/admin/catalog/schedules", headers=h).status_code, 503)

    def test_lista_devolve_tipo_parametros_dias_e_horario_para_a_tela_editar(self):
        h = self.auth(token("op"))
        itens = {
            i["name"]: i
            for i in self.client.get("/admin/catalog/schedules", headers=h).json()["items"]
        }
        enr = itens["enriquecimento-1"]
        self.assertEqual(
            (enr["kind"], enr["params"], enr["days"], enr["time"]),
            ("enriquecer", {"rodada": 1, "max": 25}, ["MON"], "07:30"),
        )
        self.assertEqual(itens["calendario"]["kind"], "calendario")
        self.assertEqual(itens["calendario"]["params"], {"meses": 3})
        self.assertEqual(itens["imagens"]["kind"], "imagens")
        self.assertIsNone(
            itens["estranho"]["kind"]
        )  # entrada desconhecida: nao se edita o conteudo
        self.assertIsNone(itens["estranho"]["days"])
        self.assertFalse(any(i["createdByPortal"] for i in itens.values()))

    def corpo_agendamento(self, **mudanca):
        return {
            "name": "enriq-quinta",
            "kind": "enriquecer",
            "days": ["THU", "MON"],
            "time": "06:05",
            "rodada": 2,
            "max": 20,
            **mudanca,
        }

    def test_criar_agendamento_exige_catalog_admin_e_usa_so_a_lista_fechada(self):
        h = self.auth(token("op"))
        url = "/admin/catalog/schedules"
        self.assertEqual(
            self.client.post(
                url, json=self.corpo_agendamento(), headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        r = self.client.post(url, json=self.corpo_agendamento(), headers=h)
        self.assertEqual(r.status_code, 201, r.text)
        feito = self.sched.created[0]
        self.assertEqual(feito["Name"], "runpass-dev-catalogo-portal-enriq-quinta")
        self.assertEqual(
            feito["ScheduleExpression"], "cron(5 6 ? * MON,THU *)"
        )  # dias em ordem, sem rate()
        self.assertEqual(feito["ScheduleExpressionTimezone"], "America/Sao_Paulo")
        self.assertEqual(feito["Target"]["RetryPolicy"], {"MaximumRetryAttempts": 0})
        self.assertEqual(
            feito["Target"]["RoleArn"].split("/")[-1],
            "runpass-dev-catalogo-semanal-SchedulerRole-X",
        )
        import json as _json

        self.assertEqual(
            _json.loads(feito["Target"]["Input"]),
            {
                "enriquecer": {
                    "relatorio": "latest",
                    "rodada": 2,
                    "max": 20,
                    "csv_semanal": "latest",
                }
            },
        )
        # nome repetido
        self.assertEqual(
            self.client.post(url, json=self.corpo_agendamento(), headers=h).status_code, 409
        )
        # tudo que foge da lista fechada e recusado e nada e criado
        ruins = [
            {"kind": "rm-rf"},
            {"kind": "historico"},
            {"days": []},
            {"days": ["MON", "MON"]},
            {"days": ["FUN"]},
            {"time": "25:00"},
            {"time": "6:5"},
            {"name": "Nome Ruim!"},
            {"name": "../x"},
            {"max": 26},
            {"max": 0},
            {"rodada": 4},
            {"extra": "campo livre"},
        ]
        for mudanca in ruins:
            antes = len(self.sched.created)
            r = self.client.post(url, json=self.corpo_agendamento(**mudanca), headers=h)
            self.assertIn(r.status_code, (400, 422), mudanca)
            self.assertEqual(len(self.sched.created), antes, mudanca)
        sem_dias = {k: v for k, v in self.corpo_agendamento().items() if k != "days"}
        self.assertEqual(self.client.post(url, json=sem_dias, headers=h).status_code, 422)

    def test_criar_agendamento_respeita_o_teto_e_audita(self):
        h = self.auth(token("op"))
        url = "/admin/catalog/schedules"
        for i in range(20):
            self.sched.items[f"runpass-dev-catalogo-portal-x{i}"] = (
                "cron(0 6 ? * MON *)",
                "ENABLED",
                "x",
                "{}",
            )
        r = self.client.post(url, json=self.corpo_agendamento(), headers=h)
        self.assertEqual((r.status_code, r.json().get("code")), (409, "SCHEDULE_LIMIT"))
        self.sched.items = {k: v for k, v in self.sched.items.items() if "portal-x" not in k}
        self.assertEqual(
            self.client.post(url, json=self.corpo_agendamento(), headers=h).status_code, 201
        )
        trilha = self.store.query("operations", "OPERATOR#op", prefix="AUDIT#")[0]
        criou = [row for _, row in trilha if row["action"] == "catalog.schedule.create"]
        self.assertEqual(len(criou), 1)
        self.assertEqual(criou[0]["schedule"], "runpass-dev-catalogo-portal-enriq-quinta")
        self.assertEqual(criou[0]["kind"], "enriquecer")

    def test_alterar_agendamento_existente_mantem_o_resto_e_so_aceita_o_que_o_tipo_permite(self):
        h = self.auth(token("op"))
        url = "/admin/catalog/schedules/enriquecimento-1"
        self.assertEqual(
            self.client.put(
                url, json={"enabled": False}, headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        r = self.client.put(
            url,
            json={
                "days": ["TUE", "FRI"],
                "time": "08:00",
                "rodada": 3,
                "max": 10,
                "enabled": False,
            },
            headers=h,
        )
        self.assertEqual(r.status_code, 200, r.text)
        feito = self.sched.updated[-1]
        self.assertEqual(feito["ScheduleExpression"], "cron(0 8 ? * TUE,FRI *)")
        self.assertEqual(feito["State"], "DISABLED")
        self.assertEqual(
            feito["Target"]["RoleArn"].split("/")[-1],
            "runpass-dev-catalogo-semanal-SchedulerRole-X",
        )  # alvo preservado
        self.assertEqual(feito["Target"]["RetryPolicy"], {"MaximumRetryAttempts": 0})
        self.assertEqual(feito["Description"], "Enriquecimento")
        self.assertEqual(feito["ScheduleExpressionTimezone"], "America/Sao_Paulo")
        import json as _json

        self.assertEqual(
            _json.loads(feito["Target"]["Input"])["enriquecer"],
            {"relatorio": "latest", "rodada": 3, "max": 10, "csv_semanal": "latest"},
        )
        # so pausar/ativar nao toca no horario nem na entrada
        antes = self.sched.items["runpass-dev-catalogo-calendario"]
        self.assertEqual(
            self.client.put(
                "/admin/catalog/schedules/calendario", json={"enabled": False}, headers=h
            ).status_code,
            200,
        )
        depois = self.sched.items["runpass-dev-catalogo-calendario"]
        self.assertEqual((depois[0], depois[3]), (antes[0], antes[3]))
        self.assertEqual(depois[1], "DISABLED")
        # dias sem horario (ou o contrario), parametro de outro tipo e entrada desconhecida: recusados
        for caminho, corpo in (
            ("enriquecimento-1", {"days": ["MON"]}),
            ("enriquecimento-1", {"time": "07:00"}),
            ("imagens", {"max": 5}),
            ("estranho", {"rodada": 2}),
            ("enriquecimento-1", {"max": 99}),
        ):
            r = self.client.put("/admin/catalog/schedules/" + caminho, json=corpo, headers=h)
            self.assertIn(r.status_code, (400, 422), (caminho, corpo))
        # o desconhecido pode ser pausado, mas a entrada dele nunca e reescrita
        n = len(self.sched.updated)
        self.assertEqual(
            self.client.put(
                "/admin/catalog/schedules/estranho", json={"enabled": False}, headers=h
            ).status_code,
            200,
        )
        self.assertEqual(self.sched.updated[n]["Target"]["Input"], '{"outra": 1}')
        self.assertEqual(
            self.client.put(
                "/admin/catalog/schedules/nao-existe", json={"enabled": False}, headers=h
            ).status_code,
            404,
        )

    def test_execucao_unica_em_uma_data_valida_futuro_e_limite_de_um_ano(self):
        h = self.auth(token("op"))
        url = "/admin/catalog/schedules"
        base = {"name": "uma-vez", "kind": "imagens", "time": "06:00"}
        # NOW = terca 10/11/2026 12:00 em SP
        r = self.client.post(url, json={**base, "date": "2026-11-20"}, headers=h)
        self.assertEqual(r.status_code, 201, r.text)
        feito = self.sched.created[-1]
        self.assertEqual(feito["ScheduleExpression"], "at(2026-11-20T06:00:00)")
        self.assertEqual(feito["ScheduleExpressionTimezone"], "America/Sao_Paulo")
        self.assertEqual(feito["ActionAfterCompletion"], "DELETE")  # some sozinho depois de rodar
        # recorrente continua sem apagar
        r = self.client.post(url, json={**base, "name": "toda-seg", "days": ["MON"]}, headers=h)
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(self.sched.created[-1]["ActionAfterCompletion"], "NONE")
        ruins = [
            {"date": "2026-11-10", "time": "11:59"},  # hoje, mas ja passou
            {"date": "2026-11-10", "time": "12:00"},  # agora nao e futuro
            {"date": "2026-11-09"},  # ontem
            {"date": "2027-11-12"},  # a mais de 1 ano
            {"date": "2026-02-30"},  # data que nao existe
            {"date": "20/11/2026"},
            {"date": "2026-11-20", "days": ["MON"]},  # as duas formas juntas
            {"date": "2026-11-20", "time": "24:00"},
        ]
        for i, mudanca in enumerate(ruins):
            antes = len(self.sched.created)
            corpo = {**base, "name": f"ruim-{i}", **mudanca}
            r = self.client.post(url, json=corpo, headers=h)
            self.assertIn(r.status_code, (400, 422), mudanca)
            self.assertEqual(len(self.sched.created), antes, mudanca)
        # nem data nem dias
        self.assertEqual(
            self.client.post(url, json={**base, "name": "sem-quando"}, headers=h).status_code, 422
        )
        # hoje mais tarde e o limite de um ano (366 dias) valem
        self.assertEqual(
            self.client.post(
                url,
                json={**base, "name": "hoje-tarde", "date": "2026-11-10", "time": "18:30"},
                headers=h,
            ).status_code,
            201,
        )
        self.assertEqual(
            self.client.post(
                url,
                json={**base, "name": "um-ano", "date": "2027-11-10", "time": "11:00"},
                headers=h,
            ).status_code,
            201,
        )

    def test_alterar_a_data_de_um_agendamento_e_trocar_entre_repetir_e_uma_vez(self):
        h = self.auth(token("op"))
        url = "/admin/catalog/schedules/calendario"
        r = self.client.put(url, json={"date": "2026-11-25", "time": "07:15"}, headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        feito = self.sched.updated[-1]
        self.assertEqual(feito["ScheduleExpression"], "at(2026-11-25T07:15:00)")
        self.assertEqual(feito["ActionAfterCompletion"], "DELETE")
        # a lista devolve data e horario para a tela editar
        itens = {
            i["name"]: i
            for i in self.client.get("/admin/catalog/schedules", headers=h).json()["items"]
        }
        self.assertEqual(
            (itens["calendario"]["date"], itens["calendario"]["time"], itens["calendario"]["days"]),
            ("2026-11-25", "07:15", None),
        )
        self.assertEqual(itens["calendario"]["nextRun"], "2026-11-25T10:15:00Z")
        # volta a repetir toda semana
        r = self.client.put(url, json={"days": ["MON", "THU"], "time": "07:00"}, headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.sched.updated[-1]["ScheduleExpression"], "cron(0 7 ? * MON,THU *)")
        self.assertEqual(self.sched.updated[-1]["ActionAfterCompletion"], "NONE")
        # data sem horario, data no passado e as duas formas juntas: recusados e nada muda
        n = len(self.sched.updated)
        for corpo in (
            {"date": "2026-11-25"},
            {"date": "2026-11-01", "time": "07:00"},
            {"date": "2026-11-25", "days": ["MON"], "time": "07:00"},
        ):
            self.assertIn(
                self.client.put(url, json=corpo, headers=h).status_code, (400, 422), corpo
            )
        self.assertEqual(len(self.sched.updated), n)

    def test_apagar_agendamento_so_do_catalogo_e_so_com_catalog_admin(self):
        h = self.auth(token("op"))
        self.assertEqual(
            self.client.delete(
                "/admin/catalog/schedules/imagens", headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        self.assertEqual(
            self.client.delete("/admin/catalog/schedules/nao-existe", headers=h).status_code, 404
        )
        for nome in ("..%2Fx", "Nome%20Ruim", "a" * 61):
            self.assertIn(
                self.client.delete("/admin/catalog/schedules/" + nome, headers=h).status_code,
                (404, 422),
            )
        self.assertEqual(self.sched.deleted, [])
        r = self.client.delete("/admin/catalog/schedules/imagens", headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            self.sched.deleted, ["runpass-dev-catalogo-imagens"]
        )  # so o prefixo do catalogo
        self.sched.fail = True
        self.assertEqual(
            self.client.delete("/admin/catalog/schedules/calendario", headers=h).status_code, 503
        )

    def test_next_run_formas_simples_e_nao_suportadas(self):
        agora = datetime(2026, 11, 16, 9, 59, tzinfo=timezone.utc)  # 06:59 em SP, segunda
        self.assertEqual(next_run("cron(0 7 ? * MON *)", "America/Sao_Paulo", agora).hour, 10)
        agora = datetime(2026, 11, 16, 10, 0, 1, tzinfo=timezone.utc)  # logo depois das 07:00
        self.assertEqual(next_run("cron(0 7 ? * MON *)", "America/Sao_Paulo", agora).day, 23)
        self.assertEqual(
            next_run("cron(0 12 1 * ? *)", "UTC", agora).isoformat(), "2026-12-01T12:00:00+00:00"
        )
        self.assertEqual(next_run("at(2027-01-01T08:00:00)", "UTC", agora).year, 2027)
        self.assertIsNone(next_run("at(2020-01-01T08:00:00)", "UTC", agora))
        for ruim in ("rate(5 minutes)", "cron(*/5 * * * ? *)", "cron(0 7 ? * MON-FRI *)", "", None):
            self.assertIsNone(next_run(ruim, "UTC", agora))

    def test_relatorio_de_qualidade_exige_catalog_admin_e_e_coerente(self):
        self.assertEqual(
            self.client.get("/admin/quality", headers=self.auth(token("fin"))).status_code, 403
        )
        r = self.client.get("/admin/quality", headers=self.auth(token("op")))
        self.assertEqual(r.status_code, 200, r.text)
        rel = r.json()
        ext, enr = rel["extraction"], rel["enrichment"]
        self.assertLessEqual(ext["matched"], ext["extracted"])
        self.assertEqual(ext["extracted"] + len(ext["notExtracted"]), ext["inPage"])
        self.assertEqual(enr["ready"] + enr["notFound"] + enr["partial"], enr["total"])
        self.assertLessEqual(max(enr["filled"].values()), enr["total"])
        self.assertTrue(
            all(
                c["result"] in ("confere", "parcial", "nao_verificado", "errada")
                for c in rel["spotCheck"]
            )
        )

    def test_custos_exigem_cost_read_e_uma_fonte_fora_do_ar_nao_esconde_a_outra(self):
        for quem in ("op", "adm"):
            self.assertEqual(
                self.client.get("/admin/costs", headers=self.auth(token(quem))).status_code, 403
            )
        h = self.auth(token("fin"))
        r = self.client.get("/admin/costs", headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            r.json(),
            {
                "aws": {"totalUsd": 5},
                "openai": {"month": "2026-11"},
                "openaiOrg": None,
                "openaiOrgStatus": "not_configured",
                "errors": [],
            },
        )
        self.openai_costs.value = None
        r = self.client.get("/admin/costs", headers=h).json()
        self.assertEqual((r["aws"], r["openai"], r["errors"]), ({"totalUsd": 5}, None, ["openai"]))

    def test_custos_com_chave_de_administrador_usam_os_dados_reais_e_caem_para_a_estimativa(self):
        h = self.auth(token("fin"))
        self.openai_org.configured, self.openai_org.value = True, {"totalUsd": 2.42}
        r = self.client.get("/admin/costs", headers=h).json()
        self.assertEqual(
            (r["openaiOrg"], r["openaiOrgStatus"], r["errors"]), ({"totalUsd": 2.42}, "ok", [])
        )
        self.openai_org.value = (
            None  # chave invalida ou OpenAI fora do ar: segue com a estimativa pelos logs
        )
        r = self.client.get("/admin/costs", headers=h).json()
        self.assertEqual((r["openaiOrg"], r["openaiOrgStatus"]), (None, "error"))
        self.assertEqual(r["openai"], {"month": "2026-11"})

    def operadores(self):
        """adm (administrador de usuarios) e dois operadores no pool falso, cada um com ACCESS."""
        for email, sub in (
            ("adm@e.invalid", "adm"),
            ("op@e.invalid", "op"),
            ("outro@e.invalid", "mod"),
        ):
            self.cognito.operators[email] = {"sub": sub, "enabled": True}

    def test_listar_operadores_mostra_acesso_e_exige_user_admin(self):
        self.operadores()
        self.assertEqual(
            self.client.get("/admin/operators", headers=self.auth(token("op"))).status_code, 403
        )
        itens = self.client.get("/admin/operators", headers=self.auth(token("adm"))).json()["items"]
        por = {i["email"]: i for i in itens}
        self.assertEqual(por["op@e.invalid"]["access"]["permissions"], ["catalog_admin"])
        self.assertEqual(por["adm@e.invalid"]["access"]["state"], "active")
        self.assertEqual(por["outro@e.invalid"]["access"]["permissions"], ["moderation"])

    def test_alterar_permissoes_revogar_e_reativar(self):
        self.operadores()
        h = self.auth(token("adm"))
        r = self.client.put(
            "/admin/operators/op/permissions",
            json={"permissions": ["catalog_admin", "cost_read"]},
            headers=h,
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            self.store.get(("identity", "OPERATOR#op", "ACCESS"))["permissions"],
            ["catalog_admin", "cost_read"],
        )
        self.assertEqual(
            self.client.put(
                "/admin/operators/op/permissions", json={"permissions": ["root"]}, headers=h
            ).status_code,
            422,
        )
        # revogar: o proprio operador perde o acesso na hora, no mesmo token
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("op"))).status_code, 200
        )
        self.assertEqual(self.client.post("/admin/operators/op/revoke", headers=h).status_code, 200)
        self.assertEqual(self.store.get(("identity", "OPERATOR#op", "ACCESS"))["state"], "revoked")
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("op"))).status_code, 401
        )
        self.assertIn(("disable", "op@e.invalid"), self.cognito.calls)
        self.assertIn(("signout", "op@e.invalid"), self.cognito.calls)
        # revogado nao recebe mudanca de permissoes ate ser reativado
        self.assertEqual(
            self.client.put(
                "/admin/operators/op/permissions",
                json={"permissions": ["catalog_admin"]},
                headers=h,
            ).status_code,
            409,
        )
        self.assertEqual(
            self.client.post("/admin/operators/op/reactivate", headers=h).status_code, 200
        )
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("op"))).status_code, 200
        )

    def test_protecoes_nao_mexer_em_si_nem_deixar_a_conta_sem_administrador(self):
        self.operadores()
        h = self.auth(token("adm"))
        for caminho, corpo in (("/permissions", None), ("/revoke", None), ("/reset", None)):
            metodo = (
                self.client.put if corpo is None and caminho == "/permissions" else self.client.post
            )
            kw = {"json": {"permissions": ["catalog_admin"]}} if caminho == "/permissions" else {}
            r = metodo("/admin/operators/adm" + caminho, headers=h, **kw)
            self.assertEqual((r.status_code, r.json()["code"]), (409, "CANNOT_CHANGE_SELF"))
        # outro administrador de usuarios: pode ser rebaixado enquanto sobrar um (adm); o ultimo nao
        grant_access(self.store, "mod", ["user_admin"], "outro", NOW)
        h2 = self.auth(token("mod"))
        r = self.client.put(
            "/admin/operators/adm/permissions", json={"permissions": ["catalog_admin"]}, headers=h2
        )
        self.assertEqual(r.status_code, 200, r.text)
        r = self.client.post("/admin/operators/mod/revoke", headers=self.auth(token("adm")))
        self.assertEqual(r.status_code, 403)  # adm perdeu user_admin
        self.assertEqual(
            self.client.post("/admin/operators/nao-existe-123/revoke", headers=h2).status_code, 404
        )
        self.assertEqual(
            self.client.post("/admin/operators/..%2Fx/revoke", headers=h2).status_code, 404
        )

    def test_ultimo_administrador_nao_pode_ser_rebaixado_por_outro_operador_inativo(self):
        self.operadores()
        grant_access(self.store, "mod", ["user_admin"], "outro", NOW)
        h = self.auth(token("adm"))
        self.assertEqual(
            self.client.post("/admin/operators/mod/revoke", headers=h).status_code, 200
        )
        # agora adm e o unico administrador ativo; "mod" revogado nao conta
        self.cognito.operators["outro@e.invalid"]["enabled"] = False
        r = self.client.put(
            "/admin/operators/mod/permissions", json={"permissions": ["catalog_admin"]}, headers=h
        )
        self.assertEqual(r.status_code, 409)  # revogado

    def test_conceder_acesso_a_quem_existe_no_pool_sem_acesso(self):
        self.operadores()
        self.cognito.operators["rafael@e.invalid"] = {"sub": "rafael-sub", "enabled": True}
        h = self.auth(token("adm"))
        # sem acesso, o login do Cognito nao basta: a API recusa
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("rafael-sub"))).status_code,
            401,
        )
        itens = self.client.get("/admin/operators", headers=h).json()["items"]
        self.assertIsNone(next(i for i in itens if i["subject"] == "rafael-sub")["access"])
        self.assertEqual(
            self.client.post(
                "/admin/operators/rafael-sub/grant",
                json={"permissions": ["catalog_admin"]},
                headers=self.auth(token("op")),
            ).status_code,
            403,
        )
        self.assertEqual(
            self.client.post(
                "/admin/operators/rafael-sub/grant", json={"permissions": ["root"]}, headers=h
            ).status_code,
            422,
        )
        r = self.client.post(
            "/admin/operators/rafael-sub/grant",
            json={"permissions": ["catalog_admin", "user_admin"]},
            headers=h,
        )
        self.assertEqual(r.status_code, 201, r.text)
        acesso = self.store.get(("identity", "OPERATOR#rafael-sub", "ACCESS"))
        self.assertEqual((acesso["state"], acesso["grantedBy"]), ("active", "adm"))
        self.assertEqual(
            self.client.get("/admin/session", headers=self.auth(token("rafael-sub"))).status_code,
            200,
        )
        # quem ja tem acesso nao e "concedido" de novo (alterar permissoes ou reativar); nem o proprio nem quem nao existe
        self.assertEqual(
            self.client.post(
                "/admin/operators/rafael-sub/grant",
                json={"permissions": ["catalog_admin"]},
                headers=h,
            ).status_code,
            409,
        )
        self.assertEqual(
            self.client.post(
                "/admin/operators/adm/grant", json={"permissions": ["catalog_admin"]}, headers=h
            ).status_code,
            409,
        )
        self.assertEqual(
            self.client.post(
                "/admin/operators/nao-existe/grant",
                json={"permissions": ["catalog_admin"]},
                headers=h,
            ).status_code,
            404,
        )

    def test_reset_apaga_e_recria_com_as_mesmas_permissoes(self):
        self.operadores()
        h = self.auth(token("adm"))
        r = self.client.post("/admin/operators/op/reset", headers=h)
        self.assertEqual(r.status_code, 200, r.text)
        novo = r.json()["subject"]
        self.assertNotEqual(novo, "op")
        self.assertEqual(self.store.get(("identity", "OPERATOR#op", "ACCESS"))["state"], "revoked")
        acesso = self.store.get(("identity", "OPERATOR#" + novo, "ACCESS"))
        self.assertEqual((acesso["state"], acesso["permissions"]), ("active", ["catalog_admin"]))
        self.assertIn(("delete", "op@e.invalid"), self.cognito.calls)
        self.assertEqual(self.cognito.created[-1]["DesiredDeliveryMediums"], ["EMAIL"])

    def png(self):
        from PIL import Image

        out = io.BytesIO()
        Image.new("RGB", (64, 36), (200, 60, 20)).save(out, format="PNG")
        return out.getvalue()

    def test_banners_candidatas_com_a_corrida_provavel_e_so_para_catalog_admin(self):
        h = self.auth(token("op"))
        self.assertEqual(
            self.client.get(
                "/admin/banners/candidates", headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        self.assertEqual(
            self.client.get("/admin/banners/candidates", headers=h).json(),
            {"source": None, "items": []},
        )
        cab = "source_external_id,nome,data,pagina_oficial,imagem_url,tipo,tamanho_bytes,credito_sugerido,direitos,situacao,observacao,aprovada\n"
        self.s3.objects["semanal/2026-11-09/imagens/candidatas.csv"] = "x\n"
        self.s3.objects["semanal/2026-11-16/imagens/candidatas.csv"] = (
            cab
            + "a,Corrida Sintética São Paulo,2026-11-08,https://o.exemplo/p,https://o.exemplo/b.png,image/png,100,Divulgação: Org,nao_verificado,candidata,,\n"
            + "b,Outra,2026-01-01,https://o.exemplo/p,https://o.exemplo/c.png,image/png,100,,nao_verificado,candidata,,\n"
            + "c,Sem imagem,2026-01-01,https://o.exemplo/p,,,,,nao_verificado,sem_imagem_declarada,,\n"
            + "d,Inseguro,2026-01-01,https://o.exemplo/p,http://o.exemplo/d.png,image/png,1,,nao_verificado,candidata,,\n"
        )
        r = self.client.get("/admin/banners/candidates", headers=h).json()
        self.assertEqual(r["source"], "2026-11-16")  # a coleta mais recente
        self.assertEqual([i["name"] for i in r["items"]], ["Corrida Sintética São Paulo", "Outra"])
        self.assertEqual(r["items"][0]["edition"]["id"], "synthetic-sp-2026")
        self.assertIsNone(r["items"][1]["edition"])

    def test_candidata_aprovada_ou_de_corrida_com_banner_sai_da_lista(self):
        h = self.auth(token("op"))
        url = "https://o.exemplo/b.png"
        self.pages[url] = (200, {"content-type": "image/png"}, self.png())
        cab = "source_external_id,nome,data,pagina_oficial,imagem_url,tipo,tamanho_bytes,credito_sugerido,direitos,situacao,observacao,aprovada\n"
        self.s3.objects["semanal/2026-11-16/imagens/candidatas.csv"] = (
            cab
            + f"a,Corrida Sintética São Paulo,2026-11-08,https://o.exemplo/p,{url},image/png,100,Divulgação: Org,nao_verificado,candidata,,\n"
        )
        antes = self.client.get("/admin/banners/candidates", headers=h).json()
        self.assertEqual([i["name"] for i in antes["items"]], ["Corrida Sintética São Paulo"])
        corpo = {
            "editionId": "synthetic-sp-2026",
            "imageUrl": url,
            "credit": "Divulgação: Org",
            "rightsNote": "Imagem da pagina oficial; risco assumido pelo responsavel",
            "confirmRights": True,
        }
        self.assertEqual(
            self.client.post("/admin/banners/approve", json=corpo, headers=h).status_code, 201
        )
        depois = self.client.get("/admin/banners/candidates", headers=h).json()
        self.assertEqual(depois["items"], [])  # aprovada: nao aparece mais
        # retirar o banner devolve a candidata para a lista
        self.assertEqual(
            self.client.post(
                "/admin/banners/remove",
                json={"editionId": "synthetic-sp-2026", "reason": "teste de retorno"},
                headers=h,
            ).status_code,
            200,
        )
        volta = self.client.get("/admin/banners/candidates", headers=h).json()
        self.assertEqual([i["name"] for i in volta["items"]], ["Corrida Sintética São Paulo"])

    def test_banner_preview_aprovar_e_retirar(self):
        h = self.auth(token("op"))
        url = "https://o.exemplo/b.png"
        self.pages[url] = (200, {"content-type": "image/png"}, self.png())
        r = self.client.post("/admin/banners/preview", json={"imageUrl": url}, headers=h)
        self.assertEqual((r.status_code, r.headers["content-type"]), (200, "image/png"))
        self.assertEqual(
            self.client.post(
                "/admin/banners/preview", json={"imageUrl": "http://x"}, headers=h
            ).status_code,
            422,
        )
        corpo = {
            "editionId": "synthetic-sp-2026",
            "imageUrl": url,
            "credit": "Divulgação: Org",
            "rightsNote": "Imagem da pagina oficial; risco assumido pelo responsavel",
            "confirmRights": True,
        }
        # sem confirmar, sem credito ou com nota curta: nada e publicado
        for mudanca in ({"confirmRights": False}, {"credit": " "}, {"rightsNote": "ok"}):
            r = self.client.post("/admin/banners/approve", json={**corpo, **mudanca}, headers=h)
            self.assertEqual(r.status_code, 422, mudanca)
        self.assertEqual(self.blobs.derived, {})
        self.assertEqual(
            self.client.post(
                "/admin/banners/approve", json=corpo, headers=self.auth(token("adm"))
            ).status_code,
            403,
        )
        r = self.client.post("/admin/banners/approve", json=corpo, headers=h)
        self.assertEqual(r.status_code, 201, r.text)
        self.assertTrue(r.json()["reference"].startswith("banner_"))
        row = self.store.get(
            ("operations", "EDITION#synthetic-sp-2026", "IMAGE#" + r.json()["reference"])
        )
        self.assertEqual(
            (row["credit"], row["approvedBy"], row["origin"]), ("Divulgação: Org", "op", "admin")
        )
        self.assertIn("risco assumido", row["rightsNote"])
        publicados = self.client.get("/admin/banners/published", headers=h).json()["items"]
        self.assertEqual([p["id"] for p in publicados], ["synthetic-sp-2026"])
        self.assertEqual(publicados[0]["credit"], "Divulgação: Org")
        # edicao inexistente
        r = self.client.post(
            "/admin/banners/approve", json={**corpo, "editionId": "nao-existe"}, headers=h
        )
        self.assertEqual(r.status_code, 404)
        # retirar exige motivo e so vale quando ha banner
        rem = {"editionId": "synthetic-sp-2026", "reason": "pedido do organizador"}
        self.assertEqual(
            self.client.post(
                "/admin/banners/remove", json={**rem, "reason": ""}, headers=h
            ).status_code,
            422,
        )
        self.assertEqual(
            self.client.post("/admin/banners/remove", json=rem, headers=h).status_code, 200
        )
        self.assertEqual(self.client.get("/admin/banners/published", headers=h).json()["items"], [])
        self.assertEqual(
            self.client.post("/admin/banners/remove", json=rem, headers=h).status_code, 409
        )

    def test_falha_ao_disparar_nao_trava_o_intervalo(self):
        h = self.auth(token("op"))
        self.lam.fail = True
        self.assertEqual(
            self.client.post("/admin/catalog/run", json={"mode": "semanal"}, headers=h).status_code,
            503,
        )
        self.lam.fail = False
        self.assertEqual(
            self.client.post("/admin/catalog/run", json={"mode": "semanal"}, headers=h).status_code,
            202,
        )


class MfaPolicyTests(unittest.TestCase):
    def test_exige_mfa_ligado_e_sem_dispositivo_lembrado_e_guarda_em_cache(self):
        clock = [1000.0]
        on = FakeCognito({"MfaConfiguration": "ON"})
        policy = MfaPolicy(on, "pool", clock=lambda: clock[0])
        self.assertTrue(policy.enforced())
        self.assertTrue(policy.enforced())
        self.assertEqual(on.calls, 1)  # cache
        clock[0] += 301
        self.assertTrue(policy.enforced())
        self.assertEqual(on.calls, 2)
        for config in (
            {"MfaConfiguration": "OPTIONAL"},
            {"MfaConfiguration": "OFF"},
            {
                "MfaConfiguration": "ON",
                "DeviceConfiguration": {"ChallengeRequiredOnNewDevice": True},
            },
        ):
            self.assertFalse(
                MfaPolicy(FakeCognito(config), "pool", clock=lambda: 1.0).enforced(), config
            )

    def test_admit_recusa_audiencia_de_corredor(self):
        store = MemoryStore()
        with self.assertRaises(AuthFailure):
            admit_operator(store, Principal("x", True, "runner", ""), token("x"), lambda: True)


if __name__ == "__main__":
    unittest.main()
