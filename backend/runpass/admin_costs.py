"""Custos para o painel do portal (so leitura).

- AWS: Cost Explorer (custo da conta: mes ate agora, por servico, por dia, ultimos meses e previsao).
  Cada consulta ao Cost Explorer e cobrada pela AWS (US$ 0,01 por chamada), entao o resultado fica em cache.
- OpenAI: soma das linhas `{"uso_openai": ...}` que as Lambdas do catalogo imprimem (chamadas, tokens, buscas).
  E uma ESTIMATIVA: o custo em dinheiro usa os precos configurados (pagina oficial de precos da OpenAI) e nao
  inclui uso feito fora das Lambdas nem o anterior a esta medicao. A fatura da OpenAI e a fonte de verdade.
"""

import json
import re
import urllib.error
import urllib.parse
import urllib.request
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


OPENAI_HOST = "https://api.openai.com"


def openai_transport(path, params, key, timeout=15):
    """GET so em api.openai.com (host fixo; so o caminho e os parametros variam). Devolve (status, json)."""
    url = f"{OPENAI_HOST}{path}?{urllib.parse.urlencode(params, doseq=True)}"
    request = urllib.request.Request(  # noqa: S310 - host fixo https
        url, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.status, json.loads(response.read(5_000_000))
    except urllib.error.HTTPError as error:
        return error.code, {}
    except (urllib.error.URLError, OSError, ValueError):
        return 0, {}


class OrgUnavailable(Unavailable):
    """Indisponivel com um motivo curto e seguro para mostrar (nunca traz a chave nem o corpo da resposta)."""

    def __init__(self, reason):
        super().__init__()
        self.reason = reason


class OpenAiOrg:
    """Gasto e uso reais da OpenAI pela API de administracao (a mesma fonte da pagina Usage do console).

    Exige uma chave de ADMINISTRADOR (`sk-admin-...`), guardada no SSM e lida so aqui; ela nunca sai da funcao
    nem e registrada. Sem a chave configurada, o painel usa a estimativa pelos logs (`OpenAiUsage`)."""

    def __init__(
        self, key_loader, clock, project_id="", monthly_limit_usd=None, transport=openai_transport
    ):
        self.key_loader, self.clock, self.project = key_loader, clock, project_id
        self.limit, self.transport = monthly_limit_usd, transport
        self._cache = None

    @property
    def configured(self):
        return self.key_loader is not None

    def _pages(self, path, params, key):
        buckets, page = [], None
        for _ in range(10):
            query = dict(params, **({"page": page} if page else {}))
            status, body = self.transport(path, query, key)
            if status != 200:
                raise OrgUnavailable("network" if status == 0 else f"http_{status}")
            buckets += body.get("data", [])
            page = body.get("next_page") if body.get("has_more") else None
            if not page:
                break
        return buckets

    def report(self):
        if not self.configured:
            raise OrgUnavailable("not_configured")
        now = self.clock()
        if self._cache and now - self._cache[0] < CACHE_TTL:
            return self._cache[1]
        try:
            key = self.key_loader()
        except Exception as error:  # noqa: BLE001 - sem permissao ou parametro: cai para a estimativa
            raise OrgUnavailable("key_read_failed:" + type(error).__name__[:40]) from error
        if not key:
            raise OrgUnavailable("empty_key")
        today = datetime.fromtimestamp(now, timezone.utc).date()
        start = _month_start(today)
        start_ts = int(
            datetime(start.year, start.month, start.day, tzinfo=timezone.utc).timestamp()
        )
        base = {"start_time": start_ts, "bucket_width": "1d", "limit": 31}
        if self.project:
            base["project_ids"] = [self.project]
        costs = self._pages("/v1/organization/costs", {**base, "group_by": ["line_item"]}, key)
        usage = self._pages(
            "/v1/organization/usage/completions", {**base, "group_by": ["api_key_id", "model"]}, key
        )
        days, items, keys, models = {}, {}, {}, {}

        def day(bucket):
            iso = datetime.fromtimestamp(bucket["start_time"], timezone.utc).date().isoformat()
            return days.setdefault(
                iso, {"date": iso, "usd": 0.0, "requests": 0, "inputTokens": 0, "outputTokens": 0}
            )

        for bucket in costs:
            row = day(bucket)
            for r in bucket.get("results", []):
                value = float((r.get("amount") or {}).get("value") or 0)
                row["usd"] += value
                name = r.get("line_item") or "outros"
                items[name] = items.get(name, 0.0) + value
        for bucket in usage:
            row = day(bucket)
            for r in bucket.get("results", []):
                req, tin, tout = (
                    int(r.get(k) or 0)
                    for k in ("num_model_requests", "input_tokens", "output_tokens")
                )
                row["requests"] += req
                row["inputTokens"] += tin
                row["outputTokens"] += tout
                for table, ident in ((keys, r.get("api_key_id")), (models, r.get("model"))):
                    entry = table.setdefault(ident or "—", {"requests": 0, "tokens": 0})
                    entry["requests"] += req
                    entry["tokens"] += tin + tout
        names = self._key_names(key)
        daily = [dict(d, usd=round(d["usd"], 4)) for _, d in sorted(days.items())]
        result = {
            "month": start.isoformat()[:7],
            "totalUsd": round(sum(d["usd"] for d in daily), 2),
            "limitUsd": self.limit,
            "totalRequests": sum(d["requests"] for d in daily),
            "totalTokens": sum(d["inputTokens"] + d["outputTokens"] for d in daily),
            "inputTokens": sum(d["inputTokens"] for d in daily),
            "outputTokens": sum(d["outputTokens"] for d in daily),
            "daily": daily,
            "byApiKey": sorted(
                ({"name": names.get(k, k[:12]), **v} for k, v in keys.items()),
                key=lambda x: -x["requests"],
            ),
            "byModel": sorted(
                ({"name": k, **v} for k, v in models.items()), key=lambda x: -x["tokens"]
            ),
            "byLineItem": sorted(
                ({"name": k, "usd": round(v, 4)} for k, v in items.items() if v),
                key=lambda x: -x["usd"],
            ),
        }
        self._cache = (now, result)
        return result

    def _key_names(self, key):
        """Nome de cada chave do projeto (so quando o projeto esta configurado); sem nome, mostra o inicio do id."""
        if not self.project:
            return {}
        status, body = self.transport(
            f"/v1/organization/projects/{urllib.parse.quote(self.project)}/api_keys",
            {"limit": 100},
            key,
        )
        if status != 200:
            return {}
        return {k["id"]: k.get("name") or k["id"][:12] for k in body.get("data", []) if "id" in k}


ANTHROPIC_HOST = "https://api.anthropic.com"
ANTHROPIC_VERSION = "2023-06-01"


def anthropic_transport(path, params, key, timeout=15):
    """GET so em api.anthropic.com (host fixo). Devolve (status, json); nunca o corpo de um erro."""
    url = f"{ANTHROPIC_HOST}{path}?{urllib.parse.urlencode(params, doseq=True)}"
    request = urllib.request.Request(  # noqa: S310 - host fixo https
        url, headers={"x-api-key": key, "anthropic-version": ANTHROPIC_VERSION}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.status, json.loads(response.read(5_000_000))
    except urllib.error.HTTPError as error:
        return error.code, {}
    except (urllib.error.URLError, OSError, ValueError):
        return 0, {}


class ClaudeCodeUsage:
    """Uso e custo estimado do Claude Code da equipe (Admin API da Anthropic, relatorio do Claude Code).

    Exige a chave de ADMINISTRADOR (`sk-ant-admin01-...`) no SSM, lida so aqui; ela nunca sai da funcao nem e
    registrada. O relatorio devolve UM dia por consulta, entao o mes e montado dia a dia (cache de 15 minutos).
    O custo e uma ESTIMATIVA da Anthropic (centavos de dolar por modelo): para assinatura Team/Enterprise nao ha
    fatura por token. So aparece quem usa o Claude Code autenticado na organizacao."""

    PATH = "/v1/organizations/usage_report/claude_code"
    MAX_PAGES_PER_DAY = 5

    def __init__(self, key_loader, clock, monthly_limit_usd=None, transport=anthropic_transport):
        self.key_loader, self.clock = key_loader, clock
        self.limit, self.transport = monthly_limit_usd, transport
        self._cache = None

    @property
    def configured(self):
        return self.key_loader is not None

    def _day(self, day, key):
        rows, page = [], None
        for _ in range(self.MAX_PAGES_PER_DAY):
            query = {"starting_at": day.isoformat(), "limit": 1000}
            if page:
                query["page"] = page
            status, body = self.transport(self.PATH, query, key)
            if status != 200:
                raise OrgUnavailable("network" if status == 0 else f"http_{status}")
            rows += body.get("data", [])
            page = body.get("next_page") if body.get("has_more") else None
            if not page:
                break
        return rows

    @staticmethod
    def _actor(row):
        actor = row.get("actor") or {}
        return actor.get("email_address") or actor.get("api_key_name") or "—"

    def report(self):
        if not self.configured:
            raise OrgUnavailable("not_configured")
        now = self.clock()
        if self._cache and now - self._cache[0] < CACHE_TTL:
            return self._cache[1]
        try:
            key = self.key_loader()
        except Exception as error:  # noqa: BLE001 - sem permissao ou parametro: sem detalhe da chave
            raise OrgUnavailable("key_read_failed:" + type(error).__name__[:40]) from error
        if not key:
            raise OrgUnavailable("empty_key")
        today = datetime.fromtimestamp(now, timezone.utc).date()
        start = _month_start(today)
        days, actors, models = [], {}, {}
        day = start
        while day <= today:
            usd = tokens = sessions = 0
            for row in self._day(day, key):
                who = actors.setdefault(
                    self._actor(row),
                    {"usd": 0.0, "tokens": 0, "sessions": 0, "type": row.get("customer_type")},
                )
                sessions += int((row.get("core_metrics") or {}).get("num_sessions") or 0)
                who["sessions"] += int((row.get("core_metrics") or {}).get("num_sessions") or 0)
                for m in row.get("model_breakdown") or []:
                    cost = float((m.get("estimated_cost") or {}).get("amount") or 0) / 100
                    t = m.get("tokens") or {}
                    count = sum(
                        int(t.get(k) or 0)
                        for k in ("input", "output", "cache_creation", "cache_read")
                    )
                    usd += cost
                    tokens += count
                    who["usd"] += cost
                    who["tokens"] += count
                    entry = models.setdefault(m.get("model") or "—", {"usd": 0.0, "tokens": 0})
                    entry["usd"] += cost
                    entry["tokens"] += count
            days.append(
                {
                    "date": day.isoformat(),
                    "usd": round(usd, 4),
                    "tokens": tokens,
                    "sessions": sessions,
                }
            )
            day += timedelta(days=1)
        result = {
            "month": start.isoformat()[:7],
            "totalUsd": round(sum(d["usd"] for d in days), 2),
            "limitUsd": self.limit,
            "totalTokens": sum(d["tokens"] for d in days),
            "totalSessions": sum(d["sessions"] for d in days),
            "daily": days,
            "byActor": sorted(
                ({"name": k, **v, "usd": round(v["usd"], 4)} for k, v in actors.items()),
                key=lambda x: -x["usd"],
            ),
            "byModel": sorted(
                (
                    {"name": k, "usd": round(v["usd"], 4), "tokens": v["tokens"]}
                    for k, v in models.items()
                ),
                key=lambda x: -x["usd"],
            ),
        }
        self._cache = (now, result)
        return result
