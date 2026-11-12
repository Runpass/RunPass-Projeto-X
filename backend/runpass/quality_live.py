"""Painel "Ultima execucao" da aba Qualidade da busca: numeros LIDOS dos relatorios que a propria rotina grava
no bucket de relatorios (so leitura), entao se atualiza sozinho a cada execucao.

O que isto mede: o que a rotina fez (quantas corridas achou, quantas vieram com fonte e trecho, quantas esperam
decisao humana). NAO mede acerto: acerto so vem de conferencia humana (a medicao manual de `quality_report.py` e as
decisoes da aba Divergencias, que entram aqui como "decisoes humanas"). Execucoes de teste (`dry-run`) ficam de fora.
"""

import json
import re

from .store import Unavailable

REPORT_KEY = re.compile(r"^semanal/(\d{4}-\d{2}-\d{2})/(?:([a-z0-9-]+)/)?relatorio\.json$")
MAX_REPORT_BYTES = 2_000_000

LABELS = {
    "semanal": "Rotina semanal (pedidos e series)",
    "calendario": "Calendario da prefeitura",
    "enriquecimento": "Enriquecimento (distancia, local, inscricao)",
    "historico": "Historico de provas ja realizadas",
    "imagens": "Banners pela pagina oficial",
}
ORDER = ["semanal", "calendario", "enriquecimento", "historico", "imagens"]


def _kind(folder):
    if folder is None:
        return "semanal"
    if folder.startswith("calendario"):
        return "calendario"
    if folder.startswith("historico"):
        return "historico"
    return folder if folder in ("enriquecimento", "imagens") else None


def _num(value):
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _list(value):
    return value if isinstance(value, list) else []


def _dicts(value):
    return [i for i in _list(value) if isinstance(i, dict)]


def _metric(label, value, of=None, note=None):
    item = {"label": label, "value": value}
    if of is not None:
        item["of"] = of
    if note:
        item["note"] = note
    return item


def _with_source(rows, key):
    return sum(1 for r in rows if r.get(key))


def summarize(kind, report):
    """Lista de metricas {label, value, of?, note?} de um relatorio. Campo ausente conta zero: nunca inventa."""
    if kind == "semanal":
        requests = _dicts(report.get("pedidos"))
        series = _dicts(report.get("catalogo"))
        summary = report.get("resumo") if isinstance(report.get("resumo"), dict) else {}
        return [
            _metric("Pedidos de prova ausente na fila", _num(summary.get("pedidos_na_fila"))),
            _metric("Pedidos pesquisados", _num(summary.get("pesquisados"))),
            _metric(
                "Series da lista consultadas",
                sum(1 for s in series if s.get("situacao") == "consultado"),
                of=len(series),
            ),
            _metric("Novas propostas", sum(_num(s.get("novas_propostas")) for s in series)),
            _metric("Linhas no CSV para importar", _num(summary.get("linhas_no_csv"))),
            _metric(
                "Pedidos sem prova encontrada",
                sum(1 for r in requests if r.get("situacao") == "nao_encontrada"),
                of=len(requests),
            ),
        ]
    if kind == "calendario":
        months = _dicts(report.get("meses"))
        found = _dicts(report.get("candidatos"))
        return [
            _metric(
                "Meses consultados",
                sum(1 for m in months if m.get("situacao") == "consultado"),
                of=len(months),
            ),
            _metric(
                "Corridas devolvidas pela busca", sum(_num(m.get("retornadas")) for m in months)
            ),
            _metric("Aceitas pelas regras (validas)", sum(_num(m.get("validas")) for m in months)),
            _metric("Rejeitadas pelas regras", sum(_num(m.get("rejeitadas")) for m in months)),
            _metric(
                "Candidatas com fonte e trecho", _with_source(found, "fonte_url"), of=len(found)
            ),
            _metric(
                "Com a distancia na propria fonte",
                sum(1 for r in found if r.get("distancia_na_fonte") is True),
                of=len(found),
            ),
        ]
    if kind == "enriquecimento":
        counts = report.get("contagens") if isinstance(report.get("contagens"), dict) else {}
        races = _dicts(report.get("provas"))
        total = len(races)
        return [
            _metric("Provas na rodada", total),
            _metric("Prontas para importar", _num(counts.get("pronta")), of=total),
            _metric("Nada encontrado", _num(counts.get("nada")), of=total),
            _metric("Sem distancia", _num(counts.get("sem_distancia")), of=total),
            _metric("Com fonte citada", _with_source(races, "fonte"), of=total),
            _metric("Linhas para o importador", _num(counts.get("linhas_importador"))),
        ]
    if kind == "historico":
        series = _dicts(report.get("series"))
        found = _dicts(report.get("candidatos"))
        return [
            _metric(
                "Series consultadas",
                sum(1 for s in series if s.get("situacao") == "consultado"),
                of=len(series),
            ),
            _metric("Edicoes encontradas", sum(_num(s.get("edicoes")) for s in series)),
            _metric(
                "Candidatas com fonte e trecho", _with_source(found, "fonte_url"), of=len(found)
            ),
        ]
    if kind == "imagens":
        situations = report.get("situacoes") if isinstance(report.get("situacoes"), dict) else {}
        done = _num(report.get("processadas"))
        return [
            _metric("Paginas oficiais processadas", done),
            _metric("Imagens candidatas", _num(situations.get("candidata")), of=done),
            _metric("Sem pagina oficial", _num(situations.get("sem_pagina_oficial")), of=done),
            _metric("Sem imagem declarada", _num(situations.get("sem_imagem_declarada")), of=done),
            _metric(
                "Falha de rede ou imagem invalida",
                _num(situations.get("erro_de_rede")) + _num(situations.get("imagem_invalida")),
                of=done,
            ),
        ]
    return []


class LiveQuality:
    def __init__(self, s3_client, report_bucket, divergences=None):
        self.s3, self.bucket, self.divergences = s3_client, report_bucket, divergences

    def _keys(self):
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
                    if match and match[2] != "dry-run" and "/dry-run/" not in obj["Key"]:
                        kind = _kind(match[2])
                        if kind:
                            found.append((kind, match[1], obj["Key"], obj.get("LastModified")))
                token = page.get("NextContinuationToken")
                if not token:
                    break
        except Exception as error:  # noqa: BLE001 - falha do provedor nao vaza detalhe
            raise Unavailable() from error
        return found

    def _read(self, key):
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read(MAX_REPORT_BYTES)
            data = json.loads(body.decode("utf-8"))
        except Exception:  # noqa: BLE001 - relatorio ausente/quebrado: o painel segue sem ele
            return None
        return data if isinstance(data, dict) else None

    def latest(self):
        newest = {}
        for kind, day, key, modified in self._keys():
            if kind not in newest or (day, key) > (newest[kind][0], newest[kind][1]):
                newest[kind] = (day, key, modified)
        runs = []
        for kind in ORDER:
            if kind not in newest:
                continue
            day, key, modified = newest[kind]
            report = self._read(key)
            if report is None:
                continue
            resumo = report.get("resumo") if isinstance(report.get("resumo"), dict) else {}
            runs.append(
                {
                    "kind": kind,
                    "label": LABELS[kind],
                    "date": day,
                    "generatedAt": modified.isoformat() if hasattr(modified, "isoformat") else None,
                    "interrupted": bool(report.get("interrompido") or resumo.get("interrompido")),
                    "metrics": summarize(kind, report),
                }
            )
        decisions = None
        if self.divergences is not None:
            try:
                decisions = self.divergences.list()["summary"]
            except Unavailable:
                decisions = None
        return {"runs": runs, "decisions": decisions}
