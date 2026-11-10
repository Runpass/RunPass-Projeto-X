"""API do portal de administracao. Dados sinteticos; MemoryStore nao prova comportamento do DynamoDB."""

import hashlib
import unittest
from datetime import datetime, timezone
from pathlib import Path

import jwt
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from runpass.admin_api import MfaPolicy, admit_operator, create_admin_app
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
        self.client = TestClient(
            create_admin_app(
                self.store, self.catalog, verify, self.policy, ORIGIN, clock=lambda: self.now
            )
        )
        grant_access(self.store, "op", ["catalog_admin"], "outro", NOW)
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
