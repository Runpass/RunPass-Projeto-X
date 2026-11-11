"""Custos do portal: Cost Explorer (AWS) e consumo da OpenAI lido dos logs. Dados sinteticos."""

import json
import unittest
from datetime import datetime, timezone

from runpass.admin_costs import (
    AwsCosts,
    ClaudeCodeUsage,
    OpenAiOrg,
    OpenAiUsage,
    anthropic_transport,
)
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


class FakeOpenAi:
    """API de administracao falsa: costs e usage/completions em 2 dias, mais as chaves do projeto."""

    def __init__(self):
        self.calls, self.status = [], 200

    def __call__(self, path, params, key):
        self.calls.append((path, params, key))
        if self.status != 200:
            return self.status, {}
        d1, d2 = 1_793_836_800, 1_793_923_200  # 2026-11-05 e 2026-11-06 (UTC)
        if path == "/v1/organization/costs":
            return 200, {
                "data": [
                    {
                        "start_time": d1,
                        "results": [
                            {
                                "amount": {"value": 0.42, "currency": "usd"},
                                "line_item": "gpt, input",
                            }
                        ],
                    },
                    {
                        "start_time": d2,
                        "results": [
                            {
                                "amount": {"value": 1.5, "currency": "usd"},
                                "line_item": "gpt, input",
                            },
                            {
                                "amount": {"value": 0.5, "currency": "usd"},
                                "line_item": "web search",
                            },
                        ],
                    },
                ],
                "has_more": False,
            }
        if path == "/v1/organization/usage/completions":
            return 200, {
                "data": [
                    {
                        "start_time": d2,
                        "results": [
                            {
                                "num_model_requests": 100,
                                "input_tokens": 1_000_000,
                                "output_tokens": 50_000,
                                "api_key_id": "key_1",
                                "model": "m1",
                            },
                            {
                                "num_model_requests": 76,
                                "input_tokens": 2_000_000,
                                "output_tokens": 334_579,
                                "api_key_id": "key_2",
                                "model": "m2",
                            },
                        ],
                    }
                ],
                "has_more": False,
            }
        if path.endswith("/api_keys"):
            return 200, {"data": [{"id": "key_1", "name": "catalogo-busca-dev"}]}
        return 404, {}


class OpenAiOrgTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW.timestamp()
        self.api = FakeOpenAi()
        self.org = OpenAiOrg(lambda: "sk-admin-teste", lambda: self.now, "proj_abc", 10, self.api)

    def test_replica_a_pagina_usage_do_console(self):
        r = self.org.report()
        self.assertEqual((r["month"], r["totalUsd"], r["limitUsd"]), ("2026-11", 2.42, 10))
        self.assertEqual((r["totalRequests"], r["totalTokens"]), (176, 3_384_579))
        self.assertEqual(
            [(d["date"], d["usd"], d["requests"]) for d in r["daily"]],
            [("2026-11-05", 0.42, 0), ("2026-11-06", 2.0, 176)],
        )
        self.assertEqual(
            r["byApiKey"][0], {"name": "catalogo-busca-dev", "requests": 100, "tokens": 1_050_000}
        )
        self.assertEqual(r["byApiKey"][1]["name"], "key_2")  # sem nome conhecido: mostra o id
        self.assertEqual([x["name"] for x in r["byModel"]], ["m2", "m1"])
        self.assertEqual(r["byLineItem"][0], {"name": "gpt, input", "usd": 1.92})
        costs = self.api.calls[0]
        self.assertEqual(costs[0], "/v1/organization/costs")
        self.assertEqual(costs[1]["project_ids"], ["proj_abc"])
        self.assertEqual(costs[1]["start_time"], 1_793_491_200)  # 01/11/2026 00:00 UTC
        self.assertEqual(costs[2], "sk-admin-teste")

    def test_motivos_seguros_para_cada_tipo_de_falha(self):
        def motivo(org):
            with self.assertRaises(Unavailable) as ctx:
                org.report()
            return ctx.exception.reason

        for status, esperado in (
            (401, "http_401"),
            (403, "http_403"),
            (400, "http_400"),
            (0, "network"),
        ):
            self.api.status = status
            self.assertEqual(
                motivo(OpenAiOrg(lambda: "sk-admin-teste", lambda: self.now, "", None, self.api)),
                esperado,
            )

        class ParameterNotFound(Exception):
            pass

        def falha():
            raise ParameterNotFound("o valor da chave nao deve vazar")

        r = motivo(OpenAiOrg(falha, lambda: self.now, "", None, self.api))
        self.assertEqual(r, "key_read_failed:ParameterNotFound")
        self.assertEqual(
            motivo(OpenAiOrg(lambda: "", lambda: self.now, "", None, self.api)), "empty_key"
        )
        self.assertEqual(motivo(OpenAiOrg(None, lambda: self.now)), "not_configured")

    def test_erro_da_openai_ou_da_leitura_da_chave_vira_indisponivel(self):
        self.api.status = 401
        with self.assertRaises(Unavailable):
            self.org.report()

        def sem_acesso():
            raise RuntimeError("AccessDenied")

        with self.assertRaises(Unavailable):
            OpenAiOrg(sem_acesso, lambda: self.now, "", None, self.api).report()
        with self.assertRaises(Unavailable):
            OpenAiOrg(None, lambda: self.now).report()  # sem chave configurada

    def test_cache_e_a_chave_nao_aparece_no_resultado(self):
        r = self.org.report()
        n = len(self.api.calls)
        self.org.report()
        self.assertEqual(len(self.api.calls), n)
        self.assertNotIn("sk-admin", json.dumps(r))


