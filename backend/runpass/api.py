"""Identity and catalog HTTP surface. Dependencies must be injected; default app fails closed."""

from datetime import date
from decimal import Decimal
from typing import Annotated
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from .catalog import CatalogFilters
from .identity import AuthFailure
from .models import (
    CompleteParticipation,
    CreateParticipation,
    CreateProfile,
    Eligibility,
    PatchParticipation,
    PatchProfile,
    ReplaceReview,
    StartUpload,
)
from .service import Problem
from .store import Unavailable

IdempotencyKey = Annotated[
    str,
    Header(alias="Idempotency-Key", min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"),
]


def create_app(service=None, verifier=None, catalog=None, participations=None, uploads=None):
    # Runtime schema is a subset; the versioned full contract remains the canonical OpenAPI.
    app = FastAPI(
        title="RunPass S03", version="0.8.0", docs_url=None, redoc_url=None, openapi_url=None
    )

    @app.exception_handler(Problem)
    async def problem(request, error):
        return JSONResponse(
            status_code=error.status,
            content={"code": error.code, "message": error.code, "correlationId": str(uuid4())},
        )

    @app.exception_handler(AuthFailure)
    async def unauthorized(request, error):
        return JSONResponse(
            status_code=401,
            content={
                "code": "INVALID_TOKEN",
                "message": "Authentication required",
                "correlationId": str(uuid4()),
            },
            headers={"WWW-Authenticate": "Bearer"},
        )

    @app.exception_handler(Unavailable)
    async def unavailable(request, error):
        return JSONResponse(
            status_code=503,
            content={
                "code": "DEPENDENCY_UNAVAILABLE",
                "message": "Try again later",
                "correlationId": str(uuid4()),
            },
        )

    @app.exception_handler(RequestValidationError)
    async def invalid(request, error):
        # Default FastAPI errors include submitted input, possibly a private birth date/token.
        return JSONResponse(
            status_code=422,
            content={
                "code": "INVALID_INPUT",
                "message": "Check required fields and limits",
                "correlationId": str(uuid4()),
            },
        )

    def principal(request: Request):
        if service is None or verifier is None:
            raise Unavailable()
        auth = request.headers.get("Authorization", "")
        scheme, _, token = auth.partition(" ")
        if scheme.lower() != "bearer" or not token or len(token) > 16384:
            raise AuthFailure()
        return verifier(token)

    Actor = Annotated[object, Depends(principal)]

    @app.put("/me", status_code=201, operation_id="createOwnProfile")
    def create_profile(body: CreateProfile, actor: Actor, idempotency_key: IdempotencyKey):
        return service.create_profile(actor, idempotency_key, body.model_dump())

    @app.get("/me", operation_id="getOwnProfile")
    def profile(actor: Actor):
        return service.profile(actor)

    @app.patch("/me", operation_id="patchOwnProfile")
    def patch_profile(body: PatchProfile, actor: Actor, idempotency_key: IdempotencyKey):
        return service.patch_profile(actor, idempotency_key, body.model_dump(exclude_unset=True))

    @app.delete("/me", status_code=202, operation_id="deleteOwnAccount")
    def delete_profile(actor: Actor, idempotency_key: IdempotencyKey):
        return service.delete_account(actor, idempotency_key)

    @app.get("/beta/status", operation_id="getMyBetaStatus")
    def status(actor: Actor):
        return service.status(actor)

    @app.post("/beta/admissions", status_code=201, operation_id="admitToBeta")
    def admit(body: Eligibility, actor: Actor, idempotency_key: IdempotencyKey):
        return service.admit(actor, idempotency_key, body.model_dump(mode="json"))

    @app.post("/beta/waitlist", status_code=201, operation_id="joinBetaWaitlist")
    def join_waitlist(body: Eligibility, actor: Actor, idempotency_key: IdempotencyKey):
        return service.admit(actor, idempotency_key, body.model_dump(mode="json"), waitlist=True)

    @app.get("/me/waitlist", operation_id="getMyWaitlistEntry")
    def waitlist(actor: Actor):
        return service.waitlist(actor)

    @app.delete("/me/waitlist", status_code=204, operation_id="removeMyWaitlistEntry")
    def remove_waitlist(actor: Actor, idempotency_key: IdempotencyKey):
        service.remove_waitlist(actor, idempotency_key)
        return Response(status_code=204)

    @app.get("/editions", operation_id="listEditions")
    def editions(
        actor: Actor,
        limit: int = Query(20, ge=1, le=100),
        cursor: str | None = Query(None, min_length=1, max_length=8192),
        namePrefix: str | None = Query(None, min_length=1, max_length=160),
        city: str | None = Query(None, min_length=1, max_length=100),
        state: str | None = Query(None, pattern=r"^[A-Za-z]{2}$"),
        dateFrom: date | None = None,
        dateTo: date | None = None,
        distanceKm: Decimal | None = Query(None, gt=0),
    ):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        try:
            filters = CatalogFilters(
                limit=limit,
                namePrefix=namePrefix,
                city=city,
                state=state,
                dateFrom=dateFrom,
                dateTo=dateTo,
                distanceKm=distanceKm,
            )
        except ValidationError as error:
            raise Problem(422, "INVALID_FILTERS") from error
        return catalog.list(actor, filters, cursor)

    @app.get("/editions/{id}", operation_id="getEdition")
    def edition(id: str, actor: Actor):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        return catalog.detail(actor, id)

    @app.post("/participations", status_code=201, operation_id="createParticipationDraft")
    def create_participation(
        body: CreateParticipation, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if participations is None:
            raise Unavailable()
        return participations.create(actor, idempotency_key, body.model_dump(exclude_none=True))

    @app.get("/participations/{id}", operation_id="getParticipation")
    def get_participation(id: str, actor: Actor):
        if participations is None:
            raise Unavailable()
        return participations.get(actor, id)

    @app.patch("/participations/{id}", operation_id="patchParticipation")
    def patch_participation(
        id: str, body: PatchParticipation, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if participations is None:
            raise Unavailable()
        return participations.patch(actor, id, idempotency_key, body.model_dump(exclude_unset=True))

    @app.delete("/participations/{id}", status_code=202, operation_id="deleteParticipation")
    def delete_participation(
        id: str,
        actor: Actor,
        idempotency_key: IdempotencyKey,
        expectedVersion: int = Query(..., ge=1),
    ):
        if participations is None:
            raise Unavailable()
        return participations.delete(actor, id, idempotency_key, expectedVersion)

    @app.get("/deletion-operations/{id}", operation_id="getDeletionOperation")
    def get_deletion_operation(id: str, actor: Actor):
        if participations is None:
            raise Unavailable()
        return participations.get_deletion(actor, id)

    @app.get("/me/participations", operation_id="listMyParticipations")
    def list_participations(
        actor: Actor,
        state: str | None = Query(None, pattern=r"^(draft|completed)$"),
        limit: int = Query(20, ge=1, le=100),
        cursor: str | None = Query(None, min_length=1, max_length=8192),
    ):
        if participations is None:
            raise Unavailable()
        return participations.list(actor, state, limit, cursor)

    @app.post("/participations/{id}/complete", operation_id="completeParticipation")
    def complete_participation(
        id: str,
        body: CompleteParticipation,
        actor: Actor,
        idempotency_key: IdempotencyKey,
    ):
        if participations is None:
            raise Unavailable()
        return participations.complete(actor, id, idempotency_key, body.model_dump())

    @app.get("/participations/{id}/review", operation_id="getParticipationReview")
    def get_participation_review(id: str, actor: Actor):
        if participations is None:
            raise Unavailable()
        return participations.get_review(actor, id)

    @app.put("/participations/{id}/review", operation_id="replaceParticipationReview")
    def replace_participation_review(
        id: str, body: ReplaceReview, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if participations is None:
            raise Unavailable()
        return participations.replace_review(
            actor, id, idempotency_key, body.model_dump(exclude_unset=True)
        )

    @app.post("/uploads", status_code=201, operation_id="startUpload")
    def start_upload(body: StartUpload, actor: Actor, idempotency_key: IdempotencyKey):
        if uploads is None:
            raise Unavailable()
        return uploads.start(actor, idempotency_key, body.model_dump())

    @app.post("/uploads/{id}/finalize", operation_id="finalizeUpload")
    def finalize_upload(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        if uploads is None:
            raise Unavailable()
        return uploads.finalize(actor, id, idempotency_key)

    @app.get("/participations/{id}/image", operation_id="getParticipationImage")
    def participation_image(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.medal_image(actor, id)

    @app.get("/uploads/{id}/status", operation_id="getUploadStatus")
    def upload_status(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.get(actor, id)

    return app


app = create_app()
