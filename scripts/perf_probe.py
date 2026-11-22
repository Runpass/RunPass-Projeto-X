"""Teste de carga LOCAL da API (nao chama a AWS, nao usa dado real).

Monta o app de verdade em memoria com dados ficticios ([FICTICIA]) e um banco que conta as chamadas e
imita a demora do DynamoDB (cada leitura ou gravacao espera alguns milissegundos). Para cada rota do app
mostra quantas idas ao banco uma requisicao faz e quanto ela demora; depois dispara requisicoes em
paralelo para achar erro sob carga.

O numero que importa e o de chamadas em SEQUENCIA: na Lambda cada uma custa uma ida ao DynamoDB.

Uso:
  PYTHONPATH=backend .venv/bin/python scripts/perf_probe.py            # tabela por rota + carga
  PYTHONPATH=backend .venv/bin/python scripts/perf_probe.py --json x.json   # salva os numeros
"""

import argparse
import json
import os
import statistics
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import jwt
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from runpass.api import create_app
from runpass.catalog import CatalogService, seed_synthetic
from runpass.edition_requests import EditionRequestService
from runpass.identity import CognitoVerifier, Principal
from runpass.participation import ParticipationService
from runpass.service import IdentityService
from runpass.social import SocialService
from runpass.store import MemoryStore
from runpass.upload import MemoryBlobStore, UploadService

ISSUER, CLIENT_ID = "https://local.invalid/pool", "local-client"
READ_MS, WRITE_MS = 4.0, 9.0  # ordem de grandeza de uma ida ao DynamoDB a partir da Lambda


class CountingStore(MemoryStore):
    """MemoryStore que conta as chamadas da requisicao atual e espera como o DynamoDB esperaria."""

    def __init__(self):
        super().__init__()
        # Contador unico (a medicao por rota e feita uma requisicao por vez; o app roda em outra thread).
        self.counts = None
        self.count_lock = threading.Lock()
        self.delay = False

    def _hit(self, kind, ms, keys=0):
        if self.counts is not None:
            with self.count_lock:
                self.counts[kind] = self.counts.get(kind, 0) + 1
                if keys:
                    self.counts["batch_keys"] = self.counts.get("batch_keys", 0) + keys
        if self.delay:
            time.sleep(ms / 1000)

    def start(self):
        self.counts = {}

    def stop(self):
        counts, self.counts = self.counts, None
        return counts

    def get(self, key):
        self._hit("get", READ_MS)
        return super().get(key)

    def batch_get(self, keys):
        # Como o DynamoStore: as leituras de um lote saem em paralelo (uma espera, nao N).
        keys = list(dict.fromkeys(keys))
        self._hit("batch", READ_MS, len(keys))
        return {key: MemoryStore.get(self, key) for key in keys}

    def query(self, table, pk, **kw):
        self._hit("query", READ_MS)
        return super().query(table, pk, **kw)

    def commit(self, expected, writes):
        self._hit("commit", WRITE_MS)
        return super().commit(expected, writes)


