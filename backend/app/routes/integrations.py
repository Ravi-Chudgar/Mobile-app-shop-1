"""Delivery partner ingestion: Swiggy + Zomato order webhooks.

Both endpoints are authenticated with a shared secret header, never a JWT:

    X-Integration-Key: <SWIGGY_API_KEY / ZOMATO_API_KEY>

A missing/incorrect key (or a key not configured in the environment) is a
401. Received orders are mapped onto a normal POS order via
orders_repo.create(..., source="swiggy"|"zomato", pickup_type="delivery",
no table) and then flow through the usual received -> preparing -> ready ->
collected pipeline.

Expected payload (same shape for both partners)::

    POST /integrations/swiggy/orders
    {
      "order_id": "SW-9981",                      # partner ref, kept in notes
      "items": [
        {"name": "Latte", "qty": 2},              # price is informational
        {"name": "Butter Croissant", "qty": 1, "price": 25000}
      ],
      "customer": {"name": "Asha", "phone": "9876543210"},
      "total": 89000,                             # ignored: server reprices
      "address": "B-402, Riverdale, Ahmedabad"    # optional -> order notes
    }

Mapping rules (documented contract):
  * items are matched to the menu by `item_id` when present, otherwise by
    case-insensitive `name`. An unmatched name is a 400 (rename the menu
    item or map it in the partner dashboard) — the POS never invents prices.
  * `price`/`total` are ignored: every line is repriced from the menu so GST
    stays correct.
  * required option groups (e.g. Size) are auto-filled with their first
    choice when the payload doesn't choose one.
  * `address` (and the partner `order_id`) are stored on `order.notes`.
  * `taken_by` = the partner name, so the staff report shows the channel.
"""
import secrets

from flask import Blueprint, request, jsonify

from ..config import Config
from ..repositories import menu as menu_repo
from ..repositories import orders as orders_repo
from ..services import printing as printing_service
from ..util import ApiError

bp = Blueprint("integrations", __name__)


def _require_key(expected):
    """401 unless X-Integration-Key exactly matches the configured secret."""
    provided = request.headers.get("X-Integration-Key") or ""
    if not expected or not provided or \
            not secrets.compare_digest(provided, expected):
        raise ApiError("Invalid or missing X-Integration-Key", 401)


def _menu_index():
    by_id, by_name = {}, {}
    for item in menu_repo.list_items():
        by_id[item["id"]] = item
        by_name[str(item.get("name", "")).strip().lower()] = item
    return by_id, by_name


def _map_items(raw_items):
    """Partner lines -> priced-order payload lines (see module docstring)."""
    if not isinstance(raw_items, list) or not raw_items:
        raise ApiError("'items' must be a non-empty list")
    by_id, by_name = _menu_index()

    mapped = []
    for entry in raw_items:
        if not isinstance(entry, dict):
            raise ApiError("Each item must be an object")
        item_id = str(entry.get("item_id") or "").strip()
        menu_item = by_id.get(item_id) if item_id else None
        if menu_item is None:
            name = str(entry.get("name") or "").strip().lower()
            menu_item = by_name.get(name)
        if menu_item is None:
            raise ApiError(
                f"No menu item matches '{entry.get('name') or item_id}' — "
                "send an item_id or use the exact menu item name")

        selected = []
        for sel in entry.get("selected_options") or entry.get("options") or []:
            if isinstance(sel, dict) and sel.get("group") and sel.get("label"):
                selected.append({"group": sel["group"], "label": sel["label"]})
        chosen_groups = {s["group"] for s in selected}
        # Required groups (Size etc.) default to their first choice so a
        # bare partner line still prices.
        for group in menu_item.get("options", []):
            if group.get("required") and group["group"] not in chosen_groups \
                    and group.get("choices"):
                selected.append({
                    "group": group["group"],
                    "label": group["choices"][0]["label"],
                })

        try:
            qty = int(entry.get("qty", 1))
        except (TypeError, ValueError):
            raise ApiError("Item 'qty' must be an integer")
        mapped.append({
            "item_id": menu_item["id"],
            "qty": qty,
            "selected_options": selected,
        })
    return mapped


def _ingest(source, expected_key):
    _require_key(expected_key)
    payload = request.get_json(silent=True) or {}
    customer = payload.get("customer") or {}
    name = str(customer.get("name") or "").strip()
    if not name:
        raise ApiError("customer.name is required")

    partner_ref = str(payload.get("order_id") or "").strip()
    address = str(payload.get("address") or "").strip()
    notes = " ".join(p for p in (
        f"Delivery partner ref: {partner_ref}" if partner_ref else "",
        f"Address: {address}" if address else "",
        str(payload.get("notes") or "").strip(),
    ) if p)

    order = orders_repo.create(
        {
            "items": _map_items(payload.get("items")),
            "customer": {
                "name": name,
                "phone": str(customer.get("phone") or "").strip() or None,
            },
            "pickup_type": "delivery",
            "table_number": None,
            "source": source,
            "notes": notes,
        },
        taken_by=source,
    )
    # A delivery order is a kitchen order too: same best-effort KOT helper
    # as the staff/QR paths (no-op unless AUTO_PRINT_KOT is enabled; any
    # printer failure is swallowed by the helper, never by this webhook).
    printing_service.maybe_auto_print_kot(order)
    return jsonify(order), 201


@bp.post("/integrations/swiggy/orders")
def swiggy_orders():
    """Swiggy order webhook — see the module docstring for the payload."""
    return _ingest("swiggy", Config.SWIGGY_API_KEY)


@bp.post("/integrations/zomato/orders")
def zomato_orders():
    """Zomato order webhook — see the module docstring for the payload."""
    return _ingest("zomato", Config.ZOMATO_API_KEY)
