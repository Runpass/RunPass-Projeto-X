"""Banners das corridas pelo portal: ver candidatas, pre-visualizar, aprovar (publica) e retirar.

Regras (as mesmas do terminal): nada e publicado sem decisao do operador, com credito e COMO a autorizacao ou
licenca foi obtida (a nota fica so na tabela de operacoes, nunca na API do app). A imagem e baixada pelo
servidor, e por isso so passa por `fetch_image`: https, sem credenciais na URL, ate 3 redirecionamentos, e o
endereco REAL da conexao precisa ser publico (confere depois de conectar, o que tambem barra DNS que muda de
resposta); o pedido so e enviado depois dessa conferencia.
"""

import csv
import hashlib
import http.client
import io
import ipaddress
import re
import ssl
from urllib.parse import urljoin, urlparse

from .admin_users import audit
from .catalog import normalized
from .operator_admin import approve_banner, normalize_image, remove_banner
from .service import Problem
from .store import Conflict, Unavailable
from .upload import UploadService

MAX_BYTES = 6_000_000
MAX_REDIRECTS = 3
TIMEOUT_S = 15
MAX_ROWS = 200
CANDIDATE_KEY = re.compile(r"^semanal/(\d{4}-\d{2}-\d{2})/imagens/candidatas\.csv$")


class Blocked(Exception):
    pass


def _public(address):
    ip = ipaddress.ip_address(address)
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_global


def default_transport(url, timeout=TIMEOUT_S):
    """GET https. Devolve (status, headers, corpo). Conecta, confere o IP do outro lado e so entao pede."""
    parts = urlparse(url)
    conn = http.client.HTTPSConnection(
        parts.hostname, parts.port or 443, timeout=timeout, context=ssl.create_default_context()
    )
    try:
        conn.connect()
        if not _public(conn.sock.getpeername()[0]):
            raise Blocked()
        path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
        conn.request(
            "GET", path, headers={"User-Agent": "RunPass-Operador/1.0", "Accept": "image/*"}
        )
        response = conn.getresponse()
        headers = {k.lower(): v for k, v in response.getheaders()}
        body = response.read(MAX_BYTES + 1) if response.status == 200 else b""
        return response.status, headers, body
    finally:
        conn.close()


def check_url(url):
    parts = urlparse(url or "")
    if (
        parts.scheme != "https"
        or not parts.hostname
        or parts.username
        or parts.password
        or len(url) > 2000
    ):
        raise Problem(422, "INVALID_IMAGE_URL")
    return parts


def fetch_image(url, transport=default_transport):
    """Baixa e normaliza (JPEG/PNG; WebP vira JPEG). Qualquer falha vira um codigo de erro curto."""
    current = url
    for _ in range(MAX_REDIRECTS + 1):
        check_url(current)
        try:
            status, headers, body = transport(current)
        except Blocked as error:
            raise Problem(422, "IMAGE_URL_BLOCKED") from error
        except (OSError, http.client.HTTPException) as error:
            raise Problem(502, "IMAGE_FETCH_FAILED") from error
        if status in (301, 302, 303, 307, 308) and headers.get("location"):
            current = urljoin(current, headers["location"])
            continue
        if status != 200:
            raise Problem(502, "IMAGE_FETCH_FAILED")
        if len(body) > MAX_BYTES:
            raise Problem(422, "IMAGE_TOO_LARGE")
        kind = headers.get("content-type", "").split(";")[0].strip().lower()
        try:
            data, kind = normalize_image(body, kind)
        except ValueError as error:
            raise Problem(422, "INVALID_IMAGE") from error
        return data, kind
    raise Problem(502, "IMAGE_FETCH_FAILED")


