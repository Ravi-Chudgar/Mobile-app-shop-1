"""CRUD operations for the inventory_items DynamoDB table."""
import uuid
from decimal import Decimal
from datetime import datetime, timezone

from ..aws import inventory_table
from ..config import Config
from ..util import ApiError, plain


def list_all():
    resp = inventory_table().scan()
    return resp.get("Items", [])


def get(item_id):
    resp = inventory_table().get_item(Key={"id": item_id})
    return resp.get("Item")


def reorder_level_of(item):
    """Reorder level of a stored item as a plain int (0 = alerts disabled)."""
    if not item:
        return 0
    raw = item.get("reorder_level", 0)
    try:
        return int(plain(raw) or 0)
    except (TypeError, ValueError):
        return 0


def _coerce_reorder_level(value):
    """Validate a client-supplied reorder_level (int >= 0)."""
    if value is None:
        return 0
    if isinstance(value, bool):
        raise ApiError("'reorder_level' must be an integer >= 0")
    try:
        level = int(value)
    except (TypeError, ValueError):
        raise ApiError("'reorder_level' must be an integer >= 0")
    if level < 0:
        raise ApiError("'reorder_level' must be an integer >= 0")
    return level


def _write(item):
    """Persist a full item (read-modify-write keeps partial updates safe and
    works the same on real DynamoDB and the offline stub)."""
    inventory_table().put_item(Item=item)
    return item


def create(data):
    item_id = data.get("id") or f"inv-{uuid.uuid4().hex[:8]}"
    now = datetime.now(timezone.utc).isoformat()
    purchase_date = data.get("purchase_date") or now
    item = {
        "id": item_id,
        "name": data["name"],
        "quantity": Decimal(str(data.get("quantity", 0))),
        "cost_price": Decimal(str(data.get("cost_price", 0))),
        "unit": data.get("unit", "piece"),
        "reorder_level": _coerce_reorder_level(data.get("reorder_level")),
        "purchase_date": purchase_date,
        "last_restocked": now,
        "created_at": now,
    }
    _write(item)
    return plain(item)


def update(item_id, data):
    existing = get(item_id)
    if not existing:
        raise ApiError("Inventory item not found", 404)

    updates = {}
    for key in ("name", "purchase_date", "unit"):
        if key in data:
            updates[key] = data[key]
    for key in ("quantity", "cost_price"):
        if key in data:
            updates[key] = Decimal(str(data[key]))
    if "reorder_level" in data:
        updates["reorder_level"] = _coerce_reorder_level(data["reorder_level"])

    if not updates:
        return plain(existing)

    existing.update(updates)
    existing["updated_at"] = datetime.now(timezone.utc).isoformat()
    _write(existing)
    return plain(existing)


def restock(item_id, qty):
    """Add stock to an existing item."""
    existing = get(item_id)
    if not existing:
        raise ApiError("Inventory item not found", 404)

    existing["quantity"] = existing.get("quantity", 0) + Decimal(str(qty))
    existing["last_restocked"] = datetime.now(timezone.utc).isoformat()
    _write(existing)
    return plain(existing)


def deduct_stock(item_id, qty):
    """Reduce stock (called when an order is placed)."""
    existing = get(item_id)
    if not existing:
        raise ApiError("Inventory item not found", 404)

    new_qty = existing.get("quantity", 0) - Decimal(str(qty))
    if new_qty < 0:
        raise ApiError("Insufficient stock", 400)

    existing["quantity"] = new_qty
    _write(existing)
    return plain(existing)


def delete(item_id):
    existing = get(item_id)
    if not existing:
        raise ApiError("Inventory item not found", 404)
    inventory_table().delete_item(Key={"id": item_id})
    return {"deleted": True}


def low_stock_alerts():
    """Items that need restocking.

    An item alerts when its reorder_level is set (> 0) and its quantity has
    dropped to (or below) that level; reorder_level = 0 disables alerts for
    that item entirely — including when it is out of stock.
    """
    alerts = []
    for raw in list_all():
        item = plain(raw)
        level = reorder_level_of(raw)
        if level <= 0:
            continue
        qty = int(item.get("quantity", 0) or 0)
        if qty <= level:
            alerts.append({
                "id": item.get("id"),
                "item": item.get("name"),
                "qty": qty,
                "reorder_level": level,
                "unit": item.get("unit", "piece"),
                "out_of_stock": qty <= 0,
            })
    alerts.sort(key=lambda a: (a["qty"], -a["reorder_level"]))
    return alerts


def summary():
    """Total inventory value and count."""
    items = list_all()
    total_value = sum(
        int(i.get("quantity", 0)) * int(i.get("cost_price", 0)) for i in items
    )
    return {
        "total_items": len(items),
        "total_value": total_value,
    }
