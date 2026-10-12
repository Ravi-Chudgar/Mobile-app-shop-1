"""Loyalty points: phone-keyed accounts + an append-only ledger + Redis cache.

Account item (key = normalized phone):
    {"phone": "9876543210", "points": 120, "updated_at": iso,
     "ledger": [{"ts": iso, "delta": 9, "reason": "earned ABC123",
                 "order_id": "ABC123"}, ...]}

The ledger lives on the account and is append-only: entries are never
mutated or removed, so every balance change stays auditable. Balances can
never go negative.

Phone numbers are normalized to digits (an Indian +91 / 0 prefix is
stripped when it leaves a 10-digit number) so "+91 98765 43210" and
"9876543210" address the same account.
"""
import re
from datetime import datetime, timezone

from botocore.exceptions import ClientError

from .. import aws
from ..cache import cache_get, cache_set, cache_exists
from ..util import plain, ApiError

# Physical table names already ensured (one per tenant — the loyalty table
# is tenant-scoped like every other table, see app/tenancy.py).
_table_ready = set()


def _now():
    return datetime.now(timezone.utc).isoformat()


def normalize_phone(phone):
    """Digits-only phone key; strips a leading +91/0 when it fits 10 digits."""
    digits = re.sub(r"\D", "", str(phone or ""))
    if len(digits) == 12 and digits.startswith("91"):
        digits = digits[2:]
    elif len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]
    return digits


def _table():
    """Loyalty table for the CURRENT tenant, created lazily on first use.

    infra.ensure_infra() predates Phase 3, so this repository creates its own
    table (idempotently) instead of depending on an edit to infra.py. The
    table name is resolved through aws.py, so each tenant gets its own
    ({slug}_loyalty_accounts) and the creation is tracked per name.
    """
    name = aws.loyalty_table_name()
    if name not in _table_ready:
        client = aws.dynamodb_client()
        try:
            client.describe_table(TableName=name)
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceNotFoundException":
                raise
            client.create_table(
                TableName=name,
                BillingMode="PAY_PER_REQUEST",
                KeySchema=[{"AttributeName": "phone", "KeyType": "HASH"}],
                AttributeDefinitions=[
                    {"AttributeName": "phone", "AttributeType": "S"}],
            )
            client.get_waiter("table_exists").wait(TableName=name)
        _table_ready.add(name)
    return aws.loyalty_table()


def get(phone):
    """Account dict (with ledger) or None when the phone is unknown."""
    cache_key = f"loyalty:account:{phone}"
    cached = cache_get(cache_key)
    if cached is not None:
        return plain(json.loads(cached)) if cached else None
    key = normalize_phone(phone)
    if not key:
        return None
    resp = _table().get_item(Key={"phone": key})
    result = plain(resp["Item"]) if "Item" in resp else None
    cache_set(cache_key, json.dumps(result) if result else None, ttl=300)
    return result


def balance(phone):
    """Current points for a phone (0 when there is no account yet)."""
    cache_key = f"loyalty:balance:{phone}"
    cached = cache_get(cache_key)
    if cached is not None:
        return int(cached)
    account = get(phone)
    points = int(account.get("points", 0)) if account else 0
    cache_set(cache_key, str(points), ttl=300)
    return points


def _empty(phone):
    return {"phone": normalize_phone(phone), "points": 0,
            "updated_at": _now(), "ledger": []}


def adjust(phone, delta, reason, order_id=None):
    """Add/subtract points in one write. Returns the updated account.

    Raises ApiError(400) for a bad delta/reason or when it would take the
    balance below zero. This is the single write path for every ledger
    entry (earn, redeem, manual owner adjustment).
    """
    try:
        delta = int(delta)
    except (TypeError, ValueError):
        raise ApiError("Loyalty delta must be an integer number of points")
    if delta == 0:
        raise ApiError("Loyalty delta cannot be zero")
    reason = str(reason or "").strip()
    if not reason:
        raise ApiError("A reason is required for every loyalty change")

    key = normalize_phone(phone)
    if not key:
        raise ApiError("A customer phone number is required for loyalty")

    account = get(key) or _empty(key)
    new_points = int(account.get("points", 0)) + delta
    if new_points < 0:
        raise ApiError(
            f"Only {account.get('points', 0)} points available", 400)

    account["points"] = new_points
    account["updated_at"] = _now()
    account.setdefault("ledger", []).append({
        "ts": _now(),
        "delta": delta,
        "reason": reason,
        "order_id": order_id,
    })
    _table().put_item(Item=account)
    return plain(account)


def recent_ledger(phone, limit=20):
    """Newest-first slice of the ledger for the lookup screen."""
    account = get(phone)
    if not account:
        return []
    return list(reversed(account.get("ledger") or []))[:max(1, int(limit))]
