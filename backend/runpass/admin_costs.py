"""Custos para o painel do portal (so leitura).

- AWS: Cost Explorer (custo da conta: mes ate agora, por servico, por dia, ultimos meses e previsao).
  Cada consulta ao Cost Explorer e cobrada pela AWS (US$ 0,01 por chamada), entao o resultado fica em cache.
- OpenAI: soma das linhas `{"uso_openai": ...}` que as Lambdas do catalogo imprimem (chamadas, tokens, buscas).
  E uma ESTIMATIVA: o custo em dinheiro usa os precos configurados (pagina oficial de precos da OpenAI) e nao
  inclui uso feito fora das Lambdas nem o anterior a esta medicao. A fatura da OpenAI e a fonte de verdade.
"""

import json
import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .store import Unavailable

CACHE_TTL = 900
FUSO = ZoneInfo("America/Sao_Paulo")


def _month_start(day):
    return day.replace(day=1)


def _add_months(day, n):
    index = day.year * 12 + day.month - 1 + n
    return date(index // 12, index % 12 + 1, 1)


class AwsCosts:
    def __init__(self, ce_client, clock, monthly_budget_usd=None):
        self.ce, self.clock, self.budget = ce_client, clock, monthly_budget_usd
        self._cache = None

    def report(self):
        now = self.clock()
        if self._cache and now - self._cache[0] < CACHE_TTL:
            return self._cache[1]
        if self.ce is None:
            raise Unavailable()
        today = datetime.fromtimestamp(now, timezone.utc).date()
        start, tomorrow = _month_start(today), today + timedelta(days=1)
        first = _add_months(start, -5)
        metric = {"Metrics": ["UnblendedCost"]}
        try:
            by_service = self.ce.get_cost_and_usage(
                TimePeriod={"Start": start.isoformat(), "End": tomorrow.isoformat()},
                Granularity="MONTHLY",
                GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
                **metric,
            )
            daily = self.ce.get_cost_and_usage(
                TimePeriod={"Start": start.isoformat(), "End": tomorrow.isoformat()},
                Granularity="DAILY",
                **metric,
            )
            monthly = self.ce.get_cost_and_usage(
                TimePeriod={"Start": first.isoformat(), "End": tomorrow.isoformat()},
                Granularity="MONTHLY",
                **metric,
            )
        except Exception as error:  # noqa: BLE001 - Cost Explorer desligado/sem permissao: sem detalhe vazado
            raise Unavailable() from error
        services = sorted(
            (
                {
                    "service": g["Keys"][0],
                    "usd": round(float(g["Metrics"]["UnblendedCost"]["Amount"]), 4),
                }
                for r in by_service["ResultsByTime"]
                for g in r["Groups"]
            ),
            key=lambda x: -x["usd"],
        )
        total = round(sum(x["usd"] for x in services), 2)
        forecast = None
        if today < _add_months(start, 1) - timedelta(days=1):
            try:  # a previsao so existe com historico suficiente; sem ela, o painel segue sem
                f = self.ce.get_cost_forecast(
                    TimePeriod={
                        "Start": tomorrow.isoformat(),
                        "End": _add_months(start, 1).isoformat(),
                    },
                    Metric="UNBLENDED_COST",
                    Granularity="MONTHLY",
                )
                forecast = round(total + float(f["Total"]["Amount"]), 2)
            except Exception:  # noqa: BLE001
                forecast = None
        result = {
            "currency": "USD",
            "month": start.isoformat()[:7],
            "totalUsd": total,
            "forecastUsd": forecast,
            "budgetUsd": self.budget,
            "byService": services[:12],
            "daily": [
                {
                    "date": r["TimePeriod"]["Start"],
                    "usd": round(float(r["Total"]["UnblendedCost"]["Amount"]), 4),
                }
                for r in daily["ResultsByTime"]
            ],
            "months": [
                {
                    "month": r["TimePeriod"]["Start"][:7],
                    "usd": round(float(r["Total"]["UnblendedCost"]["Amount"]), 2),
                    "estimated": bool(r.get("Estimated")),
                }
                for r in monthly["ResultsByTime"]
            ],
        }
        self._cache = (now, result)
        return result


class OpenAiUsage:
    """Consumo da OpenAI lido dos logs das Lambdas do catalogo (so as linhas `uso_openai`)."""

    def __init__(self, logs_client, log_groups, clock, prices=None, monthly_limit_usd=None):
        self.logs, self.groups, self.clock = logs_client, log_groups, clock
        self.prices = prices or {}
        self.limit = monthly_limit_usd

    def estimate(self, usage):
        p = self.prices
        if None in (p.get("in"), p.get("out"), p.get("search")):
            return None
        return round(
            usage["entrada"] / 1e6 * p["in"]
            + usage["saida"] / 1e6 * p["out"]
            + usage["buscas"] * p["search"],
            4,
        )

    def report(self):
        if self.logs is None or not self.groups:
            raise Unavailable()
        now = self.clock()
        today = datetime.fromtimestamp(now, FUSO).date()
        since = _add_months(_month_start(today), -1)  # mes passado + mes atual
        since_ms = int(datetime(since.year, since.month, since.day, tzinfo=FUSO).timestamp() * 1000)
        days = {}
        for group in self.groups:
            token = None
            for _ in range(10):
                args = {
                    "logGroupName": group,
                    "startTime": since_ms,
                    "filterPattern": '"uso_openai"',
                    "limit": 1000,
                }
                if token:
                    args["nextToken"] = token
                try:
                    page = self.logs.filter_log_events(**args)
                except Exception as error:  # noqa: BLE001
                    raise Unavailable() from error
                for event in page.get("events", []):
                    found = re.search(r"\{.*\}", event["message"])
                    try:
                        uso = json.loads(found[0])["uso_openai"] if found else None
                        values = {
                            k: max(0, int(uso[k]))
                            for k in ("chamadas", "entrada", "saida", "buscas")
                        }
                    except (ValueError, KeyError, TypeError):
                        continue
                    day = datetime.fromtimestamp(event["timestamp"] / 1000, FUSO).date().isoformat()
                    row = days.setdefault(day, dict.fromkeys(values, 0))
                    for k, v in values.items():
                        row[k] += v
                token = page.get("nextToken")
                if not token:
                    break
        this_month = today.isoformat()[:7]
        sums = {
            "mes": dict.fromkeys(("chamadas", "entrada", "saida", "buscas"), 0),
            "anterior": None,
        }
        previous = _add_months(_month_start(today), -1).isoformat()[:7]
        prev = dict.fromkeys(("chamadas", "entrada", "saida", "buscas"), 0)
        for day, row in days.items():
            target = sums["mes"] if day[:7] == this_month else prev if day[:7] == previous else None
            if target:
                for k, v in row.items():
                    target[k] += v
        return {
            "month": this_month,
            "priced": self.estimate(sums["mes"]) is not None,
            "limitUsd": self.limit,
            "thisMonth": {**sums["mes"], "estimatedUsd": self.estimate(sums["mes"])},
            "previousMonth": {**prev, "estimatedUsd": self.estimate(prev)},
            "daily": [
                {"date": d, **r, "estimatedUsd": self.estimate(r)}
                for d, r in sorted(days.items())
                if d[:7] == this_month
            ],
        }
