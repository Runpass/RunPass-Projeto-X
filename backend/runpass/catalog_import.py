"""Importacao de provas em lote (CSV autorizado ou conector) pelo importador real do catalogo.

Regras:
- Simulacao (`dry_run`) valida e classifica cada linha sem escrever nada.
- Reimportar o mesmo arquivo nao cria versao nova (conteudo e origem iguais).
- Uma prova que ja existe vinda de OUTRA fonte (ou cadastrada por um administrador) nunca e
  sobrescrita: vai para revisao (`needs_review`).
- Prova nova parecida com outra ja publicada (mesmo nome, data e cidade) vai para revisao;
  nunca ha mescla automatica.
- Prova que some de uma nova coleta nao e apagada nem marcada como cancelada.
"""

import csv
import io
import re
from datetime import timezone
from decimal import Decimal, InvalidOperation
from uuid import uuid4

from pydantic import ValidationError

from .catalog import CatalogImporter, ImportEdition, normalized
from .operator_admin import _already_loaded
from .service import Problem, stamp

MAX_BYTES = 2_000_000
MAX_ROWS = 2000
REQUIRED = ("source_external_id", "name", "event_date", "city", "state", "distances_km")
OPTIONAL = (
    "country",
    "registration_status",
    "event_status",
    "official_url",
    "registration_url",
    "organizer_name",
    "description",
    "venue",
    "latitude",
    "longitude",
    "last_verified_at",
    "instagram_url",
    "facebook_url",
    "organizer_post_url",
)
KNOWN_LABELS = {Decimal("21.0975"): "Meia Maratona", Decimal("42.195"): "Maratona"}
DATE_INDEX = "CAT#GLOBAL#ANY#DATE"


def slug(value):
    return re.sub(r"[^a-z0-9]+", "-", normalized(value)).strip("-")


def parse_km(text):
    """'5', '10 km', '21,0975', '21.0975K' -> Decimal positivo; levanta ValueError se invalido."""
    cleaned = re.sub(r"(?i)\s*k(m|s)?\s*$", "", text.strip()).replace(",", ".")
    try:
        value = Decimal(cleaned)
    except InvalidOperation as error:
        raise ValueError(f"distancia invalida: {text!r}") from error
    if not value.is_finite() or value <= 0 or value > 1000:
        raise ValueError(f"distancia fora do limite: {text!r}")
    return value


def distance_entry(km):
    plain = format(km.normalize(), "f")
    label = KNOWN_LABELS.get(km.normalize()) or f"{plain.rstrip('0').rstrip('.')}K"
    return {"id": plain.replace(".", "_") + "k", "kilometers": plain, "label": label}


def _url(value):
    if value and not re.match(r"^https?://[^\s]+$", value):
        raise ValueError("URL deve comecar com http:// ou https://")
    return value


def row_to_payload(row, source_code):
    """Uma linha do CSV (ou item de conector ja nos nomes do CSV) -> payload do importador."""
    external = (row.get("source_external_id") or "").strip()
    if not external:
        raise ValueError("source_external_id obrigatorio")
    km_values = [
        parse_km(part) for part in re.split(r"[;|]", row.get("distances_km") or "") if part.strip()
    ]
    if not km_values:
        raise ValueError("distances_km obrigatorio")
    payload = {
        "id": f"{source_code}-{slug(external)}"[:100],
        "name": (row.get("name") or "").strip(),
        "date": (row.get("event_date") or "").strip(),
        "city": (row.get("city") or "").strip(),
        "state": (row.get("state") or "").strip().upper(),
        "distances": [distance_entry(km) for km in dict.fromkeys(km_values)],
        "sourceCode": source_code,
        "sourceExternalId": external,
    }
    simple = {
        "country": "country",
        "registration_status": "registrationStatus",
        "event_status": "eventStatus",
        "organizer_name": "organizerName",
        "description": "description",
        "venue": "venue",
        "last_verified_at": "lastVerifiedAt",
    }
    for column, field in simple.items():
        if (row.get(column) or "").strip():
            payload[field] = row[column].strip()
    for column, field in (("official_url", "officialUrl"), ("registration_url", "registrationUrl")):
        if (row.get(column) or "").strip():
            payload[field] = _url(row[column].strip())
    for column, field in (
        ("instagram_url", "instagramUrl"),
        ("facebook_url", "facebookUrl"),
        ("organizer_post_url", "organizerPostUrl"),
    ):
        if (row.get(column) or "").strip():
            payload[field] = row[column].strip()  # ImportEdition valida e normaliza o endereco
    for column in ("latitude", "longitude"):
        if (row.get(column) or "").strip():
            payload[column] = row[column].strip().replace(",", ".")
    ImportEdition(**payload)  # mesmas regras do cadastro: datas, UF, distancias, coordenadas
    return payload


