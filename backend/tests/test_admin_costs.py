"""Custos do portal: Cost Explorer (AWS) e consumo da OpenAI lido dos logs. Dados sinteticos."""

import json
import unittest
from datetime import datetime, timezone

from runpass.admin_costs import AwsCosts, OpenAiUsage
from runpass.store import Unavailable

NOW = datetime(2026, 11, 10, 15, tzinfo=timezone.utc)


def amount(value):
    return {"UnblendedCost": {"Amount": str(value), "Unit": "USD"}}


class FakeCe:
    def __init__(self):
        self.calls, self.fail, self.forecast_fail = [], False, False

    def get_cost_and_usage(self, **args):
        if self.fail:
            raise RuntimeError("DataUnavailable")
        self.calls.append(args)
        if args.get("GroupBy"):
            return {
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": args["TimePeriod"]["Start"]},
                        "Groups": [
                            {"Keys": ["AWS Lambda"], "Metrics": amount(1.5)},
                            {"Keys": ["Amazon DynamoDB"], "Metrics": amount(4.25)},
                        ],
                    }
                ]
            }
        if args["Granularity"] == "DAILY":
            return {
                "ResultsByTime": [
                    {"TimePeriod": {"Start": "2026-11-01"}, "Total": amount(2)},
                    {"TimePeriod": {"Start": "2026-11-02"}, "Total": amount(3.75)},
                ]
            }
        return {
            "ResultsByTime": [
                {"TimePeriod": {"Start": "2026-06-01"}, "Total": amount(10), "Estimated": False},
                {"TimePeriod": {"Start": "2026-11-01"}, "Total": amount(5.75), "Estimated": True},
            ]
        }

    def get_cost_forecast(self, **args):
        if self.forecast_fail:
            raise RuntimeError("DataUnavailableException")
        self.forecast_args = args
        return {"Total": {"Amount": "12.0"}}


class AwsCostsTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW.timestamp()
        self.ce = FakeCe()
        self.costs = AwsCosts(self.ce, lambda: self.now, 54.61)

    def test_relatorio_do_mes_por_servico_dia_e_previsao(self):
        r = self.costs.report()
        self.assertEqual((r["month"], r["totalUsd"], r["budgetUsd"]), ("2026-11", 5.75, 54.61))
        self.assertEqual(r["forecastUsd"], 17.75)  # gasto ate agora + previsao do restante
        self.assertEqual([s["service"] for s in r["byService"]], ["Amazon DynamoDB", "AWS Lambda"])
        self.assertEqual(r["daily"][1], {"date": "2026-11-02", "usd": 3.75})
        self.assertEqual(r["months"][0]["month"], "2026-06")  # 6 meses, o do mes corrente incluso
        self.assertTrue(r["months"][1]["estimated"])
        periodo = self.ce.calls[0]["TimePeriod"]
        self.assertEqual(
            (periodo["Start"], periodo["End"]), ("2026-11-01", "2026-11-11")
        )  # fim exclusivo
        self.assertEqual(self.ce.calls[2]["TimePeriod"]["Start"], "2026-06-01")

    def test_cache_evita_cobranca_repetida_do_cost_explorer(self):
        self.costs.report()
        n = len(self.ce.calls)
        self.now += 60
        self.costs.report()
        self.assertEqual(len(self.ce.calls), n)
        self.now += 901
        self.costs.report()
        self.assertEqual(len(self.ce.calls), 2 * n)

    def test_sem_previsao_o_painel_segue_e_falha_do_ce_vira_indisponivel(self):
        self.ce.forecast_fail = True
        self.assertIsNone(self.costs.report()["forecastUsd"])
        self.ce.fail = True
        with self.assertRaises(Unavailable):
            AwsCosts(self.ce, lambda: self.now).report()


class FakeLogs:
    def __init__(self, events):
        self.events, self.fail, self.calls = events, False, []

    def filter_log_events(self, **args):
        if self.fail:
            raise RuntimeError("sem acesso")
        self.calls.append(args)
        return {"events": self.events.get(args["logGroupName"], [])}


def line(entrada, saida, buscas, chamadas=1, day=10, hour=12, month=11):
    ts = datetime(2026, month, day, hour, tzinfo=timezone.utc).timestamp() * 1000
    uso = {"chamadas": chamadas, "entrada": entrada, "saida": saida, "buscas": buscas}
    return {"timestamp": ts, "message": json.dumps({"uso_openai": uso})}


class OpenAiUsageTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW.timestamp()
        self.events = {
            "/aws/lambda/g-semanal": [
                line(1_000_000, 200_000, 10, 5, day=9),
                line(500_000, 100_000, 4, 3, day=10),
                line(100, 100, 1, month=10, day=30),  # mes anterior
                {"timestamp": NOW.timestamp() * 1000, "message": "uso_openai lixo {nao json}"},
                {
                    "timestamp": NOW.timestamp() * 1000,
                    "message": json.dumps({"uso_openai": {"chamadas": "x"}}),
                },
            ],
            "/aws/lambda/g-busca": [line(2_000, 300, 0, 1, day=10)],
        }
        self.logs = FakeLogs(self.events)
        self.groups = ["/aws/lambda/g-semanal", "/aws/lambda/g-busca"]

    def usage(self, prices=None):
        return OpenAiUsage(self.logs, self.groups, lambda: self.now, prices, 10)

    def test_soma_o_mes_por_dia_e_ignora_linhas_invalidas(self):
        r = self.usage().report()
        self.assertEqual(
            r["thisMonth"],
            {
                "chamadas": 9,
                "entrada": 1_502_000,
                "saida": 300_300,
                "buscas": 14,
                "estimatedUsd": None,
            },
        )
        self.assertEqual(r["previousMonth"]["chamadas"], 1)
        self.assertEqual([d["date"] for d in r["daily"]], ["2026-11-09", "2026-11-10"])
        self.assertEqual(r["daily"][1]["entrada"], 502_000)
        self.assertFalse(r["priced"])
        self.assertEqual(r["limitUsd"], 10)
        self.assertEqual(self.logs.calls[0]["filterPattern"], '"uso_openai"')

    def test_custo_estimado_so_com_os_tres_precos_configurados(self):
        r = self.usage({"in": 2.0, "out": 8.0, "search": 0.01}).report()
        # 1,502 M * 2 + 0,3003 M * 8 + 14 * 0,01
        self.assertEqual(r["thisMonth"]["estimatedUsd"], round(3.004 + 2.4024 + 0.14, 4))
        self.assertTrue(r["priced"])
        self.assertIsNone(
            self.usage({"in": 2.0, "out": None, "search": 0.01}).report()["thisMonth"][
                "estimatedUsd"
            ]
        )

    def test_dia_segue_o_fuso_de_sao_paulo(self):
        self.events["/aws/lambda/g-busca"] = [
            line(1, 1, 0, 1, day=11, hour=2)
        ]  # 23:00 de 10/11 em SP
        days = [d["date"] for d in self.usage().report()["daily"]]
        self.assertIn("2026-11-10", days)
        self.assertNotIn("2026-11-11", days)

    def test_sem_acesso_aos_logs_fica_indisponivel(self):
        self.logs.fail = True
        with self.assertRaises(Unavailable):
            self.usage().report()


if __name__ == "__main__":
    unittest.main()
