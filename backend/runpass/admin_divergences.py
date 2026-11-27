"""Divergencias da rotina do catalogo: provas em que a rotina NAO decidiu sozinha e pede decisao humana.

Fonte: o `catalogo-completo.csv` do enriquecimento mais recente no bucket de relatorios (so leitura). Entram
so as provas em revisao com um destes resultados: pista parcial (prova confirmada, sem distancia), ambigua (duas
ou mais provas parecidas na mesma data), sugestao (dados de outra edicao) e "nada encontrado".

Em "nada encontrado" a pessoa confere a mao: se EXISTE informacao util, aceita (com os dados e a fonte) e isso conta
como o que a rotina deixou de achar; se NAO existe, descarta. Esses numeros medem a revocacao do enriquecimento.

Aceitar EXIGE as distancias e a fonte com um trecho curto (regra do projeto: fato sem evidencia e anulado) e
NAO publica nada: so grava a decisao e permite baixar um CSV no formato do importador, que o operador importa
com `import-csv` (um unico lugar grava no catalogo). Reprovar descarta a prova. A decisao e imutavel e auditada.
"""

import csv
import hashlib
import io
import re

from .admin_users import audit
from .catalog_import import parse_km, slug
from .service import Problem
from .store import Conflict, Unavailable

LATEST_CSV = re.compile(r"^semanal/(\d{4}-\d{2}-\d{2})/enriquecimento/catalogo-completo\.csv$")
KINDS = {
    "pista parcial, não confirmada": "parcial",
    "enriquecida - conflito, vai para revisão": "ambigua",
    "sugestão da edição anterior": "sugestao",
    "nada encontrado": "nada",
}
KIND_ORDER = {"parcial": 0, "ambigua": 1, "sugestao": 2, "nada": 3}
MAX_DISTANCES = 8
MAX_SNIPPET = 160
EXPORT_COLUMNS = (
    "source_external_id",
    "name",
    "event_date",
    "city",
    "state",
    "distances_km",
    "venue",
    "organizer_name",
    "registration_url",
    "last_verified_at",
    "evidence_url",
    "evidence_text",
)


def item_id(run, name, date):
    return hashlib.sha256(f"{run}|{name}|{date}".encode()).hexdigest()[:16]


def _https(value):
    value = (value or "").strip()
    if (
        len(value) > 500
        or not re.match(r"^https://[^\s/]+[^\s]*$", value)
        or "@" in value.split("/")[2]
    ):
        raise ValueError("url")
    return value


