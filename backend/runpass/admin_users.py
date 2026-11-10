"""Acoes do portal de administracao sobre usuarios e sobre a atualizacao do catalogo.

- Corredores: so LEITURA do cadastro (quem ja criou conta). O e-mail sai mascarado e a consulta fica auditada.
- Operadores: criacao com convite do Cognito (senha temporaria por e-mail) e concessao de acesso na hora.
  O primeiro login exige trocar a senha e cadastrar o autenticador (MFA obrigatorio no pool).
- Catalogo: dispara a Lambda da rotina semanal so com modos de uma lista fechada, com intervalo minimo
  entre disparos (a rotina gasta a cota da OpenAI) e registro de quem disparou.
"""

import json
import re
from datetime import datetime, timezone
from uuid import uuid4

from .operator_admin import PERMISSIONS, grant_access
from .service import Problem
from .store import Conflict, Unavailable

EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
MAX_PAGES = (
    20  # 20 paginas de 60 = ate 1200 cadastros por consulta; alem disso, a resposta diz "parcial"
)
RUN_COOLDOWN = 600  # segundos entre disparos da rotina

# Modos permitidos -> evento enviado a Lambda. Nada digitado pela pessoa entra no evento.
RUN_MODES = {
    "semanal": {},
    "simulacao": {"dry_run": True},
    "enriquecer": {
        "enriquecer": {"relatorio": "latest", "rodada": 1, "max": 10, "csv_semanal": "latest"}
    },
    "imagens": {"imagens": {"csv": "latest"}},
}


def mask_email(email):
    local, _, domain = (email or "").partition("@")
    if not domain:
        return ""
    return f"{local[:1]}***@{domain}"


