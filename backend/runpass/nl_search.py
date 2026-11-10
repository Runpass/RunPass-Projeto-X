"""Busca em linguagem natural: traduz a frase em filtros do catalogo chamando a Lambda do catalogo.

A Lambda (repositorio RunPass-Catalogo) so interpreta a frase; datas, nomes e links continuam vindo
do catalogo do app. Qualquer falha dela (rede, permissao, timeout, resposta fora do contrato) cai para
busca por nome com a propria frase: a busca nunca quebra por causa da IA. Nem a frase nem a resposta
da Lambda sao registradas em log.
"""

from dataclasses import dataclass, field

from .store import Unavailable

MAX_PHRASE = 200
# Unicas chaves aceitas da Lambda: as mesmas do GET /editions. O resto e descartado.
ALLOWED_FILTERS = frozenset(
    {"state", "city", "dateFrom", "dateTo", "distanceKm", "q", "lat", "lon", "radiusKm"}
)
SOURCES = frozenset({"llm", "cache", "texto"})


@dataclass(frozen=True)
class Translation:
    source: str  # "llm" | "cache" | "text"
    filters: dict = field(default_factory=dict)
    applied: tuple = ()
    not_applied: tuple = ()
    empty: bool = False  # a frase contradiz a si mesma (ex.: futuras em periodo passado)


def text_fallback(phrase):
    return Translation("text", {"q": phrase[:160]}, ("texto",))


def _names(value):
    if not isinstance(value, list) or not all(isinstance(v, str) and len(v) < 40 for v in value):
        raise ValueError("lista de nomes invalida")
    return tuple(value)


class NaturalSearch:
    """`invoke(payload) -> dict` chama a Lambda; levanta Unavailable se nao conseguir."""

    def __init__(self, invoke):
        self.invoke = invoke

    def translate(self, phrase, lat=None, lon=None) -> Translation:
        payload = {"frase": phrase}
        if lat is not None and lon is not None:
            payload.update({"lat": lat, "lng": lon})
        try:
            answer = self.invoke(payload)
            return self._read(answer, phrase)
        except (Unavailable, ValueError, KeyError, TypeError):
            return text_fallback(phrase)

    @staticmethod
    def _read(answer, phrase) -> Translation:
        if not isinstance(answer, dict) or "erro" in answer:
            raise ValueError("resposta fora do contrato")
        source = answer["origem"]
        if source not in SOURCES:
            raise ValueError("origem desconhecida")
        params = answer["params"]
        if not isinstance(params, dict):
            raise ValueError("params invalidos")
        filters = {k: v for k, v in params.items() if k in ALLOWED_FILTERS}
        if answer.get("vazia") is True:
            return Translation("llm", {}, _names(answer["aplicados"]), (), empty=True)
        return Translation(
            "text" if source == "texto" else source,
            filters,
            _names(answer["aplicados"]),
            _names(answer["nao_aplicados"]),
        )
