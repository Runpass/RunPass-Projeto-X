"""S3 and Cognito adapters with injected clients; Stubber tests do not prove real AWS behavior."""

import hashlib
import json

from botocore.exceptions import BotoCoreError, ClientError

from .service import Problem
from .store import Unavailable

UPLOAD_URL_SECONDS = 15 * 60
VIEW_URL_SECONDS = 5 * 60
DELETE_BATCH = 1000


def _code(error):
    return error.response["Error"]["Code"]


def _delete_versions(client, bucket, prefix):
    """Versioned buckets keep bytes after DeleteObject, so every version and marker is removed."""
    removed = 0
    paginator = client.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        batch = [
            {"Key": row["Key"], "VersionId": row["VersionId"]}
            for field in ("Versions", "DeleteMarkers")
            for row in page.get(field, [])
        ]
        for start in range(0, len(batch), DELETE_BATCH):
            chunk = batch[start : start + DELETE_BATCH]
            result = client.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
            if result.get("Errors"):
                raise Unavailable()
            removed += len(chunk)
    return removed


class S3BlobStore:
    """Private versioned photos, prefixed by owner so account erasure can enumerate them."""

    def __init__(self, client, bucket):
        self.client, self.bucket = client, bucket

    @staticmethod
    def _source(owner, upload_id):
        return f"temporary/{owner}/{upload_id}"

    @staticmethod
    def _derived(owner, reference):
        return f"derived/{owner}/{reference}"

    def issue(self, upload_id, content_type, owner):
        try:
            url = self.client.generate_presigned_url(
                "put_object",
                Params={
                    "Bucket": self.bucket,
                    "Key": self._source(owner, upload_id),
                    "ContentType": content_type,
                },
                ExpiresIn=UPLOAD_URL_SECONDS,
                HttpMethod="PUT",
            )
        except (BotoCoreError, ClientError) as error:
            raise Unavailable() from error
        return {
            "uploadUrl": url,
            "uploadMethod": "PUT",
            "uploadHeaders": {"Content-Type": content_type},
        }

    def head(self, upload_id, owner):
        try:
            row = self.client.head_object(Bucket=self.bucket, Key=self._source(owner, upload_id))
        except ClientError as error:
            if _code(error) in ("404", "NoSuchKey", "NotFound"):
                raise Problem(409, "OBJECT_NOT_UPLOADED") from error
            raise Unavailable() from error
        except BotoCoreError as error:
            raise Unavailable() from error
        return {
            "version": row["VersionId"],
            "size": row["ContentLength"],
            "contentType": row["ContentType"],
        }

    def read(self, upload_id, version, owner):
        try:
            row = self.client.get_object(
                Bucket=self.bucket, Key=self._source(owner, upload_id), VersionId=version
            )
            return row["Body"].read()
        except ClientError as error:
            if _code(error) in ("NoSuchKey", "NoSuchVersion", "404"):
                raise Problem(503, "SOURCE_VERSION_UNAVAILABLE") from error
            raise Unavailable() from error
        except BotoCoreError as error:
            raise Unavailable() from error

    def write_derived(self, reference, data, content_type, owner):
        try:
            self.client.put_object(
                Bucket=self.bucket,
                Key=self._derived(owner, reference),
                Body=data,
                ContentType=content_type,
            )
        except (BotoCoreError, ClientError) as error:
            raise Unavailable() from error

    def view_url(self, owner, reference):
        """Short-lived signed GET for the sanitized copy only; originals stay unreachable."""
        key = self._derived(owner, reference)
        try:
            head = self.client.head_object(Bucket=self.bucket, Key=key)
            url = self.client.generate_presigned_url(
                "get_object",
                Params={"Bucket": self.bucket, "Key": key},
                ExpiresIn=VIEW_URL_SECONDS,
                HttpMethod="GET",
            )
        except ClientError as error:
            if _code(error) in ("404", "NoSuchKey", "NotFound"):
                raise Problem(404, "IMAGE_NOT_AVAILABLE") from error
            raise Unavailable() from error
        except BotoCoreError as error:
            raise Unavailable() from error
        return {"url": url, "contentType": head["ContentType"]}

    def delete_owner(self, owner):
        try:
            return sum(
                _delete_versions(self.client, self.bucket, f"{prefix}/{owner}/")
                for prefix in ("temporary", "derived")
            )
        except (BotoCoreError, ClientError) as error:
            raise Unavailable() from error


class S3AuditSink:
    """One object per event; the key holds no personal data, so a locator row finds it."""

    def __init__(self, client, bucket, environment):
        self.client, self.bucket, self.environment = client, bucket, environment

    def key_for(self, event_id, occurred_at):
        return f"{self.environment}/{occurred_at[:10]}/{event_id}.json"

    def put(self, event_id, occurred_at, payload):
        key = self.key_for(event_id, occurred_at)
        body = json.dumps(payload, sort_keys=True, ensure_ascii=False, default=str).encode()
        digest = hashlib.sha256(body).hexdigest()
        try:
            self.client.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=body,
                ContentType="application/json",
                Metadata={"sha256": digest},
                IfNoneMatch="*",
            )
        except ClientError as error:
            if _code(error) not in ("PreconditionFailed", "412"):
                raise Unavailable() from error
            self._require_same_content(key, digest)
        except BotoCoreError as error:
            raise Unavailable() from error
        return key

    def _require_same_content(self, key, digest):
        try:
            row = self.client.head_object(Bucket=self.bucket, Key=key)
        except (BotoCoreError, ClientError) as error:
            raise Unavailable() from error
        if row.get("Metadata", {}).get("sha256") != digest:
            raise Problem(409, "AUDIT_COLLISION")

    def delete(self, key):
        try:
            return _delete_versions(self.client, self.bucket, key)
        except (BotoCoreError, ClientError) as error:
            raise Unavailable() from error


class CognitoAccountRemover:
    def __init__(self, client, user_pool_id):
        self.client, self.user_pool_id = client, user_pool_id

    def delete_owner(self, owner):
        try:
            self.client.admin_delete_user(UserPoolId=self.user_pool_id, Username=owner)
        except ClientError as error:
            if _code(error) != "UserNotFoundException":
                raise Unavailable() from error
        except BotoCoreError as error:
            raise Unavailable() from error
