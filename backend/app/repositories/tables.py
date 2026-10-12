"""Cafe table data access + occupancy (DynamoDB).

A table's key is its number as a string. status is "empty" or "occupied";
when occupied it holds the current order id.

Optional floor-layout fields (used by the visual floor map):
    zone  (str, default "main")   — area of the cafe, e.g. "terrace"
    x, y  (int 0-100)             — top-left corner, percent of the canvas
    w, h  (int 1-100)             — size, percent of the canvas
    shape ("rect" | "round")
They are optional: legacy/missing values fall back to a client-side grid.
"""
from datetime import datetime, timezone

from ..aws import tables_table
from ..config import Config
from ..util import plain, ApiError

LAYOUT_KEYS = ("zone", "x", "y", "w", "h", "shape")
SHAPES = ("rect", "round")


def _now():
    return datetime.now(timezone.utc).isoformat()


def _int_field(data, key, lo, hi):
    """Validated int from a payload field; None when absent/null."""
    if key not in data or data[key] is None:
        return None
    try:
        value = int(data[key])
    except (TypeError, ValueError):
        raise ApiError(f"'{key}' must be an integer between {lo} and {hi}")
    if not lo <= value <= hi:
        raise ApiError(f"'{key}' must be an integer between {lo} and {hi}")
    return value


def layout_from(data):
    """Extract + validate the layout fields present in [data].

    Missing fields are simply omitted (callers keep whatever was stored).
    Raises ApiError(400) on invalid values.
    """
    layout = {}
    if data.get("zone") is not None:
        zone = str(data["zone"]).strip()
        if not zone:
            raise ApiError("'zone' must be a non-empty string")
        layout["zone"] = zone[:40]
    if data.get("shape") is not None:
        shape = str(data["shape"]).strip().lower()
        if shape not in SHAPES:
            raise ApiError("'shape' must be 'rect' or 'round'")
        layout["shape"] = shape
    for key, lo, hi in (("x", 0, 100), ("y", 0, 100), ("w", 1, 100), ("h", 1, 100)):
        value = _int_field(data, key, lo, hi)
        if value is not None:
            layout[key] = value
    return layout


def get(number):
    resp = tables_table().get_item(Key={"number": str(number)})
    return plain(resp["Item"]) if "Item" in resp else None


def list_all():
    items = [plain(i) for i in tables_table().scan().get("Items", [])]
    items.sort(key=lambda x: int(x.get("number", "0")))
    return items


def add(number, layout=None):
    number = str(number).strip()
    if not number.isdigit():
        raise ApiError("Table number must be a number")
    if get(number):
        raise ApiError("That table already exists", 409)
    table = {"number": number, "status": "empty", "order_id": None,
             "zone": "main", "shape": "rect", "updated_at": _now()}
    # Optional layout (x/y/w/h) — omitted when not supplied so the client can
    # fall back to its grid arrangement.
    table.update(layout_from(layout or {}))
    tables_table().put_item(Item=table)
    return table


def add_next():
    """Add the next sequential table number."""
    existing = [int(t["number"]) for t in list_all()]
    nxt = (max(existing) + 1) if existing else 1
    return add(nxt)


def update_layout(number, data):
    """Owner-only: move/resize/recolor a table on the floor map."""
    table = get(str(number))
    if not table:
        raise ApiError("Table not found", 404)
    layout = layout_from(data)
    if not layout:
        raise ApiError(
            "No layout fields supplied (zone, x, y, w, h, shape)")
    table.update(layout)
    table["updated_at"] = _now()
    tables_table().put_item(Item=table)
    return table


def add_next():
    """Add the next sequential table number."""
    existing = [int(t["number"]) for t in list_all()]
    nxt = (max(existing) + 1) if existing else 1
    return add(nxt)


def remove(number):
    table = get(str(number))
    if not table:
        raise ApiError("Table not found", 404)
    if table.get("status") == "occupied":
        raise ApiError("Cannot remove an occupied table", 409)
    tables_table().delete_item(Key={"number": str(number)})
    return {"removed": str(number)}


def occupy(number, order_id, taken_by=None):
    """Lock a table to an order. [taken_by] records which staff serves it."""
    table = get(str(number))
    if not table:
        # Table numbers can be free-form on the order; create if missing.
        table = {"number": str(number)}
    table.update({"status": "occupied", "order_id": order_id,
                  "taken_by": taken_by, "updated_at": _now()})
    tables_table().put_item(Item=table)
    return table


def free(number):
    table = get(str(number))
    if not table:
        return None
    table.update({"status": "empty", "order_id": None, "taken_by": None,
                  "updated_at": _now()})
    tables_table().put_item(Item=table)
    return table


def ensure_default(count=None):
    """Create tables 1..count if the table set is empty."""
    if list_all():
        return
    count = count or Config.DEFAULT_TABLE_COUNT
    for n in range(1, count + 1):
        add(n)
