"""Owner-only management: sales reports, staff approval, menu CRUD, inventory.
Most routes require an owner JWT.

Phase 4 (accounting bridge): the read-only GET report routes the CA needs
(/reports/daily, /reports/z, /billing) also accept the `cafe_ca` role via
owner_or_ca. Every handler in that allow-list is registered with @bp.get —
no mutating route accepts cafe_ca, and ca_guard.py refuses non-GET requests
carrying a cafe_ca token globally.
"""
import calendar
import uuid
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify

from ..auth import VALID_ROLES, owner_or_ca, owner_required
from ..aws import s3
from ..config import Config
from ..repositories import menu as menu_repo
from ..repositories import orders as orders_repo
from ..repositories import reports as reports_repo
from ..repositories import staff as staff_repo
from ..repositories import inventory as inventory_repo
from ..repositories import tenants as tenants_repo
from ..tenancy import tenant_prefix, current_tenant
from ..util import ApiError, plain

bp = Blueprint("admin", __name__, url_prefix="/admin")


# ---- Sales reports ---------------------------------------------------------

@bp.get("/reports/daily")
@owner_or_ca  # read-only report: owner OR cafe_ca (Phase 4)
def daily_report():
    date = request.args.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return jsonify(reports_repo.daily_summary(date))


@bp.get("/reports/z")
@owner_or_ca  # read-only report: owner OR cafe_ca (Phase 4)
def z_report():
    """Day-end Z-report: totals, GST breakup, sales by payment method."""
    date = request.args.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        datetime.strptime(date, "%Y-%m-%d")
    except ValueError:
        raise ApiError("'date' must be YYYY-MM-DD")
    return jsonify(reports_repo.z_report(date))


@bp.get("/reports/range")
@owner_required
def range_report():
    date_from = request.args.get("from")
    date_to = request.args.get("to")
    if not date_from or not date_to:
        raise ApiError("'from' and 'to' query params are required")
    return jsonify(reports_repo.range_summary(date_from, date_to))


# ---- Billing (owner) -------------------------------------------------------

@bp.get("/billing")
@owner_or_ca  # read-only report: owner OR cafe_ca (Phase 4)
def billing():
    """Collected orders grouped by day, with paid/unpaid totals.
    Optional ?date=YYYY-MM-DD restricts to a single day."""
    return jsonify(reports_repo.billing_summary(request.args.get("date")))


@bp.post("/billing/<order_id>/paid")
@owner_required
def mark_order_paid(order_id):
    """Owner confirms payment for a collected order."""
    return jsonify(orders_repo.mark_paid(order_id))


# ---- Staff management ------------------------------------------------------

@bp.get("/staff")
@owner_required
def list_staff():
    return jsonify(staff_repo.list_all())


@bp.post("/staff")
@owner_required
def create_staff():
    """Owner adds a staff member directly (already approved).

    Optional `role` in the body (default "staff") lets the owner create any
    account type, including the read-only `cafe_ca` accounting login
    (Phase 4). "owner" is never assignable here — ownership is seeded.
    """
    data = request.get_json(silent=True) or {}
    role = str(data.get("role") or "staff").strip().lower()
    if role not in VALID_ROLES or role == "owner":
        raise ApiError(
            f"'role' must be one of: {', '.join(r for r in VALID_ROLES if r != 'owner')}")
    member = staff_repo.register(
        data.get("username", ""),
        data.get("password", ""),
        data.get("name", ""),
        role=role,
        status="approved",
    )
    return jsonify(member), 201


@bp.post("/staff/<username>/approve")
@owner_required
def approve_staff(username):
    return jsonify(staff_repo.approve(username))


@bp.delete("/staff/<username>")
@owner_required
def remove_staff(username):
    return jsonify(staff_repo.remove(username))


# ---- Kitchen user management -----------------------------------------------

