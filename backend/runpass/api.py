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
    CreateComment,
    CreateParticipation,
    CreateProfile,
    EditionRequestFields,
    Eligibility,
    PatchEditionRequest,
    PatchParticipation,
    PatchProfile,
    PutRacePlan,
    ReplaceReview,
    ResubmitEditionRequest,
    StartUpload,
)
from .nl_search import MAX_PHRASE, text_fallback
from .service import Problem
from .store import Unavailable

IdempotencyKey = Annotated[
    str,
    Header(alias="Idempotency-Key", min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"),
]


def create_app(
    service=None,
    verifier=None,
    catalog=None,
    participations=None,
    uploads=None,
    social=None,
    natural_search=None,
    edition_requests=None,
):
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
        q: str | None = Query(None, min_length=1, max_length=160),
        registrationStatus: str | None = Query(None, pattern=r"^(unknown|open|closed|sold_out)$"),
        lat: float | None = Query(None, ge=-90, le=90),
        lon: float | None = Query(None, ge=-180, le=180),
        radiusKm: float | None = Query(None, gt=0, le=500),
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
                q=q,
                registrationStatus=registrationStatus,
                lat=lat,
                lon=lon,
                radiusKm=radiusKm,
            )
        except ValidationError as error:
            raise Problem(422, "INVALID_FILTERS") from error
        return catalog.list(actor, filters, cursor)

    @app.get("/editions/search", operation_id="searchEditions")
    def search_editions(
        actor: Actor,
        phrase: str = Query(..., min_length=1, max_length=MAX_PHRASE),
        limit: int = Query(20, ge=1, le=100),
        lat: float | None = Query(None, ge=-90, le=90),
        lon: float | None = Query(None, ge=-180, le=180),
    ):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        phrase = " ".join(phrase.split())
        if not phrase or (lat is None) != (lon is None):
            raise Problem(422, "INVALID_FILTERS")
        translation = (
            natural_search.translate(phrase, lat, lon) if natural_search else text_fallback(phrase)
        )
        echoed = {}
        if translation.empty:
            page = {"items": []}
        else:
            try:
                filters = CatalogFilters(limit=limit, **translation.filters)
            except ValidationError:
                # Filtro vindo da IA fora dos limites do catalogo: busca por nome, nunca erro.
                translation = text_fallback(phrase)
                filters = CatalogFilters(limit=limit, **translation.filters)
            page = catalog.list(actor, filters)
            # O cliente pagina depois por GET /editions com estes filtros e o mesmo limit.
            echoed = filters.model_dump(mode="json", exclude_none=True, exclude={"limit"})
        return {
            **page,
            "search": {
                "source": translation.source,
                "filters": echoed,
                "applied": list(translation.applied),
                "notApplied": list(translation.not_applied),
            },
        }

    @app.get("/editions/{id}", operation_id="getEdition")
    def edition(id: str, actor: Actor):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        return catalog.detail(actor, id)

    @app.get("/editions/{id}/reviews", operation_id="listEditionReviews")
    def edition_reviews(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=100),
        cursor: str | None = Query(None, min_length=1, max_length=512),
        distanceId: str | None = Query(None, min_length=1, max_length=100),
    ):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        catalog.detail(actor, id)  # 404 para edicao inexistente
        return friends().edition_reviews(actor, id, distanceId, limit, cursor)

    @app.get("/me/race-plans", operation_id="listMyRacePlans")
    def list_my_race_plans(
        actor: Actor, status: str | None = Query(None, pattern="^(wanted|registered)$")
    ):
        if participations is None:
            raise Unavailable()
        return participations.list_plans(actor, status)

    @app.put("/me/race-plans/{editionId}", operation_id="putMyRacePlan")
    def put_my_race_plan(editionId: str, body: PutRacePlan, actor: Actor):
        if participations is None:
            raise Unavailable()
        return participations.put_plan(actor, editionId, body.status, body.distanceId)

    @app.get("/me/race-plans/{editionId}", operation_id="getMyRacePlan")
    def get_my_race_plan(editionId: str, actor: Actor):
        if participations is None:
            raise Unavailable()
        return participations.get_plan(actor, editionId)

    @app.delete("/me/race-plans/{editionId}", status_code=204, operation_id="deleteMyRacePlan")
    def delete_my_race_plan(editionId: str, actor: Actor):
        if participations is None:
            raise Unavailable()
        participations.delete_plan(actor, editionId)
        return Response(status_code=204)

    @app.get("/editions/{id}/banner", operation_id="getEditionBanner")
    def edition_banner(id: str, actor: Actor):
        service.authorize(actor, admitted=True)
        if catalog is None or uploads is None:
            raise Unavailable()
        return uploads.edition_banner(actor, catalog.detail(actor, id))

    @app.get("/editions/{id}/participants", operation_id="listEditionParticipants")
    def edition_participants(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=100),
        cursor: str | None = Query(None, min_length=1, max_length=512),
        distanceId: str | None = Query(None, min_length=1, max_length=100),
    ):
        service.authorize(actor, admitted=True)
        if catalog is None:
            raise Unavailable()
        catalog.detail(actor, id)  # 404 para edicao inexistente
        return friends().edition_participants(actor, id, distanceId, limit, cursor)

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

    @app.post("/edition-requests", status_code=201, operation_id="createEditionRequest")
    def create_edition_request(
        body: EditionRequestFields, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if edition_requests is None:
            raise Unavailable()
        return edition_requests.create(actor, idempotency_key, body)

    @app.get("/me/edition-requests", operation_id="listMyEditionRequests")
    def list_my_edition_requests(
        actor: Actor,
        limit: int = Query(20, ge=1, le=100),
        cursor: str | None = Query(None, min_length=1, max_length=8192),
    ):
        if edition_requests is None:
            raise Unavailable()
        return edition_requests.list_mine(actor, limit, cursor)

    @app.get("/edition-requests/{id}", operation_id="getEditionRequest")
    def get_edition_request(id: str, actor: Actor):
        if edition_requests is None:
            raise Unavailable()
        return edition_requests.get(actor, id)

    @app.patch("/edition-requests/{id}", operation_id="patchEditionRequest")
    def patch_edition_request(
        id: str, body: PatchEditionRequest, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if edition_requests is None:
            raise Unavailable()
        return edition_requests.patch(
            actor, id, idempotency_key, body.model_dump(exclude_unset=True, mode="python")
        )

    @app.post("/edition-requests/{id}/resubmit", operation_id="resubmitEditionRequest")
    def resubmit_edition_request(
        id: str, body: ResubmitEditionRequest, actor: Actor, idempotency_key: IdempotencyKey
    ):
        if edition_requests is None:
            raise Unavailable()
        return edition_requests.resubmit(actor, id, idempotency_key, body.model_dump())

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

    def friends():
        if social is None:
            raise Unavailable()
        return social

    @app.get("/profiles", operation_id="searchProfiles")
    def search_profiles(
        actor: Actor,
        q: str = Query(..., min_length=1, max_length=80),
        limit: int = Query(20, ge=1, le=50),
    ):
        return friends().search(actor, q, limit)

    @app.get("/profiles/suggestions", operation_id="listProfileSuggestions")
    def profile_suggestions(actor: Actor, limit: int = Query(12, ge=1, le=30)):
        return friends().suggestions(actor, limit)

    @app.get("/profiles/{id}", operation_id="getPublicProfile")
    def public_profile(id: str, actor: Actor):
        return friends().profile_view(actor, id)

    @app.get("/profiles/{id}/participations", operation_id="listPublicParticipations")
    def public_participations(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
    ):
        return friends().public_participations(actor, id, limit, cursor)

    @app.get("/profiles/{id}/followers", operation_id="listProfileFollowers")
    def profile_followers(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
    ):
        return friends().list_followers(actor, id, limit, cursor)

    @app.get("/profiles/{id}/following", operation_id="listProfileFollowing")
    def profile_following(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
    ):
        return friends().list_following(actor, id, limit, cursor)

    @app.get("/profiles/{id}/friends", operation_id="listProfileFriends")
    def profile_friends(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
    ):
        return friends().list_friends(actor, id, limit, cursor)

    @app.put("/profiles/{id}/follow", operation_id="putFollow")
    def put_follow(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().follow(actor, id, idempotency_key)

    @app.delete("/profiles/{id}/follow", operation_id="deleteFollow")
    def delete_follow(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().unfollow(actor, id, idempotency_key)

    @app.put("/profiles/{id}/friend", operation_id="putFriendRequest")
    def put_friend(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().add_friend(actor, id, idempotency_key)

    @app.delete("/profiles/{id}/friend", operation_id="deleteFriend")
    def delete_friend(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().remove_friend(actor, id, idempotency_key)

    @app.get("/me/friend-requests", operation_id="listMyFriendRequests")
    def friend_requests(actor: Actor):
        return friends().friend_requests(actor)

    @app.put("/me/friend-requests/{id}", operation_id="approveFriendRequest")
    def approve_friend_request(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().decide_friend(actor, id, True, idempotency_key)

    @app.delete("/me/friend-requests/{id}", operation_id="declineFriendRequest")
    def decline_friend_request(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().decide_friend(actor, id, False, idempotency_key)

    @app.get("/feed", operation_id="getFeed")
    def get_feed(
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
        scope: str = Query("all", pattern="^(all|friends|network)$"),
    ):
        return friends().feed(actor, limit, cursor, scope)

    @app.get("/posts/{id}", operation_id="getPost")
    def get_post(id: str, actor: Actor):
        return friends().post(actor, id)

    @app.put("/posts/{id}/like", operation_id="likePost")
    def put_like(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().like(actor, id, idempotency_key, True)

    @app.delete("/posts/{id}/like", operation_id="unlikePost")
    def delete_like(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().like(actor, id, idempotency_key, False)

    @app.get("/me/notifications", operation_id="listMyNotifications")
    def list_notifications(actor: Actor):
        return friends().notifications(actor)

    @app.delete("/me/notifications/{id}", operation_id="deleteMyNotification")
    def delete_notification(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().dismiss_notification(actor, id, idempotency_key)

    @app.post("/me/notifications/read", operation_id="markMyNotificationsRead")
    def read_notifications(actor: Actor, idempotency_key: IdempotencyKey):
        return friends().mark_notifications_read(actor, idempotency_key)

    @app.get("/posts/{id}/comments", operation_id="listPostComments")
    def list_comments(
        id: str,
        actor: Actor,
        limit: int = Query(20, ge=1, le=50),
        cursor: str | None = Query(None, min_length=1, max_length=512),
    ):
        return friends().comments(actor, id, limit, cursor)

    @app.post("/posts/{id}/comments", status_code=201, operation_id="createPostComment")
    def create_comment(id: str, body: CreateComment, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().comment(actor, id, idempotency_key, body.text, body.parentId)

    @app.put("/comments/{id}/like", operation_id="likeComment")
    def put_comment_like(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().like_comment(actor, id, idempotency_key, True)

    @app.delete("/comments/{id}/like", operation_id="unlikeComment")
    def delete_comment_like(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().like_comment(actor, id, idempotency_key, False)

    @app.delete("/comments/{id}", operation_id="deleteOwnComment")
    def delete_comment(id: str, actor: Actor, idempotency_key: IdempotencyKey):
        return friends().delete_comment(actor, id, idempotency_key)

    @app.get("/profiles/{id}/photo", operation_id="getProfilePhoto")
    def profile_photo(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.profile_photo(actor, id)

    @app.get("/profiles/{id}/banner", operation_id="getProfileBanner")
    def profile_banner(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.profile_photo(actor, id, "bannerReference")

    @app.get("/participations/{id}/image", operation_id="getParticipationImage")
    def participation_image(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.medal_image(actor, id)

    @app.get("/participations/{id}/display-image", operation_id="getParticipationDisplayImage")
    def participation_display_image(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.medal_display_image(actor, id)

    @app.get("/uploads/{id}/status", operation_id="getUploadStatus")
    def upload_status(id: str, actor: Actor):
        if uploads is None:
            raise Unavailable()
        return uploads.get(actor, id)

    return app


app = create_app()
