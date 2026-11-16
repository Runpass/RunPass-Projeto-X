"""Internal operator tooling: grant access and load the catalog through the real importer.

Never exposed over HTTP. The loader requires an operator session with MFA and catalog_admin;
there is no synthetic shortcut for a persistent store.
"""

import hashlib
import io
import json
from datetime import datetime, timezone
from decimal import Decimal

from .catalog import CatalogImporter, ImportEdition
from .service import Problem
from .store import Conflict
from .upload import CATALOG_OWNER, UploadService

PERMISSIONS = ("catalog_admin", "moderation", "lake_read", "user_admin", "cost_read")
FIXTURE_ORIGIN = "https://runpass.invalid/fixture-sintetica"


def grant_access(store, subject, permissions, granted_by, now=None):
    """Create or update OPERATOR#sub/ACCESS. A distinct responsible must grant it."""
    if not subject or not granted_by:
        raise ValueError("Operator subject and responsible are required")
    if granted_by == subject:
        raise ValueError("A distinct responsible must grant operator access")
    unknown = set(permissions) - set(PERMISSIONS)
    if unknown or not permissions:
        raise ValueError("Unknown or empty permissions")
    key = ("identity", f"OPERATOR#{subject}", "ACCESS")
    current = store.get(key)
    now = now or datetime.now(timezone.utc)
    value = {
        "state": "active",
        "permissions": sorted(set(permissions)),
        "grantedBy": granted_by,
        "grantedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        store.commit({key: current}, {key: value})
    except Conflict as error:
        raise Problem(409, "ACCESS_CONFLICT") from error
    return store.get(key)


def _already_loaded(catalog, entry, head, origin):
    """True quando a versao atual do catalogo ja tem exatamente este conteudo e origem."""
    model = ImportEdition(**entry)
    body = model.model_dump(exclude_none=True, exclude={"archived"})
    body["version"] = head["version"]
    body["status"] = "archived" if model.archived else "past"
    stored = catalog.store.get(("catalog", "EDITION#" + model.id, "V#" + str(head["version"])))
    return bool(stored) and stored["edition"] == body and stored["origin"] == origin


def load_catalog(catalog, actor, fixture_text, origin=FIXTURE_ORIGIN):
    """Load editions through CatalogImporter as an MFA operator.

    Repetir e seguro: conteudo igual nao cria versao; conteudo alterado publica a proxima versao.
    """
    entries = json.loads(fixture_text, parse_float=Decimal)
    importer = CatalogImporter(catalog)
    for entry in entries:
        head = catalog.store.get(("catalog", "EDITION#" + entry["id"], "HEAD"))
        if head is None:
            importer.put(entry, expected_version=0, origin=origin, actor=actor)
        elif not _already_loaded(catalog, entry, head, origin):
            importer.put(entry, expected_version=int(head["version"]), origin=origin, actor=actor)
    return [entry["id"] for entry in entries]


def retire_catalog(catalog, actor, fixture_text, origin=FIXTURE_ORIGIN):
    """Arquiva as edicoes do arquivo e as tira da lista, sem apagar nada (o historico fica no detalhe).

    Repetir e seguro. Edicao que nunca foi carregada e ignorada.
    """
    importer = CatalogImporter(catalog)
    result = {"arquivadas": [], "tiradas_da_lista": [], "ausentes": []}
    for entry in json.loads(fixture_text, parse_float=Decimal):
        key = ("catalog", "EDITION#" + entry["id"], "HEAD")
        head = catalog.store.get(key)
        if head is None:
            result["ausentes"].append(entry["id"])
            continue
        if not head.get("archived"):
            archived = {**entry, "archived": True, "archivedReason": "unavailable"}
            importer.put(
                archived, expected_version=int(head["version"]), origin=origin, actor=actor
            )
            result["arquivadas"].append(entry["id"])
        if importer.unlist(entry["id"], actor=actor):
            result["tiradas_da_lista"].append(entry["id"])
    return result


def approve_banner(
    catalog, blobs, actor, edition_id, image, content_type, credit, rights_note, origin_url
):
    """Publica o banner de uma edicao DEPOIS da aprovacao humana.

    `image` sao os bytes baixados da fonte; sao reencodados sem metadados (mesma sanitizacao das fotos).
    O credito aparece no app. `rights_note` registra COMO a autorizacao ou licenca foi obtida e fica
    so na tabela de operacoes, nunca na API. Sem as duas coisas nada e publicado."""
    if not credit or not credit.strip():
        raise ValueError("Credito obrigatorio")
    if not rights_note or len(rights_note.strip()) < 10:
        raise ValueError("Informe como a autorizacao ou licenca foi obtida (minimo 10 caracteres)")
    data, actual_type = UploadService.sanitize(image, content_type)
    body = catalog._edition(edition_id)
    head = catalog.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
    if body is None or head is None:
        raise Problem(404, "EDITION_NOT_FOUND")
    reference = "banner_" + hashlib.sha256(data).hexdigest()[:32]
    blobs.write_derived(reference, data, actual_type, CATALOG_OWNER)
    now = catalog.identity.clock()
    image_key = ("operations", "EDITION#" + edition_id, "IMAGE#" + reference)
    if catalog.store.get(image_key) is None:
        catalog.store.commit(
            {image_key: None},
            {
                image_key: {
                    "owner": "catalog",
                    "origin": "admin",
                    "state": "valid",
                    "refs": 0,
                    "environment": catalog.identity.environment,
                    "contentType": actual_type,
                    "credit": credit.strip(),
                    "rightsNote": rights_note.strip(),
                    "sourceUrl": origin_url,
                    "approvedBy": actor.subject,
                    "approvedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
            },
        )
    payload = {k: v for k, v in body.items() if k in ImportEdition.model_fields}
    payload["archived"] = body.get("status") == "archived"
    payload["imageReference"] = reference
    payload["imageCredit"] = credit.strip()
    updated = CatalogImporter(catalog).put(
        payload, expected_version=int(head["version"]), origin=origin_url, actor=actor
    )
    return {"reference": reference, "version": updated["version"], "contentType": actual_type}


def set_social_links(catalog, actor, edition_id, links, origin_url):
    """Grava (ou apaga) os perfis de Instagram/Facebook do organizador e o post a exibir, numa nova versao da
    corrida. `links` so traz as chaves que mudam; valor vazio/None apaga. So link: nada e consultado na Meta."""
    from .social_links import check_post, check_profile

    body = catalog._edition(edition_id)
    head = catalog.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
    if body is None or head is None:
        raise Problem(404, "EDITION_NOT_FOUND")
    payload = {k: v for k, v in body.items() if k in ImportEdition.model_fields}
    payload["archived"] = body.get("status") == "archived"
    checkers = {
        "instagramUrl": lambda v: check_profile("instagram", v),
        "facebookUrl": lambda v: check_profile("facebook", v),
        "organizerPostUrl": check_post,
    }
    for key, check in checkers.items():
        if key in links:
            value = check(links[key])  # ValueError se o endereco nao for do tipo certo
            if value is None:
                payload.pop(key, None)
            else:
                payload[key] = value
    updated = CatalogImporter(catalog).put(
        payload, expected_version=int(head["version"]), origin=origin_url, actor=actor
    )
    return {"version": updated["version"], **{k: payload.get(k) for k in checkers}}


def rename_edition(catalog, actor, edition_id, name, origin_url):
    """Corrige o NOME de uma corrida do catalogo (ex.: pedido de usuario escrito errado), numa nova versao.
    O id e o resto dos dados nao mudam; so o nome, com o mesmo cuidado de espacos do cadastro."""
    clean = " ".join(str(name or "").split())
    if not clean or len(clean) > 160 or any(ord(c) < 32 for c in clean):
        raise Problem(422, "INVALID_INPUT")
    body = catalog._edition(edition_id)
    head = catalog.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
    if body is None or head is None:
        raise Problem(404, "EDITION_NOT_FOUND")
    payload = {k: v for k, v in body.items() if k in ImportEdition.model_fields}
    payload["archived"] = body.get("status") == "archived"
    payload["name"] = clean
    updated = CatalogImporter(catalog).put(
        payload, expected_version=int(head["version"]), origin=origin_url, actor=actor
    )
    return {"id": edition_id, "name": clean, "version": updated["version"]}


def normalize_image(data, content_type):
    """JPEG e PNG seguem como estao; WebP vira JPEG (o app e a limpeza usam JPEG/PNG). Outro tipo, erro."""
    if content_type in ("image/jpeg", "image/png"):
        return data, content_type
    if content_type == "image/webp":
        from PIL import Image

        try:
            image = Image.open(io.BytesIO(data)).convert("RGB")
        except Exception as error:
            raise ValueError("WebP invalido") from error
        out = io.BytesIO()
        image.save(out, format="JPEG", quality=90, optimize=True)
        return out.getvalue(), "image/jpeg"
    raise ValueError(f"Tipo {content_type} nao aceito: use JPEG, PNG ou WebP")


def remove_banner(catalog, actor, edition_id, origin_url):
    """Retira o banner (pedido do organizador, erro de imagem...). A edicao ganha uma versao sem imagem.

    O arquivo no bucket e o registro da base de autorizacao ficam guardados para auditoria."""
    body = catalog._edition(edition_id)
    head = catalog.store.get(("catalog", "EDITION#" + edition_id, "HEAD"))
    if body is None or head is None:
        raise Problem(404, "EDITION_NOT_FOUND")
    if not body.get("imageReference"):
        raise ValueError("A edicao nao tem banner")
    payload = {
        k: v
        for k, v in body.items()
        if k in ImportEdition.model_fields and k not in ("imageReference", "imageCredit")
    }
    payload["archived"] = body.get("status") == "archived"
    updated = CatalogImporter(catalog).put(
        payload, expected_version=int(head["version"]), origin=origin_url, actor=actor
    )
    return {"version": updated["version"]}
