"""In-process DynamoDB wire shape: real serialization, but no proof of service behavior."""

from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError
from runpass.store import DynamoStore

TABLES = ("identity", "catalog", "history", "operations", "projections", "erasure")
MAX_TRANSACTION_ITEMS = 100


class FakeDynamoClient:
    def __init__(self):
        self.rows = {}

    @staticmethod
    def _id(table, key):
        return table, key["PK"]["S"], key["SK"]["S"]

    def get_item(self, TableName, Key, ConsistentRead):
        row = self.rows.get(self._id(TableName, Key))
        return {"Item": row} if row else {}

    def batch_get_item(self, RequestItems):
        # O papel real da Lambda nao tem BatchGetItem: qualquer uso aqui e um erro de permissao.
        raise ClientError(
            {"Error": {"Code": "AccessDeniedException", "Message": "no BatchGetItem"}},
            "BatchGetItem",
        )

    def query(self, TableName, ExpressionAttributeValues, Limit, ExclusiveStartKey=None, **_):
        values = ExpressionAttributeValues
        pk = values[":pk"]["S"]
        lower = values.get(":lo", {}).get("S")
        upper = values.get(":hi", {}).get("S")
        prefix = values.get(":prefix", {}).get("S")
        after = ExclusiveStartKey["SK"]["S"] if ExclusiveStartKey else None
        rows = sorted(
            (sk, row)
            for (table, row_pk, sk), row in self.rows.items()
            if table == TableName
            and row_pk == pk
            and (after is None or sk > after)
            and (lower is None or sk >= lower)
            and (upper is None or sk <= upper)
            and (prefix is None or sk.startswith(prefix))
        )
        selected = rows[:Limit]
        result = {"Items": [row for _, row in selected]}
        if len(rows) > Limit:
            result["LastEvaluatedKey"] = {"PK": {"S": pk}, "SK": {"S": selected[-1][0]}}
        return result

    def _holds(self, row_id, spec):
        current = self.rows.get(row_id)
        if spec["ConditionExpression"] == "attribute_not_exists(PK)":
            return current is None
        return current is not None and current["_rev"] == spec["ExpressionAttributeValues"][":r"]

    def transact_write_items(self, TransactItems):
        if len(TransactItems) > MAX_TRANSACTION_ITEMS:
            raise ValueError("Transaction exceeds the service limit")
        planned = []
        for action in TransactItems:
            ((kind, spec),) = action.items()
            key = spec.get("Key") or {"PK": spec["Item"]["PK"], "SK": spec["Item"]["SK"]}
            planned.append((kind, spec, self._id(spec["TableName"], key)))
        if len({row_id for _, _, row_id in planned}) != len(planned):
            raise ValueError("Transaction cannot touch the same item twice")
        if not all(self._holds(row_id, spec) for _, spec, row_id in planned):
            raise ClientError(
                {
                    "Error": {"Code": "TransactionCanceledException", "Message": "conflict"},
                    "CancellationReasons": [{"Code": "ConditionalCheckFailed"}],
                },
                "TransactWriteItems",
            )
        for kind, spec, row_id in planned:
            if kind == "Put":
                self.rows[row_id] = spec["Item"]
            elif kind == "Delete":
                self.rows.pop(row_id, None)


class SerializingDynamoStore(DynamoStore):
    def __init__(self):
        super().__init__(FakeDynamoClient(), {name: name for name in TABLES})

    @property
    def items(self):
        decode = TypeDeserializer().deserialize
        return {
            row_id: {k: decode(v) for k, v in row.items() if k not in ("PK", "SK")}
            for row_id, row in self.client.rows.items()
        }
