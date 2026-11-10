"""API do portal de administracao: SO operadores, separada da API dos corredores.

Autenticacao: o navegador faz o login direto no Cognito (senha e TOTP nunca passam por esta API) e envia o
token de acesso. Esta API aceita apenas tokens do pool de operadores e so opera quando:
- o pool de operadores tem MFA obrigatorio e nao lembra dispositivos (conferido, em cache curto): assim todo
  token novo so existe depois do segundo fator;
- o `auth_time` do token e recente (ate 1 hora): um refresh antigo nao vale;
- o acesso do operador (`OPERATOR#sub/ACCESS`) esta ativo e traz a permissao da rota.
Se qualquer condicao falhar, a API recusa. Ao passar, grava o mesmo registro de sessao MFA que a ferramenta de
terminal grava, para os servicos de revisao e de catalogo (que exigem esse registro) funcionarem sem mudanca.
"""

import hashlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated
from uuid import uuid4

import jwt
from fastapi import Depends, FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field

from .catalog import normalized
from .edition_requests import EditionRequestReview
from .identity import AuthFailure
from .models import ReviewRequestDecision
from .service import Problem
from .store import Conflict, Unavailable

MAX_AUTH_AGE = 3600
MFA_CHECK_TTL = 300

# Arquivos da pagina servidos pela propria API (lista fechada: nenhum caminho vira nome de arquivo).
SITE_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/lib.js": ("lib.js", "text/javascript; charset=utf-8"),
    "/cognito.js": ("cognito.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}


def security_headers(region):
    """Cabecalhos de toda resposta: scripts e estilos so do proprio site; conexoes so ao Cognito e a si."""
    return {
        "Content-Security-Policy": (
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            f"connect-src 'self' https://cognito-idp.{region}.amazonaws.com; "
            "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        ),
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
    }


def find_portal_dir():
    """No pacote da Lambda a pasta `portal/` fica ao lado de `runpass/`; no repositorio, na raiz."""
    aqui = Path(__file__).resolve()
    for base in (aqui.parents[1], aqui.parents[2]):
        if (base / "portal" / "index.html").exists():
            return base / "portal"
    return None


class MfaPolicy:
    """Atesta, pela configuracao do pool, que todo token de operador so existe depois do MFA."""

    def __init__(self, client, pool_id, clock=time.time):
        self.client, self.pool_id, self.clock = client, pool_id, clock
        self._checked_at, self._ok = 0.0, False

    def enforced(self):
        now = self.clock()
        if now - self._checked_at < MFA_CHECK_TTL:
            return self._ok
        pool = self.client.describe_user_pool(UserPoolId=self.pool_id)["UserPool"]
        self._ok = pool.get("MfaConfiguration") == "ON" and not pool.get("DeviceConfiguration")
        self._checked_at = now
        return self._ok


def admit_operator(store, principal, token, mfa_enforced, clock=time.time):
    """Valida o operador e garante o registro de sessao MFA. Devolve o registro ACCESS."""
    if principal.audience != "operator" or not mfa_enforced():
        raise AuthFailure()
    claims = jwt.decode(
        token, options={"verify_signature": False}
    )  # token ja verificado pelo verificador
    now = int(clock())
    auth_time = claims.get("auth_time")
    if not isinstance(auth_time, int) or now - auth_time > MAX_AUTH_AGE or auth_time > now + 60:
        raise AuthFailure()
    access_key = ("identity", "OPERATOR#" + principal.subject, "ACCESS")
    access = store.get(access_key)
    if not access or access.get("state") != "active":
        raise AuthFailure()
    session_key = (
        "operations",
        "OPERATOR#" + principal.subject,
        "SESSION#" + hashlib.sha256(token.encode()).hexdigest(),
    )
    old = store.get(session_key)
    session = {
        "factor": "SOFTWARE_TOKEN_MFA",
        "accessVersion": access["_rev"],
        "issuer": claims["iss"],
        "clientId": claims["client_id"],
        "verifiedAt": now,
        "expiresAt": min(claims["exp"], auth_time + MAX_AUTH_AGE),
        "via": "portal",
    }
    if session["expiresAt"] <= now:
        raise AuthFailure()
    if (
        not old
        or old.get("accessVersion") != access["_rev"]
        or old["expiresAt"] != session["expiresAt"]
    ):
        try:
            store.commit({access_key: access, session_key: old}, {session_key: session})
        except Conflict as error:
            raise Unavailable() from error
    return access


def search_editions(catalog, text, limit=20):
    """Busca por nome (contem) no catalogo, para escolher a corrida a vincular. Sem filtros de corredor."""
    words = normalized(text)
    rows, after, found, seen, evaluated = [], None, [], set(), 0
    while len(found) < limit and evaluated < 600:
        page, after = catalog.store.query("catalog", "CAT#GLOBAL#ANY#DATE", after=after, limit=100)
        for _, row in page:
            evaluated += 1
            body = catalog._edition(row["editionId"], row["version"])
            if body is None or body["id"] in seen or body.get("status") == "archived":
                continue
            if words and words not in normalized(body["name"]):
                continue
            seen.add(body["id"])
            found.append({k: body[k] for k in ("id", "name", "date", "city", "state") if k in body})
            if len(found) >= limit:
                break
        if after is None:
            break
    del rows
    found.sort(key=lambda e: e["date"], reverse=True)
    return found


def create_admin_app(
    store,
    catalog,
    verifier,
    mfa_policy,
    portal_origin,
    clock=time.time,
    site=None,
    users=None,
    runner=None,
):
    """`site` = dict(directory=Path, region=str, client_id=str) para servir a pagina pela propria API."""
    app = FastAPI(
        title="RunPass Admin", version="0.1.0", docs_url=None, redoc_url=None, openapi_url=None
    )
    if portal_origin:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=[portal_origin],
            allow_methods=["GET", "POST", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type"],
            max_age=600,
        )
    headers_seguranca = security_headers((site or {}).get("region", "sa-east-1"))

    @app.middleware("http")
    async def seguranca(request, call_next):
        resposta = await call_next(request)
        for chave, valor in headers_seguranca.items():
            resposta.headers.setdefault(chave, valor)
        return resposta

    if site:

        def rota_do_arquivo(caminho):
            nome, tipo = SITE_FILES[caminho]

            # Funcao sem parametros: o FastAPI nao pode expor nada disto como parametro de consulta.
            def servir():
                return Response((Path(site["directory"]) / nome).read_bytes(), media_type=tipo)

            return servir

        for caminho in SITE_FILES:
            app.add_api_route(
                caminho, rota_do_arquivo(caminho), methods=["GET"], include_in_schema=False
            )

        @app.get("/config.js", include_in_schema=False)
        def config_js():
            # So valores publicos: regiao e client id do pool. A API e a pagina compartilham a origem.
            config = {"region": site["region"], "clientId": site["client_id"], "apiUrl": ""}
            return Response(
                f"export default {json.dumps(config)};", media_type="text/javascript; charset=utf-8"
            )

    review = EditionRequestReview(
        catalog, clock=lambda: datetime.fromtimestamp(clock(), timezone.utc)
    )

    def body(status, code, headers=None):
        return JSONResponse(
            status_code=status,
            content={"code": code, "message": code, "correlationId": str(uuid4())},
            headers=headers,
        )

    @app.exception_handler(Problem)
    async def problem(request, error):
        return body(error.status, error.code)

    @app.exception_handler(AuthFailure)
    async def unauthorized(request, error):
        return body(401, "INVALID_TOKEN", {"WWW-Authenticate": "Bearer"})

    @app.exception_handler(Unavailable)
    async def unavailable(request, error):
        return body(503, "DEPENDENCY_UNAVAILABLE")

    @app.exception_handler(RequestValidationError)
    async def invalid(request, error):
        return body(422, "INVALID_INPUT")

    def operator(request: Request):
        scheme, _, token = request.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "bearer" or not token or len(token) > 16384:
            raise AuthFailure()
        principal = verifier(token)
        access = admit_operator(store, principal, token, mfa_policy.enforced, clock)
        return principal, access

    Operator = Annotated[tuple, Depends(operator)]

    def need(op, permission):
        principal, access = op
        if permission not in access.get("permissions", []):
            raise Problem(403, "PERMISSION_REQUIRED")
        return principal

    @app.get("/admin/session")
    def session(op: Operator):
        principal, access = op
        return {"subject": principal.subject, "permissions": access.get("permissions", [])}

    @app.get("/admin/edition-requests")
    def pending(op: Operator, limit: int = Query(50, ge=1, le=100)):
        actor = need(op, "catalog_admin")
        items, _ = review.pending(actor, limit)
        return {"items": items}

    @app.post("/admin/edition-requests/{request_id}/decision")
    def decide(request_id: str, decision: ReviewRequestDecision, op: Operator):
        actor = need(op, "catalog_admin")
        return review.decide(actor, request_id, decision)

    @app.get("/admin/editions")
    def editions(
        op: Operator, q: str = Query("", max_length=160), limit: int = Query(20, ge=1, le=50)
    ):
        need(op, "catalog_admin")
        return {"items": search_editions(catalog, q, limit)}

    class NewOperator(BaseModel):
        model_config = ConfigDict(extra="forbid")
        email: str = Field(max_length=320)
        permissions: list[str] = Field(min_length=1, max_length=8)

    class CatalogRun(BaseModel):
        model_config = ConfigDict(extra="forbid")
        mode: str = Field(max_length=20)

    @app.get("/admin/users/runners")
    def runners(op: Operator, limit: int = Query(200, ge=1, le=500)):
        actor = need(op, "user_admin").subject
        if users is None:
            raise Unavailable()
        return users.registered_runners(actor, limit)

    @app.post("/admin/operators", status_code=201)
    def create_operator(payload: NewOperator, op: Operator):
        actor = need(op, "user_admin").subject
        if users is None:
            raise Unavailable()
        return users.create_operator(actor, payload.email, payload.permissions)

    @app.get("/admin/catalog/run")
    def last_run(op: Operator):
        need(op, "catalog_admin")
        if runner is None:
            raise Unavailable()
        return runner.last()

    @app.get("/admin/catalog/runs")
    def runs(op: Operator):
        need(op, "catalog_admin")
        if runner is None:
            raise Unavailable()
        return runner.runs()

    @app.post("/admin/catalog/run", status_code=202)
    def start_run(payload: CatalogRun, op: Operator):
        actor = need(op, "catalog_admin").subject
        if runner is None:
            raise Unavailable()
        return runner.start(actor, payload.mode)

    return app
