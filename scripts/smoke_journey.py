#!/usr/bin/env python3
"""Smoke test da jornada principal da primeira entrega, para o harness local ou DEV autorizado.

Uso: RUNPASS_ACCESS_TOKEN=<token> python3 scripts/smoke_journey.py --base-url https://api.exemplo
O token vem só do ambiente (nunca de argumento) e não é impresso, nem corpos de resposta.
Usa dados sintéticos. Exclusão de conta é destrutiva e só roda com --delete-account.
Estados: APROVADO, FALHA, NAO EXECUTADO. Ausência de medição não é aprovação.
"""

import argparse
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
import zlib
from datetime import datetime, timezone

RATINGS = dict.fromkeys(
    (
        "organization",
        "course",
        "kit",
        "medal",
        "hydration",
        "facilities",
        "safety",
        "valueForMoney",
    ),
    4,
)


def synthetic_png(side=64):
    """PNG RGB valido gerado em memoria, sem dependencias externas."""
    row = b"\x00" + b"".join(bytes((x * 4 % 256, 80, 160)) for x in range(side))
    raw = row * side

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class Journey:
    def __init__(self, base_url, token):
        self.base, self.token = base_url.rstrip("/"), token
        self.results, self.ctx = [], {}

    def call(self, method, path, body=None, headers=None, absolute=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(absolute or self.base + path, data=data, method=method)
        if absolute is None:
            request.add_header("Authorization", "Bearer " + (token or self.token))
            request.add_header("Content-Type", "application/json")
            if method in {"POST", "PUT", "PATCH", "DELETE"}:
                request.add_header("Idempotency-Key", "smoke-" + uuid.uuid4().hex)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                status = response.status
        except urllib.error.HTTPError as error:
            raw, status = error.read(), error.code
        except (urllib.error.URLError, TimeoutError) as error:
            return 0, {}, time.monotonic() - started, type(error).__name__
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError:
            payload = {}
        return status, payload, time.monotonic() - started, ""

    def step(self, name, run):
        stamp = datetime.now(timezone.utc).strftime("%H:%M:%SZ")
        try:
            state, detail = run()
        except Exception as error:  # noqa: BLE001 - qualquer falha vira FALHA no relatorio
            state, detail = "FALHA", f"excecao {type(error).__name__}"
        self.results.append((name, state, detail, stamp))
        print(f"{state:<14} {name} | {detail}", flush=True)
        return state == "APROVADO"

    def expect(self, label, got, wanted, seconds):
        ok = got in wanted if isinstance(wanted, tuple) else got == wanted
        return ("APROVADO" if ok else "FALHA"), f"{label} HTTP {got} em {seconds:.2f}s"


def run(journey, delete_account, max_image_seconds):
    j = journey

    def status():
        code, _, t, err = j.call("GET", "/beta/status")
        return j.expect("status" + (f" ({err})" if err else ""), code, 200, t)

    def profile():
        code, _, t, _ = j.call("GET", "/me")
        if code == 200:
            return "APROVADO", f"perfil ja existe, HTTP 200 em {t:.2f}s"
        suffix = uuid.uuid4().hex[:8]
        code, _, t, _ = j.call(
            "PUT", "/me", {"displayName": "Corredor Smoke", "username": "smoke_" + suffix}
        )
        return j.expect("criar perfil", code, 201, t)

    def admission():
        code, _, t, _ = j.call(
            "POST", "/beta/admissions", {"birthDate": "1990-01-01", "declaresAdult": True}
        )
        return j.expect("admissao (repeticao idempotente aceita)", code, (200, 201), t)

    def catalog():
        code, page, t, _ = j.call("GET", "/editions?limit=20")
        items = [e for e in page.get("items", []) if e.get("status") != "archived"]
        for edition in items:
            if edition.get("distances"):
                j.ctx["edition"] = edition["id"]
                j.ctx["distance"] = edition["distances"][0]["id"]
                break
        if code == 200 and "edition" not in j.ctx:
            return "FALHA", "catalogo sem edicao utilizavel"
        return j.expect("catalogo", code, 200, t)

    def detail():
        code, _, t, _ = j.call("GET", "/editions/" + j.ctx["edition"])
        return j.expect("detalhe da edicao", code, 200, t)

    def draft():
        code, body, t, _ = j.call(
            "POST",
            "/participations",
            {"editionId": j.ctx["edition"], "distanceId": j.ctx["distance"]},
        )
        j.ctx["pid"], j.ctx["version"] = body.get("id"), body.get("version")
        return j.expect("criar rascunho", code, 201, t)

    def patch_and_conflict():
        code, body, t, _ = j.call(
            "PATCH",
            "/participations/" + j.ctx["pid"],
            {"expectedVersion": j.ctx["version"], "timeSeconds": 3600},
        )
        if code != 200:
            return j.expect("atualizar rascunho", code, 200, t)
        stale = j.ctx["version"]
        j.ctx["version"] = body.get("version", stale + 1)
        code, _, t2, _ = j.call(
            "PATCH",
            "/participations/" + j.ctx["pid"],
            {"expectedVersion": stale, "timeSeconds": 3700},
        )
        return j.expect("versao antiga rejeitada", code, (409, 412), t2)

    def other_user_denied():
        other = os.environ.get("RUNPASS_ACCESS_TOKEN_OTHER", "")
        if not other:
            return "NAO EXECUTADO", "defina RUNPASS_ACCESS_TOKEN_OTHER (segundo usuario sintetico)"
        # O segundo usuario precisa ter perfil e admissao: sem isso a API responde 403 por
        # admissao ausente, o que nao prova separacao entre donos. Alheio deve dar 404.
        for method, path, body in (
            (
                "PUT",
                "/me",
                {"displayName": "Corredor Outro", "username": "outro_" + uuid.uuid4().hex[:8]},
            ),
            ("POST", "/beta/admissions", {"birthDate": "1990-01-01", "declaresAdult": True}),
        ):
            code, _, _, _ = j.call(method, path, body, token=other)
            if code not in (200, 201):
                return "FALHA", f"preparar segundo usuario {path} HTTP {code}"
        code, _, t, _ = j.call("GET", "/participations/" + j.ctx["pid"], token=other)
        return j.expect("rascunho alheio nao encontrado (404)", code, 404, t)

    def image():
        png = synthetic_png()
        code, up, t, _ = j.call(
            "POST", "/uploads", {"contentType": "image/png", "sizeBytes": len(png)}
        )
        if code != 201:
            return j.expect("iniciar upload", code, 201, t)
        url = up.get("uploadUrl", "")
        if not url.startswith("https://"):
            return "NAO EXECUTADO", "uploadUrl nao e HTTPS (armazenamento local em memoria)"
        started = time.monotonic()
        request = urllib.request.Request(url, data=png, method=up.get("uploadMethod", "PUT"))
        for name, value in up.get("uploadHeaders", {}).items():
            request.add_header(name, value)
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status not in (200, 204):
                return "FALHA", f"PUT na URL assinada HTTP {response.status}"
        code, _, _, _ = j.call("POST", f"/uploads/{up['uploadId']}/finalize")
        if code not in (200, 202):
            return "FALHA", f"finalizar HTTP {code}"
        while time.monotonic() - started < 60:
            code, state, _, _ = j.call("GET", f"/uploads/{up['uploadId']}/status")
            if state.get("state") == "valid":
                j.ctx["image"] = state["imageReference"]
                took = time.monotonic() - started
                ok = took <= max_image_seconds
                return (
                    "APROVADO" if ok else "FALHA",
                    f"imagem valida em {took:.2f}s (meta {max_image_seconds}s)",
                )
            if state.get("state") == "failed":
                return "FALHA", "imagem recusada"
            time.sleep(0.5)
        return "FALHA", "imagem nao ficou valida em 60s"

    def complete():
        if "image" not in j.ctx:
            return "NAO EXECUTADO", "sem imagem valida"
        code, _, t, _ = j.call(
            "POST",
            f"/participations/{j.ctx['pid']}/complete",
            {
                "expectedVersion": j.ctx["version"],
                "declaredCompleted": True,
                "ratings": RATINGS,
                "medalImageReference": j.ctx["image"],
                "publishToFeed": False,
            },
        )
        return j.expect("concluir com oito notas", code, (200, 201), t)

    def review():
        if "image" not in j.ctx:
            return "NAO EXECUTADO", "sem conclusao"
        code, _, t, _ = j.call("GET", f"/participations/{j.ctx['pid']}/review")
        return j.expect("ler avaliacao", code, 200, t)

    def remove():
        code, current, t, _ = j.call("GET", "/participations/" + j.ctx["pid"])
        if code != 200:
            return j.expect("ler participacao", code, 200, t)
        code, _, t, _ = j.call(
            "DELETE",
            f"/participations/{j.ctx['pid']}?expectedVersion={current.get('version', 1)}",
        )
        return j.expect("excluir participacao", code, (200, 202), t)

    def account():
        if not delete_account:
            return "NAO EXECUTADO", "exclusao de conta e destrutiva; use --delete-account"
        code, _, t, _ = j.call("DELETE", "/me")
        return j.expect("excluir conta", code, (200, 202), t)

    ordered = [
        ("01 status do beta", status),
        ("02 perfil", profile),
        ("03 admissao", admission),
        ("04 catalogo", catalog),
    ]
    for name, fn in ordered:
        if not j.step(name, fn):
            return
    rest = [
        ("05 detalhe da edicao", detail),
        ("06 criar rascunho", draft),
        ("07 atualizar e rejeitar versao antiga", patch_and_conflict),
        ("08 acesso de outro usuario negado", other_user_denied),
        ("09 imagem (upload, finalizacao, validacao)", image),
        ("10 conclusao com oito notas", complete),
        ("11 leitura da avaliacao", review),
        ("12 exclusao da participacao", remove),
        ("13 exclusao de conta", account),
    ]
    needs_draft = {"07", "09", "10", "11", "12"}
    for name, fn in rest:
        if name[:2] in needs_draft and "pid" not in j.ctx:
            j.results.append((name, "NAO EXECUTADO", "sem rascunho", ""))
            print(f"{'NAO EXECUTADO':<14} {name} | sem rascunho")
            continue
        j.step(name, fn)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--delete-account", action="store_true")
    parser.add_argument("--max-image-seconds", type=float, default=5.0)
    args = parser.parse_args()
    token = os.environ.get("RUNPASS_ACCESS_TOKEN", "")
    if not token:
        parser.error("defina RUNPASS_ACCESS_TOKEN no ambiente")
    if not args.base_url.startswith(("https://", "http://127.0.0.1", "http://localhost")):
        parser.error("use HTTPS, ou http apenas em loopback")
    journey = Journey(args.base_url, token)
    run(journey, args.delete_account, args.max_image_seconds)
    states = [state for _, state, _, _ in journey.results]
    print(
        "\nResumo: "
        + ", ".join(f"{states.count(s)} {s}" for s in ("APROVADO", "FALHA", "NAO EXECUTADO"))
    )
    sys.exit(1 if "FALHA" in states else 0)


if __name__ == "__main__":
    main()