def build(users=40, editions=300, posts_per_user=6):
    """App completo com dados ficticios: corridas, pessoas, amizades, seguidores e publicacoes."""
    now = datetime.now(timezone.utc)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subjects = [f"u{n:03d}" for n in range(users)]

    def token(sub):
        return jwt.encode(
            {
                "iss": ISSUER,
                "client_id": CLIENT_ID,
                "sub": sub,
                "iat": now,
                "exp": now + timedelta(hours=2),
                "token_use": "access",
            },
            key,
            algorithm="RS256",
            headers={"kid": "ephemeral-local"},
        )

    store = CountingStore()
    verifier = CognitoVerifier(
        ISSUER, CLIENT_ID, lambda kid: key.public_key(), lambda tok, sub: sub in subjects
    )
    identity = IdentityService(store, os.urandom(32), environment="perf", identity_namespace=ISSUER)
    catalog = CatalogService(identity, Fernet.generate_key())
    participations = ParticipationService(identity, catalog, Fernet.generate_key())
    uploads = UploadService(identity, MemoryBlobStore())
    social = SocialService(identity)

    cities = [
        ("São Paulo", -23.55, -46.63),
        ("Campinas", -22.9, -47.06),
        ("Santos", -23.96, -46.33),
    ]
    today = date.today()
    fixture = []
    for n in range(editions):
        city, lat, lon = cities[n % len(cities)]
        fixture.append(
            {
                "id": f"perf-{n:04d}",
                "raceId": f"perf-serie-{n:04d}",
                "name": f"[FICTICIA] Corrida de Carga {n:04d}",
                "date": (today + timedelta(days=(n % 240) - 60)).isoformat(),
                "city": city,
                "state": "SP",
                "latitude": lat,
                "longitude": lon,
                "description": "Dados ficticios para o teste de carga; nao e uma prova real.",
                "distances": [
                    {"id": "5k", "kilometers": 5, "label": "5 km"},
                    {"id": "10k", "kilometers": 10, "label": "10 km"},
                ],
            }
        )
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "catalog.json"
        path.write_text(json.dumps(fixture, ensure_ascii=False))
        seed_synthetic(catalog, path)

    actors = []
    for n, sub in enumerate(subjects):
        actor = Principal(sub, True)
        identity.create_profile(
            actor,
            "p-" + sub,
            {"displayName": f"[FICTICIA] Pessoa {n:03d}", "username": f"pessoa_{n:03d}"},
        )
        identity.admit(
            actor,
            "a-" + sub,
            {"birthDate": "1990-01-01", "declaresAdult": True, "gender": "undisclosed"},
        )
        actors.append(actor)
    # Cada pessoa segue as 8 seguintes e e amiga das 4 seguintes (rede densa de proposito).
    for n, actor in enumerate(actors):
        for step in range(1, 9):
            other = actors[(n + step) % users]
            social.follow(actor, other.subject, f"f-{n}-{step}")
        for step in range(1, 5):
            other = actors[(n + step) % users]
            try:
                social.add_friend(actor, other.subject, f"fa-{n}-{step}")
                social.decide_friend(other, actor.subject, True, f"fd-{n}-{step}")
            except Exception:  # noqa: BLE001 - amizade ja criada pelo outro lado
                pass
    # Participacoes concluidas e publicadas (mesmas linhas que ParticipationService.complete grava).
    for n, actor in enumerate(actors):
        pk = "USER#" + actor.subject
        for k in range(posts_per_user):
            pid = f"part-{n:03d}-{k}"
            edition_id = f"perf-{(n * 7 + k * 13) % editions:04d}"
            at = (now - timedelta(hours=n * 3 + k * 50)).strftime("%Y-%m-%dT%H:%M:%SZ")
            feed_key = ("history", "FEED#PUBLIC", f"T#{at}#{pid}")
            rows = {
                ("history", "PARTICIPATION#" + pid, "OWNER"): {"owner": actor.subject},
                ("history", pk, f"P#{pid}#PART"): {
                    "id": pid,
                    "owner": actor.subject,
                    "editionId": edition_id,
                    "distanceId": "10k",
                    "state": "completed",
                    "version": 2,
                    "completedAt": at,
                    "timeSeconds": 3000 + k,
                    "showTime": True,
                    "publishToFeed": True,
                    "catalogVersion": 1,
                },
                ("history", pk, f"EDITION#{edition_id}#CLAIM"): {"participationId": pid},
                feed_key: {"owner": actor.subject, "id": pid, "completedAt": at},
                ("history", pk, "FEEDREF#" + pid): {"sharedKeys": [list(feed_key)]},
            }
            store.commit({k2: None for k2 in rows}, rows)
    app = create_app(
        identity,
        verifier,
        catalog,
        participations,
        uploads,
        social,
        edition_requests=EditionRequestService(identity, Fernet.generate_key(), catalog),
    )
    return store, TestClient(app), {sub: token(sub) for sub in subjects}


