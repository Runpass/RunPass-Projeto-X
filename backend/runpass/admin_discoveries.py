"""Provas descobertas pela esteira do catalogo (staging persistente, antes de virar corrida do app).

Cada prova e um item `DISC#<AAAA-MM>#<data>#<hash>` na particao `CATALOG` da tabela de operacoes (sem recurso
novo, mesmo padrao do cadastro de fontes). Duas portas de entrada, a mesma regra de mescla:
- API de ingestao: evento do Lambda do portal (`{"discoveryIngest": {...}}`), so por IAM, chamado pela esteira.
- CSV manual: o operador envia o arquivo pelo portal (`POST /admin/discoveries/import`).

Regras:
- A mesma prova (data + nome + cidade, sem acento e caixa) vira um item so, qualquer que seja a origem.
- Fato novo so PREENCHE campo vazio: nunca sobrescreve o que ja tem fonte, nem uma decisao humana.
- Guarda so fatos, trecho curto (ate 160 caracteres) e a URL da fonte; nunca pagina inteira.
- Descoberta NAO publica nada: so uma pessoa com `catalog_admin` revisa, rejeita ou promove para o catalogo,
  e a promocao passa pelo mesmo importador de sempre (prova parecida ou de outra origem vai para revisao).
- Promover exige distancia (o importador do catalogo exige) e nunca sobrescreve prova existente.
- Cada decisao e auditada. Item nao e apagado.
"""

import csv
import hashlib
import io
import re
import time
import unicodedata
from datetime import date, datetime, timezone
from decimal import Decimal

from .admin_users import audit
from .catalog import AutoImportActor
from .catalog_import import MAX_BYTES, import_rows, rows_to_results, slug
from .service import Problem
from .store import Conflict, Unavailable

PARTITION = ("operations", "CATALOG")
PREFIX = "DISC#"
STATUSES = ("new", "reviewed", "rejected", "imported")
ORIGINS = ("api", "csv")
MAX_BATCH = 1000
MAX_CSV_ROWS = 5000
MAX_PAGES = 100
SOURCE_CODE = "catalogo-descoberta"
EXCERPT = 160
CSV_COLUMNS = {  # nome no CSV -> campo
    "data": "date",
    "nome": "name",
    "cidade": "city",
    "uf": "state",
    "local": "venue",
    "organizador": "organizer",
    "distancias_km": "distances",
    "fonte_url": "sourceUrl",
    "trecho": "excerpt",
    "regiao_consultada": "region",
}


class DiscoveryBulkActor(AutoImportActor):
    """Ator da promocao em lote pedida pelo dono (sem pessoa e sem MFA). So vale por evento IAM do Lambda do
    portal e em um importador `allow_system`; nunca por HTTP."""

    subject = "system:discovery-bulk"


def _fold(text):
    plain = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    return " ".join(plain.lower().split())


def _iso(clock):
    return datetime.fromtimestamp(clock(), timezone.utc).isoformat(timespec="seconds")


def discovery_id(day, name, city):
    return hashlib.sha256(f"{day}|{_fold(name)}|{_fold(city)}".encode()).hexdigest()[:16]


def _sk(day, name, city):
    return f"{PREFIX}{day[:7]}#{day}#{discovery_id(day, name, city)}"


def _clean_url(value):
    value = (value or "").strip()
    if not value:
        return None
    if len(value) > 300 or not re.match(r"^https://[^\s/@]+(/[^\s]*)?$", value):
        raise ValueError("fonte_url invalida (https)")
    return value


def _distances(value):
    if isinstance(value, str):
        value = [p for p in re.split(r"[;|,]", value) if p.strip()]
    out = []
    for part in value or []:
        try:
            km = float(str(part).strip().lower().removesuffix("km").strip().replace(",", "."))
        except ValueError as error:
            raise ValueError(f"distancia invalida: {part!r}") from error
        if not 0 < km <= 1000:
            raise ValueError("distancia fora do limite")
        out.append(Decimal(str(km)))  # o DynamoDB nao aceita float
    return list(dict.fromkeys(out))


