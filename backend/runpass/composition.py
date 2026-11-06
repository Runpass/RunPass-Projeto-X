"""Explicit AWS composition, called only by a separately authorized environment entry point."""

from dataclasses import dataclass

from .api import create_app
from .aws_adapters import CognitoAccountRemover, S3AuditSink
from .catalog import CatalogService
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


def _identity_service(settings: AwsSettings, dynamodb_client):
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
    )


def create_aws_app(settings: AwsSettings, dynamodb_client, cognito_client, blob_store=None):
    verifier = CognitoVerifier(
        settings.runner_issuer,
        settings.runner_client_id,
        JwksProvider(settings.runner_issuer, settings.region),
        CognitoDirectory(cognito_client),
    )
    service = _identity_service(settings, dynamodb_client)
    catalog = None
    participations = None
    if settings.catalog_table and settings.cursor_encryption_key:
        catalog = CatalogService(service, settings.cursor_encryption_key)
        if settings.history_table:
            participations = ParticipationService(service, catalog, settings.cursor_encryption_key)
    social = SocialService(service) if settings.history_table else None
    uploads = None
    if blob_store is not None:
        uploads = UploadService(
            service,
            blob_store,
            may_view=social.may_view_photo if social else None,
            may_view_profile=social.may_view_profile_photo if social else None,
        )
    return create_app(service, verifier, catalog, participations, uploads, social)


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
