"""Offline-first sync endpoints (staff/owner JWT).

POST /sync/batch
    Replays the mutation queue a client built up while offline. Every op is
    applied idempotently: the client's `op_id` (a uuid) is stored on the
    created order as `client_op_id`, so replaying the same op returns the
    ORIGINAL result with status "deduped" instead of creating a second
    order. One bad op never fails the batch — each op gets its own entry in
    `results` (occupied table, unknown type, bad payload ...).

GET /sync/pull?since=<ISO-8601>
    What a client that just came back online needs: orders created or
    updated at or after `since` (fallback: the order_date for legacy rows
    without timestamps), plus a FULL snapshot of menu, tables and inventory.
    A full snapshot is acceptable for the MVP: those sets are small in a
    cafe, and a delta protocol would cost far more than it saves.
"""
import logging
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify, g

from ..auth import staff_required
from ..aws import orders_table
from ..config import Config
from ..repositories import orders as orders_repo
from ..repositories import menu as menu_repo
from ..repositories import tables as tables_repo
from ..repositories import inventory as inventory_repo
from ..services import printing as printing_service
from ..util import ApiError, plain

logger = logging.getLogger(__name__)

bp = Blueprint("sync", __name__, url_prefix="/sync")

# Op types this endpoint knows how to replay. Anything else -> per-op error.
HANDLED_TYPES = ("order_create",)

# Collect/payment happens online only: a queued op may never carry these,
# so a replayed offline order always lands unpaid, exactly like a fresh one.
ONLINE_ONLY_FIELDS = ("payments", "payment_token", "redeem_points", "paid")


def _utcnow():
    return datetime.now(timezone.utc)


def _parse_since(raw):
    """ISO-8601 (or YYYY-MM-DD) -> aware datetime. Missing -> epoch."""
    if not raw:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    text = str(raw).strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    if "T" not in text and " " not in text:
        text += "T00:00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        raise ApiError("'since' must be an ISO-8601 timestamp", 400)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _timestamp(value):
    """ISO string -> aware datetime, or None when absent/unparseable."""
    if not value:
        return None
    text = str(value)
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _orders_since(since_dt):
    """Orders created or updated at/after [since_dt].

    Uses created_at/updated_at; legacy rows without either fall back to a
    string compare on order_date (the order_date index date of `since`).
    """
    cutoff_date = since_dt.strftime("%Y-%m-%d")
    out = []
    for raw in orders_table().scan().get("Items", []):
        order = plain(raw)
        stamps = [t for t in (_timestamp(order.get("created_at")),
                              _timestamp(order.get("updated_at"))) if t]
        if stamps:
            if max(stamps) >= since_dt:
                out.append(order)
        elif order.get("order_date") and str(order["order_date"]) >= cutoff_date:
            out.append(order)
    out.sort(key=lambda o: (o.get("created_at") or "", o.get("id") or ""))
    return out


# --------------------------------------------------------------------------- #
# POST /sync/batch
# --------------------------------------------------------------------------- #

def _error_entry(op_id, message):
    return {"op_id": op_id, "status": "error", "error": message}


def _apply_order_create(op, op_id):
    """Create one order from a queued op. Raises ApiError for per-op errors."""
    payload = op.get("payload")
    if not isinstance(payload, dict):
        raise ApiError("'payload' must be an object for order_create")
    # Never let a replayed op carry collect/payment fields (online-only).
    payload = {k: v for k, v in payload.items()
               if k not in ONLINE_ONLY_FIELDS}

    source = str(payload.get("source") or "counter")
    if source == "qr":
        # Mirror the public QR contract (routes/public.py): a QR order links
        # to an occupied table without stealing the lock, and needs a real
        # table + customer to track against.
        table_number = str(payload.get("table_number") or "").strip()
        if not table_number:
            raise ApiError("table_number is required")
        table = tables_repo.get(table_number)
        if not table:
            raise ApiError("Table not found", 404)
        customer = payload.get("customer") or {}
        if not str(customer.get("name") or "").strip():
            raise ApiError("customer.name is required")
        if not str(customer.get("phone") or "").strip():
            raise ApiError("customer.phone is required")
        order = orders_repo.create(
            {**payload, "table_number": table_number},
            taken_by="qr",
            occupy_table=table.get("status") != "occupied",
            client_op_id=op_id,
        )
    else:
        # Staff/owner order: identical rules to POST /orders (including the
        # 409 "table already occupied" refusal).
        order = orders_repo.create(
            payload, taken_by=g.user.get("sub"), client_op_id=op_id)
    # Same side effect as a normal order create (no-op unless auto-print is on).
    printing_service.maybe_auto_print_kot(order)
    return {"op_id": op_id, "status": "applied", "order_id": order["id"]}


def _apply(op, seen):
    """Apply one op -> one result entry. Never raises for a bad op."""
    if not isinstance(op, dict):
        return _error_entry(None, "Each op must be an object")

    op_id = op.get("op_id")
    if not isinstance(op_id, str) or not op_id.strip():
        return _error_entry(None, "op_id (client uuid) is required")
    op_id = op_id.strip()

    op_type = op.get("type")
    if op_type not in HANDLED_TYPES:
        return _error_entry(op_id, f"Unsupported op type '{op_type}'")

    # Duplicate of an op already applied in THIS batch.
    # Both dedupe branches below return BEFORE _apply_order_create, which is
    # where the auto-KOT side effect lives — a replayed op therefore never
    # prints a second kitchen ticket (exactly-once per client_op_id).
    if op_id in seen:
        entry = dict(seen[op_id])
        entry["status"] = "deduped"
        entry["deduped"] = True
        return entry

    # Replay of an op applied in an earlier batch: return the original result.
    if op_type == "order_create":
        existing = orders_repo.find_by_client_op_id(op_id)
        if existing:
            entry = {"op_id": op_id, "status": "deduped",
                     "order_id": existing.get("id"), "deduped": True}
            seen[op_id] = entry
            return dict(entry)

    try:
        result = _apply_order_create(op, op_id)
    except ApiError as e:
        # Occupied table (409), unknown menu item, bad payload ... per-op.
        return _error_entry(op_id, e.message)
    except Exception as e:  # one op must never 500 the whole batch
        logger.exception("sync: op %s (%s) failed", op_id, op_type)
        return _error_entry(op_id, f"Could not apply op: {e}")

    seen[op_id] = result
    return dict(result)


@bp.post("/batch")
@staff_required
def batch():
    body = request.get_json(silent=True) or {}
    ops = body.get("ops")
    if not isinstance(ops, list):
        raise ApiError("'ops' must be a list of offline operations")
    if len(ops) > Config.SYNC_MAX_BATCH:
        raise ApiError(
            f"Batch too large: {len(ops)} ops "
            f"(max {Config.SYNC_MAX_BATCH} per request)", 400)

    results = []
    seen = {}  # op_id -> result, for duplicates inside this batch
    for op in ops:
        results.append(_apply(op, seen))
    return jsonify({"results": results,
                    "server_time": _utcnow().isoformat()})


# --------------------------------------------------------------------------- #
# GET /sync/pull
# --------------------------------------------------------------------------- #

@bp.get("/pull")
@staff_required
def pull():
    since_dt = _parse_since(request.args.get("since"))
    return jsonify({
        "server_time": _utcnow().isoformat(),
        "orders": _orders_since(since_dt),
        # Full snapshots for the MVP (see the module docstring).
        "menu": menu_repo.list_items(),
        "tables": tables_repo.list_all(),
        "inventory": [plain(i) for i in inventory_repo.list_all()],
    })
