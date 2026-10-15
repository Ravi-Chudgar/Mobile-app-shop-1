"""Platform admin (role `admin`) — cross-cafe management.

The platform admin belongs to no cafe. It can:
  * list every registered cafe with its owner details + profit & loss,
  * open any one cafe in full owner control ("act as owner": issues an owner
    token for that cafe so every owner route works unchanged),
  * create a brand-new cafe together with its owner account.

All routes are guarded with `admin_required`. Every data read resolves the
tenant explicitly with `tenant_scope(slug)` — never `g.tenant` — because the
admin token is not scoped to a single cafe.
"""
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify

from .. import infra
from ..auth import admin_required, issue_token
from ..ratelimit import limit
from ..repositories import staff as staff_repo
from ..repositories import tenants as tenants_repo
from ..tenancy import tenant_scope
from ..util import ApiError, plain
from .admin import compute_profit_loss

bp = Blueprint("platform", __name__, url_prefix="/platform")


def _parse_month(value):
    """Query `month` (YYYY-MM / YYYY-MM-DD) -> a datetime; default = now."""
    if value:
        for fmt in ("%Y-%m-%d", "%Y-%m"):
            try:
                return datetime.strptime(value, fmt)
            except ValueError:
                continue
    return datetime.now(timezone.utc)


def _owner_username():
    """Username of the CURRENT tenant's owner account (call inside a
    tenant_scope), or None."""
    for m in staff_repo.list_all():
        if m.get("role") == "owner":
            return m.get("username")
    return None


@bp.get("/tenants")
@admin_required
def list_tenants():
    """Every cafe: registry details (owner name, GSTIN, PAN, licence, ...) plus
    the current month's profit & loss and the owner login username."""
    target = _parse_month(request.args.get("month"))
    cafes = []
    for entry in tenants_repo.list_all():
        slug = entry.get("slug")
        cafe = dict(entry)
        # One broken cafe must never hide the rest of the list.
        try:
            with tenant_scope(slug):
                cafe["pnl"] = compute_profit_loss(target)
                cafe["owner_username"] = _owner_username()
        except Exception:
            cafe["pnl"] = None
            cafe["owner_username"] = None
        cafes.append(cafe)
    return jsonify({"cafes": cafes, "count": len(cafes)})


@bp.get("/tenants/<slug>")
@admin_required
def get_tenant(slug):
    """One cafe's full details: registry row, current-month P&L, owner login and
    a light staff summary."""
    entry = tenants_repo.get(slug)
    if not entry:
        raise ApiError("Unknown cafe", 404)
    cafe = dict(entry)
    with tenant_scope(slug):
        cafe["pnl"] = compute_profit_loss(_parse_month(request.args.get("month")))
        cafe["owner_username"] = _owner_username()
        staff = staff_repo.list_all()
        cafe["staff_count"] = len(staff)
        cafe["staff"] = [plain(m) for m in staff]
    return jsonify(cafe)


@bp.post("/tenants")
@admin_required
# Creating a cafe is rare, so this stays tight — it also blunts scripted
# attempts to mass-provision cafes/owner accounts.
@limit("10 per minute")
def create_tenant():
    """Register a new cafe and seed its owner account + starter menu.

    Body: slug, display_name, owner_username, owner_password (all required),
    plus optional gstin/pan/shop_license/address/phone/bill_footer/owner_name.
    """
    data = request.get_json(silent=True) or {}
    slug = str(data.get("slug") or "").strip().lower()
    display_name = str(data.get("display_name") or "").strip()
    owner_username = str(data.get("owner_username") or "").strip().lower()
    owner_password = str(data.get("owner_password") or "")

    if not slug:
        raise ApiError("'slug' (cafe code) is required")
    if not display_name:
        raise ApiError("'display_name' is required")
    if len(owner_username) < 3:
        raise ApiError("'owner_username' must be at least 3 characters")
    if len(owner_password) < 6:
        raise ApiError("'owner_password' must be at least 6 characters")

    # Registry row first (validates the slug, refuses a duplicate -> 409).
    tenants_repo.create(
        slug, display_name,
        kind=str(data.get("kind") or "cafe"),
        gstin=str(data.get("gstin") or ""),
        address=str(data.get("address") or ""),
        phone=str(data.get("phone") or ""),
        bill_footer=str(data.get("bill_footer") or ""),
        kitchen_printer_host=str(data.get("kitchen_printer_host") or ""),
        owner_name=str(data.get("owner_name") or ""),
        pan=str(data.get("pan") or ""),
        shop_license=str(data.get("shop_license") or ""),
    )
    # Create the tenant's tables + the owner account + the starter menu.
    seeded = infra.seed_all(slug, owner_user=owner_username,
                            owner_password=owner_password)
    entry = tenants_repo.get(slug) or {"slug": slug,
                                       "display_name": display_name}
    return jsonify({
        "message": f"Cafe '{slug}' created",
        "tenant": entry,
        "owner_user": seeded.get("owner_user"),
        "menu_items": seeded.get("menu_items", 0),
        "tables": seeded.get("tables", 0),
    }), 201


@bp.post("/tenants/<slug>/act-as")
@admin_required
@limit("30 per minute")
def act_as(slug):
    """Issue an OWNER token for cafe `slug` so the admin manages it with full
    owner rights. The app swaps to this token and can swap back by keeping the
    admin session. 404 when the cafe is not registered."""
    entry = tenants_repo.get(slug)
    if not entry:
        raise ApiError("Unknown cafe", 404)
    owner_username = slug
    owner_display = (entry.get("owner_name") or entry.get("display_name")
                     or slug)
    with tenant_scope(slug):
        found = _owner_username()
        if found:
            owner_username = found
    token = issue_token(owner_username, "owner", tenant=slug)
    return jsonify({
        "token": token,
        "role": "owner",
        "tenant": slug,
        "username": owner_username,
        "name": owner_display,
    })
