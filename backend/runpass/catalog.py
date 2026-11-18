"""Catalog query planning, encrypted cursors and immutable generation activation."""

import hashlib
import json
import math
import re
import unicodedata
from collections import OrderedDict
from copy import deepcopy
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Literal
from urllib.parse import quote
from zoneinfo import ZoneInfo

from cryptography.fernet import Fernet, InvalidToken
from pydantic import Field, field_validator, model_validator

from .identity import require_operator
from .models import Input
from .service import Problem, stamp
from .store import Conflict, MemoryStore, Unavailable


def normalized(value):
    return " ".join(
        "".join(c for c in unicodedata.normalize("NFKD", value) if not unicodedata.combining(c))
        .casefold()
        .split()
    )


# Palavras que nao contam no "nucleo" do nome nem viram chave de busca.
NAME_STOPWORDS = frozenset(
    "de da do das dos e a o as os em na no nas nos para por com the of and".split()
)
_ROMAN = re.compile(r"^[ivx]{2,6}$", re.IGNORECASE)
_LETTERS = re.compile(r"[^\W\d_]+")


def title_case(name):
    """Padrao de escrita dos nomes: iniciais maiusculas e o resto minusculo ("3ª Corrida Contra a Polio").
    Preposicoes e artigos ficam minusculos (exceto no inicio); numerais romanos e o "K" de distancia (10K) ficam
    maiusculos; ordinais (3ª, 2º) e trechos entre colchetes ficam como estao."""
    words = (name or "").split()
    out = []
    for index, word in enumerate(words):
        if word.startswith("[") and word.endswith("]"):
            out.append(word)
            continue
        lower = word.lower()
        if 0 < index < len(words) - 1 and lower in NAME_STOPWORDS:
            out.append(lower)
            continue
        if re.fullmatch(r"\d+(\.\d+)?k", lower):
            out.append(lower[:-1] + "K")
            continue
        if re.fullmatch(r"\d+[ªºa-z]*", lower):
            out.append(lower)
            continue

        def fix(match, word=word):
            part = match.group(0)
            after_apostrophe = match.start() > 0 and word[match.start() - 1] in "'’"
            if after_apostrophe and len(part) <= 2:
                return part.lower()  # Women's, Int'l
            if _ROMAN.match(part):
                return part.upper()
            return part[:1].upper() + part[1:].lower()

        out.append(_LETTERS.sub(fix, word))
    return " ".join(out)


def name_words(name):
    """Palavras do nome para a busca: sem acento e caixa, sem pontuacao e sem preposicoes."""
    words = re.split(r"[^0-9a-z]+", normalized(name or ""))
    return [w for w in dict.fromkeys(words) if len(w) >= 2 and w not in NAME_STOPWORDS]


def name_core(name):
    """Nucleo do nome para achar a mesma prova escrita de outro jeito no mesmo dia: sem ano, sem "edicao" (e o
    numero dela), sem o ordinal do inicio, sem "corrida"/"run" e sem preposicoes ("2ª Pace Run - Edição 2026" e
    "Pace Run" tem o mesmo nucleo). Numeros no meio do nome continuam ("4ª Etapa", "9 Km" sao outra prova)."""
    words = [w for w in re.split(r"[^0-9a-z]+", normalized(name or "")) if w]
    ordinal = re.compile(r"\d{1,3}(a|o)?")
    while words and ordinal.fullmatch(words[0]):
        words = words[1:]  # "3ª Corrida..." / "15 Night Run..."
    ignore = NAME_STOPWORDS | {"corrida", "run", "e", "ficticia"}
    kept = []
    for i, w in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else ""
        prev = words[i - 1] if i > 0 else ""
        if w in ("edicao", "ed") or re.fullmatch(r"(19|20)\d\d", w):
            continue
        if ordinal.fullmatch(w) and (nxt in ("edicao", "ed") or prev in ("edicao", "ed")):
            continue  # "2ª Edição" / "Edição 3"
        if w not in ignore:
            kept.append(w)
    # Nome so de palavras genericas ("Corrida 2026"): compara o nome inteiro, nunca um nucleo vazio.
    return " ".join(kept) or " ".join(words) or normalized(name or "")


def name_without_year(name):
    """Nome exato sem o ano e sem pontuacao: a mesma prova com data diferente ("... 2026" em 14 e 15/03)."""
    words = re.split(r"[^0-9a-z]+", normalized(name or ""))
    return " ".join(w for w in words if w and not re.fullmatch(r"(19|20)\d\d", w))


KIDS_WORDS = re.compile(r"\b(kids?|infantil|infantis|mirim|crianca|criancas)\b")


