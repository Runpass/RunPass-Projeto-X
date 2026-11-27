import io
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from runpass import auto_import
from runpass.auto_import import AutoImport, similar_names
from runpass.catalog import AutoImportActor, CatalogImporter, CatalogService, seed_synthetic
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 11, 15, tzinfo=timezone.utc)
HEADER = (
    "source_external_id,name,event_date,city,state,country,distances_km,registration_status,"
    "official_url,registration_url,organizer_name,venue,event_status,last_verified_at\n"
)


def row(ext, name, day, city="São Paulo", state="SP", official="https://exemplo.invalid/p", reg=""):
    return f"{ext},{name},{day},{city},{state},BR,10,unknown,{official},{reg},Org,Local,scheduled,2026-11-11\n"


class FakeS3:
    def __init__(self):
        self.objects = {}

    def list_objects_v2(self, **args):
        return {
            "Contents": [{"Key": k} for k in sorted(self.objects) if k.startswith(args["Prefix"])]
        }

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key].encode())}


class AutoImportTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        identity = IdentityService(self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW)
        self.catalog = CatalogService(identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.s3 = FakeS3()
        self.auto = AutoImport(self.store, self.catalog, self.s3, "relatorios", clock=lambda: NOW)
        self.operator = mock.Mock(subject="op-1")
        # Corrida que ja existe no catalogo (outra origem), para testar a trava de parecida.
        CatalogImporter(self.catalog).put(
            {
                "id": "csv-sp-maratona-teste-int-l-2027-04-04",
                "name": "Maratona Teste Int'l de São Paulo",
                "date": "2027-04-04",
                "city": "São Paulo",
                "state": "SP",
                "distances": [{"id": "42k", "kilometers": 42.195}],
            },
            expected_version=0,
            origin="https://exemplo.invalid/antiga",
            synthetic=True,
        )

    def put_csv(self, key, text):
        self.s3.objects[key] = HEADER + text

    def ids(self):
        return sorted(
            k[1].split("#", 1)[1]
            for k in self.store.items
            if k[0] == "catalog" and k[1].startswith("EDITION#") and k[2] == "HEAD"
        )

    def test_semelhanca_de_nomes(self):
        self.assertTrue(
            similar_names(
                "101ª Corrida Internacional de São Silvestre", "101ª Corrida Int'l de São Silvestre"
            )
        )
        self.assertTrue(similar_names("Meia de Sampa", "Meia de Sampa 2026"))
        self.assertFalse(similar_names("Corrida do Parque", "Maratona de São Paulo"))
        self.assertFalse(similar_names("", "Corrida"))

    def test_desligado_por_padrao_nao_faz_nada(self):
        self.put_csv(
            "semanal/2026-11-11/candidatos.csv", row("a-1", "Corrida Nova Sintética", "2027-03-14")
        )
        self.assertFalse(self.auto.enabled())
        self.assertEqual(self.auto.run(), {"skipped": "disabled"})
        self.assertNotIn("catalogo-auto-a-1", self.ids())

    def test_so_importa_o_que_passa_em_todas_as_travas(self):
        self.auto.set_enabled(self.operator, True)
        self.put_csv(
            "semanal/2026-11-11/candidatos.csv",
            row("nova-1", "Corrida Nova Sintética", "2027-03-14", reg="https://i.invalid/inscricao")
            + row("osasco-1", "Corrida de Osasco Sintética", "2027-03-15", city="Osasco")
            + row("passada-1", "Corrida Passada Sintética", "2026-01-10")
            + row("longe-1", "Corrida Distante Sintética", "2030-01-01")
            + row("semlink-1", "Corrida Sem Link Sintética", "2027-05-01", official="")
            + row("http-1", "Corrida Http Sintética", "2027-05-02", official="http://i.invalid/p")
            + row("parecida-1", "Maratona Teste Internacional de São Paulo", "2027-04-04")
            + row("ruim-1", "Corrida Data Ruim", "31/02/2027"),
        )
        # Rodar de teste (dry-run) nunca importa.
        self.put_csv(
            "semanal/2026-11-11/dry-run/candidatos.csv",
            row("seca-1", "Corrida Seca Sintética", "2027-06-01"),
        )
        resumo = self.auto.run("manual")
        self.assertEqual(resumo["created"], 1)
        feito = resumo["files"][0]
        self.assertEqual(
            feito["counts"],
            {"created": 1, "blocked": 6, "review": 0, "unchanged": 0, "invalid": 1, "later": 0},
        )
        self.assertEqual(feito["reasons"]["fora_da_capital"], 1)
        self.assertEqual(feito["reasons"]["data_fora_da_janela"], 2)
        self.assertEqual(feito["reasons"]["sem_pagina_https"], 2)
        self.assertEqual(feito["reasons"]["parecida_com"], 1)
        novas = [i for i in self.ids() if i.startswith("catalogo-auto-")]
        self.assertEqual(novas, ["catalogo-auto-nova-1"])
        corrida = self.catalog._edition("catalogo-auto-nova-1")
        self.assertEqual(corrida["name"], "Corrida Nova Sintética")
        self.assertEqual(corrida["sourceCode"], "catalogo-auto")
        head = self.store.get(("catalog", "EDITION#catalogo-auto-nova-1", "HEAD"))
        self.assertEqual(head["publicationState"], "approved")  # ja aparece no app
        status = self.auto.status()
        self.assertEqual([e["id"] for e in status["recent"]], ["catalogo-auto-nova-1"])
        self.assertEqual(status["lastRun"]["created"], 1)

    def test_repetir_a_execucao_nao_duplica_nem_reprocessa(self):
        self.auto.set_enabled(self.operator, True)
        self.put_csv(
            "semanal/2026-11-11/candidatos.csv",
            row("nova-1", "Corrida Nova Sintética", "2027-03-14"),
        )
        self.assertEqual(self.auto.run()["created"], 1)
        segunda = self.auto.run()
        self.assertEqual((segunda["created"], segunda["files"]), (0, []))  # arquivo ja processado
        # O arquivo reescrito com a mesma corrida (outra execucao do dia) tambem nao duplica.
        self.s3.objects["semanal/2026-11-11/enriquecimento/candidatos.csv"] = self.s3.objects[
            "semanal/2026-11-11/candidatos.csv"
        ]
        terceira = self.auto.run()
        self.assertEqual(terceira["created"], 0)
        self.assertEqual(
            [i for i in self.ids() if i.startswith("catalogo-auto-")], ["catalogo-auto-nova-1"]
        )

    def test_limite_por_execucao_deixa_o_resto_para_a_proxima(self):
        self.auto.set_enabled(self.operator, True)
        self.put_csv(
            "semanal/2026-11-11/candidatos.csv",
            "".join(
                row(f"l-{i}", f"Evento Lote Numero{i} Sintetico", f"2027-0{i}-10")
                for i in range(1, 4)
            ),
        )
        with mock.patch.object(auto_import, "MAX_NEW_PER_RUN", 2):
            primeira = self.auto.run()
            self.assertEqual(primeira["created"], 2)
            self.assertEqual(primeira["files"][0]["counts"]["later"], 1)
            segunda = self.auto.run()  # o arquivo nao foi marcado: continua de onde parou
            self.assertEqual(segunda["created"], 1)
            terceira = self.auto.run()
            self.assertEqual((terceira["created"], terceira["files"]), (0, []))
        self.assertEqual(len([i for i in self.ids() if i.startswith("catalogo-auto-")]), 3)

    def test_ator_do_sistema_so_vale_com_o_importador_que_o_aceita(self):
        payload = {
            "id": "x-1",
            "name": "Corrida X Sintética",
            "date": "2027-08-08",
            "city": "São Paulo",
            "state": "SP",
            "distances": [{"id": "5k", "kilometers": 5}],
        }
        with self.assertRaises(Problem) as negado:
            CatalogImporter(self.catalog).put(
                payload, expected_version=0, origin="https://i.invalid/a", actor=AutoImportActor()
            )
        self.assertEqual(negado.exception.status, 403)
        ok = CatalogImporter(self.catalog, allow_system=True).put(
            payload, expected_version=0, origin="https://i.invalid/a", actor=AutoImportActor()
        )
        self.assertEqual(ok["version"], 1)

    def test_arquivo_invalido_vira_erro_sem_derrubar_a_execucao(self):
        self.auto.set_enabled(self.operator, True)
        self.s3.objects["semanal/2026-11-11/candidatos.csv"] = "isto,nao,e,o,formato\n1,2,3,4,5\n"
        resumo = self.auto.run()
        self.assertEqual(resumo["created"], 0)
        self.assertEqual(resumo["files"][0]["error"], "CSV_SCHEMA_INVALID")


if __name__ == "__main__":
    unittest.main()
