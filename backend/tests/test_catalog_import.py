import unittest
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet
from runpass.catalog import CatalogFilters, CatalogImporter, CatalogService, seed_synthetic
from runpass.catalog_import import import_rows, parse_csv
from runpass.catalog_sources import (
    ActiveSourceAdapter,
    CsvSourceAdapter,
    LetsDoThisSourceAdapter,
    SourceDisabled,
    SourceError,
    call_with_retry,
)
from runpass.identity import Principal
from runpass.service import IdentityService, Problem
from runpass.store import MemoryStore

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "backend/fixtures/catalog.synthetic.json"
NOW = datetime(2026, 11, 6, 15, tzinfo=timezone.utc)
ORIGIN = "https://exemplo.invalid/calendario"

# Dados FICTICIOS (nao sao provas reais).
CSV = """source_external_id,name,event_date,city,state,country,distances_km,registration_status,official_url,latitude,longitude
example-001,Corrida Exemplo 2027,2027-05-16,São Paulo,SP,BR,"5;10;21,0975",unknown,https://example.org/race-001,-23.55,-46.63
example-002,Desafio Parque Exemplo,2027-06-20,Campinas,SP,BR,"5;10",open,https://example.org/race-002,-22.90,-47.06
"""


class CatalogImportTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        identity = IdentityService(self.store, b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW)
        self.catalog = CatalogService(identity, Fernet.generate_key())
        seed_synthetic(self.catalog, FIXTURE)
        self.actor = Principal("runner", True)
        identity.create_profile(self.actor, "p", {"displayName": "Corredor", "username": "runner"})
        identity.admit(self.actor, "a", {"birthDate": "1990-01-01", "declaresAdult": True})

    def run_csv(self, text=CSV, dry_run=True, source="csv-sp"):
        return import_rows(
            self.catalog,
            None,
            parse_csv(text, source),
            origin=ORIGIN,
            source_code=source,
            dry_run=dry_run,
            synthetic=True,
        )

    def listed(self, **filters):
        return self.catalog.list(self.actor, CatalogFilters(**filters))["items"]

    # ---- CSV: simulacao, importacao e idempotencia ----
    def test_dry_run_validates_and_writes_nothing(self):
        before = len(self.store.items)
        report = self.run_csv(dry_run=True)
        self.assertEqual(report["counts"]["created"], 2)
        self.assertEqual(len(self.store.items), before)
        self.assertNotIn("runId", report)

    def test_import_then_reimport_does_not_duplicate_or_version(self):
        first = self.run_csv(dry_run=False)
        self.assertEqual(first["counts"]["created"], 2)
        found = self.listed(state="SP", dateFrom="2027-01-01", dateTo="2027-12-31")
        self.assertEqual(
            sorted(e["id"] for e in found), ["csv-sp-example-001", "csv-sp-example-002"]
        )
        one = next(e for e in found if e["id"] == "csv-sp-example-001")
        self.assertEqual(one["version"], 1)
        self.assertEqual(
            sorted(float(d["kilometers"]) for d in one["distances"]), [5.0, 10.0, 21.0975]
        )
        self.assertEqual(one["sourceCode"], "csv-sp")
        second = self.run_csv(dry_run=False)
        self.assertEqual(
            second["counts"],
            {"created": 0, "updated": 0, "unchanged": 2, "needs_review": 0, "error": 0},
        )
        again = self.listed(state="SP", dateFrom="2027-01-01", dateTo="2027-12-31")
        self.assertEqual([e["version"] for e in again], [1, 1])

    def test_changed_content_publishes_next_version(self):
        self.run_csv(dry_run=False)
        changed = CSV.replace("Corrida Exemplo 2027", "Corrida Exemplo 2027 (nova edicao)")
        report = self.run_csv(changed, dry_run=False)
        self.assertEqual(report["counts"]["updated"], 1)
        edition = self.catalog.detail(self.actor, "csv-sp-example-001")
        self.assertEqual(
            (edition["version"], edition["name"]), (2, "Corrida Exemplo 2027 (nova edicao)")
        )

    def test_bad_rows_are_reported_one_by_one_and_good_rows_still_load(self):
        bad = CSV + (
            "example-003,Sem data,2027-13-40,São Paulo,SP,BR,10,unknown,https://example.org/x,,\n"
            "example-004,Dist ruim,2027-07-01,São Paulo,SP,BR,abc,unknown,,,\n"
            "example-005,Url ruim,2027-07-02,São Paulo,SP,BR,10,unknown,ftp://nope,,\n"
            "example-006,Lat sozinha,2027-07-03,São Paulo,SP,BR,10,unknown,,-23.5,\n"
            "example-001,Repetida,2027-05-16,São Paulo,SP,BR,10,unknown,,,\n"
        )
        report = self.run_csv(bad, dry_run=False)
        self.assertEqual(report["counts"]["created"], 2)
        self.assertEqual(report["counts"]["error"], 5)
        errors = {r["externalId"]: r for r in report["rows"] if r["status"] == "error"}
        self.assertEqual(
            sorted(errors),
            ["example-001", "example-003", "example-004", "example-005", "example-006"],
        )
        self.assertTrue(all(r["errors"] for r in errors.values()))

    def test_csv_schema_and_size_limits(self):
        with self.assertRaises(Problem) as schema:
            parse_csv("name,city\nx,y\n", "csv-sp")
        self.assertEqual(schema.exception.code, "CSV_SCHEMA_INVALID")
        with self.assertRaises(Problem) as big:
            parse_csv("a" * 2_100_000, "csv-sp")
        self.assertEqual(big.exception.code, "CSV_TOO_LARGE")

    # ---- politica de fontes: nao sobrescrever, nao mesclar, nao apagar ----
    def test_import_never_overwrites_an_edition_from_another_source_or_admin(self):
        CatalogImporter(self.catalog).put(
            {
                "id": "csv-sp-example-001",
                "name": "Corrida cadastrada por admin",
                "date": "2027-05-16",
                "city": "São Paulo",
                "state": "SP",
                "distances": [{"id": "10k", "kilometers": 10}],
            },
            expected_version=0,
            origin="https://admin.invalid/manual",
            synthetic=True,
        )
        report = self.run_csv(dry_run=False)
        row = next(r for r in report["rows"] if r["externalId"] == "example-001")
        self.assertEqual(
            (row["status"], row["detail"]), ("needs_review", "EXISTS_FROM_OTHER_SOURCE_OR_ADMIN")
        )
        self.assertEqual(
            self.catalog.detail(self.actor, "csv-sp-example-001")["name"],
            "Corrida cadastrada por admin",
        )

    def test_possible_duplicate_across_sources_goes_to_review_without_merge(self):
        self.run_csv(dry_run=False, source="csv-sp")
        report = self.run_csv(dry_run=False, source="outra-fonte")
        row = next(r for r in report["rows"] if r["externalId"] == "example-001")
        self.assertEqual(row["status"], "needs_review")
        self.assertTrue(row["detail"].startswith("POSSIBLE_DUPLICATE:csv-sp-example-001"))
        with self.assertRaises(Problem):
            self.catalog.detail(self.actor, "outra-fonte-example-001")

    def test_run_is_recorded_without_payload(self):
        report = self.run_csv(dry_run=False)
        rows = [k for k in self.store.items if k[0] == "operations" and k[1] == "INGEST#csv-sp"]
        self.assertEqual(len(rows), 1)
        saved = self.store.get(rows[0])
        self.assertEqual(saved["id"], report["runId"])
        self.assertEqual(saved["counts"]["created"], 2)
        self.assertNotIn("payload", saved)

    # ---- filtros novos ----
    def test_new_filters_name_contains_registration_and_radius(self):
        self.run_csv(dry_run=False)
        self.assertEqual([e["id"] for e in self.listed(q="parque")], ["csv-sp-example-002"])
        self.assertEqual([e["id"] for e in self.listed(q="DESAFIO exemplo")], [])  # texto contiguo
        self.assertEqual(
            [e["id"] for e in self.listed(registrationStatus="open")], ["csv-sp-example-002"]
        )
        # Inscricao desconhecida nunca aparece como aberta.
        unknown = [
            e["id"]
            for e in self.listed(registrationStatus="unknown", state="SP", dateFrom="2027-01-01")
        ]
        self.assertEqual(unknown, ["csv-sp-example-001"])
        # O fixture sintetico agora tambem carrega coordenadas de Sao Paulo (decisao de
        # 08/11/2026, para testar o raio de proximidade de "Minha Cidade" no app), entao as
        # edicoes sinteticas de SP passam a bater nas duas buscas por raio abaixo.
        synthetic_sp = [
            "synthetic-sp-2024",
            "synthetic-sp-2025",
            "synthetic-sp-2026",
            "synthetic-archived",
        ]
        near_sp = self.listed(lat=-23.55, lon=-46.63, radiusKm=30)
        self.assertEqual(
            sorted(e["id"] for e in near_sp), sorted(["csv-sp-example-001", *synthetic_sp])
        )
        wide = self.listed(lat=-23.55, lon=-46.63, radiusKm=200)
        self.assertEqual(
            sorted(e["id"] for e in wide),
            sorted(["csv-sp-example-001", "csv-sp-example-002", *synthetic_sp]),
        )
        with self.assertRaises(ValueError):
            CatalogFilters(lat=-23.5, lon=-46.6)  # raio incompleto

    # ---- conectores ----
    def test_adapters_are_disabled_without_flag_or_credentials(self):
        for cls in (ActiveSourceAdapter, LetsDoThisSourceAdapter):
            calls = []
            adapter = cls.from_env({}, http=lambda *a: calls.append(a))
            with self.assertRaises(SourceDisabled):
                adapter.fetch()
            self.assertEqual(calls, [])  # nenhuma chamada de rede
            half = cls.from_env({cls.flag: "true"}, http=lambda *a: calls.append(a))
            with self.assertRaises(SourceDisabled):
                half.fetch()  # flag sem credencial
            self.assertEqual(calls, [])

    def test_active_adapter_maps_pages_and_stops(self):
        pages = {
            "1": {
                "results": [
                    {
                        "assetGuid": "g1",
                        "assetName": "Prova A",
                        "activityStartDate": "2027-03-01T07:00:00",
                        "place": {
                            "cityName": "São Paulo",
                            "stateProvinceCode": "SP",
                            "countryCode": "BR",
                        },
                        "distances_km": [5, 10],
                        "urlAdr": "https://example.org/a",
                    },
                    {
                        "assetGuid": "g2",
                        "assetName": "Sem distancia",
                        "activityStartDate": "2027-03-02",
                    },
                ]
            },
            "2": {"results": []},
        }
        seen = []

        def http(url, headers):
            seen.append(url)
            page = url.split("current_page=")[1].split("&")[0]
            return 200, pages[page]

        adapter = ActiveSourceAdapter(
            True, "chave-ficticia", http=http, sleep=lambda s: None, jitter=lambda: 0
        )
        items = adapter.fetch(per_page=2)
        self.assertEqual(len(items), 1)  # a sem distancia nao entra
        self.assertEqual(items[0]["event_date"], "2027-03-01")
        self.assertEqual(items[0]["distances_km"], "5;10")
        self.assertEqual(len(seen), 2)
        # o que o conector devolve entra no mesmo importador
        csv_like = parse_csv(
            "source_external_id,name,event_date,city,state,distances_km\n"
            + ",".join(
                [
                    items[0]["source_external_id"],
                    items[0]["name"],
                    items[0]["event_date"],
                    items[0]["city"],
                    items[0]["state"],
                    items[0]["distances_km"],
                ]
            )
            + "\n",
            "active",
        )
        self.assertEqual(csv_like[0]["errors"], [])

    def test_retry_policy_429_5xx_timeout_and_auth(self):
        sleeps = []
        answers = iter([(429, {}), (503, {}), (200, {"ok": 1})])
        self.assertEqual(
            call_with_retry(lambda: next(answers), sleep=sleeps.append, jitter=lambda: 0), {"ok": 1}
        )
        self.assertEqual(len(sleeps), 2)
        self.assertGreater(sleeps[1], sleeps[0])  # recuo exponencial
        for status in (401, 403):
            calls = []
            with self.assertRaises(SourceError) as auth:
                call_with_retry(
                    lambda s=status: (calls.append(1), (s, {}))[1], sleep=lambda s: None
                )
            self.assertEqual(
                (auth.exception.code, len(calls)), ("SOURCE_AUTH_REJECTED", 1)
            )  # sem retry

        def timeout():
            raise SourceError("SOURCE_UNREACHABLE", retryable=True)

        with self.assertRaises(SourceError) as out:
            call_with_retry(timeout, attempts=3, sleep=lambda s: None)
        self.assertEqual(out.exception.code, "SOURCE_UNREACHABLE")
        with self.assertRaises(SourceError) as always:
            call_with_retry(lambda: (500, {}), attempts=2, sleep=lambda s: None)
        self.assertEqual(always.exception.code, "SOURCE_HTTP_500")

    def test_letsdothis_adapter_uses_bearer_and_search_after(self):
        calls = []

        def http(url, headers):
            calls.append((url, headers))
            if "searchAfter" not in url:
                return 200, {
                    "events": [
                        {
                            "id": "e1",
                            "name": "Prova L",
                            "startDate": "2027-04-04",
                            "distances": ["10"],
                            "location": {"city": "São Paulo", "state": "SP"},
                        }
                    ],
                    "searchAfter": "cursor1",
                }
            return 200, {"events": []}

        adapter = LetsDoThisSourceAdapter(True, "token-ficticio", http=http, sleep=lambda s: None)
        items = adapter.fetch()
        self.assertEqual(items[0]["source_external_id"], "e1")
        self.assertEqual(calls[0][1]["Authorization"], "Bearer token-ficticio")
        self.assertIn("searchAfter=cursor1", calls[1][0])

    def test_csv_adapter_is_always_enabled(self):
        rows = CsvSourceAdapter(CSV).fetch()
        self.assertEqual(len(rows), 2)


if __name__ == "__main__":
    unittest.main()