def normalize(raw):
    """Item bruto (API ou CSV, ja nos nomes de campo) -> dict limpo; levanta ValueError se invalido."""
    name = (raw.get("name") or "").strip()
    city = (raw.get("city") or "").strip()
    if not name or len(name) > 160 or not city or len(city) > 80:
        raise ValueError("nome e cidade obrigatorios")
    try:
        day = date.fromisoformat((raw.get("date") or "").strip()).isoformat()
    except ValueError as error:
        raise ValueError("data invalida (AAAA-MM-DD)") from error
    state = (raw.get("state") or "SP").strip().upper()
    if not re.match(r"^[A-Z]{2}$", state):
        raise ValueError("uf invalida")

    def text(field, limit):
        value = (raw.get(field) or "").strip()
        return value[:limit] or None

    return {
        "name": name,
        "date": day,
        "city": city,
        "state": state,
        "venue": text("venue", 160),
        "organizer": text("organizer", 120),
        "distancesKm": _distances(raw.get("distances", raw.get("distancesKm"))),
        "sourceUrl": _clean_url(raw.get("sourceUrl")),
        "excerpt": text("excerpt", EXCERPT),
        "region": text("region", 80),
    }


def _public(sk, item):
    return {
        "id": sk.rsplit("#", 1)[1],
        "name": item["name"],
        "date": item["date"],
        "city": item["city"],
        "state": item["state"],
        "venue": item.get("venue"),
        "organizer": item.get("organizer"),
        "distancesKm": [float(d) for d in item.get("distancesKm") or []],
        "sourceUrl": item.get("sourceUrl"),
        "excerpt": item.get("excerpt"),
        "region": item.get("region"),
        "status": item["status"],
        "origin": item["origin"],
        "batchId": item.get("batchId"),
        "firstSeenAt": item["firstSeenAt"],
        "lastSeenAt": item["lastSeenAt"],
        "seen": item["seen"],
        "editionId": item.get("editionId"),
        "decidedBy": item.get("decidedBy"),
        "decidedAt": item.get("decidedAt"),
        "note": item.get("note"),
        "version": item["_rev"],
    }


