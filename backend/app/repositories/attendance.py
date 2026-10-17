"""Staff attendance: clock in / clock out — one immutable record per day.

The "a recorded clock-in can never be changed" rule is enforced HERE with
DynamoDB conditional writes, not by convention:

* one record per staff member, per cafe, per business day (PK
  ``{username}#{YYYY-MM-DD}`` in the tenant's own ``attendance`` table, so
  every cafe's clock data stays isolated like all other data);
* ``clock_in`` is written with ``attribute_not_exists(id)``: a second tap —
  even two simultaneous ones on different server workers — can never
  overwrite or duplicate the start time;
* ``clock_out`` is written with ``attribute_exists(id) AND
  attribute_not_exists(clock_out)``: once set it can never change either;
* routes/attendance.py exposes no PUT/PATCH/DELETE, so there is no code path
  that could alter a stored stamp even in principle.

Every timestamp is stored twice: the UTC instant (machine truth) and the
local ``HH:MM`` in the cafe's business timezone (Config.BUSINESS_TZ), which
also decides the business day the record belongs to.
"""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

from ..aws import attendance_table
from ..config import Config
from ..util import plain, ApiError

_CONDITION_FAILED = "ConditionalCheckFailedException"


def _tz():
    try:
        return ZoneInfo(Config.BUSINESS_TZ)
    except Exception:  # unknown timezone / missing tzdata -> UTC beats crashing
        return timezone.utc


def _local_now():
    return datetime.now(timezone.utc).astimezone(_tz())


def _date_key(local):
    return local.strftime("%Y-%m-%d")


def _record_id(username, date_key):
    return f"{username}#{date_key}"


def _public(record):
    """Response shape: optional fields always present, status derived."""
    if not record:
        return None
    rec = dict(record)
    rec.setdefault("clock_out", None)
    rec.setdefault("clock_out_local", None)
    rec["status"] = "out" if rec.get("clock_out") else "in"
    return rec


def _raw_today(username):
    """Today's stored record for `username` in the current cafe (or None)."""
    key = _record_id(username, _date_key(_local_now()))
    resp = attendance_table().get_item(Key={"id": key})
    return plain(resp["Item"]) if "Item" in resp else None


def get_today(username):
    """Public view of today's record (None when not clocked in yet)."""
    return _public(_raw_today(username))


def clock_in(username):
    """Start today's shift. Raises ApiError(409) when one already exists —
    a recorded clock-in is never overwritten."""
    local = _local_now()
    record = {
        "id": _record_id(username, _date_key(local)),
        "username": username,
        "date": _date_key(local),
        "clock_in": datetime.now(timezone.utc).isoformat(),
        "clock_in_local": local.strftime("%H:%M"),
    }
    try:
        attendance_table().put_item(
            Item=record, ConditionExpression=Attr("id").not_exists()
        )
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != _CONDITION_FAILED:
            raise
        existing = _raw_today(username)
        at = (existing or {}).get("clock_in_local", "earlier")
        raise ApiError(
            f"Already clocked in at {at} — a recorded clock-in cannot be "
            f"changed",
            409,
        )
    return _public(record)


def clock_out(username):
    """End today's shift: requires a clock-in (400) and can only happen once
    (409). The original clock_in value is copied through untouched."""
    raw = _raw_today(username)
    if not raw:
        raise ApiError("You haven't clocked in today", 400)
    if raw.get("clock_out"):
        at = raw.get("clock_out_local") or "earlier"
        raise ApiError(
            f"Already clocked out at {at} — a recorded clock-out cannot be "
            f"changed",
            409,
        )

    local = _local_now()
    updated = dict(raw)
    updated["clock_out"] = datetime.now(timezone.utc).isoformat()
    updated["clock_out_local"] = local.strftime("%H:%M")
    try:
        attendance_table().put_item(
            Item=updated,
            ConditionExpression=Attr("id").exists()
            & Attr("clock_out").not_exists(),
        )
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != _CONDITION_FAILED:
            raise
        # Lost a race: someone clocked out between our read and our write.
        raise ApiError("Already clocked out", 409)
    return _public(updated)
