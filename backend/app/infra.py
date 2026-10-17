"""Idempotent creation of the Floci/AWS resources this backend needs, plus
sample data. Imported by scripts/bootstrap.py and scripts/seed.py (and tests).

Multi-tenant: every helper takes an optional `slug` (None => default tenant,
legacy behaviour). Non-default tenants get their own prefixed tables
(``{slug}_orders`` ...); the tenant registry table and the images bucket are
GLOBAL and created regardless of slug. `scripts/create_tenant.py` wires the
three steps together: registry row -> ensure_infra(slug) -> seed_all(slug).
"""
import os
import time

from botocore.exceptions import ClientError

from . import tenancy
from .aws import dynamodb_client, dynamodb, s3
from .config import Config
from .repositories import menu as menu_repo
from .repositories import orders as orders_repo
from .repositories import staff as staff_repo
from .repositories import tables as tables_repo
from .repositories import inventory as inventory_repo
from .repositories import tenants as tenants_repo


# --------------------------------------------------------------------------- #
# Infrastructure
# --------------------------------------------------------------------------- #

def _table_exists(name):
    try:
        dynamodb_client().describe_table(TableName=name)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            return False
        raise


def _wait_active(name):
    dynamodb_client().get_waiter("table_exists").wait(TableName=name)


def ensure_menu_table(slug=None):
    name = tenancy.tenant_table_name(Config.MENU_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_orders_table(slug=None):
    name = tenancy.tenant_table_name(Config.ORDERS_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[
            {"AttributeName": "id", "AttributeType": "S"},
            {"AttributeName": "order_date", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[
            {
                "IndexName": Config.ORDER_DATE_INDEX,
                "KeySchema": [{"AttributeName": "order_date", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            }
        ],
    )
    _wait_active(name)


def ensure_staff_table(slug=None):
    name = tenancy.tenant_table_name(Config.STAFF_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "username", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "username", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_tables_table(slug=None):
    name = tenancy.tenant_table_name(Config.TABLES_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "number", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "number", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_inventory_table(slug=None):
    name = tenancy.tenant_table_name(Config.INVENTORY_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_attendance_table(slug=None):
    """Staff attendance (clock in / clock out). PK is the composite string
    ``{username}#{YYYY-MM-DD}`` so every member gets one record per day."""
    name = tenancy.tenant_table_name(Config.ATTENDANCE_TABLE, slug)
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_tenants_table():
    """GLOBAL tenant registry (`cafe_tenants`, PK slug) — never prefixed."""
    name = Config.TENANTS_TABLE
    if _table_exists(name):
        return
    dynamodb_client().create_table(
        TableName=name,
        BillingMode="PAY_PER_REQUEST",
        KeySchema=[{"AttributeName": "slug", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "slug", "AttributeType": "S"}],
    )
    _wait_active(name)


def ensure_bucket():
    client = s3()
    try:
        client.head_bucket(Bucket=Config.IMAGES_BUCKET)
    except ClientError:
        region = Config.AWS_REGION
        if region == "us-east-1":
            client.create_bucket(Bucket=Config.IMAGES_BUCKET)
        else:
            client.create_bucket(
                Bucket=Config.IMAGES_BUCKET,
                CreateBucketConfiguration={"LocationConstraint": region},
            )


def ensure_default_registry_entry():
    """Register the DEFAULT tenant so /public/<default>/* and per-tenant
    branding work out of the box. Seeded from the env cafe identity
    (CAFE_NAME/ADDRESS/GSTIN/PHONE) and never overwritten afterwards — the
    row is the operator's, not ours. Other tenants get their row from
    scripts/create_tenant.py / tenants.create()."""
    slug = Config.DEFAULT_TENANT
    if not tenancy.is_valid_slug(slug) or tenants_repo.get(slug):
        return
    tenants_repo.create(
        slug=slug,
        display_name=Config.CAFE_NAME,
        kind="cafe",
        gstin=Config.CAFE_GSTIN,
        address=Config.CAFE_ADDRESS,
        phone=Config.CAFE_PHONE,
    )


def ensure_infra(slug=None):
    """Idempotently create every resource `slug` needs.

    slug=None => the default tenant (unchanged legacy behaviour: unprefixed
    table names). The tenant registry table and the images bucket are
    global and always created.
    """
    slug = slug or Config.DEFAULT_TENANT
    ensure_tenants_table()
    ensure_bucket()
    with tenancy.tenant_scope(slug):
        if slug == Config.DEFAULT_TENANT:
            ensure_default_registry_entry()
        ensure_menu_table(slug)
        ensure_orders_table(slug)
        ensure_staff_table(slug)
        ensure_tables_table(slug)
        ensure_inventory_table(slug)
        ensure_attendance_table(slug)
        # Create the default set of tables on first boot (per tenant).
        tables_repo.ensure_default()


# --------------------------------------------------------------------------- #
# Sample data
# --------------------------------------------------------------------------- #

SIZE = {
    "group": "Size", "required": True, "choices": [
        {"label": "Small", "price_delta": 0},
        {"label": "Regular", "price_delta": 50},
        {"label": "Large", "price_delta": 90},
    ],
}
MILK = {
    "group": "Milk", "required": False, "choices": [
        {"label": "Whole", "price_delta": 0},
        {"label": "Oat", "price_delta": 40},
        {"label": "Almond", "price_delta": 40},
    ],
}
EXTRAS = {
    "group": "Extras", "required": False, "multi": True, "choices": [
        {"label": "Extra shot", "price_delta": 50},
        {"label": "Vanilla syrup", "price_delta": 30},
    ],
}

SAMPLE_MENU = [
    {"id": "espresso", "name": "Espresso", "category": "coffee", "base_price": 200,
     "description": "Rich single-origin shot.", "options": [SIZE, EXTRAS]},
    {"id": "latte", "name": "Latte", "category": "coffee", "base_price": 320,
     "description": "Smooth espresso with steamed milk.", "options": [SIZE, MILK, EXTRAS]},
    {"id": "cappuccino", "name": "Cappuccino", "category": "coffee", "base_price": 300,
     "description": "Espresso topped with airy foam.", "options": [SIZE, MILK, EXTRAS]},
    {"id": "cold-brew", "name": "Cold Brew", "category": "cold_drinks", "base_price": 340,
     "description": "Slow-steeped, smooth and bold.", "options": [SIZE, EXTRAS]},
    {"id": "chai", "name": "Masala Chai", "category": "tea", "base_price": 220,
     "description": "Spiced tea brewed with milk.", "options": [SIZE, MILK]},
    {"id": "croissant", "name": "Butter Croissant", "category": "pastries", "base_price": 250,
     "description": "Flaky, freshly baked.", "options": []},
    {"id": "avocado-toast", "name": "Avocado Toast", "category": "food", "base_price": 480,
     "description": "Sourdough, smashed avocado, chilli.", "options": []},
    {"id": "muffin", "name": "Blueberry Muffin", "category": "pastries", "base_price": 260,
     "description": "Loaded with blueberries.", "options": []},
]


def seed_menu():
    for item in SAMPLE_MENU:
        menu_repo.create(item)


def seed_owner(user=None, password=None):
    user = user or os.getenv("SEED_ADMIN_USER", "owner")
    password = password or os.getenv("SEED_ADMIN_PASSWORD", "cafe123")
    if not staff_repo.get(user):
        staff_repo.register(user, password, "Owner", role="owner",
                            status="approved")
    return user, password


def seed_staff():
    """One approved staff and one pending staff, to demo the approval flow."""
    demo = []
    if not staff_repo.get("priya"):
        staff_repo.register("priya", "staff123", "Priya", role="staff",
                           status="approved")
        demo.append(("priya", "staff123", "approved"))
    if not staff_repo.get("sam"):
        staff_repo.register("sam", "staff123", "Sam", role="staff",
                           status="pending")
        demo.append(("sam", "staff123", "pending"))
    return demo


SAMPLE_INVENTORY = [
    {"name": "Coffee Beans (Arabica)", "quantity": 50, "cost_price": 800, "sale_price": 0},
    {"name": "Milk (Whole, 1L)", "quantity": 30, "cost_price": 60, "sale_price": 0},
    {"name": "Oat Milk (1L)", "quantity": 20, "cost_price": 120, "sale_price": 0},
    {"name": "Sugar Packets", "quantity": 200, "cost_price": 5, "sale_price": 0},
    {"name": "Cups (Medium)", "quantity": 150, "cost_price": 10, "sale_price": 0},
    {"name": "Cups (Large)", "quantity": 100, "cost_price": 15, "sale_price": 0},
    {"name": "Croissant Dough", "quantity": 40, "cost_price": 30, "sale_price": 0},
    {"name": "Avocado", "quantity": 25, "cost_price": 50, "sale_price": 0},
    {"name": "Bread (Sourdough)", "quantity": 15, "cost_price": 40, "sale_price": 0},
    {"name": "Blueberries", "quantity": 10, "cost_price": 120, "sale_price": 0},
]


def seed_inventory():
    for item in SAMPLE_INVENTORY:
        existing = inventory_repo.get(
            item["name"].lower().replace(" ", "-").replace("(", "").replace(")", "")
        )
        if not existing:
            inventory_repo.create(item)


# Starter menu for a NEW tenant: an empty-ish 3-item template the owner can
# edit or delete. Deliberately tiny — no demo orders, no demo staff.
STARTER_MENU = [
    {"id": "starter-tea", "name": "Tea", "category": "tea", "base_price": 150,
     "description": "Freshly brewed, milky tea.", "options": []},
    {"id": "starter-water", "name": "Bottled Water", "category": "cold_drinks",
     "base_price": 200, "description": "Chilled 500 ml bottle.", "options": []},
    {"id": "starter-snack", "name": "Snack Platter", "category": "food",
     "base_price": 450, "description": "Assorted bites of the day.",
     "options": []},
]


def seed_starter_menu():
    created = []
    for item in STARTER_MENU:
        if not menu_repo.get_raw(item["id"]):
            created.append(menu_repo.create(dict(item)))
    return created


def seed_orders():
    """A few of today's orders so the sales dashboard isn't empty."""
    samples = [
        {"items": [{"item_id": "latte", "qty": 2,
                    "selected_options": [{"group": "Size", "label": "Large"},
                                         {"group": "Milk", "label": "Oat"}]}],
         "customer": {"name": "Aisha"}},
        {"items": [{"item_id": "cold-brew", "qty": 1,
                    "selected_options": [{"group": "Size", "label": "Regular"}]},
                   {"item_id": "muffin", "qty": 1, "selected_options": []}],
         "customer": {"name": "Ravi"}},
        {"items": [{"item_id": "espresso", "qty": 1,
                    "selected_options": [{"group": "Size", "label": "Small"},
                                         {"group": "Extras", "label": "Extra shot"}]}],
         "customer": {"name": "Meera"}},
    ]
    created = [orders_repo.create(s, taken_by="owner") for s in samples]
    # mark them collected (with payment) so they count as completed sales
    for o in created:
        orders_repo.update_status(o["id"], "collected", confirm_payment=True)
    return created


def seed_all(slug=None, owner_user=None, owner_password=None):
    """Seed data for `slug` (None => default tenant).

    Default tenant: the full legacy demo (menu, inventory, owner, demo
    staff, collected sample orders) — unchanged from before multi-tenancy.

    Any other tenant: a clean starter only — its 5 tables, DEFAULT_TABLE_COUNT
    tables, one owner account (owner_user/owner_password, defaulting to the
    SEED_ADMIN_* env) and the 3-item template menu. No demo staff, no demo
    orders.

    Returns a dict with at least {tenant, owner_user, owner_password}.
    """
    slug = slug or Config.DEFAULT_TENANT
    with tenancy.tenant_scope(slug):
        if slug == Config.DEFAULT_TENANT:
            seed_menu()
            seed_inventory()
            user, password = seed_owner(owner_user, owner_password)
            staff = seed_staff()
            orders = seed_orders()
            return {
                "tenant": slug,
                "owner_user": user,
                "owner_password": password,
                "staff": staff,
                "orders": len(orders),
            }

        # New tenant: make sure its tables exist even if ensure_infra(slug)
        # was never called (idempotent), then give it a clean starter set.
        ensure_infra(slug)
        tables_repo.ensure_default()
        user, password = seed_owner(owner_user, owner_password)
        items = seed_starter_menu()
        return {
            "tenant": slug,
            "owner_user": user,
            "owner_password": password,
            "staff": [],
            "orders": 0,
            "menu_items": len(items),
            "tables": Config.DEFAULT_TABLE_COUNT,
        }