def routes(today=None):
    """As leituras que o app faz ao abrir cada tela (rota e de qual tela ela vem)."""
    today = today or date.today()
    soon = (today + timedelta(days=20)).isoformat()
    return [
        ("Início", "GET", "/me"),
        ("Início", "GET", "/feed?limit=20&scope=all"),
        ("Início", "GET", "/feed?limit=20&scope=friends"),
        ("Início", "GET", "/feed?limit=20&scope=network"),
        ("Início / Medalhas", "GET", "/me/participations?limit=100"),
        ("Início", "GET", "/me/notifications"),
        ("Corridas", "GET", f"/editions?dateFrom={today.isoformat()}&limit=20"),
        (
            "Corridas",
            "GET",
            f"/editions?state=SP&dateFrom={today.isoformat()}&dateTo={soon}&limit=100",
        ),
        ("Corridas", "GET", "/editions?q=Corrida&limit=20"),
        ("Corridas", "GET", "/me/race-plans"),
        ("Corrida", "GET", "/editions/perf-0010"),
        ("Corrida", "GET", "/editions/perf-0010/reviews?limit=50"),
        ("Corrida", "GET", "/editions/perf-0010/comments"),
        ("Perfil", "GET", "/me/posts"),
        ("Perfil", "GET", "/profiles/u001"),
        ("Perfil", "GET", "/profiles/u001/participations?limit=50"),
        ("Perfil", "GET", "/profiles/u001/followers?limit=30"),
        ("Buscar amigos", "GET", "/profiles/suggestions?limit=12"),
        ("Buscar amigos", "GET", "/profiles?q=pessoa&limit=30"),
        ("Publicação", "GET", "/posts/part-001-0/comments?limit=50"),
    ]


def measure(store, client, tokens, repeat=5):
    headers = {"Authorization": "Bearer " + tokens["u000"]}
    rows = []
    for screen, method, url in routes():
        store.delay = False
        store.start()
        response = client.request(method, url, headers=headers)
        counts = store.stop() or {}
        store.delay = True
        times = []
        for _ in range(repeat):
            began = time.perf_counter()
            client.request(method, url, headers=headers)
            times.append((time.perf_counter() - began) * 1000)
        store.delay = False
        reads = counts.get("get", 0) + counts.get("query", 0) + counts.get("batch", 0)
        rows.append(
            {
                "screen": screen,
                "route": f"{method} {url.split('?')[0]}"
                + ("?" + url.split("?")[1] if "?" in url else ""),
                "status": response.status_code,
                "roundTrips": reads + counts.get("commit", 0),
                "get": counts.get("get", 0),
                "query": counts.get("query", 0),
                "batch": counts.get("batch", 0),
                "batchKeys": counts.get("batch_keys", 0),
                "commit": counts.get("commit", 0),
                "ms": round(statistics.median(times)),
            }
        )
    return rows


def stress(store, client, tokens, workers=24, rounds=6):
    """Varias pessoas abrindo o app ao mesmo tempo: conta respostas por status e o tempo de cada uma."""
    store.delay = True
    plan = [
        (sub, method, url)
        for _ in range(rounds)
        for sub in list(tokens)[:workers]
        for _, method, url in routes()
    ]
    statuses, times, lock = {}, [], threading.Lock()

    def call(item):
        sub, method, url = item
        began = time.perf_counter()
        response = client.request(method, url, headers={"Authorization": "Bearer " + tokens[sub]})
        took = (time.perf_counter() - began) * 1000
        with lock:
            statuses[response.status_code] = statuses.get(response.status_code, 0) + 1
            times.append(took)

    began = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(call, plan))
    elapsed = time.perf_counter() - began
    store.delay = False
    times.sort()
    return {
        "requests": len(plan),
        "workers": workers,
        "seconds": round(elapsed, 1),
        "perSecond": round(len(plan) / elapsed),
        "statuses": dict(sorted(statuses.items())),
        "p50ms": round(times[len(times) // 2]),
        "p95ms": round(times[int(len(times) * 0.95)]),
        "maxMs": round(times[-1]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--json", help="arquivo para salvar os numeros")
    parser.add_argument("--no-stress", action="store_true", help="so a tabela por rota")
    args = parser.parse_args()
    store, client, tokens = build()
    rows = measure(store, client, tokens)
    print(f"{'idas':>5} {'ms':>6}  {'st':>3}  rota  (get/query/lote/gravar)")
    for row in sorted(rows, key=lambda r: -r["roundTrips"]):
        print(
            f"{row['roundTrips']:>5} {row['ms']:>6}  {row['status']:>3}  {row['route']}"
            f"  ({row['get']}/{row['query']}/{row['batch']}/{row['commit']})"
        )
    result = {"routes": rows}
    if not args.no_stress:
        result["stress"] = stress(store, client, tokens)
        print("carga:", json.dumps(result["stress"], ensure_ascii=False))
    if args.json:
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