def is_kids(name):
    """Corrida kids pelo NOME (palavras explicitas como Kids, Infantil, Mirim). E uma deducao
    simples e transparente, nao um dado curado: decisao do produto em 11/11/2026, ate o catalogo
    ter um campo proprio de publico por distancia."""
    return bool(KIDS_WORDS.search(normalized(name)))


def distance(value):
    try:
        number = Decimal(str(value))
        if not number.is_finite() or number <= 0:
            raise ValueError()
        return format(number.normalize(), "f")
    except (InvalidOperation, ValueError) as error:
        raise ValueError("Positive finite distance required") from error


def pack(value):
    return json.dumps(
        value,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
        default=lambda v: format(v.normalize(), "f") if isinstance(v, Decimal) else str(v),
    )


class CatalogFilters(Input):
    limit: int = Field(default=20, ge=1, le=100)
    namePrefix: str | None = Field(default=None, min_length=1, max_length=160)
    city: str | None = Field(default=None, min_length=1, max_length=100)
    state: str | None = Field(default=None, pattern=r"^[A-Za-z]{2}$")
    dateFrom: date | None = None
    dateTo: date | None = None
    distanceKm: Decimal | None = None
    # Nome contendo o texto (sem acento nem caixa). Filtra o resultado; nao muda o indice.
    q: str | None = Field(default=None, min_length=1, max_length=160)
    registrationStatus: Literal["unknown", "open", "closed", "sold_out"] | None = None
    # kids = nome com Kids/Infantil/Mirim; adult = o resto (ver is_kids).
    audience: Literal["kids", "adult"] | None = None
    # Raio em torno de um ponto: os tres juntos ou nenhum.
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    radiusKm: float | None = Field(default=None, gt=0, le=500)

    @field_validator("namePrefix", "city", "q")
    @classmethod
    def text(cls, value):
        if value is None:
            return None
        value = normalized(value)
        if not value:
            raise ValueError("Nonblank filter required")
        return value

    @field_validator("state")
    @classmethod
    def uf(cls, value):
        return value.upper() if value else None

    @field_validator("distanceKm", mode="before")
    @classmethod
    def km(cls, value):
        return Decimal(distance(value)) if value is not None else None

    @field_validator("dateFrom", "dateTo", mode="before")
    @classmethod
    def day(cls, value):
        if value is None or isinstance(value, date):
            return value
        return date.fromisoformat(value)

    @model_validator(mode="after")
    def interval(self):
        if self.dateFrom and self.dateTo and self.dateFrom > self.dateTo:
            raise ValueError("dateFrom must precede dateTo")
        if len({self.lat is None, self.lon is None, self.radiusKm is None}) != 1:
            raise ValueError("lat, lon and radiusKm must be given together")
        return self

    def plan(self):
        scope = ["UF=" + self.state] if self.state else []
        if self.city:
            scope.append("CITY=" + quote(self.city, safe=""))
        facet = "#".join(scope) or "GLOBAL"
        order = "NAME" if self.namePrefix and not (self.dateFrom or self.dateTo) else "DATE"
        km = distance(self.distanceKm) if self.distanceKm is not None else "ANY"
        pk = f"CAT#{facet}#{km}#{order}"
        query = (
            {"prefix": self.namePrefix}
            if order == "NAME"
            else {
                "lower": str(self.dateFrom or date.min) + "#",
                "upper": str(self.dateTo or date.max) + "#\U0010ffff",
            }
        )
        return pk, query


