"""Public (unauthenticated) endpoints for the QR self-order flow.

A table card carries a QR code that encodes a URL opening the mobile
self-order flow, which browses the menu, posts orders and tracks them.

Two families of routes share ONE handler body per action:

* Legacy paths (`/public/menu`, `/public/qr/<n>`, `/public/orders`,
  `/public/orders/<id>`) serve the DEFAULT tenant — byte-for-byte the same
  behaviour as before multi-tenancy, so existing QR cards and the current
  Flutter app keep working while it migrates.
* Tenant-scoped paths (`/public/<slug>/menu`, `/public/<slug>/qr/<n>`,
  `/public/<slug>/orders`, `/public/<slug>/orders/<id>`,
  `/public/<slug>/config`) resolve `<slug>` against the `cafe_tenants`
  registry (404 when unknown/malformed) and bind it with `set_tenant()`,
  so every repository call in the handler reads that tenant's own tables.
  `/public/<slug>/config` returns the public branding subset
  {display_name, kind, bill_footer} — never the kitchen printer host.

QR encoding:
  legacy          -> {QR_BASE_URL}/table/<n>
  tenant-scoped   -> {tenant.qr_base_url || QR_BASE_URL || request.host_url}
                     /t/<slug>/table/<n>

Occupied-table behaviour (documented contract):
  * table free      -> the QR order takes the lock, exactly like a staff
                       order (table.status = occupied, order_id = this
                       order, taken_by = "qr"). Staff double-booking is
                       still refused with 409 as before.
  * table occupied  -> the QR order is still created and linked to the
                       table (table_number set, so it shows up in the staff
                       queue for that table) but the existing lock is left
                       untouched: no re-occupy, no steal, no 409. The
                       table is freed only by the order that owns the lock
                       (update_status only frees when table.order_id matches).
"""
import io
import os

import qrcode
from flask import Blueprint, request, jsonify, Response

from ..config import Config
from ..repositories import menu as menu_repo
from ..repositories import orders as orders_repo
from ..repositories import tables as tables_repo
from ..repositories import tenants as tenants_repo
from ..services import printing as printing_service
from ..tenancy import is_valid_slug, set_tenant
from ..util import ApiError

bp = Blueprint("public", __name__, url_prefix="/public")

# Fields a customer is allowed to see on the menu (no stock/cost internals).
_MENU_FIELDS = ("id", "name", "description", "category", "gst_rate",
                "options", "image_url")


# --------------------------------------------------------------------------- #
# Tenant resolution (scoped routes only; legacy paths rely on the default)
# --------------------------------------------------------------------------- #

def _activate(slug):
    """Validate <slug> against the registry and bind it for this request.

    Unknown or malformed slugs 404 (a public endpoint should not explain
    *why* a tenant is missing). The default tenant is implicitly known even
    before its registry row exists, so env-only deployments keep working.
    """
    slug = str(slug or "")
    if not is_valid_slug(slug):
        raise ApiError("Unknown tenant", 404)
    if slug != Config.DEFAULT_TENANT and not tenants_repo.get(slug):
        raise ApiError("Unknown tenant", 404)
    set_tenant(slug)
    return slug


# --------------------------------------------------------------------------- #
# Shared handler bodies (used by BOTH the legacy and the scoped route)
# --------------------------------------------------------------------------- #

def _menu_response():
    """Available menu items for browsing: id, name, price, category,
    gst_rate and options. Unavailable items are hidden."""
    items = []
    for item in menu_repo.list_items():
        if not item.get("available", True):
            continue
        entry = {k: item.get(k) for k in _MENU_FIELDS}
        entry["price"] = item.get("base_price")
        entry["base_price"] = item.get("base_price")
        items.append(entry)
    return jsonify(items)


def _qr_response(table_number, url):
    """PNG QR code for a table card (or its JSON description)."""
    if request.args.get("format") == "json":
        return jsonify({"table_number": str(table_number), "url": url})
    buf = io.BytesIO()
    qrcode.make(url).save(buf, format="PNG")
    return Response(buf.getvalue(), mimetype="image/png",
                    headers={"X-QR-Url": url})


