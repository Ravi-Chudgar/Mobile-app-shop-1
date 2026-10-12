"""Create a new tenant (business): registry row + DynamoDB tables + owner.

Runs with the same env as the app (load_dotenv picks up backend/.env), so
inside the container:

    docker compose exec backend python scripts/create_tenant.py \
        --slug test_hostel --name "Test Hostel" --kind hostel \
        --owner-user admin --owner-password secret123 \
        --gstin 24ABCTST0001C1ZV --address "5 Lake View, Udaipur" \
        --phone "+91 98765 43210" \
        --bill-footer "Reception: dial 0 | WiFi: hostel-guest" \
        --qr-base-url https://test-hostel.example \
        --kitchen-printer-host 192.168.1.50

The slug is the tenant code. It becomes the table prefix for every
non-default tenant (test_hostel_orders, test_hostel_menu_items,
test_hostel_staff, test_hostel_cafe_tables, test_hostel_inventory_items,
test_hostel_loyalty_accounts) and the public URL space
(GET /public/test_hostel/menu, POST /auth/login {"tenant": "test_hostel"}).
"""
import argparse
import os
import sys

# Make `app` importable when run as `python scripts/create_tenant.py`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv  # noqa: E402

load_dotenv()

from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.repositories import tenants as tenants_repo  # noqa: E402
from app.tenancy import is_valid_slug, tenant_table_name  # noqa: E402
from app.util import ApiError  # noqa: E402

BASE_TABLES = ("MENU_TABLE", "ORDERS_TABLE", "STAFF_TABLE", "TABLES_TABLE",
               "INVENTORY_TABLE", "LOYALTY_TABLE")


def build_parser():
    p = argparse.ArgumentParser(
        prog="create_tenant.py",
        description="Create a tenant (business): cafe_tenants row + its own "
                    "DynamoDB tables + an owner login.")
    p.add_argument("--slug", required=True,
                   help="tenant code used in URLs/logins/table names, "
                        "2-31 chars ^[a-z][a-z0-9_]{1,30}$ (e.g. chai_point)")
    p.add_argument("--name", required=True,
                   help="display name printed on receipts (e.g. 'Chai Point')")
    p.add_argument("--owner-user", required=True, help="owner login username")
    p.add_argument("--owner-password", required=True, help="owner password")
    p.add_argument("--kind", default="cafe",
                   help="business kind: cafe | hostel | ... (default: cafe)")
    p.add_argument("--gstin", default="", help="GSTIN on the bill header")
    p.add_argument("--address", default="", help="address on the bill header")
    p.add_argument("--phone", default="", help="phone on the bill header")
    p.add_argument("--bill-footer", default="",
                   help="footer line printed at the end of receipts")
    p.add_argument("--qr-base-url", default="",
                   help="base URL encoded into this tenant's table QR codes")
    p.add_argument("--kitchen-printer-host", default="",
                   help="ESC/POS kitchen printer host for this tenant's KOTs")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    slug = str(args.slug or "").strip().lower()

    if not is_valid_slug(slug):
        print(f"ERROR: invalid slug '{args.slug}' — expected "
              r"^[a-z][a-z0-9_]{1,30}$ (e.g. chai_point)", file=sys.stderr)
        return 2

    try:
        tenants_repo.create(
            slug=slug,
            display_name=args.name,
            kind=args.kind,
            gstin=args.gstin,
            address=args.address,
            phone=args.phone,
            bill_footer=args.bill_footer,
            qr_base_url=args.qr_base_url,
            kitchen_printer_host=args.kitchen_printer_host,
        )
    except ApiError as e:
        print(f"ERROR: {e.message}", file=sys.stderr)
        return 1

    ensure_infra(slug)
    result = seed_all(slug, owner_user=args.owner_user,
                      owner_password=args.owner_password)

    tables = [tenant_table_name(getattr(Config, attr), slug)
              for attr in BASE_TABLES]
    default_note = ""
    if slug == Config.DEFAULT_TENANT:
        default_note = (f"\n  NOTE: '{slug}' IS the default tenant "
                        f"(DEFAULT_TENANT={Config.DEFAULT_TENANT}) — it keeps "
                        "the legacy unprefixed table names and gets the full "
                        "demo seed.")

    if "menu_items" in result:
        menu_line = f"{result['menu_items']} starter item(s), no demo orders"
    else:
        menu_line = "full demo menu + sample orders"
    print("=" * 64)
    print(f"Tenant created: {args.name}  (tenant code: {slug})")
    print(f"  Kind         : {args.kind or 'cafe'}")
    if args.gstin:
        print(f"  GSTIN        : {args.gstin}")
    print(f"  Owner login  : {result['owner_user']} / "
          f"{result['owner_password']}   (role: owner)")
    print(f"  Tables       : {', '.join(tables)}")
    print(f"  Menu         : {menu_line}")
    print(f"  Floor tables : {result.get('tables', Config.DEFAULT_TABLE_COUNT)}")
    print(f"  Public menu  : GET /public/{slug}/menu")
    print(f"  Branding     : GET /public/{slug}/config")
    print(f"  Table QR     : GET /public/{slug}/qr/<table_number>")
    print("  Staff login  : POST /auth/login "
          f'{{"tenant": "{slug}", "username": ..., "password": ...}}')
    if default_note:
        print(default_note)
    print("=" * 64)
    return 0


if __name__ == "__main__":
    sys.exit(main())
