"""Conectores de fontes externas de provas. TODOS DESLIGADOS por padrao.

Nada aqui conecta a servico real sem: flag ligada, credencial no ambiente (nunca no codigo nem
no app), termos de uso que permitam o uso e cobertura de provas brasileiras conferida numa
amostra real. As respostas abaixo foram escritas a partir da documentacao publica e de
fixtures FICTICIAS dos testes; o formato real da resposta de cada fornecedor ainda precisa ser
confirmado com uma amostra da conta antes de ligar em producao.

Testado contra a rede em 06/11/2026: sem chave, a ACTIVE responde 403 ("Developer Inactive")
e a Let's Do This responde 401.
"""

import json
import os
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Protocol

MAX_PAGES = 20


class SourceDisabled(Exception):
    """Fonte desligada ou sem credencial: a busca interna continua funcionando normalmente."""


class SourceError(Exception):
    def __init__(self, code, retryable=False):
        super().__init__(code)
        self.code, self.retryable = code, retryable


class RaceSourceAdapter(Protocol):
    source_code: str

    def fetch(self, **params) -> list[dict]:
        """Itens ja nos nomes do CSV (source_external_id, name, event_date, ...)."""


def default_http(url, headers, timeout=15):
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise SourceError("SOURCE_UNREACHABLE", retryable=True) from error


def call_with_retry(call, attempts=4, base=0.5, sleep=time.sleep, jitter=random.random):
    """429/5xx e rede: repete com recuo exponencial e jitter. 401/403/404: nao repete."""
    for attempt in range(attempts):
        try:
            status, body = call()
        except SourceError as error:
            if not error.retryable or attempt == attempts - 1:
                raise
        else:
            if status == 200:
                return body
            if status in (401, 403):
                raise SourceError("SOURCE_AUTH_REJECTED")
            if status not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise SourceError(f"SOURCE_HTTP_{status}")
        sleep(base * (2**attempt) * (0.5 + jitter()))
    raise SourceError("SOURCE_UNAVAILABLE")  # pragma: no cover


def _first(item, *names):
    for name in names:
        value = item.get(name)
        if value not in (None, ""):
            return value
    return None


class _Base:
    source_code = ""
    flag = ""
    secret = ""

    def __init__(self, enabled, secret, http=default_http, sleep=time.sleep, jitter=random.random):
        self.enabled, self._secret = enabled, secret
        self.http, self.sleep, self.jitter = http, sleep, jitter

    @classmethod
    def from_env(cls, env=None, **kwargs):
        env = os.environ if env is None else env
        return cls(env.get(cls.flag, "").lower() == "true", env.get(cls.secret, ""), **kwargs)

    def _require(self):
        if not self.enabled or not self._secret:
            raise SourceDisabled(self.source_code)


class CsvSourceAdapter:
    """Arquivo CSV autorizado; habilitado sempre (nao depende de rede nem de credencial)."""

    source_code = "csv"

    def __init__(self, text):
        self.text = text

    def fetch(self, **params):
        import csv
        import io

        return list(csv.DictReader(io.StringIO(self.text.lstrip("﻿"))))


class ActiveSourceAdapter(_Base):
    """ACTIVE Network Activity Search API v2 (GET /v2/search). NAO VERIFICADO com resposta real."""

    source_code = "active"
    flag = "RUNPASS_SOURCE_ACTIVE_ENABLED"
    secret = "RUNPASS_SOURCE_ACTIVE_KEY"
    base = "https://api.amp.active.com/v2/search"

    def fetch(self, *, query="corrida", city="Sao Paulo", state="SP", per_page=50, **_):
        self._require()
        items = []
        for page in range(1, MAX_PAGES + 1):
            params = {
                "query": query,
                "city": city,
                "state": state,
                "country": "BR",
                "current_page": page,
                "per_page": per_page,
                "api_key": self._secret,
            }
            url = self.base + "?" + urllib.parse.urlencode(params)
            body = call_with_retry(
                lambda url=url: self.http(url, {"Accept": "application/json"}),
                sleep=self.sleep,
                jitter=self.jitter,
            )
            results = body.get("results") or []
            items.extend(filter(None, (self.map(r) for r in results)))
            if len(results) < per_page:
                break
        return items

    @staticmethod
    def map(item):
        place = item.get("place") or {}
        distances = _first(item, "distances_km", "distances")
        if not distances:
            return None  # sem distancia nao ha como cadastrar a prova
        return {
            "source_external_id": str(_first(item, "assetGuid", "id") or ""),
            "name": _first(item, "assetName", "name") or "",
            "event_date": str(_first(item, "activityStartDate", "startDate") or "")[:10],
            "city": _first(place, "cityName", "city") or "",
            "state": _first(place, "stateProvinceCode", "state") or "",
            "country": _first(place, "countryCode", "country") or "",
            "distances_km": distances
            if isinstance(distances, str)
            else ";".join(map(str, distances)),
            "official_url": _first(item, "urlAdr", "url") or "",
            "registration_url": _first(item, "registrationUrlAdr", "registrationUrl") or "",
            "venue": _first(place, "placeName", "venue") or "",
            "latitude": _first(place, "latitude") or "",
            "longitude": _first(place, "longitude") or "",
        }


class LetsDoThisSourceAdapter(_Base):
    """Let's Do This Marketplace API (events/search). NAO VERIFICADO com resposta real."""

    source_code = "letsdothis"
    flag = "RUNPASS_SOURCE_LETSDOTHIS_ENABLED"
    secret = "RUNPASS_SOURCE_LETSDOTHIS_TOKEN"
    base = "https://api.letsdothis.com/marketplace/v1/events/search"

    def fetch(self, *, query="corrida Sao Paulo", page_size=50, **_):
        self._require()
        items, search_after = [], None
        for _page in range(MAX_PAGES):
            params = {"query": query, "pageSize": page_size}
            if search_after:
                params["searchAfter"] = search_after
            url = self.base + "?" + urllib.parse.urlencode(params)
            body = call_with_retry(
                lambda url=url: self.http(
                    url, {"Authorization": f"Bearer {self._secret}", "Accept": "application/json"}
                ),
                sleep=self.sleep,
                jitter=self.jitter,
            )
            results = body.get("events") or body.get("results") or []
            items.extend(filter(None, (self.map(r) for r in results)))
            search_after = body.get("searchAfter") or body.get("nextSearchAfter")
            if not results or not search_after:
                break
        return items

    @staticmethod
    def map(item):
        distances = _first(item, "distances_km", "distances")
        if not distances:
            return None
        location = item.get("location") or {}
        return {
            "source_external_id": str(_first(item, "id", "eventId") or ""),
            "name": _first(item, "name", "title") or "",
            "event_date": str(_first(item, "startDate", "date") or "")[:10],
            "city": _first(location, "city") or _first(item, "city") or "",
            "state": _first(location, "state", "region") or _first(item, "state") or "",
            "country": _first(location, "country") or "",
            "distances_km": distances
            if isinstance(distances, str)
            else ";".join(map(str, distances)),
            "official_url": _first(item, "url", "eventUrl") or "",
            "registration_url": _first(item, "registrationUrl", "url") or "",
        }


ADAPTERS = {"active": ActiveSourceAdapter, "letsdothis": LetsDoThisSourceAdapter}
