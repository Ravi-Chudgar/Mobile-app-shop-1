"""Minimal in-memory boto3 stand-in: just enough of DynamoDB + S3 for the
offline smoke test. NOT for production — the real boto3 is used at runtime."""
import io

from botocore.exceptions import ClientError

_STORE = {"tables": {}, "buckets": {}}


def _reset():
    _STORE["tables"].clear()
    _STORE["buckets"].clear()


# --------------------------- DynamoDB (resource) --------------------------- #

class _Table:
    def __init__(self, name):
        self.name = name

    def _t(self):
        return _STORE["tables"][self.name]

    def _pk(self, item):
        return item[self._t()["hash_key"]]

    def put_item(self, Item, ConditionExpression=None, **kw):
        # Mirrors DynamoDB: the condition is evaluated against the STORED
        # item (an empty view when no item exists yet), and a failure raises
        # ConditionalCheckFailedException without writing anything.
        pk = self._pk(Item)
        if ConditionExpression is not None:
            current = self._t()["items"].get(pk)
            if not ConditionExpression.matches(current or {}):
                raise ClientError("ConditionalCheckFailedException",
                                  "condition did not hold")
        self._t()["items"][pk] = dict(Item)
        return {}

    def get_item(self, Key):
        pk = list(Key.values())[0]
        item = self._t()["items"].get(pk)
        return {"Item": dict(item)} if item is not None else {}

    def delete_item(self, Key):
        pk = list(Key.values())[0]
        self._t()["items"].pop(pk, None)
        return {}

    def scan(self, FilterExpression=None, **kw):
        items = list(self._t()["items"].values())
        if FilterExpression is not None:
            items = [i for i in items if FilterExpression.matches(i)]
        return {"Items": [dict(i) for i in items]}

    def query(self, IndexName=None, KeyConditionExpression=None, **kw):
        items = list(self._t()["items"].values())
        if KeyConditionExpression is not None:
            items = [i for i in items if KeyConditionExpression.matches(i)]
        return {"Items": [dict(i) for i in items]}


class _DynamoResource:
    def Table(self, name):  # noqa: N802
        return _Table(name)


# --------------------------- DynamoDB (client) ----------------------------- #

class _Waiter:
    def wait(self, **kw):
        return None


class _DynamoClient:
    def describe_table(self, TableName):
        if TableName not in _STORE["tables"]:
            raise ClientError("ResourceNotFoundException", "no such table")
        return {"Table": {"TableName": TableName}}

    def create_table(self, TableName, KeySchema, AttributeDefinitions,
                     GlobalSecondaryIndexes=None, **kw):
        hash_key = next(k["AttributeName"] for k in KeySchema if k["KeyType"] == "HASH")
        _STORE["tables"][TableName] = {"hash_key": hash_key, "items": {}}
        return {}

    def get_waiter(self, name):
        return _Waiter()


# ------------------------------- S3 client --------------------------------- #

class _S3Client:
    def head_bucket(self, Bucket):
        if Bucket not in _STORE["buckets"]:
            raise ClientError("404", "no bucket")
        return {}

    def create_bucket(self, Bucket, **kw):
        _STORE["buckets"].setdefault(Bucket, {})
        return {}

    def upload_fileobj(self, fileobj, Bucket, Key, ExtraArgs=None):
        data = fileobj.read() if hasattr(fileobj, "read") else fileobj
        _STORE["buckets"].setdefault(Bucket, {})[Key] = data
        return {}

    def generate_presigned_url(self, op, Params=None, ExpiresIn=None):
        Params = Params or {}
        return f"https://s3.local/{Params.get('Bucket')}/{Params.get('Key')}"

    def list_objects_v2(self, Bucket, **kw):
        objs = _STORE["buckets"].get(Bucket, {})
        return {"Contents": [{"Key": k} for k in objs]}


# ------------------------------- factory ----------------------------------- #

def resource(name, **kw):
    if name == "dynamodb":
        return _DynamoResource()
    raise ValueError(f"stub has no resource '{name}'")


def client(name, **kw):
    if name == "dynamodb":
        return _DynamoClient()
    if name == "s3":
        return _S3Client()
    raise ValueError(f"stub has no client '{name}'")
