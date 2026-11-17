"""Atualizacao mensal do catalogo: aplica no app o que a rotina mensal (Lambda do catalogo) achou.

A rotina mensal procura provas novas dos proximos meses em todas as regioes do estado e grava
`semanal/<data>/descoberta-mensalHHMM/relatorio.json`. Esta etapa le cada relatorio ainda nao aplicado e:
  1. guarda as provas na area de descobertas (so fatos e fonte);
  2. completa dado faltante das corridas que ja estao no catalogo (so o que esta vazio);
  3. promove as provas novas para o catalogo (pelo importador de sempre) em rodadas curtas.
Cada aplicacao fica registrada (data, quem disparou, contadores) para o portal mostrar o historico."""

import hashlib
import json
import re
from uuid import uuid4

from .admin_users import _iso, _now, audit
from .service import Problem
from .store import Conflict, Unavailable

REPORT_KEY = re.compile(r"^semanal/(\d{4}-\d{2}-\d{2})/descoberta-mensal\d{4}/relatorio\.json$")
MAX_REPORT_BYTES = 8_000_000
PARTITION = ("operations", "CATALOG")
CONFIG_KEY = (*PARTITION, "MONTHLY#CONFIG")
RUN_PREFIX = "MONTHLY#RUN#"
FILE_PREFIX = "MONTHLY#FILE#"
PROMOTE_PER_RUN = 40


def items_of(report):
    """Provas do relatorio da busca -> itens da API de ingestao (so fatos e fonte)."""
    out = []
    for p in report.get("candidatos", []):
        out.append(
            {
                "name": p.get("nome"),
                "date": p.get("data"),
                "city": p.get("cidade"),
                "state": p.get("uf") or "SP",
                "venue": p.get("local"),
                "organizer": p.get("organizador"),
                "distances": list(p.get("distancias_km") or []),
                "sourceUrl": p.get("fonte_url"),
                "excerpt": (p.get("trecho") or "")[:160] or None,
                "region": p.get("regiao_consultada"),
            }
        )
    return out


class MonthlyUpdate:
    def __init__(self, store, discoveries, s3, bucket, clock):
        self.store, self.discoveries, self.s3, self.bucket = store, discoveries, s3, bucket
        self.clock = clock

    # ---- configuracao ------------------------------------------------------------------------------

    def enabled(self):
        config = self.store.get(CONFIG_KEY)
        return True if config is None else bool(config.get("enabled"))

    def set_enabled(self, actor, enabled):
        current = self.store.get(CONFIG_KEY)
        try:
            self.store.commit({CONFIG_KEY: current}, {CONFIG_KEY: {"enabled": bool(enabled)}})
        except Conflict as error:
            raise Problem(409, "VERSION_CONFLICT") from error
        audit(self.store, actor, "catalog.monthly.config", {"enabled": bool(enabled)}, self.clock)
        return {"enabled": bool(enabled)}

    # ---- relatorios ---------------------------------------------------------------------------------

    def _reports(self):
        if self.s3 is None or not self.bucket:
            raise Unavailable()
        found, token = [], None
        try:
            for _ in range(20):
                args = {"Bucket": self.bucket, "Prefix": "semanal/"}
                if token:
                    args["ContinuationToken"] = token
                page = self.s3.list_objects_v2(**args)
                for obj in page.get("Contents", []):
                    if REPORT_KEY.match(obj["Key"]):
                        found.append((obj["Key"], str(obj.get("ETag", ""))))
                token = page.get("NextContinuationToken")
                if not token:
                    break
        except Exception as error:  # noqa: BLE001 - falha do provedor nao vaza detalhe
            raise Unavailable() from error
        return sorted(found)

    @staticmethod
    def _file_key(key, etag):
        digest = hashlib.sha256((key + "|" + etag).encode()).hexdigest()[:32]
        return (*PARTITION, FILE_PREFIX + digest)

    def pending(self):
        return [(k, e) for k, e in self._reports() if self.store.get(self._file_key(k, e)) is None]

    def _read(self, key):
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read(
                MAX_REPORT_BYTES + 1
            )
        except Exception as error:  # noqa: BLE001
            raise Unavailable() from error
        if len(body) > MAX_REPORT_BYTES:
            raise Problem(422, "REPORT_TOO_LARGE")
        return json.loads(body.decode("utf-8"))

    # ---- execucao -----------------------------------------------------------------------------------

    def run(self, trigger="schedule", actor="system:monthly", force=False):
        """Uma rodada curta: aplica um relatorio pendente e promove ate PROMOTE_PER_RUN provas novas."""
        if not force and not self.enabled():
            return {"skipped": "disabled"}
        counts = {
            "reports": 0,
            "found": 0,
            "staged": 0,
            "completed": 0,
            "promoted": 0,
            "needsReview": 0,
            "errors": 0,
        }
        pending = self.pending()
        file_key = None
        if pending:
            key, etag = pending[0]
            file_key = self._file_key(key, etag)
            report = self._read(key)
            items = items_of(report)
            counts["reports"], counts["found"] = 1, len(items)
            for start in range(0, len(items), 500):
                result = self.discoveries.ingest(
                    items[start : start + 500], "api", "mensal-" + key.split("/")[1]
                )
                counts["staged"] += result["counts"]["created"]
                counts["errors"] += result["counts"]["invalid"]
            for raw in items:
                try:
                    found = self.discoveries.find(raw["date"], raw["name"], raw["city"])
                except (KeyError, TypeError):
                    continue
                if found and found.get("status") == "imported":
                    outcome = self.discoveries.complete_edition(found)
                    counts["completed"] += outcome == "completed"
                    counts["errors"] += outcome == "error"
        bulk = self.discoveries.promote_bulk(limit=PROMOTE_PER_RUN, max_seconds=12, dry_run=False)
        counts["promoted"] = bulk["counts"]["created"]
        counts["needsReview"] = bulk["counts"]["needs_review"]
        counts["errors"] += bulk["counts"]["error"]
        if file_key is not None:
            try:
                self.store.commit(
                    {file_key: None}, {file_key: {"key": key, "at": _iso(_now(self.clock))}}
                )
            except Conflict:
                pass
        remaining = len(pending) - (1 if file_key else 0)
        if counts["reports"] == 0 and counts["promoted"] == 0 and counts["needsReview"] == 0:
            if not force:
                return {"skipped": "nothing_to_do", "remaining": bulk["remaining"]}
        record = {
            "at": _iso(_now(self.clock)),
            "trigger": trigger,
            "by": actor,
            "counts": counts,
            "pendingReports": remaining,
            "toPromote": bulk["remaining"],
        }
        run_key = (*PARTITION, f"{RUN_PREFIX}{record['at']}#{uuid4().hex[:6]}")
        self.store.commit({run_key: None}, {run_key: record})
        audit(self.store, actor, "catalog.monthly.run", {"trigger": trigger, **counts}, self.clock)
        return record

    def history(self, limit=20):
        rows, _ = self.store.query("operations", "CATALOG", prefix=RUN_PREFIX, limit=100)
        items = [i for _, i in rows][-limit:]
        return {
            "enabled": self.enabled(),
            "runs": list(reversed(items)),
            "pendingReports": len(self.pending()) if self.s3 is not None and self.bucket else None,
        }
