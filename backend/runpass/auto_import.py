"""Importe automatico das corridas achadas pela rotina do catalogo (busca e enriquecimento).

Decisao do produto (11/11/2026): depois de cada busca ou enriquecimento, as corridas do `candidatos.csv` que passam
em TODAS as travas abaixo entram no catalogo e ja aparecem no app, sem uma pessoa importar. O que nao passa fica
para a revisao humana (o `import-csv` do operador segue valendo para isso). E uma excecao consciente a regra de que a
IA nao publica: por isso e DESLIGADO por padrao, so liga pelo portal (aba Atualizar catalogo), registra cada entrada e
tem botao Desfazer.

Travas (a corrida so entra se passar em todas):
- linha valida pelo mesmo importador do operador (datas, UF, distancias, enderecos);
- capital de Sao Paulo (cidade e UF);
- data futura e dentro de 18 meses;
- pagina oficial ou de inscricao em https (fonte rastreavel);
- sem corrida parecida no mesmo dia (semelhanca de nome, mais rigida que a do importador: pega "Int'l" x
  "Internacional");
- so CRIA corrida nova: corrida que ja existe (mesma origem) ou veio de outra origem vai para a revisao.
No maximo 50 corridas novas por execucao; o resto fica para a proxima (a execucao e repetivel).
"""

import hashlib
import re
from datetime import date, timedelta
from zoneinfo import ZoneInfo

from .admin_users import audit
from .catalog import AutoImportActor, CatalogImporter, ImportEdition, normalized
from .catalog_import import DATE_INDEX, classify, import_rows, parse_csv
from .service import Problem, stamp
from .store import Conflict, Unavailable

SOURCE_CODE = "catalogo-auto"
REPORT_KEY = re.compile(r"^semanal/(\d{4}-\d{2}-\d{2})/(?:([a-z0-9-]+)/)?candidatos\.csv$")
MAX_NEW_PER_RUN = 50
MAX_FILES_PER_RUN = 6
MAX_CSV_BYTES = 2_000_000
HORIZON_DAYS = 548  # ~18 meses
LOCAL_ZONE = ZoneInfo("America/Sao_Paulo")
STOPWORDS = {"de", "da", "do", "das", "dos", "e", "a", "o", "the"}
GATES = [
    "linha válida pelo mesmo importador do operador",
    "capital de São Paulo (cidade e UF)",
    "data futura, dentro de 18 meses",
    "página oficial ou de inscrição em https",
    "sem corrida parecida no mesmo dia",
    "só cria corrida nova (o que já existe vai para a revisão)",
]
CONFIG_KEY = ("operations", "CATALOG", "AUTOIMPORT#CONFIG")
LAST_KEY = ("operations", "CATALOG", "AUTOIMPORT#LAST")


def _tokens(name):
    return {
        t for t in re.split(r"[^a-z0-9]+", normalized(name)) if len(t) > 1 and t not in STOPWORDS
    }


def similar_names(a, b):
    """Nomes que parecem ser a mesma corrida: um contem o outro ou dividem metade das palavras."""
    ta, tb = _tokens(a), _tokens(b)
    if not ta or not tb:
        return False
    if ta <= tb or tb <= ta:
        return True
    return len(ta & tb) / len(ta | tb) >= 0.5


def _https(value):
    return isinstance(value, str) and value.startswith("https://")


