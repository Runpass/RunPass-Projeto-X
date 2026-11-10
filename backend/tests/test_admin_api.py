"""API do portal de administracao. Dados sinteticos; MemoryStore nao prova comportamento do DynamoDB."""

import hashlib
import unittest
from datetime import datetime, timezone
from pathlib import Path

import jwt
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.admin_api import MfaPolicy, admit_operator, create_admin_app
from runpass.admin_users import AdminUsers, CatalogRunner, CatalogSchedules, next_run
from runpass.catalog import CatalogService, seed_synthetic
from runpass.edition_requests import EditionRequestService
from runpass.identity import AuthFailure, Principal
from runpass.models import EditionRequestFields
from runpass.operator_admin import grant_access
from runpass.service import IdentityService
from runpass.store import MemoryStore

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
    """Cognito falso: um pool de corredores e a criacao de operadores."""

    def __init__(self):
        self.created, self.exists = [], False

    def list_users(self, **args):
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
        if self.exists:
            raise type("UsernameExistsException", (Exception,), {})()
        self.created.append(args)
        return {
            "User": {"Username": "novo-sub", "Attributes": [{"Name": "sub", "Value": "novo-sub"}]}
        }


class FakeLogs:
    def __init__(self):
        self.events, self.fail, self.args = [], False, None

    def filter_log_events(self, **args):
        if self.fail:
            raise RuntimeError("sem acesso")
        self.args = args
        return {"events": self.events}


class FakeScheduler:
    def __init__(self):
        self.fail = False
        self.items = {
            "runpass-dev-catalogo-enriquecimento-1": (
                "cron(30 7 ? * MON *)",
                "ENABLED",
                "Enriquecimento",
            ),
            "runpass-dev-catalogo-calendario": ("cron(0 7 ? * MON *)", "ENABLED", "Calendario"),
            "runpass-dev-catalogo-imagens": ("cron(30 9 ? * MON *)", "DISABLED", "Imagens"),
            "runpass-dev-catalogo-estranho": ("rate(1 day)", "ENABLED", "Rate"),
        }

    def list_schedules(self, **args):
        if self.fail:
            raise RuntimeError("negado")
        self.args = args
        return {"Schedules": [{"Name": n} for n in self.items]}

    def get_schedule(self, Name):
        e, st, d = self.items[Name]
        return {
            "Name": Name,
            "ScheduleExpression": e,
            "State": st,
            "Description": d,
            "ScheduleExpressionTimezone": "America/Sao_Paulo",
        }


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
                    self.sched, "runpass-dev-catalogo-semanal", lambda: self.now
                ),
                site={
                    "directory": self.portal_dir,
                    "region": "sa-east-1",
                    "client_id": "cliente-publico",
                },
            )
        )
        grant_access(self.store, "op", ["catalog_admin"], "outro", NOW)
        grant_access(self.store, "adm", ["user_admin"], "outro", NOW)
        grant_access(self.store, "mod", ["moderation"], "outro", NOW)

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
        acesso = self.store.get(("identity", "OPERATOR#novo-sub", "ACCESS"))
        self.assertEqual(acesso["permissions"], ["catalog_admin"])
        self.assertEqual(acesso["grantedBy"], "adm")
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
