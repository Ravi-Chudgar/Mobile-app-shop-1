"""Order data access (DynamoDB) + Redis cache."""
import uuid
import logging
from datetime import datetime, timezone

from datetime import datetime, timezone
from boto3.dynamodb.conditions import Key, Attr

from ..aws import orders_table
from ..cache import cache_get, cache_set, cache_exists
from ..config import Config
from ..util import plain, ApiError
from ..pricing import price_order, order_tax_totals
from . import menu as menu_repo
from . import tables as tables_repo
from . import inventory as inventory_repo
from . import loyalty as loyalty_repo

logger = logging.getLogger(__name__)

VALID_STATUSES = ("received", "preparing", "ready", "collected", "cancelled")
NEXT_STATUS = {
    "received": "preparing",
    "preparing": "ready",
    "ready": "collected",
}
# When an order reaches one of these, its table is freed.
FREEING_STATUSES = ("collected", "cancelled")

# Payment methods accepted on a split/multi payment payload.
# "loyalty" is the points-redemption row injected at collect time (Phase 3);
# it is only ever valid together with a `redeem_points` on the payload.
PAYMENT_METHODS = ("cash", "upi", "card", "gpay", "credit", "other", "loyalty")



def normalize_payments(payments, due):
    """Validate a split-payment payload against the amount still due.

    payments: [{"method": str, "amount": <paise>, "ref": optional}]
    Returns the cleaned list, or None when the payload has no payments
    (legacy single payment_method payloads keep working unchanged).
    Raises ApiError(400) for bad methods or a sum that != due.
    """
    if payments is None:
        return None
    if not isinstance(payments, list):
        raise ApiError("'payments' must be a list of payment entries")
    if not payments:
        return None

    cleaned = []
    for entry in payments:
        if not isinstance(entry, dict):
            raise ApiError("Each payment must be an object")
        method = str(entry.get("method", "")).strip().lower()
        if method not in PAYMENT_METHODS:
            raise ApiError(
                f"Invalid payment method '{entry.get('method')}'. "
                f"Allowed: {', '.join(PAYMENT_METHODS)}")
        try:
            amount = int(entry.get("amount"))
        except (TypeError, ValueError):
            raise ApiError("Payment 'amount' must be an integer in paise")
        if amount <= 0:
            raise ApiError("Payment amounts must be positive")
        item = {"method": method, "amount": amount}
        if entry.get("ref"):
            item["ref"] = str(entry["ref"])
        cleaned.append(item)

    total_paid = sum(p["amount"] for p in cleaned)
    if total_paid != int(due):
        raise ApiError(
            f"Payments sum ({total_paid}) must equal the amount due ({int(due)})")
    return cleaned


