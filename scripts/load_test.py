#!/usr/bin/env python3
"""Teste de carga da API, so com rotas de LEITURA (GET), para o harness local ou o DEV autorizado.

Uso (DEV):
  RUNPASS_ACCESS_TOKEN=<token> python3 scripts/load_test.py --base-url https://api.exemplo \
      --rate 20 --duration 1800 --autorizado

O token vem so do ambiente e nunca e impresso, nem corpos de resposta. Nada e gravado nem apagado:
as rotas sao as que as telas do app consultam (Inicio, Avisos, Corridas, Medalhas, Perfil, Sugestoes).

Contra um endereco que nao seja de loopback, o script exige `--autorizado`: confirma que Thiago e
Rafael autorizaram a rodada e que ela esta registrada no `PDLC/M4/S09-integracao-dev.md`. Gera custo.

Estados: APROVADO, FALHA, NAO EXECUTADO. Ausencia de medicao nao e aprovacao. O que a SPEC pede
(`SPEC_RunPass_MVP_v1.md`): operacoes leves com media abaixo de 500 ms e p95 abaixo de 1 s.
Respostas 429 (limite de taxa do API Gateway) sao contadas a parte: nao sao falha do codigo, mas
mostram que o patamar pedido nao passa pela configuracao atual (`ApiRateLimit` em `app.template.yaml`).
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

LOOPBACK = {"127.0.0.1", "localhost", "::1"}

# Rotas que as telas do app consultam. `{edition}` e descoberto no catalogo antes de comecar.
ROUTES = [
    ("Inicio", "/feed?limit=20&scope=all"),
    ("Inicio amigos", "/feed?limit=20&scope=friends"),
    ("Avisos", "/me/notifications"),
    ("Corridas", "/editions?limit=20"),
    ("Corridas busca", "/editions?q=Corrida&limit=20"),
    ("Corrida", "/editions/{edition}"),
    ("Corrida avaliacoes", "/editions/{edition}/reviews?limit=50"),
    ("Medalhas", "/me/participations?limit=100"),
    ("Perfil", "/me"),
    ("Minhas publicacoes", "/me/posts"),
    ("Sugestoes de amigos", "/profiles/suggestions?limit=12"),
    ("Planos de corrida", "/me/race-plans"),
]

MEAN_LIMIT_MS = 500
P95_LIMIT_MS = 1000
ERROR_LIMIT = 0.01
WINDOW = 200  # respostas recentes olhadas pelas travas de parada
MIN_WINDOW = 50


def percentile(values, p):
    """Posto mais proximo (nearest-rank) sobre uma lista de numeros; 0 se vazia."""
    if not values:
        return 0
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * p // 100))  # teto, sem float
    return ordered[min(int(rank), len(ordered)) - 1]


def classify(status):
    if status == 0:
        return "rede"
    if status == 429:
        return "limite"
    if status == 401 or status == 403:
        return "auth"
    if status >= 500:
        return "servidor"
    return "ok" if 200 <= status < 300 else "cliente"


def should_abort(recent, abort_5xx, abort_429, auth_streak=10):
    """Motivo para parar (texto) ou None. `recent` e uma lista de estados de `classify`."""
    tail = list(recent)[-auth_streak:]
    if len(tail) >= auth_streak and all(c == "auth" for c in tail):
        return "token recusado (401/403) em sequencia: expirou ou nao tem acesso"
    if len(recent) < MIN_WINDOW:
        return None
    total = len(recent)
    failed = sum(1 for c in recent if c in ("servidor", "rede")) / total
    if failed > abort_5xx:
        return f"{failed:.0%} de falhas de servidor ou rede nas ultimas {total} respostas"
    throttled = sum(1 for c in recent if c == "limite") / total
    if throttled > abort_429:
        return f"{throttled:.0%} de respostas 429: o limite do API Gateway esta barrando o patamar"
    return None


def summarize(records, elapsed):
    """Numeros por rota e no total. Cada registro: (rota, status, ms, atraso_ms)."""
    routes = {}
    for route, status, ms, _lag in records:
        routes.setdefault(route, []).append((status, ms))

    def block(items):
        times = [ms for status, ms in items if 200 <= status < 300]
        kinds = [classify(status) for status, _ in items]
        return {
            "requests": len(items),
            "ok": kinds.count("ok"),
            "limite429": kinds.count("limite"),
            "servidor5xx": kinds.count("servidor"),
            "rede": kinds.count("rede"),
            "outros": len(items)
            - kinds.count("ok")
            - kinds.count("limite")
            - kinds.count("servidor")
            - kinds.count("rede"),
            "meanMs": round(sum(times) / len(times)) if times else 0,
            "p50Ms": round(percentile(times, 50)),
            "p95Ms": round(percentile(times, 95)),
            "p99Ms": round(percentile(times, 99)),
            "maxMs": round(max(times)) if times else 0,
        }

    lags = [lag for *_, lag in records]
    return {
        "routes": {name: block(items) for name, items in sorted(routes.items())},
        "total": block([(status, ms) for _, status, ms, _ in records]),
        "seconds": round(elapsed, 1),
        "achievedPerSecond": round(len(records) / elapsed, 1) if elapsed > 0 else 0,
        "generatorLagP95Ms": round(percentile(lags, 95)),
        "generatorLagMaxMs": round(max(lags)) if lags else 0,
    }


def verdicts(summary, requested_rate, aborted):
    """Lista de (criterio, estado, detalhe). Nunca aprova o que nao foi medido."""
    total = summary["total"]
    out = []
    if total["requests"] == 0:
        return [("Execucao", "NAO EXECUTADO", "nenhuma requisicao enviada")]
    out.append(("Execucao", "FALHA" if aborted else "APROVADO", aborted or "ate o fim, sem parada"))
    out.append(
        (
            "Gerador de carga",
            "APROVADO" if summary["generatorLagP95Ms"] <= 250 else "FALHA",
            f"atraso p95 {summary['generatorLagP95Ms']} ms, maximo {summary['generatorLagMaxMs']} ms"
            + (
                ""
                if summary["generatorLagP95Ms"] <= 250
                else " (aumente --workers ou use outra maquina)"
            ),
        )
    )
    achieved = summary["achievedPerSecond"]
    out.append(
        (
            "Taxa pedida",
            "APROVADO" if achieved >= requested_rate * 0.9 else "FALHA",
            f"{achieved}/s alcancados de {requested_rate}/s pedidos",
        )
    )
    failed = (total["servidor5xx"] + total["rede"]) / total["requests"]
    out.append(
        (
            "Erros de servidor e rede",
            "APROVADO" if failed <= ERROR_LIMIT else "FALHA",
            f"{failed:.2%} (limite {ERROR_LIMIT:.0%})",
        )
    )
    out.append(
        (
            "Limite de taxa (429)",
            "APROVADO" if total["limite429"] == 0 else "FALHA",
            f"{total['limite429']} respostas 429"
            + ("" if total["limite429"] == 0 else ": ver ApiRateLimit/ApiBurstLimit"),
        )
    )
    for name, row in summary["routes"].items():
        if row["ok"] == 0:
            out.append((f"Rota {name}", "NAO EXECUTADO", "nenhuma resposta 2xx para medir"))
            continue
        good = row["meanMs"] < MEAN_LIMIT_MS and row["p95Ms"] < P95_LIMIT_MS
        out.append(
            (
                f"Rota {name}",
                "APROVADO" if good else "FALHA",
                f"media {row['meanMs']} ms, p95 {row['p95Ms']} ms, p99 {row['p99Ms']} ms",
            )
        )
    return out


class Runner:
    def __init__(self, base, token, timeout):
        self.base, self.token, self.timeout = base.rstrip("/"), token, timeout
        self.records = []
        self.recent = deque(maxlen=WINDOW)
        self.lock = threading.Lock()

    def get(self, path):
        request = urllib.request.Request(self.base + path, method="GET")
        request.add_header("Authorization", "Bearer " + self.token)
        began = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw, status = response.read(), response.status
        except urllib.error.HTTPError as error:
            raw, status = error.read(), error.code
        except (urllib.error.URLError, TimeoutError, OSError):
            return 0, {}, (time.monotonic() - began) * 1000
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError:
            payload = {}
        return status, payload, (time.monotonic() - began) * 1000

    def one(self, route, path, lag_ms):
        status, _, ms = self.get(path)
        with self.lock:
            self.records.append((route, status, ms, lag_ms))
            self.recent.append(classify(status))


def discover_edition(runner):
    """Id de uma edicao do catalogo, ou None. Tambem prova que o token funciona."""
    status, page, _ = runner.get("/editions?limit=20")
    if status != 200:
        return status, None
    for edition in page.get("items", []):
        if edition.get("status") != "archived" and edition.get("id"):
            return status, edition["id"]
    return status, None


def run(runner, plan, rate, workers, max_requests, abort_5xx, abort_429, say=print):
    total = min(len(plan), max_requests) if max_requests else len(plan)
    started = time.monotonic()
    aborted = None
    submitted = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for index in range(total):
            due = started + index / rate
            wait = due - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            lag_ms = max(0.0, (time.monotonic() - due) * 1000)
            route, path = plan[index]
            pool.submit(runner.one, route, path, lag_ms)
            submitted += 1
            if index % 50 == 49:
                with runner.lock:
                    reason = should_abort(runner.recent, abort_5xx, abort_429)
                if reason:
                    aborted = reason
                    say(f"PARADA {reason} (apos {submitted} requisicoes enviadas)")
                    break
            if index % (rate * 30 or 1) == (rate * 30 or 1) - 1:
                with runner.lock:
                    done = len(runner.records)
                say(
                    f"  {datetime.now(timezone.utc):%H:%M:%SZ} enviadas {submitted}/{total}, respondidas {done}"
                )
    return aborted, time.monotonic() - started


def build_plan(edition, total):
    routes = [(name, path.replace("{edition}", edition)) for name, path in ROUTES]
    return [routes[i % len(routes)] for i in range(total)]


def check_target(base_url, authorized):
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return "informe --base-url completo, como https://api.exemplo"
    local = parsed.hostname in LOOPBACK
    if not local and parsed.scheme != "https":
        return "fora do loopback so HTTPS"
    if not local and not authorized:
        return (
            "carga contra servico real gera custo e exige --autorizado (autorizacao de Thiago e "
            "Rafael registrada no PDLC/M4/S09-integracao-dev.md)"
        )
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--rate", type=int, default=5, help="requisicoes por segundo")
    parser.add_argument("--duration", type=int, default=60, help="segundos")
    parser.add_argument("--workers", type=int, default=0, help="threads; 0 = automatico")
    parser.add_argument(
        "--max-requests", type=int, default=0, help="teto de requisicoes; 0 = so a duracao"
    )
    parser.add_argument("--abort-5xx", type=float, default=0.05, help="para se passar desta fracao")
    parser.add_argument("--abort-429", type=float, default=0.5, help="para se passar desta fracao")
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--autorizado", action="store_true", help="exigido fora do loopback")
    parser.add_argument("--json", help="arquivo para salvar os numeros (sem token nem corpos)")
    args = parser.parse_args(argv)

    problem = check_target(args.base_url, args.autorizado)
    if problem:
        print("NAO EXECUTADO", problem, file=sys.stderr)
        return 2
    token = os.environ.get("RUNPASS_ACCESS_TOKEN", "")
    if not token:
        print("NAO EXECUTADO RUNPASS_ACCESS_TOKEN nao definido no ambiente", file=sys.stderr)
        return 2
    if args.rate < 1 or args.duration < 1:
        print("NAO EXECUTADO --rate e --duration precisam ser maiores que zero", file=sys.stderr)
        return 2

    runner = Runner(args.base_url, token, args.timeout)
    status, edition = discover_edition(runner)
    if edition is None:
        print(
            f"NAO EXECUTADO preparo: catalogo HTTP {status}, sem edicao utilizavel", file=sys.stderr
        )
        return 2
    total = args.rate * args.duration
    workers = args.workers or min(300, max(16, args.rate * 3))
    print(
        f"Carga: {args.rate}/s por {args.duration}s = {total} requisicoes, {workers} threads, "
        f"{len(ROUTES)} rotas de leitura. Parada se 5xx/rede > {args.abort_5xx:.0%} ou 429 > {args.abort_429:.0%}.",
        flush=True,
    )
    plan = build_plan(edition, total)
    aborted, elapsed = run(
        runner, plan, args.rate, workers, args.max_requests, args.abort_5xx, args.abort_429
    )
    time.sleep(min(args.timeout, 5))  # respostas ainda em voo
    summary = summarize(runner.records, elapsed)
    results = verdicts(summary, args.rate, aborted)
    print()
    print(
        f"{'rota':<24}{'n':>7}{'2xx':>7}{'429':>6}{'5xx':>6}{'media':>8}{'p50':>7}{'p95':>7}{'p99':>7}{'max':>7}"
    )
    for name, row in summary["routes"].items():
        print(
            f"{name:<24}{row['requests']:>7}{row['ok']:>7}{row['limite429']:>6}{row['servidor5xx']:>6}"
            f"{row['meanMs']:>8}{row['p50Ms']:>7}{row['p95Ms']:>7}{row['p99Ms']:>7}{row['maxMs']:>7}"
        )
    print()
    for name, state, detail in results:
        print(f"{state:<14} {name} | {detail}")
    failed = sum(1 for _, state, _ in results if state == "FALHA")
    print(
        f"\nResumo: {len(results) - failed} nao-falhas, {failed} FALHA; {summary['total']['requests']} requisicoes"
    )
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "startedAt": datetime.now(timezone.utc).isoformat(),
                    "rate": args.rate,
                    "duration": args.duration,
                    "aborted": aborted,
                    "summary": summary,
                    "verdicts": results,
                },
                handle,
                ensure_ascii=False,
                indent=2,
            )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