@bp.post("/kitchen")
@owner_required
def create_kitchen_user():
    """Owner adds a kitchen display user (auto-approved)."""
    data = request.get_json(silent=True) or {}
    member = staff_repo.register(
        data.get("username", ""),
        data.get("password", ""),
        data.get("name", ""),
        role="kitchen",
        status="approved",
    )
    return jsonify(member), 201


# ---- Menu management -------------------------------------------------------

@bp.post("/menu")
@owner_required
def create_item():
    data = request.get_json(silent=True) or {}
    if not data.get("name") or "base_price" not in data:
        raise ApiError("'name' and 'base_price' are required")
    # Store ingredients mapping for auto stock deduction
    if "ingredients" in data:
        data["ingredients"] = data["ingredients"]
    return jsonify(menu_repo.create(data)), 201


@bp.put("/menu/<item_id>")
@owner_required
def update_item(item_id):
    data = request.get_json(silent=True) or {}
    if "ingredients" in data:
        data["ingredients"] = data["ingredients"]
    return jsonify(menu_repo.update(item_id, data))


@bp.patch("/menu/<item_id>/availability")
@owner_required
def set_availability(item_id):
    data = request.get_json(silent=True) or {}
    if "available" not in data:
        raise ApiError("'available' boolean is required")
    return jsonify(menu_repo.set_availability(item_id, data["available"]))


@bp.delete("/menu/<item_id>")
@owner_required
def delete_item(item_id):
    return jsonify(menu_repo.delete(item_id))


@bp.post("/menu/<item_id>/image")
@owner_required
def upload_image(item_id):
    if "file" not in request.files:
        raise ApiError("multipart 'file' is required")
    if not menu_repo.get_raw(item_id):
        raise ApiError("Menu item not found", 404)

    file = request.files["file"]
    ext = (file.filename.rsplit(".", 1)[-1] if "." in file.filename else "jpg").lower()
    # Tenant-scoped S3 key: "<slug>/menu/<item>-<rand>.<ext>" so one bucket
    # can hold every tenant's images without collisions.
    key = f"{tenant_prefix()}menu/{item_id}-{uuid.uuid4().hex[:6]}.{ext}"
    s3().upload_fileobj(
        file, Config.IMAGES_BUCKET, key,
        ExtraArgs={"ContentType": file.mimetype or "image/jpeg"},
    )
    item = menu_repo.set_image_key(item_id, key)
    return jsonify({"image_url": item.get("image_url"), "image_key": key})


# ---- Inventory management ---------------------------------------------------

@bp.get("/inventory")
@owner_required
def list_inventory():
    return jsonify(plain(inventory_repo.list_all()))


@bp.get("/inventory/alerts")
@owner_required
def inventory_alerts():
    """Low-stock alerts: items whose reorder_level is set (> 0) and whose
    quantity has dropped to (or below) it, plus out-of-stock items.

    Each entry: {id, item, qty, reorder_level, unit, out_of_stock}.
    reorder_level = 0 disables alerts for that item (never returned).
    """
    return jsonify(inventory_repo.low_stock_alerts())


@bp.get("/inventory/summary")
@owner_required
def inventory_summary():
    return jsonify(inventory_repo.summary())


@bp.post("/inventory")
@owner_required
def create_inventory_item():
    data = request.get_json(silent=True) or {}
    if not data.get("name"):
        raise ApiError("'name' is required")
    return jsonify(inventory_repo.create(data)), 201


@bp.put("/inventory/<item_id>")
@owner_required
def update_inventory_item(item_id):
    data = request.get_json(silent=True) or {}
    return jsonify(inventory_repo.update(item_id, data))


@bp.post("/inventory/<item_id>/restock")
@owner_required
def restock_item(item_id):
    data = request.get_json(silent=True) or {}
    qty = data.get("quantity")
    if qty is None or int(qty) <= 0:
        raise ApiError("'quantity' must be a positive integer")
    return jsonify(inventory_repo.restock(item_id, qty))


@bp.delete("/inventory/<item_id>")
@owner_required
def delete_inventory_item(item_id):
    return jsonify(inventory_repo.delete(item_id))


# ---- Profit / Loss report ---------------------------------------------------

