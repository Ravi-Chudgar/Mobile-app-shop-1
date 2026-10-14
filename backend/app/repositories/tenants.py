"""Tenant registry — one global `cafe_tenants` table (PK `slug`).

One row per tenant holding its identity + config:

    slug, display_name, kind ("cafe" | "hostel" | ...), gstin, address,
    phone, bill_footer, qr_base_url, kitchen_printer_host, auto_print_kot
    (bool), owner_name, pan, shop_license, created_at

The row is the source of truth for branding (printing.cafe_info), for
GET /public/<slug>/config and for the QR / kitchen-printer overrides. The
tenant's DATA lives in its own DynamoDB tables ({slug}_orders,
{slug}_menu_items, ...) resolved by app/aws.py via app/tenancy.py.

Reads are deliberately forgiving: when the registry table does not exist
yet (a deployment that never ran ensure_infra), get/list_all return
None/[] instead of raising, so auth and printing fall back to env config.
"""
from datetime import datetime, timezone

from .. import aws
from ..config import Config
from ..tenancy import is_valid_slug, validate_slug
from ..util import plain, ApiError


def _now():
    return datetime.now(timezone.utc).isoformat()


def create(slug, display_name, kind="cafe", gstin="", address="", phone="",
           bill_footer="", qr_base_url="", kitchen_printer_host="",
           auto_print_kot=False, owner_name="", pan="", shop_license=""):
    """Register a new tenant (validates the slug, refuses duplicates).

    Raises ApiError(400) for a bad slug/name, ApiError(409) when the slug is
    already taken. Does NOT create the tenant's tables — call
    infra.ensure_infra(slug) + infra.seed_all(slug, ...) afterwards.
    """
    validate_slug(slug)
    display_name = str(display_name or "").strip()
    if not display_name:
        raise ApiError("'name' (display name) is required")
    kind = str(kind or "cafe").strip().lower() or "cafe"
    if get(slug):
        raise ApiError(f"Tenant '{slug}' already exists", 409)

    item = {
        "slug": slug,
        "display_name": display_name,
        "kind": kind,
        "gstin": str(gstin or "").strip(),
        "address": str(address or "").strip(),
        "phone": str(phone or "").strip(),
        "bill_footer": str(bill_footer or "").strip(),
        "qr_base_url": str(qr_base_url or "").strip(),
        "kitchen_printer_host": str(kitchen_printer_host or "").strip(),
        "auto_print_kot": bool(auto_print_kot),
        "owner_name": str(owner_name or "").strip(),
        "pan": str(pan or "").strip(),
        "shop_license": str(shop_license or "").strip(),
        "created_at": _now(),
    }
    aws.tenants_table().put_item(Item=item)
    return plain(item)


# Registry fields an owner may edit from the Cafe Profile screen. `display_name`
# is included so the cafe's printed name is settable; slug/kind/created_at are
# intentionally excluded (immutable identity).
_EDITABLE = (
    "display_name", "gstin", "address", "phone", "bill_footer",
    "owner_name", "pan", "shop_license",
)


def update(slug, **fields):
    """Update the editable registry fields for `slug` (partial update).

    Creates a minimal row first if none exists yet (a tenant provisioned before
    the registry table existed). Returns the merged row. Raises ApiError(400)
    when an unknown field is passed.
    """
    unknown = set(fields) - set(_EDITABLE)
    if unknown:
        raise ApiError(f"Unknown field(s): {', '.join(sorted(unknown))}")
    current = get(slug) or {
        "slug": str(slug), "kind": "cafe", "created_at": _now(),
    }
    for key in _EDITABLE:
        if key in fields:
            # bill_footer and text fields are plain strings; auto_print_kot is
            # not editable here. Store trimmed strings.
            current[key] = str(fields[key] or "").strip()
    aws.tenants_table().put_item(Item=current)
    return plain(current)


def get(slug):
    """Registry row for `slug` (None when unknown / no registry table yet)."""
    if not slug:
        return None
    try:
        resp = aws.tenants_table().get_item(Key={"slug": str(slug)})
    except Exception:  # table not created yet (fresh deployment)
        return None
    return plain(resp["Item"]) if "Item" in resp else None


def list_all():
    """Every registered tenant, newest slug first (defensive like get)."""
    try:
        items = [plain(i) for i in aws.tenants_table().scan().get("Items", [])]
    except Exception:  # table not created yet (fresh deployment)
        return []
    items.sort(key=lambda x: x.get("slug", ""))
    return items


def config_for(slug):
    """Public branding subset for a tenant: {display_name, kind, bill_footer}.

    This is what GET /public/<slug>/config returns — never the kitchen
    printer host or other operator config. Falls back to the env cafe
    identity (CAFE_NAME etc.) when the tenant has no registry row yet.
    """
    entry = get(slug) or {}
    return {
        "display_name": entry.get("display_name") or Config.CAFE_NAME,
        "kind": entry.get("kind") or "cafe",
        "bill_footer": entry.get("bill_footer") or "",
    }


# Re-exported so callers only import the repository for slug rules too.
__all__ = ["create", "update", "get", "list_all", "config_for", "is_valid_slug"]