class FakeClaudeCode:
    """Relatorio do Claude Code falso (dados ficticios): um dia por consulta, com paginacao no dia 10."""

    def __init__(self):
        self.calls, self.status = [], 200

    def __call__(self, path, params, key):
        self.calls.append((path, dict(params), key))
        if self.status != 200:
            return self.status, {}
        day = params["starting_at"]
        if day == "2026-11-02":
            row = {
                "actor": {"type": "user_actor", "email_address": "dev1@exemplo.test"},
                "core_metrics": {"num_sessions": 3},
                "customer_type": "subscription",
                "model_breakdown": [
                    {
                        "model": "claude-sonnet-5-5",
                        "estimated_cost": {"amount": 250, "currency": "USD"},
                        "tokens": {
                            "input": 1000,
                            "output": 200,
                            "cache_creation": 50,
                            "cache_read": 750,
                        },
                    }
                ],
            }
            return 200, {"data": [row], "has_more": False, "next_page": None}
        if day == "2026-11-10":
            if "page" not in params:
                row = {
                    "actor": {"type": "api_actor", "api_key_name": "ci-key"},
                    "core_metrics": {"num_sessions": 1},
                    "customer_type": "api",
                    "model_breakdown": [
                        {
                            "model": "claude-opus-5-5",
                            "estimated_cost": {"amount": 1234, "currency": "USD"},
                            "tokens": {
                                "input": 10,
                                "output": 20,
                                "cache_creation": 0,
                                "cache_read": 0,
                            },
                        }
                    ],
                }
                return 200, {"data": [row], "has_more": True, "next_page": "p2"}
            row = {
                "actor": {"type": "user_actor", "email_address": "dev1@exemplo.test"},
                "core_metrics": {"num_sessions": 2},
                "customer_type": "subscription",
                "model_breakdown": [
                    {
                        "model": "claude-sonnet-5-5",
                        "estimated_cost": {"amount": 50, "currency": "USD"},
                        "tokens": {
                            "input": 100,
                            "output": 100,
                            "cache_creation": 0,
                            "cache_read": 0,
                        },
                    }
                ],
            }
            return 200, {"data": [row], "has_more": False, "next_page": None}
        return 200, {"data": [], "has_more": False, "next_page": None}


class ClaudeCodeUsageTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW.timestamp()
        self.api = FakeClaudeCode()
        self.usage = ClaudeCodeUsage(
            lambda: "sk-ant-admin01-teste", lambda: self.now, 100, self.api
        )

    def test_soma_o_mes_dia_a_dia_com_custo_em_dolar_e_paginacao(self):
        r = self.usage.report()
        self.assertEqual(r["month"], "2026-11")
        self.assertEqual(len(r["daily"]), 10)  # 1 a 10 de novembro
        self.assertEqual(r["totalUsd"], 15.34)  # 2,50 + 12,34 + 0,50
        self.assertEqual(r["totalSessions"], 6)
        self.assertEqual(r["totalTokens"], 2000 + 30 + 200)
        self.assertEqual(r["limitUsd"], 100)
        by_actor = {a["name"]: a for a in r["byActor"]}
        self.assertEqual(by_actor["dev1@exemplo.test"]["usd"], 3.0)
        self.assertEqual(by_actor["ci-key"]["type"], "api")
        self.assertEqual([m["name"] for m in r["byModel"]][0], "claude-opus-5-5")
        self.assertEqual(r["daily"][9]["usd"], 12.84)

    def test_a_consulta_leva_so_a_chave_no_cabecalho_do_transporte_e_pagina(self):
        self.usage.report()
        ten = [c for c in self.api.calls if c[1]["starting_at"] == "2026-11-10"]
        self.assertEqual(len(ten), 2)
        self.assertEqual(ten[1][1]["page"], "p2")
        self.assertTrue(
            all(c[0] == "/v1/organizations/usage_report/claude_code" for c in self.api.calls)
        )

    def test_motivos_seguros_cache_e_chave_fora_do_resultado(self):
        def motivo(usage):
            with self.assertRaises(Unavailable) as erro:
                usage.report()
            return erro.exception.reason

        self.api.status = 401
        self.assertEqual(motivo(self.usage), "http_401")
        self.api.status = 0
        self.assertEqual(
            motivo(ClaudeCodeUsage(lambda: "k", lambda: self.now, None, self.api)), "network"
        )
        self.assertEqual(motivo(ClaudeCodeUsage(None, lambda: self.now)), "not_configured")
        self.assertEqual(motivo(ClaudeCodeUsage(lambda: "", lambda: self.now)), "empty_key")

        def sem_acesso():
            raise RuntimeError("ParameterNotFound")

        self.assertEqual(
            motivo(ClaudeCodeUsage(sem_acesso, lambda: self.now)), "key_read_failed:RuntimeError"
        )
        self.api.status = 200
        ok = ClaudeCodeUsage(lambda: "sk-ant-admin01-segredo", lambda: self.now, None, self.api)
        first = ok.report()
        calls = len(self.api.calls)
        self.assertIs(ok.report(), first)  # cache de 15 minutos
        self.assertEqual(len(self.api.calls), calls)
        self.assertNotIn("segredo", json.dumps(first))


class ResilienciaTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW.timestamp()

    def test_chave_com_espaco_ou_quebra_de_linha_e_limpa_antes_de_usar(self):
        usadas = []

        def api(path, params, key):
            usadas.append(key)
            return 200, {"data": [], "has_more": False}

        ClaudeCodeUsage(lambda: "  sk-ant-admin01-teste\n", lambda: self.now, None, api).report()
        OpenAiOrg(lambda: "sk-admin-teste \n", lambda: self.now, "", None, api).report()
        self.assertTrue(usadas)
        self.assertTrue(all(k == k.strip() and k for k in usadas))

    def test_limite_429_fica_60_segundos_em_cache_e_depois_tenta_de_novo(self):
        chamadas, relogio = [], [self.now]

        def api(path, params, key):
            chamadas.append(path)
            return 429, {}

        for usage in (
            OpenAiOrg(lambda: "k", lambda: relogio[0], "", None, api),
            ClaudeCodeUsage(lambda: "k", lambda: relogio[0], None, api),
        ):
            chamadas.clear()
            relogio[0] = self.now
            for _ in range(3):  # cliques repetidos em "Atualizar"
                with self.assertRaises(Unavailable) as erro:
                    usage.report()
                self.assertEqual(erro.exception.reason, "http_429")
            self.assertEqual(len(chamadas), 1)
            relogio[0] += 61
            with self.assertRaises(Unavailable):
                usage.report()
            self.assertEqual(len(chamadas), 2)

    def test_erro_de_chave_nao_fica_em_cache(self):
        def api(path, params, key):
            return 401, {}

        usage = ClaudeCodeUsage(lambda: "k", lambda: self.now, None, api)
        with self.assertRaises(Unavailable):
            usage.report()
        api2 = lambda path, params, key: (200, {"data": [], "has_more": False})  # noqa: E731
        usage.transport = api2  # a pessoa corrigiu a chave: a proxima consulta ja vale
        self.assertEqual(usage.report()["totalUsd"], 0)

    def test_falha_de_rede_diz_o_tipo(self):
        def api(path, params, key):
            return 0, {"error": "invalid_header"}

        with self.assertRaises(Unavailable) as erro:
            ClaudeCodeUsage(lambda: "k", lambda: self.now, None, api).report()
        self.assertEqual(erro.exception.reason, "network:invalid_header")

    def test_transporte_classifica_o_erro_sem_rede_real(self):
        import urllib.error
        from unittest import mock

        casos = [
            (ValueError("Invalid header value b'x\\n'"), "invalid_header"),
            (ValueError("Expecting value"), "invalid_json"),
            (TimeoutError(), "timeout"),
            (urllib.error.URLError("[SSL: CERTIFICATE_VERIFY_FAILED]"), "tls"),
            (urllib.error.URLError("Name or service not known"), "dns_or_connect"),
            (ConnectionResetError(), "connect"),
        ]
        for falha, esperado in casos:
            with mock.patch("urllib.request.urlopen", side_effect=falha):
                self.assertEqual(anthropic_transport("/x", {}, "k"), (0, {"error": esperado}))
