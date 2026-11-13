"""Cadastro das fontes de coleta de corridas (organizadores, plataformas e calendarios).

Cada fonte e um item `SOURCE#<id>` na particao `CATALOG` da tabela de operacoes (sem recurso novo). Regras:
- Toda fonte nasce `pending` e DESATIVADA. So coleta (`collectable`) a fonte ativa E `verified`.
- Verificar e decisao humana de quem conferiu URL oficial, robots.txt, termos e API/feed; exige uma nota.
- Mudar o site da fonte derruba a verificacao (volta a `pending`) e desativa: a conferencia valia para outro endereco.
- Nivel de confianca: 1 = site do organizador, 2 = plataforma de inscricao, 3 = calendario agregador (organizador e
  sempre nivel 1). A busca na web e so descoberta e nao e uma fonte cadastrada.
- Nada aqui acessa a rede: o cadastro e a trava; a coleta (outras fatias) so le fontes `collectable`.
- Cada mudanca e auditada. Fonte nao e apagada: so desativada.
"""

import re
from datetime import datetime, timezone

from .admin_users import audit
from .service import Problem
from .store import Conflict, Unavailable

PARTITION = ("operations", "CATALOG")
PREFIX = "SOURCE#"
TYPES = ("organizer", "platform", "calendar")
METHODS = ("website", "api", "feed", "sitemap", "manual")
STATUSES = ("pending", "verified", "rejected")
ID = re.compile(r"^[a-z0-9_]{2,40}$")
INSTAGRAM = re.compile(r"^https://(www\.)?instagram\.com/[A-Za-z0-9._]{1,30}/?$")
MIN_HOURS, MAX_HOURS = 1, 24 * 90
MAX_NOTE = 300
MAX_ERROR = 300

# Lista candidata de 13/11/2026 (mesma de `config/sources_candidates.yaml` do repositorio do catalogo). NENHUMA verificada.
CANDIDATES = (
    ("iguana_sports", "Iguana Sports", "organizer", 1, "https://iguanasports.com.br", "https://www.instagram.com/iguanasports/"),
    ("yescom", "Yescom", "organizer", 1, "https://www.yescom.com.br", None),
    ("norte_marketing", "Norte Marketing", "organizer", 1, "https://www.nortemkt.com", None),
    ("beta_sports", "Beta Sports", "organizer", 1, "https://www.betasports.com.br", None),
    ("run_sports", "Run Sports", "organizer", 1, "https://runsports.com.br", None),
    ("sagaz_esportes", "Sagaz Esportes", "organizer", 1, "https://www.sagazesportes.com", None),
    ("chelso_sports", "Chelso Sports", "organizer", 1, "https://chelso.com.br", None),
    ("raveli_sports", "Raveli Sports", "organizer", 1, "https://www.ravelisports.com.br", None),
    ("noblu_sports", "Noblu Sports", "organizer", 1, "https://www.noblu.com.br", None),
    ("moai_sports", "MOAI Sports", "organizer", 1, "https://www.moaisports.com.br", None),
    ("g2p_eventos", "G2P Eventos", "organizer", 1, "https://eventosg2p.com", None),
    ("ideal_5k", "Ideal 5K", "organizer", 1, "https://ideal5k.com.br", None),
    ("partiu_corrida", "Partiu Corrida", "organizer", 1, "https://partiucorrida.com", None),
    ("uhuw_eventos", "UHUW Eventos", "organizer", 1, "https://uhuweventos.com.br", None),
    ("jjs_eventos", "JJS Eventos", "organizer", 1, "https://www.jjseventos.com.br", None),
    ("tfsports", "TFSports", "organizer", 1, "https://www.tfsports.com.br", None),
    ("unlimited_sports", "Unlimited Sports", "organizer", 1, "https://unlimitedsports.com.br", None),
    ("ticket_sports", "Ticket Sports", "platform", 2, "https://www.ticketsports.com.br", None),
    ("correria_campinas", "Correria Campinas", "calendar", 3, "https://correriacampinas.com.br", None),
    ("abraceo", "Abrace o", "calendar", 3, "https://abraceo.com.br", None),
    ("agendarun", "AgendaRun", "calendar", 3, "https://agendarun.com.br", None),
)  # fmt: skip


def _stamp(clock):
    return datetime.fromtimestamp(clock(), timezone.utc).isoformat(timespec="seconds")


def _https(value, optional=False):
    value = (value or "").strip()
    if not value and optional:
        return None
    if (
        len(value) > 300
        or not re.match(r"^https://[^\s/@]+(/[^\s]*)?$", value)
        or "." not in value.split("/")[2]
    ):
        raise Problem(422, "INVALID_INPUT")
    return value