@bp.get("/reports/profit-loss")
@owner_required
def profit_loss():
    """Profit/loss report using actual COGS from collected orders."""
    month_str = request.args.get("month")
    target = None
    if month_str:
        for fmt in ("%Y-%m-%d", "%Y-%m"):
            try:
                target = datetime.strptime(month_str, fmt)
                break
            except ValueError:
                continue
    if target is None:
        target = datetime.now(timezone.utc)

    year, month = target.year, target.month
    # Real calendar days (February has 28/29, March has 31, ...).
    days_in_month = calendar.monthrange(year, month)[1]

    # Sum sales revenue for the month
    total_sales = 0
    total_orders = 0
    for day in range(1, days_in_month + 1):
        try:
            date_str = f"{year}-{month:02d}-{day:02d}"
            summary = reports_repo.daily_summary(date_str)
            total_sales += summary.get("gross_sales", 0)
            total_orders += summary.get("order_count", 0)
        except Exception:
            continue

    # Sum COGS from collected orders
    total_cogs = 0
    all_orders = orders_repo.list_orders(status="collected")
    for o in all_orders:
        created = o.get("created_at", "")
        if created.startswith(f"{year}-{month:02d}"):
            total_cogs += int(o.get("cogs", 0))

    # Fallback: when per-order COGS is missing, estimate with inventory value.
    cogs_estimated = False
    if total_cogs == 0:
        inv_summary = inventory_repo.summary()
        total_cogs = int(inv_summary.get("total_value", 0) or 0)
        cogs_estimated = total_cogs > 0
    cogs_source = ("none" if total_cogs == 0
                   else "inventory_estimate" if cogs_estimated else "orders")

    revenue = total_sales
    net_profit = revenue - total_cogs
    in_profit = net_profit >= 0
    # Profit margin = net / revenue (a percentage of sales).
    profit_margin = round((net_profit / revenue) * 100, 1) if revenue else 0.0
    # Markup on cost, exposed separately from the margin.
    markup = round((net_profit / total_cogs) * 100, 1) if total_cogs > 0 else 0.0

    suggestion = None
    if not in_profit and total_cogs > 0:
        suggestion = (
            f"Sales ({revenue}) are below cost ({total_cogs}). "
            f"Consider: (1) reduce slow-moving stock, (2) negotiate better supplier prices, "
            f"(3) increase prices on low-margin items."
        )

    return jsonify({
        "total_sales": total_sales,
        "revenue": revenue,
        "total_cost": total_cogs,
        "cogs_source": cogs_source,
        "cogs_estimated": cogs_estimated,
        "net_profit": net_profit,
        "in_profit": in_profit,
        "profit_margin": profit_margin,
        "markup": markup,
        "total_orders": total_orders,
        "days_in_month": days_in_month,
        "suggestion": suggestion,
    })


# --- Cafe profile (business identity printed on bills) ----------------------
# The owner sets these once from the Cafe Profile screen; they show up on the
# thermal receipt (GST / PAN / shop licence / owner name). `bill_footer` is the
# free-text line printed just above "Thank you".

_PROFILE_FIELDS = ("display_name", "gstin", "address", "phone",
                   "bill_footer", "owner_name", "pan", "shop_license")


@bp.get("/cafe/profile")
@owner_required
def get_cafe_profile():
    """Current tenant's editable business identity (empty strings when unset)."""
    entry = tenants_repo.get(current_tenant()) or {}
    return jsonify({f: entry.get(f, "") or "" for f in _PROFILE_FIELDS})


@bp.put("/cafe/profile")
@owner_required
def update_cafe_profile():
    """Partially update the cafe profile. Only whitelisted fields are stored."""
    data = request.get_json(silent=True) or {}
    fields = {k: data[k] for k in _PROFILE_FIELDS if k in data}
    if not fields:
        raise ApiError("No editable fields supplied")
    updated = tenants_repo.update(current_tenant(), **fields)
    return jsonify({f: updated.get(f, "") or "" for f in _PROFILE_FIELDS})
