import unittest
from datetime import datetime, timezone

from runpass.identity import Principal
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore, Unavailable
from runpass.web_lookup import DAILY_LIMIT, WebLookup

NOW = datetime(2026, 11, 18, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True}

# Dados [FICTICIA]: resposta da Lambda de busca do catalogo.
FOUND = {
    "corridas": [
        {
            "nome": "CORRIDA ACHADA NA WEB [FICTICIA]",
            "data": "2026-12-06",
            "cidade": "Campinas",
            "uf": "SP",
            "distancias_km": [10, 5, 5],
            "fonte_url": "https://exemplo.invalid/corrida",
            "local": "Parque Exemplo",
            "organizador": "Org Exemplo",
        },
        {"nome": "Sem data", "data": "", "cidade": "Santos"},
        {"nome": "Url ruim", "data": "2026-12-07", "cidade": "Santos", "fonte_url": "http://x"},
    ]
}


class WebLookupTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.identity = IdentityService(
            self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW
        )
        self.actor = Principal("runner", True)
        self.identity.create_profile(self.actor, "p", {"displayName": "R", "username": "runner"})
        self.identity.admit(self.actor, "a", ADULT)
        self.calls = []

    def lookup(self, answer=FOUND):
        def invoke(payload):
            self.calls.append(payload)
            if isinstance(answer, Exception):
                raise answer
            return answer

        return WebLookup(self.identity, invoke)

    def test_devolve_lista_simples_para_preencher_o_pedido(self):
        r = self.lookup().find(self.actor, "corrida achada", "Campinas", "SP")
        self.assertEqual(
            self.calls, [{"procura": {"nome": "corrida achada", "cidade": "Campinas", "uf": "SP"}}]
        )
        self.assertEqual(r["remaining"], DAILY_LIMIT - 1)
        first = r["items"][0]
        self.assertEqual(first["name"], "Corrida Achada na Web [FICTICIA]")
        self.assertEqual(
            (first["date"], first["city"], first["state"], first["distancesKm"]),
            ("2026-12-06", "Campinas", "SP", [5.0, 10.0]),
        )
        self.assertEqual(first["officialUrl"], "https://exemplo.invalid/corrida")
        # sem data vira fora; endereco que nao e https fica vazio
        self.assertEqual(len(r["items"]), 2)
        self.assertIsNone(r["items"][1]["officialUrl"])

    def test_limite_por_dia_e_falhas_viram_erros_claros(self):
        w = self.lookup()
        for _ in range(DAILY_LIMIT):
            w.find(self.actor, "corrida achada")
        with self.assertRaises(Problem) as caught:
            w.find(self.actor, "corrida achada")
        self.assertEqual(caught.exception.code, "WEB_LOOKUP_LIMIT")
        with self.assertRaises(Problem) as caught:
            self.lookup(Unavailable()).find(Principal("outro", True), "x y z")
        self.assertIn(caught.exception.code, ("RUNNER_REQUIRED", "BETA_ADMISSION_REQUIRED"))
        other = Principal("b", True)
        self.identity.create_profile(other, "p", {"displayName": "B", "username": "bbb"})
        self.identity.admit(other, "a", ADULT)
        for answer, code in (
            (Unavailable(), "WEB_LOOKUP_UNAVAILABLE"),
            ({"erro": "PROCURA_INDISPONIVEL"}, "WEB_LOOKUP_UNAVAILABLE"),
            ({"erro": "PROCURA_INVALIDA"}, "INVALID_INPUT"),
        ):
            with self.assertRaises(Problem) as caught:
                self.lookup(answer).find(other, "corrida x")
            self.assertEqual(caught.exception.code, code)


if __name__ == "__main__":
    unittest.main()