def parse_csv(text, source_code):
    """Valida o CSV inteiro e devolve uma linha de resultado por registro (sem escrever nada)."""
    if len(text.encode()) > MAX_BYTES:
        raise Problem(422, "CSV_TOO_LARGE")
    reader = csv.DictReader(io.StringIO(text.lstrip("﻿")))
    missing = [c for c in REQUIRED if c not in (reader.fieldnames or [])]
    if missing:
        raise Problem(422, "CSV_SCHEMA_INVALID")
    return rows_to_results(list(reader), source_code)


def rows_to_results(rows, source_code):
    """Linhas (do CSV ou de um conector, ja nos nomes do CSV) -> resultado validado por linha."""
    results, seen = [], set()
    for number, row in enumerate(rows, start=2):  # linha 1 e o cabecalho
        if number - 1 > MAX_ROWS:
            raise Problem(422, "CSV_TOO_MANY_ROWS")
        result = {"row": number, "externalId": (row.get("source_external_id") or "").strip()}
        try:
            payload = row_to_payload(row, source_code)
            if payload["id"] in seen:
                raise ValueError("source_external_id repetido no arquivo")
            seen.add(payload["id"])
            result.update(id=payload["id"], payload=payload, errors=[])
        except (ValueError, ValidationError) as error:
            messages = (
                [f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in error.errors()]
                if isinstance(error, ValidationError)
                else [str(error)]
            )
            result.update(payload=None, errors=messages)
        results.append(result)
    return results


def _same_day_candidates(catalog, day, payload):
    """Editions ja publicadas no mesmo dia com mesmo nome e cidade (outro id)."""
    found = []
    rows, _ = catalog.store.query(
        "catalog", DATE_INDEX, lower=day + "#", upper=day + "#\U0010ffff", limit=500
    )
    for _, row in rows:
        body = catalog._edition(row["editionId"], row["version"])
        if (
            body
            and body["id"] != payload["id"]
            and normalized(body["name"]) == normalized(payload["name"])
            and normalized(body["city"]) == normalized(payload["city"])
        ):
            found.append(body["id"])
    return found


def classify(catalog, payload, origin, source_code):
    """('created'|'updated'|'unchanged'|'needs_review', detalhe, versao esperada)."""
    head = catalog.store.get(("catalog", "EDITION#" + payload["id"], "HEAD"))
    if head is None:
        twins = _same_day_candidates(catalog, payload["date"], payload)
        if twins:
            return "needs_review", "POSSIBLE_DUPLICATE:" + ",".join(sorted(set(twins))), 0
        return "created", None, 0
    stored = catalog.store.get(("catalog", "EDITION#" + payload["id"], "V#" + str(head["version"])))
    if not stored or stored["edition"].get("sourceCode") != source_code:
        return "needs_review", "EXISTS_FROM_OTHER_SOURCE_OR_ADMIN", int(head["version"])
    if _already_loaded(catalog, payload, head, origin):
        return "unchanged", None, int(head["version"])
    return "updated", None, int(head["version"])


def import_rows(
    catalog,
    actor,
    results,
    *,
    origin,
    source_code,
    dry_run=True,
    synthetic=False,
    allow_system=False,
):
    """Aplica (ou simula) as linhas validas. Devolve o relatorio com contadores e o detalhe."""
    counts = {"created": 0, "updated": 0, "unchanged": 0, "needs_review": 0, "error": 0}
    report = []
    importer = CatalogImporter(catalog, allow_system=allow_system)
    for result in results:
        entry = {"row": result["row"], "externalId": result["externalId"]}
        if result["errors"]:
            entry.update(status="error", errors=result["errors"])
            counts["error"] += 1
            report.append(entry)
            continue
        payload = result["payload"]
        status, detail, version = classify(catalog, payload, origin, source_code)
        entry.update(id=payload["id"], status=status)
        if detail:
            entry["detail"] = detail
        if not dry_run and status in ("created", "updated"):
            try:
                importer.put(
                    payload,
                    expected_version=version,
                    origin=origin,
                    actor=actor,
                    synthetic=synthetic,
                )
            except Problem as problem:
                status = "error"
                entry.update(status="error", errors=[problem.code])
        counts[status] += 1
        report.append(entry)
    summary = {"dryRun": dry_run, "sourceCode": source_code, "counts": counts, "rows": report}
    if not dry_run:
        summary["runId"] = _record_run(catalog, source_code, counts, origin)
    return summary


def _record_run(catalog, source_code, counts, origin):
    """Registro auditavel da execucao (sem payload bruto nem dados pessoais)."""
    run_id = str(uuid4())
    now = catalog.identity.clock().astimezone(timezone.utc)
    key = ("operations", "INGEST#" + source_code, f"RUN#{stamp(now)}#{run_id}")
    catalog.store.commit(
        {key: None},
        {
            key: {
                "id": run_id,
                "sourceCode": source_code,
                "origin": origin,
                "finishedAt": stamp(now),
                "counts": counts,
                "recordsRead": sum(counts.values()),
            }
        },
    )
    return run_id


__all__ = ["import_rows", "parse_csv", "row_to_payload", "rows_to_results"]
