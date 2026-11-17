import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from runpass.admin_discoveries import DiscoveryStore, discovery_id
from runpass.catalog import CatalogService, seed_synthetic
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 17, 15, tzinfo=timezone.utc)
HEADER = "data;nome;cidade;uf;local;organizador;distancias_km;fonte_url;trecho;regiao_consultada\n"


def item(name="[FICTICIA] Corrida A", day="2026-12-06", city="Campinas", **kw):
    return {
        "name": name,
        "date": day,
        "city": city,
        "state": "SP",
        "distances": kw.pop("distances", [5, 10]),
        "sourceUrl": "https://exemplo.invalid/a",
        "excerpt": "[FICTICIO] trecho",
        "region": "Campinas e regiao",
        **kw,
    }


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        identity = IdentityService(self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW)
        self.catalog = CatalogService(identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.disc = DiscoveryStore(self.store, lambda: NOW.timestamp(), self.catalog)
        self.op = mock.Mock(subject="op-1")

    def test_api_cria_e_a_mesma_prova_nao_duplica_entre_lotes_e_origens(self):
        r = self.disc.ingest([item()], "api", "lote-1")
        self.assertEqual(r["counts"], {"created": 1, "updated": 0, "unchanged": 0, "invalid": 0})
        again = self.disc.ingest(
            [item(name="[ficticia]  CORRIDA A", city="CAMPINAS")], "csv", "lote-2"
        )
        self.assertEqual(again["counts"]["created"], 0)
        rows = self.disc.list()["items"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["seen"], rows[0]["origin"]), (2, "api"))
        # mesmo lote reenviado: nada muda
        self.assertEqual(self.disc.ingest([item()], "api", "lote-2")["counts"]["unchanged"], 1)

    def test_fato_novo_so_preenche_vazio_e_nunca_sobrescreve(self):
        self.disc.ingest([item(venue="Parque A", organizer=None, distances=[])], "api", "l1")
        self.disc.ingest(
            [item(venue="Parque B", organizer="Org", distances=[21.0975])], "api", "l2"
        )
        row = self.disc.list()["items"][0]
        self.assertEqual(
            (row["venue"], row["organizer"], row["distancesKm"]), ("Parque A", "Org", [21.0975])
        )
        self.assertEqual(row["sourceUrl"], "https://exemplo.invalid/a")

    def test_item_invalido_e_contado_e_nao_gravado(self):
        bad = [
            item(day="2026-13-40"),
            item(name=""),
            item(distances=[0]),
            {**item(), "sourceUrl": "http://inseguro.invalid/x"},
            item(city="X" * 100),
        ]
        r = self.disc.ingest(bad + [item()], "api", "l1")
        self.assertEqual((r["counts"]["invalid"], r["counts"]["created"]), (5, 1))
        self.assertEqual(len(r["errors"]), 5)
        self.assertEqual(self.disc.list()["matching"], 1)

    def test_trecho_e_cortado_em_160_e_lote_grande_e_recusado(self):
        self.disc.ingest([item(excerpt="x" * 500)], "api", "l1")
        self.assertEqual(len(self.disc.list()["items"][0]["excerpt"]), 160)
        with self.assertRaises(Problem) as ctx:
            self.disc.ingest([item()] * 1001, "api", "l")
        self.assertEqual(ctx.exception.code, "BATCH_TOO_LARGE")
        with self.assertRaises(Problem):
            self.disc.ingest([item()], "outra", "l")

    def test_csv_manual_com_bom_e_ponto_e_virgula_e_mesmo_arquivo_duas_vezes(self):
        text = (
            "﻿"
            + HEADER
            + (
                "2026-12-06;[FICTICIA] Corrida A;Campinas;SP;Parque;Org;5|10;https://exemplo.invalid/a;trecho;Campinas\n"
                "2026-12-07;[FICTICIA] Corrida B;Santos;SP;;;;;;Baixada\n"
                "data-ruim;[FICTICIA] C;Santos;SP;;;;;;\n"
            )
        )
        r = self.disc.import_csv(self.op, text)
        self.assertEqual(r["counts"], {"created": 2, "updated": 0, "unchanged": 0, "invalid": 1})
        self.assertEqual(r["errors"][0]["item"], 3)
        again = self.disc.import_csv(self.op, text)
        self.assertEqual(again["counts"]["created"], 0)
        self.assertEqual(self.disc.list(origin="csv")["matching"], 2)

    def test_csv_com_virgula_e_sem_colunas_obrigatorias(self):
        ok = "data,nome,cidade\n2026-12-06,[FICTICIA] D,Jundiai\n"
        self.assertEqual(self.disc.import_csv(self.op, ok)["counts"]["created"], 1)
        with self.assertRaises(Problem) as ctx:
            self.disc.import_csv(self.op, "a;b\n1;2\n")
        self.assertEqual(ctx.exception.code, "CSV_SCHEMA_INVALID")

    def test_lista_filtra_por_mes_status_cidade_busca_e_resume(self):
        self.disc.ingest(
            [
                item("[FICTICIA] A", "2026-12-06", "Campinas"),
                item("[FICTICIA] B", "2027-01-10", "Santos", distances=[]),
                item("[FICTICIA] C", "2026-12-20", "Santos"),
            ],
            "api",
            "l1",
        )
        self.assertEqual(self.disc.list(month="2026-12")["matching"], 2)
        self.assertEqual(self.disc.list(city="santos")["matching"], 2)
        self.assertEqual(self.disc.list(query="[ficticia] c")["matching"], 1)
        s = self.disc.list()["summary"]
        self.assertEqual((s["total"], s["withDistance"], s["cities"]), (3, 2, 2))
        self.assertEqual(s["byMonth"], {"2026-12": 2, "2027-01": 1})
        self.assertEqual(len(self.disc.list(limit=1)["items"]), 1)
        with self.assertRaises(Problem):
            self.disc.list(status="qualquer")

    def test_decisao_humana_com_controle_de_versao_e_auditoria(self):
        self.disc.ingest([item()], "api", "l1")
        row = self.disc.list()["items"][0]
        done = self.disc.decide(self.op, row["id"], row["version"], "review", "conferida")
        self.assertEqual((done["status"], done["decidedBy"]), ("reviewed", "op-1"))
        with self.assertRaises(Problem) as ctx:  # versao velha
            self.disc.decide(self.op, row["id"], row["version"], "reject")
        self.assertEqual(ctx.exception.code, "VERSION_CONFLICT")
        again = self.disc.list()["items"][0]
        self.disc.decide(self.op, row["id"], again["version"], "reject")
        # nova entrada da esteira nao desfaz a decisao humana
        self.disc.ingest([item(venue="Parque")], "api", "l9")
        self.assertEqual(self.disc.list()["items"][0]["status"], "rejected")
        self.assertTrue(any(k[1].startswith("OPERATOR#op-1") for k in self.store.items))
        with self.assertRaises(Problem):
            self.disc.decide(self.op, row["id"], 99, "invalida")
        with self.assertRaises(Problem) as ctx:
            self.disc.decide(self.op, "0" * 16, 1, "review")
        self.assertEqual(ctx.exception.code, "DISCOVERY_NOT_FOUND")

    def test_distancias_sao_gravadas_como_decimal_porque_o_dynamodb_nao_aceita_float(self):
        from decimal import Decimal

        self.disc.ingest([item(distances=[5, 10.5, 21.0975])], "api", "l1")
        gravados = [
            v
            for k, v in self.store.items.items()
            if k[0] == "operations" and k[2].startswith("DISC#")
        ]
        self.assertEqual(len(gravados), 1)
        self.assertTrue(all(isinstance(d, Decimal) for d in gravados[0]["distancesKm"]))
        self.assertEqual(self.disc.list()["items"][0]["distancesKm"], [5.0, 10.5, 21.0975])

    def test_promocao_em_lote_cria_so_com_distancia_nao_repete_e_manda_parecida_para_revisao(self):
        from runpass.catalog import CatalogImporter

        self.disc.ingest(
            [
                item("[FICTICIA] Lote A", "2027-04-04", "Campinas"),
                item("[FICTICIA] Lote B", "2027-04-05", "Santos", distances=[]),
                item("[FICTICIA] Lote C", "2027-04-06", "Jundiai"),
                item("[FICTICIA] Parecida", "2027-04-07", "Sorocaba"),
            ],
            "api",
            "l1",
        )
        # prova parecida ja publicada por outra origem no mesmo dia: o importador manda para revisao
        CatalogImporter(self.catalog).put(
            {
                "id": "outra-origem-parecida",
                "name": "[FICTICIA] Parecida",
                "date": "2027-04-07",
                "city": "Sorocaba",
                "state": "SP",
                "distances": [{"id": "5k", "kilometers": 5}],
            },
            expected_version=0,
            origin="https://exemplo.invalid/outra",
            synthetic=True,
        )
        sim = self.disc.promote_bulk(limit=10, dry_run=True)
        self.assertEqual((sim["processed"], sim["counts"]["created"]), (3, 2))
        self.assertEqual(self.disc.list(status="imported")["matching"], 0)  # simulacao nao grava
        real = self.disc.promote_bulk(limit=10)
        self.assertEqual((real["counts"]["created"], real["counts"]["needs_review"]), (2, 1))
        self.assertEqual(self.disc.list(status="imported")["matching"], 2)
        sem = next(i for i in self.disc.list()["items"] if not i["distancesKm"])
        self.assertEqual(sem["status"], "new")  # sem distancia nunca promove
        again = self.disc.promote_bulk(limit=10)
        self.assertEqual(again["processed"], 0)  # nada e tentado de novo
        for i in self.disc.list(status="imported")["items"]:
            self.assertTrue(self.catalog._edition(i["editionId"]))

    def test_promocao_em_lote_respeita_o_limite_e_diz_quanto_falta(self):
        self.disc.ingest(
            [item(f"[FICTICIA] L{i}", f"2027-05-{i + 1:02d}", "Campinas") for i in range(5)],
            "api",
            "l1",
        )
        r = self.disc.promote_bulk(limit=2)
        self.assertEqual((r["processed"], r["remaining"], r["counts"]["created"]), (2, 3, 2))

    def test_id_e_estavel_sem_acento_e_caixa(self):
        self.assertEqual(
            discovery_id("2026-12-06", "Corrida São José", "Jundiaí"),
            discovery_id("2026-12-06", "corrida  sao jose", "JUNDIAI"),
        )


if __name__ == "__main__":
    unittest.main()
