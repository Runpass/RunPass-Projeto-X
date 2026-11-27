"""One-time backfill: write the missing FEED#PUBLIC pointer (and its FEEDREF# erasure
reference) for participations that were already completed and published to the feed
*before* the global "Todos" feed pointer existed (see social.py:_public_feed and
participation.py:complete, which only write this pointer going forward from the deploy
that introduced it).

Idempotent: writes are conditioned on the pointer not already existing, so running this
again is a no-op for rows already backfilled. Does not touch any other data.

Usage (one off, against an already-authenticated boto3 session/profile):
    AWS_PROFILE=... python backend/scripts/backfill_public_feed.py <history-table-name>
"""

import sys

import boto3
from boto3.dynamodb.types import TypeSerializer

serializer = TypeSerializer()


def encode(item):
    return {k: serializer.serialize(v) for k, v in item.items()}


def backfill(ddb, table):
    created, skipped, scanned = 0, 0, 0
    last_key = None
    while True:
        kwargs = {"TableName": table, "Limit": 200}
        if last_key:
            kwargs["ExclusiveStartKey"] = last_key
        page = ddb.scan(**kwargs)
        for item in page.get("Items", []):
            sk = item.get("SK", {}).get("S", "")
            pk = item.get("PK", {}).get("S", "")
            if not (pk.startswith("USER#") and sk.endswith("#PART")):
                continue
            scanned += 1
            if item.get("state", {}).get("S") != "completed":
                continue
            if not item.get("publishToFeed", {}).get("BOOL"):
                continue
            owner = pk[len("USER#") :]
            participation_id = item["id"]["S"]
            completed_at = item["completedAt"]["S"]
            feed_sk = f"T#{completed_at}#{participation_id}"
            feed_pk = "FEED#PUBLIC"
            feedref_sk = "FEEDREF#" + participation_id
            try:
                ddb.put_item(
                    TableName=table,
                    Item=encode(
                        {
                            "PK": feed_pk,
                            "SK": feed_sk,
                            "owner": owner,
                            "id": participation_id,
                            "completedAt": completed_at,
                            "_rev": 1,
                        }
                    ),
                    ConditionExpression="attribute_not_exists(PK)",
                )
                ddb.put_item(
                    TableName=table,
                    Item=encode(
                        {
                            "PK": pk,
                            "SK": feedref_sk,
                            "sharedKeys": [["history", feed_pk, feed_sk]],
                            "_rev": 1,
                        }
                    ),
                    ConditionExpression="attribute_not_exists(PK)",
                )
                created += 1
                print(f"  criado: owner={owner} id={participation_id} completedAt={completed_at}")
            except ddb.exceptions.ConditionalCheckFailedException:
                skipped += 1
                print(f"  ja existia: owner={owner} id={participation_id}")
        last_key = page.get("LastEvaluatedKey")
        if not last_key:
            break
    print(
        f"\nParticipacoes publicadas varridas: {scanned}; novos ponteiros: {created}; ja existiam: {skipped}"
    )


def main():
    table = sys.argv[1]
    ddb = boto3.client("dynamodb")
    backfill(ddb, table)


if __name__ == "__main__":
    main()