def _order_response():
    """Customer places a table order (see module docstring for the
    occupied-table rule).

    Payload: {"table_number": <n>, "items": [{"item_id", "qty",
    "selected_options"}], "customer": {"name": "...", "phone": "..."}}.
    Priced server-side; source = "qr", taken_by = "qr".

    After the order is created the shared auto-KOT helper fires once (same
    as the staff route) — no-op unless AUTO_PRINT_KOT is enabled.
    """
    payload = request.get_json(silent=True) or {}

    table_number = str(payload.get("table_number") or "").strip()
    if not table_number:
        raise ApiError("table_number is required")
    table = tables_repo.get(table_number)
    if not table:
        raise ApiError("Table not found", 404)

    customer = payload.get("customer") or {}
    name = str(customer.get("name") or "").strip()
    phone = str(customer.get("phone") or "").strip()
    if not name:
        raise ApiError("customer.name is required")
    if not phone:
        raise ApiError("customer.phone is required")
    if not payload.get("items"):
        raise ApiError("Order must contain at least one item")

    occupied = table.get("status") == "occupied"
    order = orders_repo.create(
        {
            **payload,
            "table_number": table_number,
            "customer": {"name": name, "phone": phone},
            "source": "qr",
        },
        taken_by="qr",
        # Occupied table: link the order without touching the lock.
        occupy_table=not occupied,
    )
    # Best-effort kitchen ticket — exactly the same side effect as a staff
    # order create (routes/orders.py): no-op unless AUTO_PRINT_KOT is on, and
    # the printer host comes from the CURRENT tenant (g.tenant is set by the
    # scoped route before this shared handler runs). Never raises.
    printing_service.maybe_auto_print_kot(order)
    return jsonify(order), 201


def _order_status_response(order_id):
    """Customer-facing tracking view: status, items, total (no payments)."""
    order = orders_repo.get(order_id)
    if not order:
        raise ApiError("Order not found", 404)
    return jsonify({
        "id": order.get("id"),
        "status": order.get("status"),
        "items": order.get("items", []),
        "total": order.get("total", 0),
        "sub_total": order.get("sub_total"),
        "tax_total": order.get("tax_total", 0),
        "table_number": order.get("table_number"),
        "source": order.get("source", "counter"),
        "payment_status": order.get("payment_status", "unpaid"),
        "created_at": order.get("created_at"),
    })


# --------------------------------------------------------------------------- #
# Legacy routes (default tenant)
# --------------------------------------------------------------------------- #

@bp.get("/menu")
def public_menu():
    return _menu_response()


@bp.get("/qr/<table_number>")
def table_qr(table_number):
    """PNG QR code for a table card: encodes {QR_BASE_URL}/table/<n>.

    Append ?format=json to get {"url", "table_number"} instead of the image
    (the mobile app uses it to show/print the link next to the QR).
    """
    if not tables_repo.get(str(table_number)):
        raise ApiError("Table not found", 404)
    base = (Config.QR_BASE_URL or "http://localhost:9999").rstrip("/")
    return _qr_response(table_number, f"{base}/table/{table_number}")


@bp.post("/orders")
def place_order():
    return _order_response()


@bp.get("/orders/<order_id>")
def order_status(order_id):
    return _order_status_response(order_id)


# --------------------------------------------------------------------------- #
# Tenant-scoped routes (GET /public/<slug>/...)
# --------------------------------------------------------------------------- #

@bp.get("/<slug>/menu")
def scoped_public_menu(slug):
    _activate(slug)
    return _menu_response()


@bp.get("/<slug>/qr/<table_number>")
def scoped_table_qr(slug, table_number):
    """QR for a tenant's table card:
    {tenant.qr_base_url || QR_BASE_URL || request.host_url}/t/<slug>/table/<n>
    """
    _activate(slug)
    if not tables_repo.get(str(table_number)):
        raise ApiError("Table not found", 404)
    entry = tenants_repo.get(slug) or {}
    base = (entry.get("qr_base_url")
            or os.getenv("QR_BASE_URL")
            or os.getenv("APP_BASE_URL")
            or request.host_url)
    base = str(base).rstrip("/")
    return _qr_response(table_number,
                        f"{base}/t/{slug}/table/{table_number}")


@bp.post("/<slug>/orders")
def scoped_place_order(slug):
    _activate(slug)
    return _order_response()


@bp.get("/<slug>/orders/<order_id>")
def scoped_order_status(slug, order_id):
    _activate(slug)
    return _order_status_response(order_id)


@bp.get("/<slug>/config")
def scoped_config(slug):
    """Public branding for the app: {display_name, kind, bill_footer}.
    Kitchen printer host and other operator config are never exposed."""
    _activate(slug)
    return jsonify(tenants_repo.config_for(slug))