def create(payload, taken_by=None, occupy_table=True, client_op_id=None):
    """Create an order with input validation."""
    # Validate payload structure
    if not payload or not isinstance(payload, dict):
        raise ApiError("Invalid order payload", 400)
    
    items = payload.get("items", [])
    if not items or not isinstance(items, list):
        raise ApiError("Order must contain at least one item", 400)
    
    # Validate table number if provided
    table_number = payload.get("table_number")
    if table_number is not None and not isinstance(table_number, str):
        raise ApiError("Table number must be a string", 400)
    
    # Validate source
    valid_sources = ("counter", "qr", "swiggy", "zomato")
    source = payload.get("source", "counter")
    if source not in valid_sources:
        raise ApiError(f"Invalid source. Must be one of: {', '.join(valid_sources)}", 400)
    
    # Validate payment method
    valid_payment_methods = ("cash", "upi", "card", "gpay", "credit", "other", "loyalty")
    payment_method = payload.get("payment_method", "cash")
    if payment_method not in valid_payment_methods:
        raise ApiError(f"Invalid payment method. Must be one of: {', '.join(valid_payment_methods)}", 400)
    
    lines, total = price_order(payload.get("items", []), menu_repo.get_raw)
    sub_total, tax_total = order_tax_totals(lines)

    now = datetime.now(timezone.utc)
    table_number = payload.get("table_number")
    if table_number is not None:
        table_number = str(table_number)
    order = {
        "id": uuid.uuid4().hex[:6].upper(),  # doubles as the pickup number
        "items": lines,
        "total": total,
        # Tax-inclusive: sub_total == total here, tax_total is the GST inside.
        "sub_total": sub_total,
        "tax_total": tax_total,
        "customer": {
            "name": (payload.get("customer") or {}).get("name", "Guest"),
            "phone": (payload.get("customer") or {}).get("phone"),
        },
        "pickup_type": payload.get("pickup_type", "counter"),
        "table_number": table_number,
        "taken_by": taken_by,
        # Where the order came from: "counter" (staff), "qr" (self-order),
        # "swiggy"/"zomato" (delivery partner ingestion).
        "source": payload.get("source", "counter"),
        "payment_method": payload.get("payment_method", "cash"),
        "payment_status": "unpaid",
        "paid_amount": 0,
        "status": "received",
        "notes": payload.get("notes", ""),
        "created_at": now.isoformat(),
        "order_date": now.strftime("%Y-%m-%d"),
    }
    # Offline-sync dedupe key (routes/sync.py): stored ON the order itself —
    # no marker rows, so list/scan/report results stay untouched.
    if client_op_id:
        order["client_op_id"] = str(client_op_id)
    # Refuse a table that is already locked by another order (prevents two
    # staff taking the same table) BEFORE persisting anything.
    # occupy_table=False is the QR self-order path: the order is linked to an
    # already-occupied table without taking (or stealing) the lock.
    if table_number and occupy_table:
        existing_table = tables_repo.get(table_number)
        if existing_table and existing_table.get("status") == "occupied":
            raise ApiError(f"Table {table_number} is already occupied", 409)

    orders_table().put_item(Item=order)
    # Occupy the table for this order.
    if table_number and occupy_table:
        tables_repo.occupy(table_number, order["id"], taken_by=taken_by)
    return plain(order)



def get(order_id):
    cache_key = f"order:{order_id}"
    cached = cache_get(cache_key)
    if cached is not None:
        return cached
    resp = orders_table().get_item(Key={"id": order_id})
    result = plain(resp["Item"]) if "Item" in resp else None
    cache_set(cache_key, result, ttl=300)
    return result


def find_by_client_op_id(op_id):
    """Order created by this offline client op id (sync dedupe lookup).

    The key lives on the order itself, so no marker items are written into
    the orders table and list/scan/report results are unaffected. Paginated
    scan-filter: correct on a real DynamoDB, cheap on the test stub.
    """
    if not op_id:
        return None
    kwargs = {"FilterExpression": Attr("client_op_id").eq(str(op_id))}
    while True:
        resp = orders_table().scan(**kwargs)
        items = resp.get("Items", [])
        if items:
            return plain(items[0])
        last = resp.get("LastEvaluatedKey")
        if not last:
            return None
        kwargs["ExclusiveStartKey"] = last


def _deduct_ingredients(order):
    """Auto-deduct inventory based on menu item ingredients and calculate COGS."""
    total_cogs = 0
    for line in order.get("items", []):
        menu_item = menu_repo.get_raw(line.get("item_id"))
        if not menu_item:
            continue
        ingredients = menu_item.get("ingredients", [])
        for ing in ingredients:
            inv_id = ing.get("inventory_item_id")
            qty_per_serving = ing.get("qty_per_serving", 0)
            if inv_id and qty_per_serving > 0:
                total_qty = qty_per_serving * line.get("qty", 1)
                try:
                    inv_item = inventory_repo.get(inv_id)
                    if inv_item:
                        cost_per_unit = int(inv_item.get("cost_price", 0))
                        total_cogs += cost_per_unit * total_qty
                    inventory_repo.deduct_stock(inv_id, total_qty)
                    logger.info(f"Deducted {total_qty} of inventory {inv_id} for menu item {line.get('name')}")
                except Exception as e:
                    logger.warning(f"Failed to deduct inventory {inv_id}: {e}")
    order["cogs"] = total_cogs


