import json
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from runpass.admin_discoveries import DiscoveryStore
from runpass.catalog import CatalogService, seed_synthetic
from runpass.identity import Principal
from runpass.monthly_update import MonthlyUpdate
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 12, 1, 12, tzinfo=timezone.utc)
KEY = "semanal/2026-12-01/descoberta-mensal0300/relatorio.json"


class FakeS3:
    def __init__(self, files):
        self.files = files

    def list_objects_v2(self, **args):
        return {"Contents": [{"Key": k, "ETag": "e"} for k in self.files]}

    def get_object(self, Bucket, Key):
        body = self.files[Key]
        return {"Body": mock.Mock(read=lambda n=None: body)}


def cand(nome, data, cidade="Campinas", **kw):
    return {
        "nome": nome,
        "data": data,
        "cidade": cidade,
        "uf": "SP",
        "distancias_km": kw.pop("distancias_km", [10]),
        "fonte_url": "https://exemplo.invalid/a",
        "trecho": "[FICTICIO]",
        "regiao_consultada": "Campinas e regiao",
        **kw,
    }


def relatorio(*cands):
    return json.dumps({"candidatos": list(cands)}).encode()


class MonthlyUpdateTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        identity = IdentityService(self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW)
        self.catalog = CatalogService(identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.disc = DiscoveryStore(self.store, lambda: NOW.timestamp(), self.catalog)

    def monthly(self, files):
        return MonthlyUpdate(
            self.store, self.disc, FakeS3(files), "bucket", lambda: NOW.timestamp()
        )

    def test_aplica_relatorio_novo_promove_e_nao_repete(self):
        m = self.monthly({KEY: relatorio(cand("[FICTICIA] Prova Nova", "2027-01-10"))})
        out = m.run("manual", "op-1", force=True)
        self.assertEqual(out["counts"]["staged"], 1)
        self.assertEqual(out["counts"]["promoted"], 1)
        self.assertEqual(self.disc.list(status="imported")["matching"], 1)
        again = m.run("schedule")
        self.assertEqual(again["skipped"], "nothing_to_do")  # relatorio ja aplicado
        self.assertEqual(len(m.history()["runs"]), 1)

    def test_desligado_nao_faz_nada_no_horario_mas_o_manual_roda(self):
        m = self.monthly({KEY: relatorio(cand("[FICTICIA] Prova Nova", "2027-01-10"))})
        m.set_enabled("op-1", False)
        self.assertEqual(m.run("schedule"), {"skipped": "disabled"})
        self.assertEqual(m.run("manual", "op-1", force=True)["counts"]["promoted"], 1)

    def test_completa_dado_faltante_de_corrida_existente_sem_trocar_o_que_ja_tem(self):
        sem = cand("[FICTICIA] Sem Km", "2027-01-17", distancias_km=[])
        self.monthly({KEY: relatorio(sem)}).run("manual", "op-1", force=True)
        found = self.disc.find("2027-01-17", "[FICTICIA] Sem Km", "Campinas")
        body = self.catalog._edition(found["editionId"])
        self.assertEqual((body["distances"], body.get("venue")), ([], None))
        # outro mes: a busca achou a distancia, o organizador e o local
        key2 = "semanal/2027-01-01/descoberta-mensal0300/relatorio.json"
        com = cand(
            "[FICTICIA] Sem Km",
            "2027-01-17",
            distancias_km=[10],
            organizador="Org X",
            local="Parque",
        )
        out = self.monthly({key2: relatorio(com)}).run("manual", "op-1", force=True)
        self.assertEqual(out["counts"]["completed"], 1)
        body = self.catalog._edition(found["editionId"])
        self.assertEqual([d["kilometers"] for d in body["distances"]], [10])
        self.assertEqual((body["organizerName"], body["venue"]), ("Org X", "Parque"))
        # terceira busca com outros valores: nada e trocado
        key3 = "semanal/2027-02-01/descoberta-mensal0300/relatorio.json"
        outro = cand(
            "[FICTICIA] Sem Km", "2027-01-17", distancias_km=[5], organizador="Outra", local="Outro"
        )
        out = self.monthly({key3: relatorio(outro)}).run("manual", "op-1", force=True)
        self.assertEqual(out["counts"]["completed"], 0)
        self.assertEqual(self.catalog._edition(found["editionId"])["organizerName"], "Org X")

    def test_fonte_confirma_distancia_informada_por_corredor_sem_apagar_a_do_corredor(self):
        self.monthly(
            {KEY: relatorio(cand("[FICTICIA] Km Corredor", "2027-01-24", distancias_km=[]))}
        ).run("manual", "op-1", force=True)
        found = self.disc.find("2027-01-24", "[FICTICIA] Km Corredor", "Campinas")
        runner = Principal("runner", True)
        identity = self.catalog.identity
        identity.create_profile(runner, "p", {"displayName": "Corredor", "username": "runner"})
        identity.admit(
            runner, "a", {"birthDate": "1990-01-01", "declaresAdult": True, "gender": "undisclosed"}
        )
        self.catalog.add_runner_distance(runner, found["editionId"], "7")
        com = cand("[FICTICIA] Km Corredor", "2027-01-24", distancias_km=[7, 14])
        key2 = "semanal/2027-01-02/descoberta-mensal0300/relatorio.json"
        self.monthly({key2: relatorio(com)}).run("manual", "op-1", force=True)
        distances = self.catalog._edition(found["editionId"])["distances"]
        self.assertEqual(sorted(d["kilometers"] for d in distances), [7, 14])
        self.assertTrue(all("informedBy" not in d for d in distances))

    def test_relatorio_enorme_e_recusado(self):
        m = self.monthly({KEY: b"x" * 8_000_001})
        with self.assertRaises(Problem):
            m.run("manual", "op-1", force=True)