def haversine_km(lat1, lon1, lat2, lon2):
    """Distancia em linha reta entre dois pontos, em km."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (
        math.sin((p2 - p1) / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    )
    return 2 * 6371.0088 * math.asin(math.sqrt(a))


class CursorCodec:
    def __init__(self, key, clock, environment):
        self.cipher, self.clock, self.environment = Fernet(key), clock, environment

    def binding(self, actor, filters):
        return hashlib.sha256(
            pack(
                {
                    "actor": actor.subject,
                    "env": self.environment,
                    "route": "/editions",
                    "filters": filters.model_dump(mode="json"),
                }
            ).encode()
        ).hexdigest()

    def issue(self, actor, filters, after):
        return self.cipher.encrypt_at_time(
            pack({"binding": self.binding(actor, filters), "after": after}).encode(),
            int(self.clock().timestamp()),
        ).decode()

    def read(self, token, actor, filters):
        try:
            if len(token) > 8192:
                raise ValueError()
            payload = json.loads(
                self.cipher.decrypt_at_time(token.encode(), 899, int(self.clock().timestamp()))
            )
            if payload["binding"] != self.binding(actor, filters) or not isinstance(
                payload["after"], str
            ):
                raise ValueError()
            return payload["after"]
        except (InvalidToken, ValueError, KeyError, TypeError) as error:
            raise Problem(422, "INVALID_CURSOR") from error


class CatalogService:
    def __init__(self, identity, cursor_key):
        self.identity, self.store = identity, identity.store
        self.codec = CursorCodec(cursor_key, identity.clock, identity.environment)
        self._versions = OrderedDict()

    def _head(self, edition_id):
        return self.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))

    MAX_CACHED_VERSIONS = 2000

    def _remember(self, key, edition):
        """Conteudo de uma versao (nunca muda depois de gravado): fica na memoria da Lambda."""
        self._versions[key] = edition
        self._versions.move_to_end(key)
        while len(self._versions) > self.MAX_CACHED_VERSIONS:
            self._versions.popitem(last=False)

    def _bodies(self, edition_ids):
        """{id: corpo atual ou None} lendo em lote (BatchGetItem): HEAD, versoes ainda nao vistas e notas.
        A versao e imutavel, entao HEAD + versao dispensam transacao de conferencia."""
        ids = list(dict.fromkeys(edition_ids))
        heads = self.store.batch_get([("catalog", "EDITION#" + i, "HEAD") for i in ids])
        current = {}
        for i in ids:
            head = heads[("catalog", "EDITION#" + i, "HEAD")]
            if head and head.get("publicationState") == "approved":
                current[i] = head
        missing = [
            (i, h["version"]) for i, h in current.items() if (i, h["version"]) not in self._versions
        ]
        fetched = (
            self.store.batch_get([("catalog", "EDITION#" + i, "V#" + str(v)) for i, v in missing])
            if missing
            else {}
        )
        for i, v in missing:
            item = fetched[("catalog", "EDITION#" + i, "V#" + str(v))]
            if not item:
                raise Problem(503, "CATALOG_INTEGRITY_FAILURE")
            self._remember((i, v), item["edition"])
        scores = self._scores(list(current))
        today = self.identity.clock().astimezone(ZoneInfo("America/Sao_Paulo")).date()
        out = {i: None for i in ids}
        for i, head in current.items():
            body = deepcopy(self._versions[(i, head["version"])])
            body["version"] = head["version"]
            body["status"] = (
                "archived"
                if head["archived"]
                else ("upcoming" if date.fromisoformat(body["date"]) > today else "past")
            )
            if scores.get(i):
                body["runScore"] = scores[i]
            out[i] = body
        return out

    def _edition(self, edition_id, expected_version=None):
        body = self._bodies([edition_id])[edition_id]
        if (
            body is not None
            and expected_version is not None
            and body["version"] != expected_version
        ):
            return None
        return body

    def _scores(self, edition_ids):
        """Notas publicas (projecao ja calculada pelo consumidor), em lote; nunca inventa nota."""
        try:
            items = self.store.batch_get(
                [("projections", "EDITION#" + i, "SCORE#current") for i in edition_ids]
            )
        except (KeyError, Unavailable):
            # Sem a tabela de projecoes ou sem leitura dela: a nota e opcional e nunca derruba a lista.
            return {}
        out = {}
        for i in edition_ids:
            item = items.get(("projections", "EDITION#" + i, "SCORE#current"))
            if not item or not item.get("reviewCount"):
                continue
            value = Decimal(item["ratingSum"]) / Decimal(8 * item["reviewCount"])
            out[i] = {
                "value": float(value.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)),
                "reviewCount": int(item["reviewCount"]),
            }
        return out

    def detail(self, actor, edition_id):
        self.identity.authorize(actor, admitted=True)
        result = self._edition(edition_id)
        self.identity.authorize(actor, admitted=True)
        if result is None:
            raise Problem(404, "EDITION_NOT_FOUND")
        return result

    MAX_WORD_ROWS = 3000

    def _search_by_words(self, actor, filters, cursor):
        """Busca por nome pelo indice de palavras: le so as corridas que tem a palavra mais longa digitada, confere
        todas as palavras e os demais filtros, e ordena: as proximas primeiro (da mais perto para a mais longe) e
        depois as que ja passaram (da mais recente para a mais antiga). None se a busca nao tem palavra util."""
        words = name_words(filters.q)
        if not words or max(len(w) for w in words) < 3:
            return None
        key = max(words, key=len)
        rows, after = [], None
        while len(rows) < self.MAX_WORD_ROWS:
            page, after = self.store.query(
                "catalog", WORD_INDEX + key[:3], prefix=key, after=after, limit=500
            )
            rows += page
            if after is None:
                break
        ids = list(dict.fromkeys(row["editionId"] for _, row in rows))
        bodies = self._bodies(ids)
        today = self.identity.clock().astimezone(ZoneInfo("America/Sao_Paulo")).date().isoformat()
        found = []
        for body in bodies.values():
            if body is None or body["status"] == "archived":
                continue  # arquivada (duplicada, cancelada) nunca aparece na lista nem na busca
            name_text = normalized(body["name"])
            if not all(word in name_text for word in filters.q.split()):
                continue
            if filters.city and normalized(body["city"]) != filters.city:
                continue
            if filters.state and body["state"] != filters.state:
                continue
            if filters.distanceKm is not None and not any(
                Decimal(str(d["kilometers"])) == filters.distanceKm for d in body["distances"]
            ):
                continue
            if filters.audience and is_kids(body["name"]) != (filters.audience == "kids"):
                continue
            if (
                filters.registrationStatus
                and body.get("registrationStatus", "unknown") != filters.registrationStatus
            ):
                continue
            day = date.fromisoformat(body["date"])
            if (filters.dateFrom and day < filters.dateFrom) or (
                filters.dateTo and day > filters.dateTo
            ):
                continue
            found.append(body)
        upcoming = sorted(
            (b for b in found if b["date"] >= today), key=lambda b: (b["date"], b["id"])
        )
        past = sorted(
            (b for b in found if b["date"] < today),
            key=lambda b: (b["date"], b["id"]),
            reverse=True,
        )
        ordered = upcoming + past
        try:
            start = int(self.codec.read(cursor, actor, filters)) if cursor else 0
        except ValueError as error:
            raise Problem(422, "INVALID_CURSOR") from error
        items = ordered[start : start + filters.limit]
        self.identity.authorize(actor, admitted=True)
        result = {"items": items}
        if start + filters.limit < len(ordered):
            result["nextCursor"] = self.codec.issue(actor, filters, str(start + filters.limit))
        return result

    def list(self, actor, filters, cursor=None):
        self.identity.authorize(actor, admitted=True)
        if filters.q and not filters.namePrefix and filters.radiusKm is None:
            result = self._search_by_words(actor, filters, cursor)
            if result is not None:
                return result
        pk, query = filters.plan()
        after = self.codec.read(cursor, actor, filters) if cursor else None
        items, seen, evaluated, more = [], set(), 0, True
        while len(items) < filters.limit and evaluated < 500 and more:
            rows, next_key = self.store.query(
                "catalog",
                pk,
                after=after,
                limit=min(filters.limit - len(items), 500 - evaluated),
                **query,
            )
            bodies = self._bodies([row["editionId"] for _, row in rows])
            for sk, row in rows:
                after = sk
                evaluated += 1
                body = bodies[row["editionId"]]
                if body is None or body["version"] != row["version"] or body["id"] in seen:
                    continue
                if body["status"] == "archived":
                    continue  # arquivada so abre pelo id (historico de quem participou)
                if filters.namePrefix and not normalized(body["name"]).startswith(
                    filters.namePrefix
                ):
                    continue
                # Recheck all facets against the active source, never trusting an index alone.
                if filters.city and normalized(body["city"]) != filters.city:
                    continue
                if filters.state and body["state"] != filters.state:
                    continue
                if filters.distanceKm is not None and not any(
                    Decimal(str(d["kilometers"])) == filters.distanceKm for d in body["distances"]
                ):
                    continue
                if filters.q:
                    # Todas as palavras da busca precisam estar no nome, em qualquer ordem e sem exigir os
                    # mesmos hifens/pontuacao ("clube itau edicao circo" acha "Clube Itau - Edicao Circo").
                    name_text = normalized(body["name"])
                    if not all(word in name_text for word in filters.q.split()):
                        continue
                if filters.audience and is_kids(body["name"]) != (filters.audience == "kids"):
                    continue
                # Inscricao desconhecida nunca vira "aberta": so casa com "unknown".
                if (
                    filters.registrationStatus
                    and body.get("registrationStatus", "unknown") != filters.registrationStatus
                ):
                    continue
                if filters.radiusKm is not None:
                    if body.get("latitude") is None or body.get("longitude") is None:
                        continue
                    if (
                        haversine_km(
                            filters.lat,
                            filters.lon,
                            float(body["latitude"]),
                            float(body["longitude"]),
                        )
                        > filters.radiusKm
                    ):
                        continue
                day = date.fromisoformat(body["date"])
                if (filters.dateFrom and day < filters.dateFrom) or (
                    filters.dateTo and day > filters.dateTo
                ):
                    continue
                seen.add(body["id"])
                items.append(body)
            more = next_key is not None
            if more:
                after = next_key
        self.identity.authorize(actor, admitted=True)
        result = {"items": items}
        if more and after is not None:
            result["nextCursor"] = self.codec.issue(actor, filters, after)
        return result

    def require_completable(self, actor, edition_id, distance_id):
        body = self.detail(actor, edition_id)
        if body["status"] == "archived":
            raise Problem(409, "EDITION_ARCHIVED")
        if body["status"] == "upcoming":
            raise Problem(409, "EDITION_NOT_FINISHED")
        if not any(d["id"] == distance_id for d in body["distances"]):
            raise Problem(422, "DISTANCE_NOT_IN_EDITION")
        return body  # S04/S06 must additionally condition their commit on HEAD's version.

    def require_draftable(self, actor, edition_id, distance_id):
        body = self.detail(actor, edition_id)
        if body["status"] == "archived":
            raise Problem(409, "EDITION_ARCHIVED")
        if not any(d["id"] == distance_id for d in body["distances"]):
            raise Problem(422, "DISTANCE_NOT_IN_EDITION")
        return body

    MAX_RUNNER_DISTANCES = 5

    def add_runner_distance(self, actor, edition_id, kilometers):
        """O corredor informa a distancia de uma corrida que veio sem ela (ou so com distancias de corredores).
        Nunca mexe em distancia que veio de uma fonte, e acrescenta so uma por vez, marcada `informedBy`."""
        from .catalog_import import distance_entry, parse_km

        try:
            km = parse_km(str(kilometers))
        except ValueError as error:
            raise Problem(422, "INVALID_DISTANCE") from error
        entry = {**distance_entry(km), "informedBy": "runner"}
        for _ in range(3):
            body = self.detail(actor, edition_id)
            if body["status"] == "archived":
                raise Problem(409, "EDITION_ARCHIVED")
            current = body.get("distances", [])
            if any(d.get("informedBy") != "runner" for d in current):
                raise Problem(409, "DISTANCE_NOT_ADDABLE")
            for existing in current:
                if Decimal(str(existing["kilometers"])) == km:
                    return body  # ja informada: nada a gravar
            if len(current) >= self.MAX_RUNNER_DISTANCES:
                raise Problem(409, "DISTANCE_LIMIT_REACHED")
            payload = {k: v for k, v in body.items() if k in ImportEdition.model_fields}
            payload["distances"] = [*current, entry]
            payload["distancesOptional"] = True
            actor_runner = RunnerDistanceActor("runner:" + actor.subject)
            try:
                return CatalogImporter(self, allow_system=True).put(
                    payload,
                    expected_version=body["version"],
                    origin="https://corredor.runpass.invalid/distancia",
                    actor=actor_runner,
                )
            except Problem as problem:
                if problem.code not in ("VERSION_CONFLICT", "CATALOG_VERSION_CONFLICT"):
                    raise
        raise Problem(409, "VERSION_CONFLICT")


class ImportDistance(Input):
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,100}$")
    kilometers: Decimal
    label: str | None = Field(default=None, min_length=1)
    medalImageReference: str | None = Field(default=None, min_length=1)
    # Distancia informada por um corredor (nao pela fonte): aparece como "informada" e nao e dado conferido.
    informedBy: Literal["runner"] | None = None

    @field_validator("kilometers", mode="before")
    @classmethod
    def km(cls, value):
        return Decimal(distance(value))


class ImportEdition(Input):
    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,100}$")
    raceId: str | None = Field(default=None, min_length=1)
    name: str = Field(min_length=1)
    date: str
    city: str = Field(min_length=1)
    state: str = Field(pattern=r"^[A-Z]{2}$")
    # Pais da prova; ausente significa Brasil. Alimenta "Paises visitados" no medalheiro.
    country: str | None = Field(default=None, min_length=2, max_length=80)
    venue: str | None = Field(default=None, min_length=1, max_length=250)
    # Decimal, nao float: o DynamoDB nao grava float.
    latitude: Decimal | None = Field(default=None, ge=-90, le=90, max_digits=12, decimal_places=7)
    longitude: Decimal | None = Field(
        default=None, ge=-180, le=180, max_digits=12, decimal_places=7
    )
    # Situacao informada pela fonte; ausente significa desconhecida (nunca presumir "aberta").
    registrationStatus: Literal["unknown", "open", "closed", "sold_out"] | None = None
    eventStatus: Literal["scheduled", "postponed", "cancelled", "completed", "unknown"] | None = (
        None
    )
    lastVerifiedAt: str | None = Field(default=None, max_length=40)
    # Proveniencia: de onde veio e com que identificador na fonte.
    sourceCode: str | None = Field(default=None, pattern=r"^[a-z0-9_-]{2,40}$")
    sourceExternalId: str | None = Field(default=None, min_length=1, max_length=200)
    distances: list[ImportDistance] = Field(default_factory=list)
    # So as descobertas do catalogo entram sem distancia (o corredor informa ao se inscrever).
    distancesOptional: bool = False
    description: str | None = None
    organizerName: str | None = None
    organizerId: str | None = None
    officialUrl: str | None = None
    registrationUrl: str | None = None
    # Redes do organizador (links conferidos por uma pessoa) e UM post para exibir pelo embed da Meta.
    instagramUrl: str | None = None
    facebookUrl: str | None = None
    organizerPostUrl: str | None = None
    imageReference: str | None = None
    # Credito exibido junto do banner (ex.: "Divulgação: Organizador"); so com imageReference.
    imageCredit: str | None = Field(default=None, min_length=1, max_length=200)
    medalImageReference: str | None = None
    archived: bool = False
    # Por que a edição saiu de circulação; só vale com archived=True.
    archivedReason: Literal["cancelled", "unavailable", "duplicate", "ended"] | None = None

    @field_validator("name", "city", "country")
    @classmethod
    def nonblank(cls, value):
        if value is not None and not normalized(value):
            raise ValueError("Nonblank text required")
        return value

    @field_validator("name")
    @classmethod
    def standard_name(cls, value):
        # Padrao de escrita do catalogo: iniciais maiusculas e o resto minusculo (vale para toda entrada).
        return title_case(value.strip())

    @field_validator("date")
    @classmethod
    def day(cls, value):
        if date.fromisoformat(value).isoformat() != value:
            raise ValueError("YYYY-MM-DD required")
        return value

    @field_validator("latitude", "longitude", mode="before")
    @classmethod
    def decimal_coordinate(cls, value):
        # O modelo e estrito: aceita numero ou texto e converte para Decimal.
        if value is None or isinstance(value, Decimal):
            return value
        try:
            return Decimal(str(value))
        except InvalidOperation as error:
            raise ValueError("Coordenada invalida") from error

    @field_validator("instagramUrl", "facebookUrl", "organizerPostUrl")
    @classmethod
    def social(cls, value, info):
        from .social_links import check_post, check_profile

        if info.field_name == "organizerPostUrl":
            return check_post(value)
        return check_profile(
            "instagram" if info.field_name == "instagramUrl" else "facebook", value
        )

    @field_validator("lastVerifiedAt")
    @classmethod
    def verified(cls, value):
        if value is not None:
            from datetime import datetime

            datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value

    @model_validator(mode="after")
    def coordinates_together(self):
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("latitude and longitude must be given together")
        return self

    @model_validator(mode="after")
    def unique_distances(self):
        if not self.distances and not self.distancesOptional:
            raise ValueError("At least one distance required")
        if len({d.id for d in self.distances}) != len(self.distances):
            raise ValueError("Duplicate distance ID")
        if self.imageCredit and not self.imageReference:
            raise ValueError("imageCredit requires imageReference")
        if self.archivedReason and not self.archived:
            raise ValueError("archivedReason requires an archived edition")
        return self


WORD_INDEX = "CAT#W#"


def index_rows(body, version):
    rows = {}
    kms = ["ANY", *sorted({distance(d["kilometers"]) for d in body["distances"]})]
    for uf in [None, body["state"]]:
        for city in [None, body["city"]]:
            for km in kms:
                common = {"state": uf, "city": city, "distanceKm": None if km == "ANY" else km}
                for order, title in [("DATE", body["date"]), ("NAME", normalized(body["name"]))]:
                    filters = CatalogFilters(**common, namePrefix="x" if order == "NAME" else None)
                    pk, _ = filters.plan()
                    sk = f"{title}#{body['id']}#{version}"
                    if len(pk.encode()) > 2048 or len(sk.encode()) > 1024:
                        raise Problem(422, "CATALOG_KEY_TOO_LARGE")
                    rows[("catalog", pk, sk)] = {"editionId": body["id"], "version": version}
    # Busca por nome: uma linha por palavra, agrupada pelas 3 primeiras letras (a busca le so o grupo da palavra
    # mais longa digitada, em vez de percorrer o catalogo inteiro).
    for word in name_words(body["name"]):
        pk = f"{WORD_INDEX}{word[:3]}"
        sk = f"{word}#{body['date']}#{body['id']}#{version}"
        if len(sk.encode()) <= 1024:
            rows[("catalog", pk, sk)] = {"editionId": body["id"], "version": version}
    return rows


class AutoImportActor:
    """Ator do importe automatico (sem pessoa e sem MFA). So vale em um importador criado com
    `allow_system=True`, o que so o servico de importe automatico faz (ver auto_import.py)."""

    subject = "system:auto-import"
    token_digest = ""


class RunnerDistanceActor(AutoImportActor):
    """Ator da distancia informada por um corredor: registra a pessoa na auditoria, sem poder de operador."""

    def __init__(self, subject):
        self.subject = subject


class CatalogImporter:
    """Internal operation; there is no HTTP bypass for runners or MFA-less operators."""

    def __init__(self, catalog, allow_system=False):
        self.catalog, self.store = catalog, catalog.store
        self.allow_system = allow_system

    def _authorization(self, actor, synthetic):
        if synthetic:
            if not isinstance(self.store, MemoryStore):
                raise ValueError("Synthetic loader is local-memory only")
            return {}
        if isinstance(actor, AutoImportActor):
            if not self.allow_system:
                raise Problem(403, "OPERATOR_SESSION_REQUIRED")
            return {}
        if actor is None:
            raise Problem(403, "OPERATOR_SESSION_REQUIRED")
        require_operator(self.store, actor, "catalog_admin", self.catalog.identity.clock())
        access = ("identity", f"OPERATOR#{actor.subject}", "ACCESS")
        session = ("operations", f"OPERATOR#{actor.subject}", f"SESSION#{actor.token_digest}")
        expected = {k: self.store.get(k) for k in (access, session)}
        if (
            not expected[access]
            or expected[access]["state"] != "active"
            or "catalog_admin" not in expected[access].get("permissions", [])
            or not expected[session]
            or expected[session]["accessVersion"] != expected[access]["_rev"]
            or expected[session].get("factor") != "SOFTWARE_TOKEN_MFA"
            or expected[session]["expiresAt"] <= int(self.catalog.identity.clock().timestamp())
        ):
            raise Problem(403, "OPERATOR_SESSION_REQUIRED")
        return expected

    def put(self, payload, *, expected_version, origin, actor=None, synthetic=False):
        from pydantic import ValidationError

        try:
            model = ImportEdition(**payload)
        except (ValidationError, ValueError) as error:
            raise Problem(422, "INVALID_CATALOG_ENTRY") from error
        if not origin or (not synthetic and not origin.startswith("https://")):
            raise Problem(422, "CATALOG_SOURCE_REQUIRED")
        if (
            not isinstance(expected_version, int)
            or isinstance(expected_version, bool)
            or expected_version < 0
        ):
            raise Problem(422, "INVALID_VERSION")
        authorization = self._authorization(actor, synthetic)
        body = model.model_dump(exclude_none=True, exclude={"archived", "distancesOptional"})
        version = expected_version + 1
        body["version"] = version
        body["status"] = "archived" if model.archived else "past"
        reference_guards = {}
        if body.get("organizerId"):
            organizer_key = ("catalog", "ORGANIZER#" + body["organizerId"], "META")
            organizer = self.store.get(organizer_key)
            if not organizer:
                raise Problem(422, "ORGANIZER_NOT_FOUND")
            reference_guards[organizer_key] = organizer
        image_guards = {}
        targets = [(None, body.get("medalImageReference")), (None, body.get("imageReference"))]
        targets += [(d["id"], d.get("medalImageReference")) for d in body["distances"]]
        for distance_id, reference in targets:
            if reference is None:
                continue
            key = ("operations", "EDITION#" + model.id, "IMAGE#" + reference)
            image = self.store.get(key)
            if (
                not image
                or image.get("state") != "valid"
                or image.get("origin") != "admin"
                or image.get("environment") != self.catalog.identity.environment
                or image.get("distanceId") != distance_id
            ):
                raise Problem(422, "CATALOG_IMAGE_NOT_VALIDATED")
            image_guards[key] = image
        rows = index_rows(body, version)
        digest = hashlib.sha256(pack({"edition": body, "origin": origin}).encode()).hexdigest()
        head_key = ("catalog", "EDITION#" + model.id, "HEAD")
        version_key = ("catalog", "EDITION#" + model.id, "V#" + str(version))
        manifest = {
            "edition": body,
            "digest": digest,
            "origin": origin,
            "reviewRef": "CATALOG#" + model.id + "/REV#" + str(version),
            "reviewedAt": stamp(self.catalog.identity.clock()),
            "indexKeys": [[k[1], k[2]] for k in rows],
        }
        from boto3.dynamodb.types import TypeSerializer

        encoded = {k: TypeSerializer().serialize(v) for k, v in manifest.items()}
        if len(json.dumps(encoded, ensure_ascii=False).encode()) > 390000:
            raise Problem(422, "CATALOG_ITEM_TOO_LARGE")
        current_head = self.store.get(head_key)
        if (current_head or {}).get("version", 0) not in (expected_version, version):
            raise Problem(409, "VERSION_CONFLICT")
        old_version = self.store.get(version_key)
        if old_version and old_version["digest"] != digest:
            raise Problem(409, "CATALOG_VERSION_CONFLICT")
        if not old_version:
            try:
                self.store.commit({version_key: None, **authorization}, {version_key: manifest})
            except Conflict as error:
                raise Problem(409, "CATALOG_VERSION_CONFLICT") from error
        head = self.store.get(head_key)
        if head and head["version"] == version:
            return self.catalog._edition(model.id)
        if (head or {}).get("version", 0) != expected_version:
            raise Problem(409, "VERSION_CONFLICT")
        staged = list(rows.items())
        for start in range(0, len(staged), 80):
            expected, writes = self._authorization(actor, synthetic), {}
            for key, row in staged[start : start + 80]:
                current = self.store.get(key)
                if current is not None:
                    if {k: v for k, v in current.items() if k != "_rev"} != row:
                        raise Problem(409, "CATALOG_INDEX_CONFLICT")
                    continue
                expected[key], writes[key] = None, row
            if writes:
                try:
                    self.store.commit(expected, writes)
                except Conflict as error:
                    raise Problem(409, "CATALOG_LOAD_RETRY") from error
        if any(not self.store.get(key) for key in rows):
            raise Problem(503, "CATALOG_INDEX_INCOMPLETE")
        authorization = self._authorization(actor, synthetic)
        audit_key = ("operations", "CATALOG#" + model.id, "REV#" + str(version))
        now = self.catalog.identity.clock()
        expected = {
            head_key: head,
            version_key: self.store.get(version_key),
            audit_key: self.store.get(audit_key),
            **authorization,
            **image_guards,
            **reference_guards,
        }
        if len(expected) > 100:
            raise Problem(422, "CATALOG_TRANSACTION_TOO_LARGE")
        audit = {
            "action": "activate_catalog_version",
            "version": version,
            "occurredAt": stamp(now),
            "actor": "synthetic-seed" if synthetic else actor.subject,
            "origin": origin,
            "expiresAt": int((now + timedelta(days=90)).timestamp()),
        }
        try:
            self.store.commit(
                expected,
                {
                    head_key: {
                        "version": version,
                        "archived": model.archived,
                        "publicationState": "approved",
                    },
                    audit_key: audit,
                    **{k: {**v, "refs": v.get("refs", 0) + 1} for k, v in image_guards.items()},
                },
            )
        except Conflict as error:
            raise Problem(409, "VERSION_CONFLICT") from error
        return self.catalog._edition(model.id)

    def retire_indexes(self, edition_id, version, *, actor=None, synthetic=False):
        """Retire only superseded index rows; keep immutable edition and image references."""
        self._authorization(actor, synthetic)
        head_key = ("catalog", "EDITION#" + edition_id, "HEAD")
        manifest_key = ("catalog", "EDITION#" + edition_id, "V#" + str(version))
        manifest = self.store.get(manifest_key)
        head = self.store.get(head_key)
        if not manifest or not head or head["version"] <= version:
            raise Problem(409, "ACTIVE_OR_UNKNOWN_CATALOG_VERSION")
        keys = [("catalog", pk, sk) for pk, sk in manifest["indexKeys"]]
        for start in range(0, len(keys), 80):
            expected = {
                head_key: head,
                manifest_key: manifest,
                **self._authorization(actor, synthetic),
            }
            writes = {}
            for key in keys[start : start + 80]:
                row = self.store.get(key)
                if row is not None:
                    expected[key], writes[key] = row, None
            if writes:
                try:
                    self.store.commit(expected, writes)
                except Conflict as error:
                    raise Problem(409, "CATALOG_LOAD_RETRY") from error

    def unlist(self, edition_id, *, actor=None):
        """Tira da lista a edicao ARQUIVADA ativa; o detalhe por id (historico de quem participou) fica."""
        head_key = ("catalog", "EDITION#" + edition_id, "HEAD")
        head = self.store.get(head_key)
        if not head or not head.get("archived"):
            raise Problem(409, "ONLY_ARCHIVED_EDITIONS_CAN_BE_UNLISTED")
        manifest_key = ("catalog", "EDITION#" + edition_id, "V#" + str(int(head["version"])))
        manifest = self.store.get(manifest_key)
        if not manifest:
            raise Problem(409, "ACTIVE_OR_UNKNOWN_CATALOG_VERSION")
        keys = [("catalog", pk, sk) for pk, sk in manifest["indexKeys"]]
        removed = 0
        for start in range(0, len(keys), 80):
            expected = {head_key: head, manifest_key: manifest, **self._authorization(actor, False)}
            writes = {}
            for key in keys[start : start + 80]:
                row = self.store.get(key)
                if row is not None:
                    expected[key], writes[key] = row, None
            if writes:
                try:
                    self.store.commit(expected, writes)
                except Conflict as error:
                    raise Problem(409, "CATALOG_LOAD_RETRY") from error
                removed += len(writes)
        return removed


def seed_synthetic(catalog, path):
    if not isinstance(catalog.store, MemoryStore):
        raise ValueError("Synthetic seed requires MemoryStore")
    entries = json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal)
    importer = CatalogImporter(catalog)
    for entry in entries:
        importer.put(entry, expected_version=0, origin="synthetic-fixture", synthetic=True)
    return len(entries)