def _coerce_redeem_points(value):
    """Validate the `redeem_points` collect payload field (int >= 0)."""
    if value is None or value == "":
        return 0
    try:
        points = int(value)
    except (TypeError, ValueError):
        raise ApiError("'redeem_points' must be an integer number of points")
    if points < 0:
        raise ApiError("'redeem_points' cannot be negative")
    return points


def _loyalty_payment_rows(existing, due, payments, redeem_points,
                           payment_method):
    """Validate redemption and build the final split-payment row list.

    Returns (rows, points, value_paise):
      - rows: what gets handed to normalize_payments() — the client's rows
        (any `loyalty` row is stripped and recomputed) plus one loyalty row
        for `redeem_points × LOYALTY_POINT_VALUE_PAISE`.
      - points/value: the redemption to deduct (0 when not redeeming).

    When only loyalty covers the due, the remainder rides on the legacy
    single `payment_method` so the sum still equals the amount due.
    """
    points = _coerce_redeem_points(redeem_points)
    if payments is not None and not isinstance(payments, list):
        # Same message normalize_payments() would raise, raised before we
        # start iterating the payload.
        raise ApiError("'payments' must be a list of payment entries")
    if not points:
        # No redemption: a bare loyalty row is meaningless — reject it so a
        # client can't smuggle one past the redeem_points balance check.
        for row in payments or []:
            if isinstance(row, dict) and \
                    str(row.get("method", "")).strip().lower() == "loyalty":
                raise ApiError(
                    "'loyalty' payments require 'redeem_points' on the payload")
        return payments, 0, 0

    phone = (existing.get("customer") or {}).get("phone")
    if not phone:
        raise ApiError(
            "A customer phone number is required to redeem loyalty points", 400)
    available = loyalty_repo.balance(phone)
    if points > available:
        raise ApiError(f"Only {available} points available", 400)
    value = points * Config.LOYALTY_POINT_VALUE_PAISE
    if value > due:
        raise ApiError(
            f"Cannot redeem {points} points ({value} paise) against a due "
            f"amount of {due} paise", 400)

    rows = []
    for row in payments or []:
        is_loyalty = isinstance(row, dict) and \
            str(row.get("method", "")).strip().lower() == "loyalty"
        if is_loyalty:
            try:
                sent = int(row.get("amount"))
            except (TypeError, ValueError):
                raise ApiError("Payment 'amount' must be an integer in paise")
            if sent != value:
                raise ApiError(
                    f"Loyalty payment amount ({sent}) must equal "
                    f"redeem_points x point value ({value})")
        else:
            rows.append(row)
    if not rows:
        # Legacy single-method collect: the part loyalty doesn't cover stays
        # on the primary method.
        remainder = due - value
        if remainder > 0:
            primary = payment_method or existing.get("payment_method") or "cash"
            rows = [{"method": primary, "amount": remainder}]
    rows = rows + [{"method": "loyalty", "amount": value}]
    return rows, points, value