class AutoImport:
    def __init__(self, store, catalog, s3_client, report_bucket, clock=None):
        self.store, self.catalog, self.s3, self.bucket = store, catalog, s3_client, report_bucket
        self.clock = clock or catalog.identity.clock  # devolve datetime
        self.epoch = lambda: self.clock().timestamp()  # o audit pede segundos desde 1970

    # ---- configuracao (interruptor do portal) -------------------------------------------------------

    def enabled(self):
        row = self.store.get(CONFIG_KEY)
        return bool(row and row.get("enabled") is True)

    def set_enabled(self, actor, enabled):
        now = stamp(self.clock())
        old = self.store.get(CONFIG_KEY)
        row = {"enabled": bool(enabled), "by": actor.subject, "at": now}
        try:
            self.store.commit({CONFIG_KEY: old}, {CONFIG_KEY: row})
        except Conflict as error:
            raise Problem(409, "CONCURRENT_RETRY_REQUIRED") from error
        audit(
            self.store, actor.subject, "autoimport.config", {"enabled": bool(enabled)}, self.epoch
        )
        return {"enabled": bool(enabled)}

    # ---- travas -------------------------------------------------------------------------------------

    def _today(self):
        return self.clock().astimezone(LOCAL_ZONE).date()

    def _similar_on_day(self, payload):
        rows, _ = self.store.query(
            "catalog",
            DATE_INDEX,
            lower=payload["date"] + "#",
            upper=payload["date"] + "#\U0010ffff",
            limit=500,
        )
        for _, row in rows:
            body = self.catalog._edition(row["editionId"], row["version"])
            if (
                body
                and body["id"] != payload["id"]
                and similar_names(body["name"], payload["name"])
            ):
                return body["id"]
        return None

    def gate(self, payload):
        """None se a corrida pode entrar; senao o motivo curto de ficar na revisao."""
        if normalized(payload.get("city", "")) != "sao paulo" or payload.get("state") != "SP":
            return "fora_da_capital"
        day = date.fromisoformat(payload["date"])
        today = self._today()
        if not (today <= day <= today + timedelta(days=HORIZON_DAYS)):
            return "data_fora_da_janela"
        if not (_https(payload.get("officialUrl")) or _https(payload.get("registrationUrl"))):
            return "sem_pagina_https"
        twin = self._similar_on_day(payload)
        if twin:
            return "parecida_com:" + twin
        return None

    # ---- arquivos de relatorio ----------------------------------------------------------------------

    def _files(self):
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
                    match = REPORT_KEY.match(obj["Key"])
                    if match and match[2] != "dry-run":
                        found.append((match[1], obj["Key"], str(obj.get("ETag", ""))))
                token = page.get("NextContinuationToken")
                if not token:
                    break
        except Exception as error:  # noqa: BLE001 - falha do provedor nao vaza detalhe
            raise Unavailable() from error
        return sorted(found, reverse=True)  # mais recentes primeiro

    @staticmethod
    def _file_key(key, etag):
        return (
            "operations",
            "CATALOG",
            "AUTOIMPORT#FILE#" + hashlib.sha256((key + "|" + etag).encode()).hexdigest()[:32],
        )

    def _read(self, key):
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read(MAX_CSV_BYTES + 1)
        except Exception as error:  # noqa: BLE001
            raise Unavailable() from error
        if len(body) > MAX_CSV_BYTES:
            raise Problem(422, "CSV_TOO_LARGE")
        return body.decode("utf-8")

    # ---- execucao -----------------------------------------------------------------------------------

    def _process(self, key, remaining):
        """Importa as corridas elegiveis de um arquivo. Devolve (resumo, terminou)."""
        counts = {"created": 0, "blocked": 0, "review": 0, "unchanged": 0, "invalid": 0, "later": 0}
        reasons, created_ids = {}, []
        try:
            results = parse_csv(self._read(key), SOURCE_CODE)
        except Problem as problem:
            return {"key": key, "error": problem.code, "counts": counts, "reasons": reasons}, True
        origin = "https://relatorios.runpass.invalid/" + key
        eligible = []
        for result in results:
            if result["errors"]:
                counts["invalid"] += 1
                continue
            payload = result["payload"]
            reason = self.gate(payload)
            if reason:
                counts["blocked"] += 1
                short = reason.split(":")[0]
                reasons[short] = reasons.get(short, 0) + 1
                continue
            status, _, _ = classify(self.catalog, payload, origin, SOURCE_CODE)
            if status == "created":
                eligible.append(result)
            elif status == "unchanged":
                counts["unchanged"] += 1
            else:  # updated | needs_review: nunca automatico
                counts["review"] += 1
        finished = True
        if len(eligible) > remaining:
            counts["later"] = len(eligible) - remaining
            eligible, finished = eligible[:remaining], False
        if eligible:
            actor = AutoImportActor()
            report = import_rows(
                self.catalog,
                actor,
                eligible,
                origin=origin,
                source_code=SOURCE_CODE,
                dry_run=False,
                allow_system=True,
            )
            for row in report["rows"]:
                if row["status"] == "created":
                    counts["created"] += 1
                    created_ids.append(row["id"])
                elif row["status"] == "error":
                    counts["invalid"] += 1
        now = stamp(self.clock())
        for ident in created_ids:
            body = self.catalog._edition(ident) or {}
            marker = ("operations", "CATALOG", f"AUTOIMPORT#EDITION#{now}#{ident}")
            self.store.commit(
                {marker: None},
                {
                    marker: {
                        "id": ident,
                        "name": body.get("name", ""),
                        "date": body.get("date", ""),
                        "file": key,
                        "at": now,
                        "undone": False,
                    }
                },
            )
            audit(
                self.store,
                AutoImportActor.subject,
                "autoimport.created",
                {"editionId": ident},
                self.epoch,
            )
        return {"key": key, "counts": counts, "reasons": reasons, "created": created_ids}, finished

    def run(self, trigger="schedule"):
        """Importa o que estiver pendente nos relatorios. Desligado = nao faz nada (falha fechado)."""
        if not self.enabled():
            return {"skipped": "disabled"}
        summary = {"trigger": trigger, "files": [], "created": 0}
        budget = MAX_NEW_PER_RUN
        done = 0
        for _, key, etag in self._files():
            if done >= MAX_FILES_PER_RUN or budget <= 0:
                break
            marker = self._file_key(key, etag)
            if self.store.get(marker) is not None:
                continue
            file_summary, finished = self._process(key, budget)
            budget -= file_summary["counts"]["created"]
            summary["created"] += file_summary["counts"]["created"]
            summary["files"].append(file_summary)
            done += 1
            if finished:
                try:
                    self.store.commit(
                        {marker: None},
                        {
                            marker: {
                                "key": key,
                                "at": stamp(self.clock()),
                                "counts": file_summary["counts"],
                            }
                        },
                    )
                except Conflict:
                    pass  # outra execucao ja marcou: o resultado e o mesmo
        record = {
            "at": stamp(self.clock()),
            "trigger": trigger,
            "created": summary["created"],
            "files": len(summary["files"]),
        }
        old = self.store.get(LAST_KEY)
        try:
            self.store.commit(
                {LAST_KEY: old}, {LAST_KEY: {**record, "detail": summary["files"][:6]}}
            )
        except Conflict:
            pass
        return summary

    # ---- leitura e desfazer (portal) ----------------------------------------------------------------

    def _markers(self, limit=300):
        rows, _ = self.store.query(
            "operations", "CATALOG", prefix="AUTOIMPORT#EDITION#", limit=limit
        )
        return rows

    def status(self, limit=30):
        recent = []
        for sk, row in reversed(self._markers()):
            if len(recent) >= limit:
                break
            body = self.catalog._edition(row["id"]) or {}
            recent.append(
                {
                    "id": row["id"],
                    "name": row.get("name") or body.get("name", ""),
                    "date": row.get("date") or body.get("date", ""),
                    "at": row.get("at", ""),
                    "undone": bool(row.get("undone")),
                    "archived": body.get("status") == "archived",
                }
            )
        last = self.store.get(LAST_KEY)
        return {
            "enabled": self.enabled(),
            "gates": GATES,
            "lastRun": {
                k: last[k] for k in ("at", "trigger", "created", "files", "detail") if k in last
            }
            if last
            else None,
            "recent": recent,
        }

    def undo(self, actor, edition_id, reason):
        """Desfaz uma entrada automatica: arquiva a corrida (so as que o importe automatico criou)."""
        if len((reason or "").strip()) < 3:
            raise Problem(422, "INVALID_INPUT")
        marker = next(
            (
                (sk, row)
                for sk, row in self._markers(500)
                if row["id"] == edition_id and not row.get("undone")
            ),
            None,
        )
        if marker is None:
            raise Problem(404, "AUTOIMPORT_ENTRY_NOT_FOUND")
        sk, row = marker
        body = self.catalog._edition(edition_id)
        head = self.catalog.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
        if body is None or head is None:
            raise Problem(404, "EDITION_NOT_FOUND")
        payload = {k: v for k, v in body.items() if k in ImportEdition.model_fields}
        payload["archived"] = True
        payload["archivedReason"] = "unavailable"
        CatalogImporter(self.catalog).put(
            payload,
            expected_version=int(head["version"]),
            origin="https://portal.runpass.invalid/desfazer-importe-automatico",
            actor=actor,
        )
        key = ("operations", "CATALOG", sk)
        self.store.commit(
            {key: self.store.get(key)},
            {
                key: {
                    **row,
                    "undone": True,
                    "undoneBy": actor.subject,
                    "undoneAt": stamp(self.clock()),
                    "undoReason": reason.strip()[:200],
                }
            },
        )
        audit(
            self.store,
            actor.subject,
            "autoimport.undo",
            {"editionId": edition_id, "reason": reason.strip()[:200]},
            self.epoch,
        )
        return {"id": edition_id, "undone": True}
