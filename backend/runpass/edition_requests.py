"""Pedidos de prova ausente (contrato EditionRequest*).

O pedido e privado do dono e fica em revisao humana: nunca vira edicao publica sozinho, e resolve-lo
nao conclui participacao. A fila de revisao e um indice (`EREQ_QUEUE#pending`) e o mapa id -> dono
(`EREQ#<id>/OWNER`) ficam fora da particao da pessoa; ambos entram em `sharedKeys` para o apagamento
de conta remove-los junto com o pedido.
"""

import hashlib
import json
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from cryptography.fernet import Fernet, InvalidToken
from pydantic import ValidationError

from .catalog import CatalogFilters, CatalogImporter, normalized
from .catalog_import import distance_entry, parse_km, slug
from .identity import require_operator
from .models import EditionRequestFields, ReviewRequestDecision
from .service import Problem, stamp
from .store import Conflict

MAX_PENDING = 10  # pedidos aguardando revisao por pessoa: freia abuso sem atrapalhar uso real
QUEUE = "EREQ_QUEUE#pending"
# Pedido aprovado pela equipe cuja corrida ainda nao esta no catalogo (falta dado para cria-la). Quando a corrida
# aparecer, o vinculo e feito sozinho (`sweep`).
QUEUE_AWAITING = "EREQ_QUEUE#awaiting"
AWAITING = "awaiting_load"
REVIEWABLE = ("pending", AWAITING)
FIRST_DATE = date(1990, 1, 1)
LOCAL_ZONE = ZoneInfo("America/Sao_Paulo")


def item_key(owner, request_id):
    return ("history", "USER#" + owner, "EREQ#" + request_id)


def owner_key(request_id):
    return ("history", "EREQ#" + request_id, "OWNER")


def queue_key(created_at, request_id):
    return ("history", QUEUE, f"{created_at}#{request_id}")


def new_id(now):
    """Mais novo primeiro quando lido em ordem crescente de chave (a lista da pessoa e recente->antiga)."""
    return f"{9_999_999_999 - int(now.timestamp()):010d}-{uuid4().hex[:10]}"


def projection(item):
    out = {
        key: item[key]
        for key in ("id", "version", "status", "details", "reason", "linkedEditionId")
        if key in item
    }
    return out


def check_date(value, now):
    if not (FIRST_DATE <= value <= now.astimezone(LOCAL_ZONE).date() + timedelta(days=730)):
        raise Problem(422, "INVALID_INPUT")


def stored_details(model: EditionRequestFields):
    details = {
        "name": model.name,
        "date": model.date.isoformat(),
        "city": model.city,
        "distanceKm": model.distanceKm,
    }
    if model.state:
        details["state"] = model.state
    if model.officialUrl:
        details["officialUrl"] = model.officialUrl
    return details