def _host(url):
    return url.split("/")[2].lower().removeprefix("www.")


def _public(sid, item):
    return {
        "id": sid,
        "name": item["name"],
        "type": item["type"],
        "trustLevel": item["trustLevel"],
        "websiteUrl": item["websiteUrl"],
        "instagramUrl": item.get("instagramUrl"),
        "region": item["region"],
        "method": item["method"],
        "frequencyHours": item["frequencyHours"],
        "active": item["active"],
        "verification": item["verification"],
        "verificationNote": item.get("verificationNote"),
        "verifiedBy": item.get("verifiedBy"),
        "verifiedAt": item.get("verifiedAt"),
        "lastCollectedAt": item.get("lastCollectedAt"),
        "lastSuccessAt": item.get("lastSuccessAt"),
        "lastError": item.get("lastError"),
        "collectable": collectable(item),
        "version": item["_rev"],
    }


def collectable(item):
    """So coleta fonte ativa E verificada. Fonte candidata (`pending`) nunca coleta."""
    return bool(item.get("active")) and item.get("verification") == "verified"


class SourceRegistry:
    def __init__(self, store, clock):
        self.store, self.clock = store, clock

    # ---- leitura -----------------------------------------------------------------------------

    def _key(self, sid):
        return (*PARTITION, PREFIX + sid)

    def _all(self):
        items, after = [], None
        for _ in range(20):
            page, after = self.store.query(
                PARTITION[0], PARTITION[1], prefix=PREFIX, after=after, limit=100
            )
            items += [(sk[len(PREFIX) :], item) for sk, item in page]
            if not after:
                break
        return items

    def list(self):
        rows = [_public(sid, item) for sid, item in self._all()]
        rows.sort(key=lambda r: (r["trustLevel"], r["name"].lower()))
        total = len(rows)
        return {
            "items": rows,
            "summary": {
                "total": total,
                "active": sum(1 for r in rows if r["active"]),
                "verified": sum(1 for r in rows if r["verification"] == "verified"),
                "pending": sum(1 for r in rows if r["verification"] == "pending"),
                "collectable": sum(1 for r in rows if r["collectable"]),
                "withError": sum(1 for r in rows if r["lastError"]),
            },
        }

    def collectable_sources(self):
        """O que a coleta pode ler: ativas e verificadas, da mais confiavel para a menos."""
        rows = [_public(sid, item) for sid, item in self._all() if collectable(item)]
        return sorted(rows, key=lambda r: (r["trustLevel"], r["name"].lower()))

    # ---- escrita -----------------------------------------------------------------------------

    def _get(self, sid):
        if not ID.match(sid):
            raise Problem(404, "SOURCE_NOT_FOUND")
        item = self.store.get(self._key(sid))
        if item is None:
            raise Problem(404, "SOURCE_NOT_FOUND")
        return item

    def _commit(self, sid, current, new):
        try:
            self.store.commit({self._key(sid): current}, {self._key(sid): new})
        except Conflict as error:
            raise Problem(409, "VERSION_CONFLICT") from error
        except Unavailable:
            raise

    def _check(self, sid, fields, ignore=None):
        """Valida o conjunto de campos (cria e edita pelas mesmas regras)."""
        if (
            not fields["name"].strip()
            or len(fields["name"].strip()) > 80
            or fields["type"] not in TYPES
            or fields["trustLevel"] not in (1, 2, 3)
            or (fields["type"] == "organizer") != (fields["trustLevel"] == 1)
            or fields["method"] not in METHODS
            or not MIN_HOURS <= fields["frequencyHours"] <= MAX_HOURS
            or not re.match(r"^[A-Z]{2}$", fields["region"])
        ):
            raise Problem(422, "INVALID_INPUT")
        host = _host(fields["websiteUrl"])
        for other_id, other in self._all():
            if other_id != ignore and _host(other["websiteUrl"]) == host:
                raise Problem(409, "SOURCE_DUPLICATE")
        if fields.get("instagramUrl") and not INSTAGRAM.match(fields["instagramUrl"]):
            raise Problem(422, "INVALID_INPUT")

    def _fields(self, name, kind, trust, website, instagram, region, method, hours):
        return {
            "name": (name or "").strip(),
            "type": kind,
            "trustLevel": trust,
            "websiteUrl": _https(website),
            "instagramUrl": _https(instagram, optional=True),
            "region": (region or "SP").strip().upper(),
            "method": method,
            "frequencyHours": hours,
        }

    def create(self, actor, sid, name, kind, trust, website, instagram, region, method, hours):
        if not ID.match(sid or ""):
            raise Problem(422, "INVALID_INPUT")
        fields = self._fields(name, kind, trust, website, instagram, region, method, hours)
        self._check(sid, fields)
        if self.store.get(self._key(sid)) is not None:
            raise Problem(409, "SOURCE_DUPLICATE")
        item = {
            **fields,
            "active": False,
            "verification": "pending",
            "createdBy": actor.subject,
            "createdAt": _stamp(self.clock),
        }
        self._commit(sid, None, item)
        audit(self.store, actor.subject, "catalog.source.create", {"source": sid}, self.clock)
        return _public(sid, {**item, "_rev": 1})

    def update(
        self, actor, sid, version, name, kind, trust, website, instagram, region, method, hours
    ):
        current = self._get(sid)
        if current["_rev"] != version:
            raise Problem(409, "VERSION_CONFLICT")
        fields = self._fields(name, kind, trust, website, instagram, region, method, hours)
        self._check(sid, fields, ignore=sid)
        new = {k: v for k, v in current.items() if k != "_rev"}
        new.update(fields)
        reset = _host(fields["websiteUrl"]) != _host(current["websiteUrl"])
        if reset:  # a conferencia valia para outro endereco
            new.update(active=False, verification="pending")
            for key in ("verificationNote", "verifiedBy", "verifiedAt"):
                new.pop(key, None)
        self._commit(sid, current, new)
        audit(
            self.store,
            actor.subject,
            "catalog.source.update",
            {"source": sid, "verificationReset": reset},
            self.clock,
        )
        return _public(sid, {**new, "_rev": version + 1})

    def verify(self, actor, sid, version, status, note):
        if status not in STATUSES:
            raise Problem(422, "INVALID_INPUT")
        current = self._get(sid)
        if current["_rev"] != version:
            raise Problem(409, "VERSION_CONFLICT")
        note = (note or "").strip()
        if status != "pending" and not note or len(note) > MAX_NOTE:
            raise Problem(
                422, "INVALID_INPUT"
            )  # verificar ou rejeitar exige dizer o que foi conferido
        new = {k: v for k, v in current.items() if k != "_rev"}
        new.update(verification=status)
        if status == "verified":
            new.update(
                verificationNote=note, verifiedBy=actor.subject, verifiedAt=_stamp(self.clock)
            )
        else:
            new["active"] = False  # fonte nao verificada nunca fica ativa
            new["verificationNote"] = note or None
            new.pop("verifiedBy", None)
            new.pop("verifiedAt", None)
        self._commit(sid, current, new)
        audit(
            self.store,
            actor.subject,
            "catalog.source.verify",
            {"source": sid, "status": status},
            self.clock,
        )
        return _public(sid, {**new, "_rev": version + 1})

    def set_active(self, actor, sid, version, active):
        current = self._get(sid)
        if current["_rev"] != version:
            raise Problem(409, "VERSION_CONFLICT")
        if active and current.get("verification") != "verified":
            raise Problem(409, "SOURCE_NOT_VERIFIED")  # so ativa depois de verificada
        new = {k: v for k, v in current.items() if k != "_rev"}
        new["active"] = bool(active)
        self._commit(sid, current, new)
        audit(
            self.store,
            actor.subject,
            "catalog.source.activate" if active else "catalog.source.deactivate",
            {"source": sid},
            self.clock,
        )
        return _public(sid, {**new, "_rev": version + 1})

    def seed_candidates(self, actor):
        """Carrega a lista candidata (todas `pending` e desativadas). Repetivel: o que ja existe nao e tocado."""
        created, skipped = [], []
        existing = {_host(item["websiteUrl"]) for _, item in self._all()}
        for sid, name, kind, trust, website, instagram in CANDIDATES:
            if self.store.get(self._key(sid)) is not None or _host(website) in existing:
                skipped.append(sid)
                continue
            self.create(actor, sid, name, kind, trust, website, instagram, "SP", "website", 24)
            created.append(sid)
        return {"created": created, "skipped": skipped}

    def record_run(self, sid, ok, error=None):
        """Para o coletor (outras fatias): anota a ultima coleta. Erro e truncado e nunca guarda conteudo da pagina."""
        current = self._get(sid)
        new = {k: v for k, v in current.items() if k != "_rev"}
        now = _stamp(self.clock)
        new["lastCollectedAt"] = now
        if ok:
            new["lastSuccessAt"] = now
            new["lastError"] = None
        else:
            new["lastError"] = (error or "erro")[:MAX_ERROR]
        self._commit(sid, current, new)