def update_status(order_id, status, confirm_payment=False, payment_method=None,
                  payment_token=None, payments=None, redeem_points=None):
    """Move an order to [status]. Collecting an order REQUIRES the staff to
    confirm payment (confirm_payment=True) — an order can't be completed
    without payment being recorded.

    `payments` is an optional split-payment payload:
        [{"method": "cash", "amount": <paise>, "ref": "..."}]
    Its sum must equal the amount still due (total - paid_amount). When it is
    absent, the legacy single `payment_method` path is used unchanged.

    Phase 3 — loyalty (only on `collected`):
      `redeem_points` (int >= 0) burns that many points for the customer's
      phone. The value is injected as a {"method": "loyalty"} payment row so
      Phase 1's sum-validation still applies. Points are deducted here and
      credited again on reopen+recollect ONLY when a new redeem_points is
      sent — reopening an order does NOT restore already-redeemed points.
      Earning: collecting an order with a customer phone credits
      floor(paid_amount in rupees x LOYALTY_EARN_RATE) points once per order
      (`loyalty_earned` guard survives a reopen/recollect).
    """
    if status not in VALID_STATUSES:
        raise ApiError(f"Invalid status '{status}'")
    existing = get(order_id)
    if not existing:
        raise ApiError("Order not found", 404)
    if status == "collected" and not confirm_payment:
        raise ApiError(
            "Payment is required before collecting this order", 400)
    existing["status"] = status
    earned_points = 0
    # Completing the order records the payment so it shows as paid in billing.
    if status == "collected":
        due = int(existing.get("total", 0)) - int(existing.get("paid_amount", 0) or 0)
        due = max(due, 0)
        rows, redeem, redeem_value = _loyalty_payment_rows(
            existing, due, payments, redeem_points, payment_method)
        clean_payments = normalize_payments(rows, due)
        existing["payment_status"] = "paid"
        existing["paid_amount"] = int(existing.get("total", 0))
        existing["paid_at"] = datetime.now(timezone.utc).isoformat()
        existing["collected_at"] = existing.get("collected_at") or \
            datetime.now(timezone.utc).isoformat()
        if clean_payments:
            # Split payment: keep the full list, primary = first method.
            existing["payments"] = list(existing.get("payments") or []) + clean_payments
            existing["payment_method"] = clean_payments[0]["method"]
        elif payment_method:
            existing["payment_method"] = payment_method
        if payment_token:
            existing["payment_token"] = payment_token
        # Burn the points now, before the order is persisted: a failed write
        # aborts the collect instead of handing out a free discount. The
        # `loyalty_redeemed` marker stops a retried collect deducting twice.
        if redeem:
            already = int(existing.get("loyalty_redeemed") or 0)
            if already != redeem:
                loyalty_repo.adjust(
                    phone=(existing.get("customer") or {}).get("phone"),
                    delta=-redeem,
                    reason=f"redeemed {order_id}",
                    order_id=order_id,
                )
            existing["loyalty_redeemed"] = redeem
        # Earn on the paid amount (rupees x earn rate, floored), once per
        # order. The flag is persisted with the order; the credit itself is
        # written after the order so a loyalty outage can't fail the sale.
        phone = (existing.get("customer") or {}).get("phone")
        if phone and not existing.get("loyalty_earned"):
            earned_points = int(
                float(existing.get("paid_amount", 0) or 0) / 100.0
                * Config.LOYALTY_EARN_RATE)
            if earned_points > 0:
                existing["loyalty_earned"] = earned_points
            else:
                earned_points = 0
        # Auto-deduct inventory based on menu item ingredients
        _deduct_ingredients(existing)
    # Any status/payment change makes the order "updated" for GET /sync/pull.
    existing["updated_at"] = datetime.now(timezone.utc).isoformat()
    orders_table().put_item(Item=existing)
    if earned_points > 0:
        try:
            loyalty_repo.adjust(
                phone=(existing.get("customer") or {}).get("phone"),
                delta=earned_points,
                reason=f"earned {order_id}",
                order_id=order_id,
            )
        except Exception as e:  # never fail a completed sale over a reward
            logger.warning(f"Failed to credit {earned_points} loyalty points "
                           f"for order {order_id}: {e}")
    # Free the table once the order is done.
    if status in FREEING_STATUSES and existing.get("table_number"):
        table = tables_repo.get(str(existing["table_number"]))
        # Only free if this order still owns the table.
        if table and table.get("order_id") == order_id:
            tables_repo.free(existing["table_number"])
    return existing