class EditionRequestService:
    def __init__(self, identity, cursor_key):
        self.identity, self.store = identity, identity.store
        self.cipher = Fernet(cursor_key)

    def _pending_count(self, actor):
        rows, _ = self.store.query("history", "USER#" + actor.subject, prefix="EREQ#", limit=100)
        return sum(1 for _, item in rows if item.get("status") == "pending")

    def create(self, actor, key, fields: EditionRequestFields):
        details = stored_details(fields)
        payload = {**details, "date": details["date"], "distanceKm": str(details["distanceKm"])}

        def work(read, write, account, now, replay):
            if replay is not None:
                item = read(item_key(actor.subject, replay["id"]))
                if not item:
                    raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
                return projection(item), replay
            check_date(fields.date, now)
            if self._pending_count(actor) >= MAX_PENDING:
                raise Problem(409, "TOO_MANY_PENDING_REQUESTS")
            request_id, created = new_id(now), stamp(now)
            queue, owner = queue_key(created, request_id), owner_key(request_id)
            item = {
                "id": request_id,
                "owner": actor.subject,
                "status": "pending",
                "version": 1,
                "details": details,
                "createdAt": created,
                "updatedAt": created,
                "sharedKeys": [list(owner), list(queue)],
            }
            write(item_key(actor.subject, request_id), item)
            write(owner, {"owner": actor.subject})
            write(queue, {"id": request_id, "createdAt": created, "details": details})
            return projection(item), {"id": request_id}

        return self.identity.transact(
            actor, "createEditionRequest", key, payload, work, admitted=True
        )

    def get(self, actor, request_id):
        def work(read, write, account, now, replay):
            item = read(item_key(actor.subject, request_id))
            if not item:
                raise Problem(404, "EDITION_REQUEST_NOT_FOUND")  # de outra pessoa = mesma resposta
            return projection(item), {}

        return self.identity.transact(actor, "getEditionRequest", None, {}, work, admitted=True)

    def _binding(self, actor, limit):
        return hashlib.sha256(f"ereq|{actor.subject}|{limit}".encode()).hexdigest()

    def list_mine(self, actor, limit, cursor):
        self.identity.authorize(actor, admitted=True)
        after = None
        if cursor:
            try:
                data = json.loads(self.cipher.decrypt(cursor.encode(), ttl=899))
                if data["binding"] != self._binding(actor, limit):
                    raise ValueError()
                after = data["after"]
            except (InvalidToken, ValueError, KeyError, TypeError) as error:
                raise Problem(422, "INVALID_CURSOR") from error
        rows, next_key = self.store.query(
            "history", "USER#" + actor.subject, prefix="EREQ#", after=after, limit=limit
        )
        self.identity.authorize(actor, admitted=True)
        result = {"items": [projection(item) for _, item in rows]}
        if next_key:
            token = {"binding": self._binding(actor, limit), "after": next_key}
            result["nextCursor"] = self.cipher.encrypt(json.dumps(token).encode()).decode()
        return result

    def patch(self, actor, request_id, key, payload):
        changes = {k: v for k, v in payload.items() if k != "expectedVersion"}
        fingerprint = {k: str(v) for k, v in payload.items()}

        def work(read, write, account, now, replay):
            ikey = item_key(actor.subject, request_id)
            item = read(ikey)
            if not item:
                raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
            if replay is not None:
                return projection(item), replay
            if item["status"] != "rejected":
                raise Problem(409, "REQUEST_NOT_EDITABLE")  # aprovado/vinculado aponta ao catalogo
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            merged = {**item["details"], **changes}
            try:
                fields = EditionRequestFields.model_validate(merged)
            except ValidationError as error:
                raise Problem(422, "INVALID_INPUT") from error
            check_date(fields.date, now)
            item.update(
                details=stored_details(fields),
                version=item["version"] + 1,
                updatedAt=stamp(now),
            )
            write(ikey, item)
            return projection(item), {"version": item["version"]}

        return self.identity.transact(
            actor,
            "patchEditionRequest",
            key,
            {"id": request_id, **fingerprint},
            work,
            admitted=True,
        )

    def resubmit(self, actor, request_id, key, payload):
        def work(read, write, account, now, replay):
            ikey = item_key(actor.subject, request_id)
            item = read(ikey)
            if not item:
                raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
            if replay is not None:
                return projection(item), replay
            if item["status"] != "rejected":
                raise Problem(409, "REQUEST_NOT_REJECTED")
            if item["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            if self._pending_count(actor) >= MAX_PENDING:
                raise Problem(409, "TOO_MANY_PENDING_REQUESTS")
            created = stamp(now)
            queue = queue_key(created, request_id)
            item.update(
                status="pending",
                version=item["version"] + 1,
                updatedAt=created,
                sharedKeys=[list(owner_key(request_id)), list(queue)],
            )
            item.pop("reason", None)
            write(ikey, item)
            write(queue, {"id": request_id, "createdAt": created, "details": item["details"]})
            return projection(item), {"version": item["version"]}

        return self.identity.transact(
            actor, "resubmitEditionRequest", key, {"id": request_id, **payload}, work, admitted=True
        )


class EditionRequestReview:
    """Revisao pelo operador com MFA (`catalog_admin`), via ferramenta interna; nunca por HTTP."""

    def __init__(self, catalog, clock=lambda: datetime.now(timezone.utc)):
        self.catalog, self.store, self.clock = catalog, catalog.store, clock

    def pending(self, actor, limit=20, after=None):
        require_operator(self.store, actor, "catalog_admin", self.clock())
        rows, next_key = self.store.query("history", QUEUE, after=after, limit=limit)
        out = []
        for _, entry in rows:
            owner = self.store.get(owner_key(entry["id"]))
            item = owner and self.store.get(item_key(owner["owner"], entry["id"]))
            if item and item["status"] == "pending":
                out.append({**projection(item), "createdAt": item["createdAt"]})
        return out, next_key

    def decide(self, actor, request_id, decision):
        """`decision` e um ReviewRequestDecision. Aprovar/vincular exige edicao aprovada do catalogo."""
        guards = CatalogImporter(self.catalog)._authorization(actor, False)
        owner = self.store.get(owner_key(request_id))
        if not owner:
            raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
        ikey = item_key(owner["owner"], request_id)
        item = self.store.get(ikey)
        if not item:
            raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
        if item["status"] not in REVIEWABLE:
            raise Problem(409, "REQUEST_NOT_PENDING")
        if item["version"] != decision.expectedVersion:
            raise Problem(409, "VERSION_CONFLICT")
        expected = {**guards, ikey: item}
        if decision.decision != "reject":
            head_key = ("catalog", "EDITION#" + decision.editionId, "HEAD")
            head = self.store.get(head_key)
            if not head or head.get("publicationState") != "approved" or head.get("archived"):
                raise Problem(422, "EDITION_NOT_LINKABLE")
            expected[head_key] = head
        queue = next(k for k in map(tuple, item["sharedKeys"]) if k[1] in (QUEUE, QUEUE_AWAITING))
        owner_row = owner_key(request_id)
        expected[queue] = self.store.get(queue)
        now = self.clock()
        version = item["version"] + 1
        new_item = {
            **{k: v for k, v in item.items() if k != "reason"},
            "status": {"approve": "approved", "link": "linked", "reject": "rejected"}[
                decision.decision
            ],
            "version": version,
            "updatedAt": stamp(now),
            "sharedKeys": [list(owner_row)],
        }
        if decision.decision == "reject":
            new_item["reason"] = decision.reason.strip()
        else:
            new_item["linkedEditionId"] = decision.editionId
        audit = ("operations", "EREQ#" + request_id, f"REV#{version}")
        expected[audit] = self.store.get(audit)
        record = {
            "operator": actor.subject,
            "decision": decision.decision,
            "at": stamp(now),
            **({"editionId": decision.editionId} if decision.editionId else {}),
            **({"reason": new_item["reason"]} if "reason" in new_item else {}),
        }
        try:
            self.store.commit(expected, {ikey: new_item, queue: None, audit: record})
        except Conflict as error:
            raise Problem(409, "CONCURRENT_RETRY_REQUIRED") from error
        return projection(new_item)

    # ---- aprovar criando a corrida e vinculando ------------------------------------------------

    def _load(self, request_id):
        owner = self.store.get(owner_key(request_id))
        if not owner:
            raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
        ikey = item_key(owner["owner"], request_id)
        item = self.store.get(ikey)
        if not item:
            raise Problem(404, "EDITION_REQUEST_NOT_FOUND")
        return ikey, item

    def _matches(self, name, day):
        """Corridas do catalogo na mesma data com nome igual ou contido um no outro (a pessoa confirma antes)."""
        pk, query = CatalogFilters(dateFrom=day, dateTo=day, limit=100).plan()
        rows, _ = self.store.query("catalog", pk, limit=100, **query)
        wanted, seen, found = normalized(name), set(), []
        for _, row in rows:
            body = self.catalog._edition(row["editionId"], row["version"])
            if body is None or body["id"] in seen or body.get("status") == "archived":
                continue
            other = normalized(body["name"])
            if wanted and (wanted == other or wanted in other or other in wanted):
                seen.add(body["id"])
                found.append(body)
        return found

    def approve_and_load(self, actor, request_id, expected_version, state=None, distances=None):
        """Aprova o pedido: acha a corrida no catalogo e vincula; se nao existir, CRIA a partir dos dados do pedido
        (a pessoa da equipe confere UF e distancias antes) e vincula; se faltar dado essencial, fica aguardando.

        Devolve (resultado, pedido): resultado e "linked", "created" ou "awaiting"."""
        ikey, item = self._load(request_id)
        if item["status"] not in REVIEWABLE:
            raise Problem(409, "REQUEST_NOT_PENDING")
        if item["version"] != expected_version:
            raise Problem(409, "VERSION_CONFLICT")
        details = item["details"]
        day = date.fromisoformat(details["date"])
        found = self._matches(details["name"], day)
        if found:
            decision = ReviewRequestDecision(
                expectedVersion=expected_version, decision="link", editionId=found[0]["id"]
            )
            return "linked", self.decide(actor, request_id, decision)
        uf = (state or details.get("state") or "").strip().upper()
        try:
            kms = [parse_km(str(d)) for d in (distances or [details["distanceKm"]])]
        except (ValueError, KeyError) as error:
            raise Problem(422, "INVALID_INPUT") from error
        if len(uf) != 2 or not uf.isalpha() or not kms or len(kms) > 8:
            if item["status"] == AWAITING:  # continua aguardando: nada muda
                return "awaiting", projection(item)
            return "awaiting", self._await(actor, request_id, ikey, item)
        edition_id = f"pedido-{slug(details['name'])[:60]}-{details['date']}-{request_id[-6:]}"
        payload = {
            "id": edition_id,
            "name": details["name"],
            "date": details["date"],
            "city": details["city"],
            "state": uf,
            "distances": [distance_entry(k) for k in dict.fromkeys(kms)],
            "sourceCode": "pedido-usuario",
            "sourceExternalId": request_id,
        }
        if details.get("officialUrl"):
            payload["officialUrl"] = details["officialUrl"]
        CatalogImporter(self.catalog).put(
            payload,
            expected_version=0,
            origin=f"https://portal.runpass.invalid/pedido/{request_id}",
            actor=actor,
        )
        decision = ReviewRequestDecision(
            expectedVersion=expected_version, decision="approve", editionId=edition_id
        )
        return "created", self.decide(actor, request_id, decision)

    def _await(self, actor, request_id, ikey, item):
        """Aprovado, mas sem dado para criar a corrida: sai da fila de revisao e entra na de espera."""
        guards = CatalogImporter(self.catalog)._authorization(actor, False)
        now = self.clock()
        version = item["version"] + 1
        pending_queue = next(k for k in map(tuple, item["sharedKeys"]) if k[1] == QUEUE)
        waiting_queue = ("history", QUEUE_AWAITING, pending_queue[2])
        new_item = {
            **item,
            "status": AWAITING,
            "version": version,
            "updatedAt": stamp(now),
            "sharedKeys": [list(owner_key(request_id)), list(waiting_queue)],
        }
        audit = ("operations", "EREQ#" + request_id, f"REV#{version}")
        record = {"operator": actor.subject, "decision": "await", "at": stamp(now)}
        expected = {
            **guards,
            ikey: item,
            pending_queue: self.store.get(pending_queue),
            waiting_queue: None,
            audit: None,
        }
        try:
            self.store.commit(
                expected,
                {
                    ikey: new_item,
                    pending_queue: None,
                    waiting_queue: {"id": request_id},
                    audit: record,
                },
            )
        except Conflict as error:
            raise Problem(409, "CONCURRENT_RETRY_REQUIRED") from error
        return projection(new_item)

    def waiting(self, actor, limit=50):
        require_operator(self.store, actor, "catalog_admin", self.clock())
        rows, _ = self.store.query("history", QUEUE_AWAITING, limit=limit)
        out = []
        for _, entry in rows:
            owner = self.store.get(owner_key(entry["id"]))
            item = owner and self.store.get(item_key(owner["owner"], entry["id"]))
            if item and item["status"] == AWAITING:
                out.append({**projection(item), "createdAt": item["createdAt"]})
        return out

    def sweep(self, actor, limit=50):
        """Vincula sozinho os pedidos aguardando cuja corrida ja entrou no catalogo. Devolve (vinculados, restantes)."""
        waiting, linked = self.waiting(actor, limit), 0
        for item in waiting:
            found = self._matches(
                item["details"]["name"], date.fromisoformat(item["details"]["date"])
            )
            if not found:
                continue
            decision = ReviewRequestDecision(
                expectedVersion=item["version"], decision="link", editionId=found[0]["id"]
            )
            try:
                self.decide(actor, item["id"], decision)
                linked += 1
            except Problem:
                continue  # mudou no meio do caminho: a proxima verificacao tenta de novo
        return linked, len(waiting) - linked