class DivergenceReview:
    def __init__(self, store, s3_client, report_bucket, clock):
        self.store, self.s3, self.bucket, self.clock = store, s3_client, report_bucket, clock

    # ---- leitura -----------------------------------------------------------------------------

    def _latest(self):
        if self.s3 is None or not self.bucket:
            raise Unavailable()
        keys, token = [], None
        try:
            for _ in range(10):
                args = {"Bucket": self.bucket, "Prefix": "semanal/"}
                if token:
                    args["ContinuationToken"] = token
                page = self.s3.list_objects_v2(**args)
                keys += [o["Key"] for o in page.get("Contents", []) if LATEST_CSV.match(o["Key"])]
                token = page.get("NextContinuationToken")
                if not token:
                    break
            if not keys:
                return None, []
            key = max(keys)
            body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read().decode("utf-8")
        except Exception as error:  # noqa: BLE001
            raise Unavailable() from error
        run = LATEST_CSV.match(key)[1]
        rows = list(csv.DictReader(io.StringIO(body.lstrip("﻿")), delimiter=";"))
        return run, rows

    def _decision(self, ident):
        try:
            return self.store.get(("operations", "CATALOG", "DIVERGENCE#" + ident))
        except Unavailable:
            raise
        except KeyError:
            return None

    def _items(self):
        run, rows = self._latest()
        items = []
        for row in rows:
            kind = KINDS.get((row.get("resultado_enriquecimento") or "").strip())
            if kind is None or row.get("status") == "pronta_para_importar":
                continue
            ident = item_id(run, row.get("nome", ""), row.get("data_evento", ""))
            decided = self._decision(ident)
            items.append(
                {
                    "id": ident,
                    "name": row.get("nome", ""),
                    "date": row.get("data_evento", ""),
                    "city": row.get("cidade", ""),
                    "state": row.get("uf", ""),
                    "venue": row.get("local_largada", ""),
                    "kind": kind,
                    "note": row.get("observacao", ""),
                    "source": row.get("fonte_enriquecimento")
                    or row.get("fonte_sugestao")
                    or row.get("fonte_lista", ""),
                    "listSource": row.get("fonte_lista", ""),
                    "suggestedKm": [
                        d
                        for d in re.split(r"[;|]", row.get("distancias_sugeridas_serie") or "")
                        if d.strip()
                    ],
                    "decision": (
                        {
                            "result": decided["decision"],
                            "at": decided["at"],
                            "reason": decided.get("reason", ""),
                            "distances": decided.get("distances", []),
                            "sourceUrl": decided.get("sourceUrl", ""),
                        }
                        if decided
                        else None
                    ),
                    "_row": row,
                }
            )
        items.sort(key=lambda i: (KIND_ORDER[i["kind"]], i["name"]))
        return run, items

    def list(self):
        run, items = self._items()
        public = [{k: v for k, v in i.items() if k != "_row"} for i in items]
        summary = {
            "total": len(public),
            "pending": sum(1 for i in public if i["decision"] is None),
            "accepted": sum(
                1 for i in public if i["decision"] and i["decision"]["result"] == "accepted"
            ),
            "rejected": sum(
                1 for i in public if i["decision"] and i["decision"]["result"] == "rejected"
            ),
        }
        # Revocacao: das "nada encontrado" ja conferidas, quantas tinham informacao util (a rotina deixou de achar).
        checked = [i for i in public if i["kind"] == "nada" and i["decision"]]
        summary["nothingFound"] = {
            "total": sum(1 for i in public if i["kind"] == "nada"),
            "checked": len(checked),
            "hadInfo": sum(1 for i in checked if i["decision"]["result"] == "accepted"),
        }
        return {"run": run, "summary": summary, "items": public}

    # ---- acoes -------------------------------------------------------------------------------

    def decide(self, actor, ident, decision, distances, source_url, snippet, reason):
        if decision not in ("accepted", "rejected"):
            raise Problem(422, "INVALID_INPUT")
        run, items = self._items()
        item = next((i for i in items if i["id"] == ident), None)
        if item is None:
            raise Problem(404, "DIVERGENCE_NOT_FOUND")
        record = {"decision": decision, "by": actor.subject, "at": _stamp(self.clock), "run": run}
        if decision == "accepted":
            try:
                km = [format(parse_km(d).normalize(), "f") for d in (distances or [])]
                url = _https(source_url)
            except ValueError as error:
                raise Problem(422, "INVALID_INPUT") from error
            text = (snippet or "").strip()
            if not km or len(km) > MAX_DISTANCES or not text or len(text) > MAX_SNIPPET:
                raise Problem(422, "INVALID_INPUT")
            record.update(distances=list(dict.fromkeys(km)), sourceUrl=url, snippet=text)
        else:
            text = (reason or "").strip()
            if len(text) > 200:
                raise Problem(422, "INVALID_INPUT")
            record["reason"] = text
        key = ("operations", "CATALOG", "DIVERGENCE#" + ident)
        try:
            self.store.commit({key: None}, {key: record})
        except Conflict as error:
            raise Problem(409, "ALREADY_DECIDED") from error
        audit(
            self.store,
            actor.subject,
            "catalog.divergence." + ("accept" if decision == "accepted" else "reject"),
            {"divergence": ident, "name": item["name"][:80], "kind": item["kind"]},
            self.clock,
        )
        return {"id": ident, "decision": decision}

    def accepted_csv(self):
        """CSV das aceitas da ultima coleta, no formato do importador (o operador confere e importa)."""
        run, items = self._items()
        out = io.StringIO()
        writer = csv.DictWriter(out, fieldnames=EXPORT_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for item in items:
            decided = self._decision(item["id"])
            if not decided or decided["decision"] != "accepted":
                continue
            row = item["_row"]
            writer.writerow(
                {
                    "source_external_id": f"{slug(item['name'])}-{item['date']}"[:80],
                    "name": item["name"],
                    "event_date": item["date"],
                    "city": item["city"] or "São Paulo",
                    "state": item["state"] or "SP",
                    "distances_km": "|".join(decided["distances"]),
                    "venue": item["venue"],
                    "organizer_name": row.get("organizador", ""),
                    "registration_url": row.get("url_inscricao", ""),
                    "last_verified_at": decided["at"],
                    "evidence_url": decided["sourceUrl"],
                    "evidence_text": decided["snippet"],
                }
            )
        return run, out.getvalue()


def _stamp(clock):
    from datetime import datetime, timezone

    return datetime.fromtimestamp(clock(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