def mark_paid(order_id):
    """Owner confirms payment for a collected order."""
    existing = get(order_id)
    if not existing:
        raise ApiError("Order not found", 404)
    if existing.get("status") != "collected":
        raise ApiError("Only collected orders can be marked as paid", 409)
    existing["payment_status"] = "paid"
    existing["paid_amount"] = int(existing.get("total", 0))
    existing["paid_at"] = datetime.now(timezone.utc).isoformat()
    orders_table().put_item(Item=existing)
    return existing


def reopen(order_id, taken_by=None):
    """Reopen a collected order so the customer can add more items.

    The already-paid amount stays as credit (paid_amount is kept); the order
    goes back to 'received' and its table is locked to the staff reopening it.
    """
    existing = get(order_id)
    if not existing:
        raise ApiError("Order not found", 404)
    if existing.get("status") != "collected":
        raise ApiError("Only collected orders can be reopened", 409)
    if existing.get("table_number"):
        table = tables_repo.get(existing["table_number"])
        if table and table.get("status") == "occupied":
            raise ApiError(
                f"Table {existing['table_number']} is already in use", 409)
    existing["status"] = "received"
    existing["payment_status"] = "unpaid"  # paid_amount carries over as credit
    existing.pop("collected_at", None)
    existing.pop("paid_at", None)
    # Redeemed points are NOT restored (documented limitation) — only the
    # marker goes, so a later recollect may redeem against the new due.
    existing.pop("loyalty_redeemed", None)
    existing["updated_at"] = datetime.now(timezone.utc).isoformat()
    orders_table().put_item(Item=existing)
    # Lock the table to this staff member again.
    if existing.get("table_number"):
        tables_repo.occupy(existing["table_number"], order_id, taken_by=taken_by)
    return existing


def add_items(order_id, items):
    """Append more menu lines to an open order and bump its total."""
    existing = get(order_id)
    if not existing:
        raise ApiError("Order not found", 404)
    if existing.get("status") == "collected":
        raise ApiError("Reopen the order before adding items", 409)
    if not items:
        raise ApiError("No items to add")
    lines, added_total = price_order(items, menu_repo.get_raw)
    prev_total = int(existing.get("total", 0))
    # Legacy orders predate the tax fields: their sub_total was the total.
    prev_sub = existing.get("sub_total")
    prev_sub = prev_total if prev_sub is None else int(prev_sub)
    prev_tax = int(existing.get("tax_total") or 0)
    added_sub, added_tax = order_tax_totals(lines)
    existing["items"] = list(existing.get("items", [])) + lines
    existing["total"] = prev_total + added_total
    existing["sub_total"] = prev_sub + added_sub
    existing["tax_total"] = prev_tax + added_tax
    existing["updated_at"] = datetime.now(timezone.utc).isoformat()
    orders_table().put_item(Item=existing)
    return existing


def advance_status(order_id):
    existing = get(order_id)
    if not existing:
        raise ApiError("Order not found", 404)
    nxt = NEXT_STATUS.get(existing["status"])
    if not nxt:
        raise ApiError(f"Cannot advance from '{existing['status']}'", 409)
    return update_status(order_id, nxt)


def list_by_date(order_date):
    """Query the order_date GSI — one indexed lookup for a whole day."""
    cache_key = f"orders:date:{order_date}"
    cached = cache_get(cache_key)
    if cached is not None:
        return cached
    resp = orders_table().query(
        IndexName=Config.ORDER_DATE_INDEX,
        KeyConditionExpression=Key("order_date").eq(order_date),
    )
    result = [plain(i) for i in resp.get("Items", [])]
    cache_set(cache_key, result, ttl=60)
    return result


def list_orders(status=None, order_date=None, taken_by=None):
    if order_date:
        items = list_by_date(order_date)
    else:
        kwargs = {}
        if status:
            kwargs["FilterExpression"] = Attr("status").eq(status)
        items = [plain(i) for i in orders_table().scan(**kwargs).get("Items", [])]
    if status:
        items = [i for i in items if i.get("status") == status]
    if taken_by:
        items = [i for i in items if i.get("taken_by") == taken_by]
    items.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return items