class BannerAdmin:
    def __init__(
        self, store, catalog, blobs, s3_client, report_bucket, clock, transport=default_transport
    ):
        self.store, self.catalog, self.blobs = store, catalog, blobs
        self.s3, self.bucket, self.clock, self.transport = (
            s3_client,
            report_bucket,
            clock,
            transport,
        )

    # ---- leitura -----------------------------------------------------------------------------

    def _editions(self):
        """Todas as edicoes atuais do catalogo (sem arquivadas), numa varredura so."""
        found, seen, after = [], set(), None
        for _ in range(20):
            page, after = self.catalog.store.query(
                "catalog", "CAT#GLOBAL#ANY#DATE", after=after, limit=100
            )
            for _, row in page:
                body = self.catalog._edition(row["editionId"], row["version"])
                if body is None or body["id"] in seen or body.get("status") == "archived":
                    continue
                seen.add(body["id"])
                found.append(body)
            if after is None:
                break
        return found

    @staticmethod
    def _brief(body):
        return {
            "id": body["id"],
            "name": body["name"],
            "date": body["date"],
            "city": body.get("city", ""),
            "state": body.get("state", ""),
            "hasBanner": bool(body.get("imageReference")),
            "credit": body.get("imageCredit", ""),
        }

    def published(self):
        items = [self._brief(b) for b in self._editions() if b.get("imageReference")]
        items.sort(key=lambda e: e["date"])
        return {"items": items}

    def _latest_csv(self):
        if self.s3 is None or not self.bucket:
            raise Unavailable()
        keys, token = [], None
        try:
            for _ in range(10):
                args = {"Bucket": self.bucket, "Prefix": "semanal/"}
                if token:
                    args["ContinuationToken"] = token
                page = self.s3.list_objects_v2(**args)
                keys += [
                    o["Key"] for o in page.get("Contents", []) if CANDIDATE_KEY.match(o["Key"])
                ]
                token = page.get("NextContinuationToken")
                if not token:
                    break
            if not keys:
                return None, ""
            key = max(keys)
            return key, self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read().decode(
                "utf-8"
            )
        except Exception as error:  # noqa: BLE001
            raise Unavailable() from error

    def candidates(self):
        """Candidatas da coleta mais recente com a corrida do catalogo que parece ser a mesma (a pessoa confirma).

        Some da lista a candidata que: (1) tem a MESMA IMAGEM de um banner ja publicado (mesmo que a pessoa
        tenha escolhido a mao outra corrida), (2) combina com QUALQUER corrida do catalogo que ja tem banner
        (nao so a primeira) ou (3) foi excluida pela pessoa. Retirar o banner a devolve para a lista."""
        key, text = self._latest_csv()
        if key is None:
            return {"source": None, "items": []}
        editions = self._editions()
        approved = self._approved_urls(editions)
        items = []
        for row in csv.DictReader(io.StringIO(text)):
            if row.get("situacao") != "candidata" or not row.get("imagem_url", "").startswith(
                "https://"
            ):
                continue
            name = normalized(row.get("nome", ""))
            matches = [
                e
                for e in editions
                if e["date"] == row.get("data")
                and name
                and (
                    name == normalized(e["name"])
                    or name in normalized(e["name"])
                    or normalized(e["name"]) in name
                )
            ]
            match = matches[0] if matches else None
            if (
                row["imagem_url"] in approved
                or any(m.get("imageReference") for m in matches)
                or self._dismissed(row["imagem_url"])
            ):
                continue  # ja publicada, corrida com banner ou excluida: sai da lista
            items.append(
                {
                    "name": row.get("nome", ""),
                    "date": row.get("data", ""),
                    "officialPage": row.get("pagina_oficial", ""),
                    "imageUrl": row["imagem_url"],
                    "credit": row.get("credito_sugerido", ""),
                    "rights": row.get("direitos", ""),
                    "edition": self._brief(match) if match else None,
                }
            )
            if len(items) >= MAX_ROWS:
                break
        return {"source": key.split("/")[1], "items": items}

    def _approved_urls(self, editions):
        """Enderecos das imagens dos banners publicados agora (lidos do registro de cada banner)."""
        urls = set()
        for e in editions:
            ref = e.get("imageReference")
            if not ref:
                continue
            record = self.catalog.store.get(("operations", "EDITION#" + e["id"], "IMAGE#" + ref))
            if record and record.get("sourceUrl"):
                urls.add(record["sourceUrl"])
        return urls

    @staticmethod
    def _dismiss_key(image_url):
        digest = hashlib.sha256(image_url.strip().encode()).hexdigest()[:32]
        return ("operations", "CATALOG", "BANNER_DISMISSED#" + digest)

    def _dismissed(self, image_url):
        return self.store.get(self._dismiss_key(image_url)) is not None

    # ---- acoes -------------------------------------------------------------------------------

    def dismiss(self, actor, image_url):
        """Exclui uma candidata da lista (nao apaga a imagem da coleta; a coleta seguinte nao a traz de volta)."""
        url = (image_url or "").strip()
        if not url.startswith("https://") or len(url) > 2000:
            raise Problem(422, "INVALID_INPUT")
        key = self._dismiss_key(url)
        try:
            self.store.commit(
                {key: None},
                {key: {"by": actor.subject, "at": _stamp(self.clock), "imageUrl": url[:200]}},
            )
        except Conflict:
            return {"dismissed": True}  # ja estava excluida: o resultado e o mesmo
        audit(self.store, actor.subject, "banner.dismiss", {"imageUrl": url[:200]}, self.clock)
        return {"dismissed": True}

    def preview(self, image_url):
        """A imagem como seria publicada (ja sem metadados), para a pessoa ver antes de aprovar."""
        data, kind = fetch_image(image_url, self.transport)
        return UploadService.sanitize(data, kind)

    def approve(self, actor, edition_id, image_url, credit, rights_note, confirmed):
        if not confirmed:
            raise Problem(422, "RIGHTS_NOT_CONFIRMED")
        if not (credit or "").strip() or len((rights_note or "").strip()) < 10:
            raise Problem(422, "INVALID_INPUT")
        data, kind = fetch_image(image_url, self.transport)
        try:
            result = approve_banner(
                self.catalog,
                self.blobs,
                actor,
                edition_id,
                data,
                kind,
                credit,
                rights_note,
                image_url,
            )
        except ValueError as error:
            raise Problem(422, "INVALID_INPUT") from error
        audit(
            self.store,
            actor.subject,
            "banner.approve",
            {"editionId": edition_id, "reference": result["reference"]},
            self.clock,
        )
        return result

    def remove(self, actor, edition_id, reason):
        if len((reason or "").strip()) < 5:
            raise Problem(422, "INVALID_INPUT")
        try:
            result = remove_banner(
                self.catalog, actor, edition_id, "https://portal.runpass.invalid/remocao"
            )
        except ValueError as error:
            raise Problem(409, "NO_BANNER") from error
        audit(
            self.store,
            actor.subject,
            "banner.remove",
            {"editionId": edition_id, "reason": reason.strip()[:200]},
            self.clock,
        )
        return result


def _stamp(clock):
    from datetime import datetime, timezone

    return datetime.fromtimestamp(clock(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