class DiscoveryStore:
    def __init__(self, store, clock, catalog=None):
        self.store, self.clock, self.catalog = store, clock, catalog

    # ---- escrita: entrada (API e CSV) ---------------------------------------------------------------

    def _put(self, key, current, new):
        try:
            self.store.commit({key: current}, {key: new})
        except Conflict as error:
            raise Problem(409, "VERSION_CONFLICT") from error

    def ingest(self, items, origin, batch_id, actor="catalog-pipeline"):
        """Mescla um lote. Devolve contadores e ate 20 erros (sem texto da fonte)."""
        if origin not in ORIGINS:
            raise Problem(422, "INVALID_INPUT")
        if not isinstance(items, list) or len(items) > MAX_BATCH:
            raise Problem(422, "BATCH_TOO_LARGE")
        batch_id = re.sub(r"[^A-Za-z0-9_.:-]", "", str(batch_id or ""))[:60] or None
        now = _iso(self.clock)
        counts = {"created": 0, "updated": 0, "unchanged": 0, "invalid": 0}
        errors = []
        for number, raw in enumerate(items, start=1):
            try:
                data = normalize(raw)
            except (ValueError, AttributeError, TypeError) as error:
                counts["invalid"] += 1
                if len(errors) < 20:
                    errors.append({"item": number, "error": str(error)[:120]})
                continue
            key = (*PARTITION, _sk(data["date"], data["name"], data["city"]))
            current = self.store.get(key)
            if current is None:
                new = {
                    **data,
                    "status": "new",
                    "origin": origin,
                    "batchId": batch_id,
                    "firstSeenAt": now,
                    "lastSeenAt": now,
                    "seen": 1,
                }
                self._put(key, None, new)
                counts["created"] += 1
                continue
            new = dict(current)
            changed = False
            for field in ("venue", "organizer", "sourceUrl", "excerpt", "region"):
                if not current.get(field) and data[field]:
                    new[field] = data[field]
                    changed = True
            if not current.get("distancesKm") and data["distancesKm"]:
                new["distancesKm"] = data["distancesKm"]
                changed = True
            if batch_id and current.get("batchId") != batch_id:
                new["batchId"] = batch_id
                new["seen"] = current["seen"] + 1
                new["lastSeenAt"] = now
                changed = True
            if changed:
                self._put(key, current, new)
                counts["updated"] += 1
            else:
                counts["unchanged"] += 1
        if counts["created"] or counts["updated"]:
            audit(
                self.store,
                actor,
                "discovery.ingest",
                {"origin": origin, "batchId": batch_id, **counts},
                self.clock,
            )
        return {"origin": origin, "batchId": batch_id, "counts": counts, "errors": errors}

    def import_csv(self, actor, text):
        """CSV manual do portal (o mesmo formato que a esteira gera: `;` ou `,`, com ou sem BOM)."""
        if len(text.encode()) > MAX_BYTES:
            raise Problem(422, "CSV_TOO_LARGE")
        body = text.lstrip("﻿")
        header = body.split("\n", 1)[0]
        reader = csv.DictReader(io.StringIO(body), delimiter=";" if ";" in header else ",")
        if not {"data", "nome", "cidade"} <= set(reader.fieldnames or []):
            raise Problem(422, "CSV_SCHEMA_INVALID")
        rows = []
        for number, row in enumerate(reader, start=1):
            if number > MAX_CSV_ROWS:
                raise Problem(422, "CSV_TOO_MANY_ROWS")
            rows.append({field: row.get(col) for col, field in CSV_COLUMNS.items()})
        batch = "csv-" + hashlib.sha256(body.encode()).hexdigest()[:12]
        total = {"created": 0, "updated": 0, "unchanged": 0, "invalid": 0}
        errors = []
        for start in range(0, len(rows), MAX_BATCH):
            part = self.ingest(rows[start : start + MAX_BATCH], "csv", batch, actor.subject)
            for key, value in part["counts"].items():
                total[key] += value
            errors += [{**e, "item": e["item"] + start} for e in part["errors"] if len(errors) < 20]
        return {"origin": "csv", "batchId": batch, "counts": total, "errors": errors[:20]}

    # ---- leitura -------------------------------------------------------------------------------------

    def _all(self, month=None):
        prefix = PREFIX + (month + "#" if month else "")
        rows, after = [], None
        for _ in range(MAX_PAGES):
            page, after = self.store.query(
                PARTITION[0], PARTITION[1], prefix=prefix, after=after, limit=100
            )
            rows += page
            if not after:
                break
        return rows

    def list(
        self, month=None, status=None, city=None, query=None, origin=None, limit=100, offset=0
    ):
        if month is not None and not re.match(r"^\d{4}-\d{2}$", month):
            raise Problem(422, "INVALID_INPUT")
        if status is not None and status not in STATUSES:
            raise Problem(422, "INVALID_INPUT")
        rows = [_public(sk, item) for sk, item in self._all()]
        summary = {
            "total": len(rows),
            "byStatus": {s: sum(1 for r in rows if r["status"] == s) for s in STATUSES},
            "byMonth": {},
            "withDistance": sum(1 for r in rows if r["distancesKm"]),
            "cities": len({_fold(r["city"]) for r in rows}),
        }
        for r in rows:
            summary["byMonth"][r["date"][:7]] = summary["byMonth"].get(r["date"][:7], 0) + 1
        summary["byMonth"] = dict(sorted(summary["byMonth"].items()))
        q = _fold(query) if query else None
        rows = [
            r
            for r in rows
            if (month is None or r["date"].startswith(month))
            and (status is None or r["status"] == status)
            and (origin is None or r["origin"] == origin)
            and (city is None or _fold(r["city"]) == _fold(city))
            and (q is None or q in _fold(r["name"] + " " + r["city"]))
        ]
        rows.sort(key=lambda r: (r["date"], _fold(r["city"]), r["id"]))
        return {
            "items": rows[offset : offset + limit],
            "matching": len(rows),
            "summary": summary,
        }

    # ---- decisao humana ------------------------------------------------------------------------------

    def _find(self, discovery_id_):
        if not re.match(r"^[0-9a-f]{16}$", discovery_id_ or ""):
            raise Problem(404, "DISCOVERY_NOT_FOUND")
        for sk, item in self._all():
            if sk.endswith("#" + discovery_id_):
                return (*PARTITION, sk), item
        raise Problem(404, "DISCOVERY_NOT_FOUND")

    def decide(self, actor, discovery_id_, version, decision, note=None):
        """`review` (conferida), `reject` (descartada) ou `reopen` (volta a nova). Importada nao muda."""
        key, item = self._find(discovery_id_)
        if item["_rev"] != version:
            raise Problem(409, "VERSION_CONFLICT")
        target = {"review": "reviewed", "reject": "rejected", "reopen": "new"}.get(decision)
        if target is None:
            raise Problem(422, "INVALID_INPUT")
        if item["status"] == "imported":
            raise Problem(409, "DISCOVERY_ALREADY_IMPORTED")
        new = {
            **item,
            "status": target,
            "decidedBy": actor.subject,
            "decidedAt": _iso(self.clock),
            "note": (note or "").strip()[:300] or None,
        }
        self._put(key, item, new)
        audit(
            self.store,
            actor.subject,
            "discovery." + decision,
            {"id": discovery_id_},
            self.clock,
        )
        return _public(key[2], {**new, "_rev": item["_rev"] + 1})

    def promote(self, actor, discovery_id_, version, dry_run=True, allow_system=False):
        """Cria a corrida no catalogo pelo importador de sempre. Simulacao por padrao."""
        if self.catalog is None:
            raise Unavailable()
        key, item = self._find(discovery_id_)
        if item["_rev"] != version:
            raise Problem(409, "VERSION_CONFLICT")
        if item["status"] in ("imported", "rejected"):
            raise Problem(409, "DISCOVERY_NOT_PROMOTABLE")
        row = {
            "source_external_id": f"{slug(item['name'])}-{item['date']}",
            "name": item["name"],
            "event_date": item["date"],
            "city": item["city"],
            "state": item["state"],
            "distances_km": "|".join(f"{float(d):g}" for d in item["distancesKm"]),
            "registration_status": "unknown",
            "event_status": "scheduled",
            "organizer_name": item.get("organizer") or "",
            "venue": item.get("venue") or "",
            "last_verified_at": _iso(self.clock)[:10],
        }
        results = rows_to_results([row], SOURCE_CODE, allow_no_distance=True)
        report = import_rows(
            self.catalog,
            actor,
            results,
            origin=f"https://descobertas.runpass.invalid/{discovery_id_}",
            source_code=SOURCE_CODE,
            dry_run=dry_run,
            allow_system=allow_system,
        )
        entry = report["rows"][0]
        outcome = {"dryRun": dry_run, "status": entry["status"], "editionId": entry.get("id")}
        if entry.get("errors"):
            outcome["errors"] = entry["errors"]
        if not dry_run and entry["status"] == "created":
            new = {
                **item,
                "status": "imported",
                "editionId": entry["id"],
                "decidedBy": actor.subject,
                "decidedAt": _iso(self.clock),
            }
            self._put(key, item, new)
            audit(
                self.store,
                actor.subject,
                "discovery.promote",
                {"id": discovery_id_, "editionId": entry["id"]},
                self.clock,
            )
        return outcome

    def promote_bulk(self, limit=40, max_seconds=20, dry_run=False):
        """Promove em lote as provas `new` ou `reviewed` com distancia, pelo importador de sempre (so cria prova
        nova; parecida ou de outra origem vai para revisao e fica anotada). Cada rodada processa ate `limit`
        provas ou `max_seconds`. Uma prova ja tentada (`bulkOutcome`) nao e tentada de novo."""
        if self.catalog is None:
            raise Unavailable()
        actor, started = DiscoveryBulkActor(), time.monotonic()
        counts = {"created": 0, "needs_review": 0, "unchanged": 0, "updated": 0, "error": 0}
        remaining, done = 0, 0
        for sk, item in sorted(self._all(), key=lambda r: r[0]):
            if item["status"] not in ("new", "reviewed"):
                continue
            if item.get("bulkOutcome"):
                continue
            if done >= limit or time.monotonic() - started > max_seconds:
                remaining += 1
                continue
            done += 1
            key = (*PARTITION, sk)
            try:
                out = self.promote(
                    actor, sk.rsplit("#", 1)[1], item["_rev"], dry_run=dry_run, allow_system=True
                )
            except Problem as problem:
                counts["error"] += 1
                if not dry_run:
                    self._put(key, item, {**item, "bulkOutcome": "error:" + problem.code})
                continue
            counts[out["status"] if out["status"] in counts else "error"] += 1
            if not dry_run and out["status"] != "created":
                current = self.store.get(key)
                self._put(key, current, {**current, "bulkOutcome": out["status"]})
        return {"dryRun": dry_run, "processed": done, "counts": counts, "remaining": remaining}
