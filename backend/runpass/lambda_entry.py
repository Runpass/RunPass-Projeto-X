"""AWS Lambda handlers. Clients and secrets load on first use, never at import time."""

import json
import logging
import os
from functools import lru_cache

from boto3.dynamodb.types import TypeDeserializer

from .aws_adapters import S3AuditSink, S3BlobStore
from .composition import (
    AwsSettings,
    create_aws_app,
    create_erasure_processor,
    create_event_processor,
)
from .service import Problem
from .store import DynamoStore, Unavailable

logger = logging.getLogger("runpass")
logger.setLevel(logging.INFO)

EVENT_PARTITION_PREFIX = "WORK#event#pending#"


def _boto_client(service, **kwargs):
    import boto3

    return boto3.client(service, **kwargs)


def _s3_client():
    from botocore.config import Config

    # Presigned URLs must use SigV4 and the regional endpoint to work outside us-east-1.
    return _boto_client(
        "s3", config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"})
    )


def _secret(ssm, env_name):
    return ssm.get_parameter(Name=os.environ[env_name], WithDecryption=True)["Parameter"][
        "Value"
    ].encode()


@lru_cache(maxsize=2)
def _settings(with_cursor_key=False):
    ssm = _boto_client("ssm")
    return AwsSettings(
        runner_issuer=os.environ["RUNPASS_RUNNER_ISSUER"],
        runner_client_id=os.environ["RUNPASS_RUNNER_CLIENT_ID"],
        environment=os.environ["RUNPASS_ENV"],
        region=os.environ["AWS_REGION"],
        identity_table=os.environ["RUNPASS_IDENTITY_TABLE"],
        operations_table=os.environ["RUNPASS_OPERATIONS_TABLE"],
        erasure_table=os.environ["RUNPASS_ERASURE_TABLE"],
        erasure_hmac_key=_secret(ssm, "RUNPASS_ERASURE_HMAC_PARAM"),
        catalog_table=os.environ["RUNPASS_CATALOG_TABLE"],
        cursor_encryption_key=(
            _secret(ssm, "RUNPASS_CURSOR_KEY_PARAM") if with_cursor_key else None
        ),
        history_table=os.environ["RUNPASS_HISTORY_TABLE"],
        projections_table=os.environ["RUNPASS_PROJECTIONS_TABLE"],
        runner_user_pool_id=os.environ["RUNPASS_RUNNER_USER_POOL_ID"],
    )


@lru_cache(maxsize=1)
def _api():
    from mangum import Mangum

    app = create_aws_app(
        _settings(with_cursor_key=True),
        _boto_client("dynamodb"),
        _boto_client("cognito-idp"),
        S3BlobStore(_s3_client(), os.environ["RUNPASS_MEDAL_BUCKET"]),
    )
    return Mangum(app, lifespan="off")


@lru_cache(maxsize=1)
def _events():
    return create_event_processor(
        _settings(), _boto_client("dynamodb"), _s3_client(), os.environ["RUNPASS_AUDIT_BUCKET"]
    )


@lru_cache(maxsize=1)
def _erasure():
    s3 = _s3_client()
    return create_erasure_processor(
        _settings(),
        _boto_client("dynamodb"),
        _boto_client("cognito-idp"),
        S3BlobStore(s3, os.environ["RUNPASS_MEDAL_BUCKET"]),
        os.environ["RUNPASS_RUNNER_USER_POOL_ID"],
        S3AuditSink(s3, os.environ["RUNPASS_AUDIT_BUCKET"], os.environ["RUNPASS_ENV"]),
    )


@lru_cache(maxsize=1)
def _sqs():
    return _boto_client("sqs")


@lru_cache(maxsize=1)
def _publisher_store():
    # The publisher only reads the dispatch epoch, so it receives no secrets.
    return DynamoStore(
        _boto_client("dynamodb"), {"operations": os.environ["RUNPASS_OPERATIONS_TABLE"]}
    )


def api_handler(event, context):
    return _api()(event, context)


def consume(processor, consumer, event):
    """Only retryable failures return to SQS; durable markers let the reconciler recover the rest."""
    failures = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            processor.deliver(body["owner"], body["eventId"], consumer, body["dispatchEpoch"])
        except (KeyError, ValueError):
            logger.error("discarded malformed message consumer=%s", consumer)
        except Problem as error:
            logger.warning("delivery refused consumer=%s code=%s", consumer, error.code)
            if error.status >= 500:
                failures.append({"itemIdentifier": record["messageId"]})
        except Unavailable:
            logger.warning("dependency unavailable consumer=%s", consumer)
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


def consumer_handler(event, context):
    return consume(_events(), os.environ["RUNPASS_CONSUMER"], event)


def publish(store, sqs, queue_urls, event):
    """Stream records only wake the publisher; a marker that fails stays with the reconciler."""
    deserializer = TypeDeserializer()
    failures = []
    for record in event.get("Records", []):
        try:
            image = {
                key: deserializer.deserialize(value)
                for key, value in record["dynamodb"].get("NewImage", {}).items()
            }
            if not image.get("PK", "").startswith(EVENT_PARTITION_PREFIX):
                continue
            owner, event_id = image["owner"], image["eventId"]
            current = store.get(("operations", "USER#" + owner, "EVENT#" + event_id))
            if not current:
                continue
            body = json.dumps(
                {
                    "owner": owner,
                    "eventId": event_id,
                    "dispatchEpoch": int(current["dispatchEpoch"]),
                }
            )
            for queue_url in queue_urls:
                sqs.send_message(QueueUrl=queue_url, MessageBody=body)
        except Exception:  # noqa: BLE001 -- never log record content; the reconciler recovers it.
            logger.exception("publish failed")
            failures.append({"itemIdentifier": record["dynamodb"]["SequenceNumber"]})
            break
    return {"batchItemFailures": failures}


def publisher_handler(event, context):
    return publish(
        _publisher_store(),
        _sqs(),
        [os.environ["RUNPASS_SCORE_QUEUE_URL"], os.environ["RUNPASS_AUDIT_QUEUE_URL"]],
        event,
    )


def run_maintenance(events, erasure, worker_id):
    """Each task runs even if another fails; the final raise makes the error alarm fire."""
    summary, failed = {}, []
    tasks = {
        "reconcile": lambda: events.reconcile(worker_id=worker_id),
        "expire": events.expire_payloads,
        "erasure": erasure.run_pending,
    }
    for name, task in tasks.items():
        try:
            summary[name] = task()
        except Problem as error:
            if error.code != "LEASE_HELD":
                failed.append(name)
            summary[name] = {"skipped": error.code}
        except Unavailable:
            failed.append(name)
            summary[name] = {"skipped": "DEPENDENCY_UNAVAILABLE"}
    logger.info("maintenance %s", json.dumps(summary, default=str))
    if failed:
        raise RuntimeError("Maintenance failed: " + ",".join(failed))
    return summary


def maintenance_handler(event, context):
    return run_maintenance(_events(), _erasure(), context.aws_request_id)
