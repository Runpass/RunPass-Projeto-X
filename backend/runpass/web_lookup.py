"""Procura na web de uma corrida que nao esta no catalogo (tela "Pedir cadastro").

A Lambda de busca do catalogo faz uma busca na web (OpenAI) e devolve so o que a propria busca citou. Aqui:
limite por pessoa e por dia (custo), formato simples para preencher o formulario do pedido, e nada e gravado no
catalogo: a pessoa escolhe uma corrida, confere e envia o pedido, que segue para a equipe como sempre."""

import re
from datetime import timedelta
from decimal import Decimal

from .catalog import title_case
from .service import Problem, stamp
from .store import Conflict, Unavailable

DAILY_LIMIT = 5


def _https(value):
    value = (value or "").strip()
    return value if re.fullmatch(r"https://[^\s]{4,500}", value) else None


def _item(raw):
    try:
        day = str(raw.get("data") or "")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            return None
        name = " ".join(str(raw.get("nome") or "").split())[:160]
        city = " ".join(str(raw.get("cidade") or "").split())[:100]
        if not name or not city:
            return None
        state = str(raw.get("uf") or "").strip().upper()
        distances = []
        for km in raw.get("distancias_km") or []:
            value = Decimal(str(km))
            if 0 < value <= 1000:
                distances.append(float(value))
        return {
            "name": title_case(name),
            "date": day,
            "city": city,
            "state": state if re.fullmatch(r"[A-Z]{2}", state) else None,
            "distancesKm": sorted(set(distances)),
            "officialUrl": _https(raw.get("fonte_url")),
            "venue": (str(raw.get("local") or "").strip()[:160] or None),
            "organizer": (str(raw.get("organizador") or "").strip()[:120] or None),
        }
    except (ArithmeticError, ValueError, TypeError, AttributeError):
        return None


class WebLookup:
    def __init__(self, identity, invoke):
        self.identity, self.store, self.invoke = identity, identity.store, invoke

    def _charge(self, actor):
        """Conta uma procura do dia (antes de chamar: a busca custa mesmo sem achar). Devolve quantas restam."""
        now = self.identity.clock()
        key = ("operations", "USER#" + actor.subject, "WEBLOOKUP#" + now.date().isoformat())
        for _ in range(3):
            current = self.store.get(key)
            used = int((current or {}).get("count", 0))
            if used >= DAILY_LIMIT:
                raise Problem(429, "WEB_LOOKUP_LIMIT")
            try:
                self.store.commit(
                    {key: current},
                    {
                        key: {
                            "count": used + 1,
                            "at": stamp(now),
                            "expiresAt": int((now + timedelta(days=2)).timestamp()),
                        }
                    },
                )
                return DAILY_LIMIT - used - 1
            except Conflict:
                continue
        raise Problem(503, "CONCURRENT_RETRY_REQUIRED")

    def find(self, actor, name, city=None, state=None):
        self.identity.authorize(actor, admitted=True)
        if self.invoke is None:
            raise Problem(503, "WEB_LOOKUP_UNAVAILABLE")
        remaining = self._charge(actor)
        try:
            answer = self.invoke(
                {"procura": {"nome": name, "cidade": city or "", "uf": state or ""}}
            )
        except Unavailable as error:
            raise Problem(503, "WEB_LOOKUP_UNAVAILABLE") from error
        if not isinstance(answer, dict) or answer.get("erro") == "PROCURA_INDISPONIVEL":
            raise Problem(503, "WEB_LOOKUP_UNAVAILABLE")
        if answer.get("erro"):
            raise Problem(422, "INVALID_INPUT")
        items = [i for i in (_item(r) for r in answer.get("corridas") or []) if i][:5]
        return {"items": items, "remaining": remaining}