def _iso(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value else None


def _now(clock):
    return datetime.fromtimestamp(clock(), timezone.utc)


def audit(store, actor, action, detail, clock):
    """Registro imutavel (chave nova a cada acao) de quem fez o que. Sem dados pessoais alem do necessario."""
    now = _now(clock)
    key = ("operations", "OPERATOR#" + actor, f"AUDIT#{now:%Y%m%dT%H%M%S}#{uuid4().hex[:8]}")
    try:
        store.commit({key: None}, {key: {"action": action, "at": _iso(now), **detail}})
    except Conflict as error:
        raise Unavailable() from error


class AdminUsers:
    def __init__(self, store, cognito, runner_pool_id, operator_pool_id, clock):
        self.store, self.cognito, self.clock = store, cognito, clock
        self.runner_pool_id, self.operator_pool_id = runner_pool_id, operator_pool_id

    def registered_runners(self, actor, limit=200):
        """Cadastros do app (pool dos corredores): quem criou conta, quando e se confirmou o e-mail."""
        items, token, pages = [], None, 0
        counts = {}
        while pages < MAX_PAGES:
            args = {"UserPoolId": self.runner_pool_id, "Limit": 60, "AttributesToGet": ["email"]}
            if token:
                args["PaginationToken"] = token
            try:
                page = self.cognito.list_users(**args)
            except Exception as error:  # noqa: BLE001 - falha do provedor nao vaza detalhe
                raise Unavailable() from error
            pages += 1
            for user in page.get("Users", []):
                status = user.get("UserStatus", "")
                counts[status] = counts.get(status, 0) + 1
                email = next(
                    (a["Value"] for a in user.get("Attributes", []) if a["Name"] == "email"), ""
                )
                items.append(
                    {
                        "id": user["Username"][:8],
                        "email": mask_email(email),
                        "status": status,
                        "enabled": bool(user.get("Enabled", True)),
                        "createdAt": _iso(user.get("UserCreateDate")),
                    }
                )
            token = page.get("PaginationToken")
            if not token:
                break
        items.sort(key=lambda u: u["createdAt"] or "", reverse=True)
        audit(self.store, actor, "runners.list", {"total": len(items)}, self.clock)
        return {
            "total": len(items),
            "partial": bool(token),
            "byStatus": counts,
            "items": items[:limit],
        }

    def create_operator(self, actor, email, permissions):
        email = (email or "").strip().lower()
        wanted = sorted(set(permissions or []))
        if not EMAIL.match(email) or not wanted or set(wanted) - set(PERMISSIONS):
            raise Problem(422, "INVALID_INPUT")
        try:
            created = self.cognito.admin_create_user(
                UserPoolId=self.operator_pool_id,
                Username=email,
                UserAttributes=[
                    {"Name": "email", "Value": email},
                    {"Name": "email_verified", "Value": "true"},
                ],
                DesiredDeliveryMediums=["EMAIL"],
            )
        except Exception as error:  # noqa: BLE001
            if type(error).__name__ == "UsernameExistsException":
                raise Problem(409, "OPERATOR_EXISTS") from error
            if type(error).__name__ in ("InvalidParameterException", "InvalidPasswordException"):
                raise Problem(422, "INVALID_INPUT") from error
            raise Unavailable() from error
        attrs = {a["Name"]: a["Value"] for a in created["User"].get("Attributes", [])}
        subject = attrs.get("sub") or created["User"]["Username"]
        try:
            grant_access(self.store, subject, wanted, actor, _now(self.clock))
        except (ValueError, Problem) as error:
            # Conta criada sem acesso: nao concede nada; o operador pode ser removido no Cognito.
            raise Problem(409, "ACCESS_CONFLICT") from error
        audit(
            self.store,
            actor,
            "operator.create",
            {"subject": subject, "permissions": wanted},
            self.clock,
        )
        return {"subject": subject, "email": mask_email(email), "permissions": wanted}


class CatalogRunner:
    def __init__(self, store, lambda_client, function_name, clock, logs_client=None):
        self.store, self.lambda_client, self.function_name = store, lambda_client, function_name
        self.clock, self.logs = clock, logs_client

    def invocations(self, since_ms):
        """Execucoes da Lambda lidas dos proprios registros dela (START/REPORT), sem dados do conteudo."""
        if self.logs is None or not self.function_name:
            return None
        found, token, pages = {}, None, 0
        while pages < 5:
            args = {
                "logGroupName": f"/aws/lambda/{self.function_name}",
                "startTime": since_ms,
                "filterPattern": '?"START RequestId" ?"REPORT RequestId"',
                "limit": 1000,
            }
            if token:
                args["nextToken"] = token
            try:
                page = self.logs.filter_log_events(**args)
            except Exception:  # noqa: BLE001 - sem leitura de logs, a lista mostra so os disparos
                return None
            pages += 1
            for event in page.get("events", []):
                match = re.match(r"(START|REPORT) RequestId: (\S+)", event["message"])
                if not match:
                    continue
                row = found.setdefault(match[2], {})
                if match[1] == "START":
                    row["startedMs"] = event["timestamp"]
                else:
                    row["endedMs"] = event["timestamp"]
                    duration = re.search(r"Duration: ([\d.]+) ms", event["message"])
                    row["durationMs"] = int(float(duration[1])) if duration else None
                    status = re.search(r"Status: (\w+)", event["message"])
                    row["result"] = status[1] if status else "success"
            token = page.get("nextToken")
            if not token:
                break
        return sorted((r for r in found.values() if "startedMs" in r), key=lambda r: r["startedMs"])

    def runs(self, limit=10):
        """Disparos do portal + execucoes agendadas, mais recentes primeiro, com a situacao de cada uma."""
        now_ms = int(self.clock() * 1000)
        dispatched, _ = self.store.query("operations", "CATALOG", prefix="RUN#", limit=100)
        since = now_ms - 7 * 86400 * 1000
        dispatched = [i for _, i in dispatched if int(i["startedEpoch"]) * 1000 >= since][-limit:]
        logs = self.invocations(since)
        used, result = set(), []
        for item in dispatched:
            start_ms = int(item["startedEpoch"]) * 1000
            match = None
            for i, inv in enumerate(logs or []):
                if i not in used and inv["startedMs"] >= start_ms - 5000:
                    match = i
                    break
            row = {
                "origin": "portal",
                "mode": item["mode"],
                "by": item["by"],
                "at": item["startedAt"],
            }
            if item.get("failed"):
                row["status"] = "dispatch_failed"
                result.append(row)
                continue
            if logs is None:
                row["status"] = "unknown"
            elif match is None:
                row["status"] = "waiting" if now_ms - start_ms < 5 * 60 * 1000 else "no_record"
            else:
                used.add(match)
                row.update(self._situation(logs[match], now_ms))
            result.append(row)
        for i, inv in enumerate(logs or []):
            if i not in used:
                row = {
                    "origin": "scheduled",
                    "at": _iso(datetime.fromtimestamp(inv["startedMs"] / 1000, timezone.utc)),
                }
                row.update(self._situation(inv, now_ms))
                result.append(row)
        result.sort(key=lambda r: r["at"], reverse=True)
        return {"items": result[:limit], "logsAvailable": logs is not None}

    @staticmethod
    def _situation(inv, now_ms):
        if "endedMs" not in inv:
            # Limite da Lambda: 15 minutos. Depois disso sem REPORT, o registro ficou incompleto.
            return {
                "status": "running" if now_ms - inv["startedMs"] < 16 * 60 * 1000 else "no_record"
            }
        status = {"success": "done", "error": "failed", "timeout": "timeout"}.get(
            inv["result"], "failed"
        )
        return {"status": status, "durationMs": inv.get("durationMs")}

    @property
    def key(self):
        return ("operations", "CATALOG", "LAST_RUN")

    def last(self):
        last = self.store.get(self.key)
        if not last:
            return {"last": None}
        return {"last": {k: last[k] for k in ("mode", "startedAt", "by") if k in last}}

    def start(self, actor, mode):
        if mode not in RUN_MODES or not self.function_name:
            raise Problem(422, "INVALID_INPUT")
        now = int(self.clock())
        previous = self.store.get(self.key)
        if previous and now - int(previous.get("startedEpoch", 0)) < RUN_COOLDOWN:
            raise Problem(429, "RUN_TOO_SOON")
        record = {
            "mode": mode,
            "by": actor,
            "startedAt": _iso(_now(self.clock)),
            "startedEpoch": now,
        }
        run_key = (
            "operations",
            "CATALOG",
            f"RUN#{_now(self.clock):%Y%m%dT%H%M%S}#{uuid4().hex[:6]}",
        )
        try:  # reserva o intervalo ANTES de invocar: dois cliques juntos disparam uma vez so
            self.store.commit(
                {self.key: previous, run_key: None}, {self.key: record, run_key: record}
            )
        except Conflict as error:
            raise Problem(429, "RUN_TOO_SOON") from error
        try:
            self.lambda_client.invoke(
                FunctionName=self.function_name,
                InvocationType="Event",
                Payload=json.dumps(RUN_MODES[mode]).encode(),
            )
        except Exception as error:  # noqa: BLE001
            failed = {**record, "startedEpoch": 0, "failed": True}  # nao trava o intervalo
            try:
                self.store.commit(
                    {self.key: self.store.get(self.key), run_key: self.store.get(run_key)},
                    {self.key: failed, run_key: {**record, "failed": True}},
                )
            except Conflict:
                pass
            raise Unavailable() from error
        audit(self.store, actor, "catalog.run", {"mode": mode}, self.clock)
        return {"accepted": True, "mode": mode, "startedAt": record["startedAt"]}
