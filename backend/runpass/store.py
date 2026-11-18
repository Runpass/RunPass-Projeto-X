"""Optimistic transactions shared by the local harness and the DynamoDB adapter."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from threading import RLock
from typing import Protocol

from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import BotoCoreError, ClientError

Key = tuple[str, str, str]
Item = dict | None


class Conflict(Exception):
    pass


class Unavailable(Exception):
    pass


class Store(Protocol):
    def get(self, key: Key) -> Item: ...
    def commit(self, expected: dict[Key, Item], writes: dict[Key, Item]) -> None: ...
    def batch_get(self, keys) -> dict[Key, Item]: ...
    def query(self, table, pk, *, lower=None, upper=None, prefix=None, after=None, limit=20): ...


def iter_partition(store, table, pk, page_size=100):
    """Every row of one partition; callers must not treat a single page as the whole partition."""
    after = None
    while True:
        rows, after = store.query(table, pk, after=after, limit=page_size)
        yield from rows
        if after is None:
            return


class MemoryStore:
    """Local, single-process adapter. Its lock is not evidence of DynamoDB concurrency."""

    def __init__(self):
        self.items = {}
        self.lock = RLock()

    def get(self, key):
        with self.lock:
            return deepcopy(self.items.get(key))

    def batch_get(self, keys):
        return {key: self.get(key) for key in keys}

    def commit(self, expected, writes):
        with self.lock:
            if not writes.keys() <= expected.keys():
                raise ValueError("Write without expected version")
            if any(self.items.get(k) != v for k, v in expected.items()):
                raise Conflict()
            for key, value in writes.items():
                if key not in expected:
                    raise ValueError("Write without expected version")
                if value is None:
                    self.items.pop(key, None)
                else:
                    value = deepcopy(value)
                    value["_rev"] = (expected[key] or {}).get("_rev", 0) + 1
                    self.items[key] = value

    def query(self, table, pk, *, lower=None, upper=None, prefix=None, after=None, limit=20):
        """Local query equivalent, scoped to one partition; used by catalog tests."""
        with self.lock:
            rows = sorted(
                (sk, item) for (t, p, sk), item in self.items.items() if t == table and p == pk
            )
            eligible = [
                (sk, item)
                for sk, item in rows
                if (after is None or sk > after)
                and (lower is None or sk >= lower)
                and (upper is None or sk <= upper)
                and (prefix is None or sk.startswith(prefix))
            ]
            selected = eligible[:limit]
            cursor = selected[-1][0] if selected and len(eligible) > len(selected) else None
            return [(sk, deepcopy(item)) for sk, item in selected], cursor


class DynamoStore:
    """Explicit low-level boto3 client; no SDK session or credentials discovered here."""

    def __init__(self, client, tables):
        self.client, self.tables = client, tables
        self.encoder, self.decoder = TypeSerializer(), TypeDeserializer()

    def encode(self, item):
        return {k: self.encoder.serialize(v) for k, v in item.items()}

    def get(self, key):
        table, pk, sk = key
        try:
            result = self.client.get_item(
                TableName=self.tables[table],
                Key=self.encode({"PK": pk, "SK": sk}),
                ConsistentRead=True,
            ).get("Item")
        except (ClientError, BotoCoreError) as error:
            raise Unavailable() from error
        if not result:
            return None
        return {k: self.decoder.deserialize(v) for k, v in result.items() if k not in ("PK", "SK")}

    def batch_get(self, keys):
        """Varias leituras consistentes ao mesmo tempo (GetItem em paralelo). Nao usa BatchGetItem: o papel da
        Lambda so tem GetItem/Query (privilegio minimo). Chave de tabela nao configurada volta como ausente.
        Devolve {chave: item ou None}."""
        keys = list(dict.fromkeys(keys))
        result = {key: None for key in keys}
        wanted = [key for key in keys if key[0] in self.tables]
        if not wanted:
            return result
        if len(wanted) == 1:
            result[wanted[0]] = self.get(wanted[0])
            return result
        with ThreadPoolExecutor(max_workers=min(16, len(wanted))) as pool:
            for key, item in zip(wanted, pool.map(self.get, wanted)):
                result[key] = item
        return result

    def commit(self, expected, writes):
        if not writes.keys() <= expected.keys() or len(expected) > 100:
            raise ValueError("Invalid transaction")
        actions = []
        for key, previous in expected.items():
            table, pk, sk = key
            args = {"TableName": self.tables[table], "Key": self.encode({"PK": pk, "SK": sk})}
            if previous is None:
                args["ConditionExpression"] = "attribute_not_exists(PK)"
            else:
                args.update(
                    ConditionExpression="#r = :r",
                    ExpressionAttributeNames={"#r": "_rev"},
                    ExpressionAttributeValues=self.encode({":r": previous["_rev"]}),
                )
            if key not in writes:
                action = "ConditionCheck"
            elif writes[key] is None:
                action = "Delete"
            else:
                action = "Put"
                args.pop("Key")
                args["Item"] = self.encode(
                    {**writes[key], "PK": pk, "SK": sk, "_rev": (previous or {}).get("_rev", 0) + 1}
                )
            actions.append({action: args})
        try:
            self.client.transact_write_items(TransactItems=actions)
        except BotoCoreError as error:
            raise Unavailable() from error
        except ClientError as error:
            code = error.response["Error"]["Code"]
            reasons = error.response.get("CancellationReasons", [])
            if code == "TransactionCanceledException" and any(
                r.get("Code") in ("ConditionalCheckFailed", "TransactionConflict") for r in reasons
            ):
                raise Conflict() from error
            raise Unavailable() from error

    def query(self, table, pk, *, lower=None, upper=None, prefix=None, after=None, limit=20):
        values = {":pk": pk}
        expression = "PK = :pk"
        if prefix is not None:
            expression += " AND begins_with(SK, :prefix)"
            values[":prefix"] = prefix
        elif lower is not None and upper is not None:
            expression += " AND SK BETWEEN :lo AND :hi"
            values.update({":lo": lower, ":hi": upper})
        elif lower is not None:
            expression += " AND SK >= :lo"
            values[":lo"] = lower
        elif upper is not None:
            expression += " AND SK <= :hi"
            values[":hi"] = upper
        args = {
            "TableName": self.tables[table],
            "KeyConditionExpression": expression,
            "ExpressionAttributeValues": self.encode(values),
            "ConsistentRead": True,
            "Limit": limit,
            "ScanIndexForward": True,
        }
        if after is not None:
            args["ExclusiveStartKey"] = self.encode({"PK": pk, "SK": after})
        try:
            result = self.client.query(**args)
        except (ClientError, BotoCoreError) as error:
            raise Unavailable() from error
        rows = []
        for raw in result.get("Items", []):
            item = {k: self.decoder.deserialize(v) for k, v in raw.items()}
            sk = item.pop("SK")
            item.pop("PK")
            rows.append((sk, item))
        cursor = result.get("LastEvaluatedKey", {}).get("SK", {}).get("S")
        return rows, cursor
