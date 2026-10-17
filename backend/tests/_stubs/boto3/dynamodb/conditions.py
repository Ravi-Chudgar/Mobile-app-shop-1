"""Minimal stand-in for boto3.dynamodb.conditions.

Supports `.eq` (query filters) plus `.exists()` / `.not_exists()` and `&`
conjunctions for conditional writes — just enough for the attendance
repository's immutability checks.
"""


class _Cond:
    def __init__(self, name, value=None, op="eq"):
        self.name = name
        self.value = value
        self.op = op

    def matches(self, item):
        if self.op == "eq":
            return item.get(self.name) == self.value
        if self.op == "exists":
            return self.name in item
        # not_exists
        return self.name not in item

    def __and__(self, other):
        return _And(self, other)


class _And:
    def __init__(self, left, right):
        self.left = left
        self.right = right

    def matches(self, item):
        return self.left.matches(item) and self.right.matches(item)


class _Ref:
    def __init__(self, name):
        self.name = name

    def eq(self, value):
        return _Cond(self.name, value, "eq")

    def exists(self):
        return _Cond(self.name, op="exists")

    def not_exists(self):
        return _Cond(self.name, op="not_exists")


def Attr(name):  # noqa: N802 (match boto3 API)
    return _Ref(name)


def Key(name):  # noqa: N802
    return _Ref(name)
