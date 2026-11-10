"""Explicit AWS composition, called only by a separately authorized environment entry point."""

import time
from dataclasses import dataclass

from .admin_api import MfaPolicy, create_admin_app, find_portal_dir
from .admin_users import AdminUsers, CatalogRunner, CatalogSchedules
from .api import create_app
from .aws_adapters import CognitoAccountRemover, S3AuditSink
from .catalog import CatalogService
from .edition_requests import EditionRequestService
from .erasure import ErasureProcessor
from .events import EventProcessor
from .identity import CognitoDirectory, CognitoVerifier, JwksProvider
from .participation import ParticipationService
from .service import IdentityService
from .social import SocialService
from .store import DynamoStore
from .upload import UploadService


@dataclass(frozen=True)
class AwsSettings:
    runner_issuer: str
    runner_client_id: str
    environment: str
    region: str
    identity_table: str
    operations_table: str
    erasure_table: str
    erasure_hmac_key: bytes
    catalog_table: str | None = None
    cursor_encryption_key: bytes | None = None
    history_table: str | None = None
    projections_table: str | None = None
    runner_user_pool_id: str | None = None


def _identity_service(settings: AwsSettings, dynamodb_client, account_remover=None):
    store = DynamoStore(
        dynamodb_client,
        {
            "identity": settings.identity_table,
            "operations": settings.operations_table,
            "erasure": settings.erasure_table,
            **({"catalog": settings.catalog_table} if settings.catalog_table else {}),
            **({"history": settings.history_table} if settings.history_table else {}),
            **({"projections": settings.projections_table} if settings.projections_table else {}),
        },
    )
    return IdentityService(
        store,
        settings.erasure_hmac_key,
        environment=settings.environment,
        identity_namespace=settings.runner_issuer,
        account_remover=account_remover,
    )


def create_aws_app(
    settings: AwsSettings, dynamodb_client, cognito_client, blob_store=None, natural_search=None
):
    verifier = CognitoVerifier(
        settings.runner_issuer,
        settings.runner_client_id,
        JwksProvider(settings.runner_issuer, settings.region),
        CognitoDirectory(cognito_client),
    )
    # Com o pool configurado, DELETE /me libera o email/username no Cognito na hora do pedido,
    # em vez de so no proximo ciclo da manutencao (ver ErasureProcessor).
    account_remover = (
        CognitoAccountRemover(cognito_client, settings.runner_user_pool_id)
        if settings.runner_user_pool_id
        else None
    )
    service = _identity_service(settings, dynamodb_client, account_remover)
    catalog = None
    participations = None
    edition_requests = None
    if settings.catalog_table and settings.cursor_encryption_key:
        catalog = CatalogService(service, settings.cursor_encryption_key)
        if settings.history_table:
            participations = ParticipationService(service, catalog, settings.cursor_encryption_key)
            edition_requests = EditionRequestService(service, settings.cursor_encryption_key)
    social = SocialService(service) if settings.history_table else None
    uploads = None
    if blob_store is not None:
        uploads = UploadService(
            service,
            blob_store,
            may_view=social.may_view_photo if social else None,
            may_view_profile=social.may_view_profile_photo if social else None,
        )
    return create_app(
        service,
        verifier,
        catalog,
        participations,
        uploads,
        social,
        natural_search,
        edition_requests,
    )


def create_admin_aws_app(
    settings: AwsSettings,
    dynamodb_client,
    cognito_client,
    operator_issuer,
    operator_client_id,
    operator_pool_id,
    portal_origin,
    runner_pool_id="",
    lambda_client=None,
    catalog_function="",
    logs_client=None,
    scheduler_client=None,
):
    """API do portal: so tokens do pool de operadores; o MFA do pool e conferido (ver admin_api)."""
    service = _identity_service(settings, dynamodb_client)
    catalog = CatalogService(service, settings.cursor_encryption_key)
    verifier = CognitoVerifier(
        operator_issuer,
        operator_client_id,
        JwksProvider(operator_issuer, settings.region),
        CognitoDirectory(cognito_client),
        audience="operator",
    )
    portal = find_portal_dir()
    clock = time.time
    return create_admin_app(
        service.store,
        catalog,
        verifier,
        MfaPolicy(cognito_client, operator_pool_id),
        portal_origin,
        clock=clock,
        users=AdminUsers(service.store, cognito_client, runner_pool_id, operator_pool_id, clock),
        runner=CatalogRunner(service.store, lambda_client, catalog_function, clock, logs_client),
        schedules=CatalogSchedules(scheduler_client, catalog_function, clock),
        site=(
            {"directory": portal, "region": settings.region, "client_id": operator_client_id}
            if portal
            else None
        ),
    )


def create_event_processor(settings: AwsSettings, dynamodb_client, s3_client, audit_bucket):
    return EventProcessor(
        _identity_service(settings, dynamodb_client),
        S3AuditSink(s3_client, audit_bucket, settings.environment),
    )


def create_erasure_processor(
    settings: AwsSettings, dynamodb_client, cognito_client, blob_store, user_pool_id, audit_sink
):
    return ErasureProcessor(
        _identity_service(settings, dynamodb_client),
        blob_store,
        external=(CognitoAccountRemover(cognito_client, user_pool_id),),
        audit=audit_sink,
    )
