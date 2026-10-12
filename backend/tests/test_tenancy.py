"""Multi-tenancy: per-tenant tables, config, auth, public routes, printing.

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network.

Covers:
  * table naming: default tenant keeps legacy names, tenant `b` gets
    `b_orders` etc.; ensure_infra("test_hostel") creates `test_hostel_*`;
  * data isolation: menu/orders/staff/tables/loyalty per tenant;
  * login {"tenant": "bean"} scopes accounts (B owner <-> A owner cannot cross);
  * a B token's authenticated requests hit B's tables;
  * /public/bean/menu, /public/bean/qr, /public/bean/orders, /public/bean/config;
  * unknown tenant -> 404; legacy /public/menu still serves the default;
  * receipts for B carry B's display name/footer (printing.cafe_info).

Run:  python3 tests/test_tenancy.py
"""
import base64
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"
# Legacy QR base — the old /public/qr/<n> must keep encoding exactly this.
os.environ["QR_BASE_URL"] = "https://legacy.example/base"

import boto3  # noqa: E402  (the in-memory stub, path inserted above)

from app import create_app  # noqa: E402
from app.auth import decode_token  # noqa: E402
from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.repositories import loyalty as loyalty_repo  # noqa: E402
from app.repositories import menu as menu_repo  # noqa: E402
from app.repositories import orders as orders_repo  # noqa: E402
from app.repositories import staff as staff_repo  # noqa: E402
from app.repositories import tables as tables_repo  # noqa: E402
from app.repositories import tenants as tenants_repo  # noqa: E402
from app.services import printing  # noqa: E402
from app.tenancy import tenant_scope, tenant_table_name  # noqa: E402
from app.util import ApiError  # noqa: E402
from scripts.create_tenant import main as create_tenant  # noqa: E402

DEFAULT = Config.DEFAULT_TENANT  # "main" (env DEFAULT_TENANT)
STARTER_IDS = {"starter-tea", "starter-water", "starter-snack"}
DEMO_IDS = {"espresso", "latte", "cappuccino", "cold-brew", "chai",
            "croissant", "avocado-toast", "muffin"}
B_BRANDING = {
    "display_name": "Bean House Cafe",
    "kind": "cafe",
    "bill_footer": "Wi-Fi: beanhouse-guest",
}

fails = []


def ok(name, cond, extra=""):
    if not cond:
        fails.append(name)
        print("FAIL:", name, extra)


def bearer(token):
    return {"Authorization": "Bearer " + token}


def table_names():
    return set(boto3._STORE["tables"])


def raises(fn, status):
    """True when fn() raises ApiError with the expected HTTP status."""
    try:
        fn()
    except ApiError as e:
        return e.status == status
    return False


def orders_of(slug):
    with tenant_scope(slug):
        return orders_repo.list_orders()


def main():
    # ------------------------------------------------------------------ #
    # 0. Default tenant + create tenants "bean" (via the CLI script) and
    #    "test_hostel" (via repo + infra/seed functions)
    # ------------------------------------------------------------------ #
    ensure_infra()
    seed_all()

    rc = create_tenant([
        "--slug", "bean", "--name", "Bean House Cafe", "--kind", "cafe",
        "--owner-user", "bowner", "--owner-password", "bsecret123",
        "--gstin", "24BHOUSE0001A1Z5",
        "--address", "4 Park Street, Mumbai 400001",
        "--phone", "+91 90000 00001",
        "--bill-footer", "Wi-Fi: beanhouse-guest",
        "--qr-base-url", "https://bean.example",
        "--kitchen-printer-host", "10.1.2.3",
    ])
    ok("script: create_tenant rc 0", rc == 0, str(rc))

    created = tenants_repo.create(
        slug="test_hostel", display_name="Test Hostel", kind="hostel",
        gstin="24ABCTST0001C1ZV", address="5 Lake View, Udaipur",
        phone="+91 98765 43210")
    ok("registry: created row", created["slug"] == "test_hostel"
       and created["kind"] == "hostel")
    ok("registry: duplicate refused",
       raises(lambda: tenants_repo.create(slug="test_hostel",
                                          display_name="Dup"), 409))
    ok("registry: invalid slug refused",
       raises(lambda: tenants_repo.create(slug="Bad-Slug!",
                                          display_name="Nope"), 400))
    # The mandated slug regex needs 2+ chars: single letters are rejected.
    ok("registry: single-char slug refused",
       raises(lambda: tenants_repo.create(slug="b", display_name="Nope"),
              400))
    ensure_infra("test_hostel")
    seed_all("test_hostel", owner_user="howner", owner_password="hsecret123")

    # ------------------------------------------------------------------ #
    # 1. Table naming rule + ensure_infra output for test_hostel
    # ------------------------------------------------------------------ #
    ok("naming: default tenant unprefixed",
       tenant_table_name(Config.ORDERS_TABLE) == Config.ORDERS_TABLE
       and tenant_table_name(Config.ORDERS_TABLE, DEFAULT)
       == Config.ORDERS_TABLE)
    ok("naming: tenant prefixed",
       tenant_table_name(Config.ORDERS_TABLE, "bean") == "bean_orders"
       and tenant_table_name(Config.ORDERS_TABLE, "test_hostel")
       == "test_hostel_orders")

    hostel_tables = sorted(n for n in table_names()
                           if n.startswith("test_hostel_"))
    for base in ("menu_items", "orders", "staff", "cafe_tables",
                 "inventory_items"):
        name = f"test_hostel_{base}"
        ok(f"infra: {name} created", name in table_names())
    ok("infra: bean tables created",
       {"bean_menu_items", "bean_orders", "bean_staff", "bean_cafe_tables",
        "bean_inventory_items"} <= table_names())
    ok("infra: registry table is global",
       Config.TENANTS_TABLE in table_names()
       and not Config.TENANTS_TABLE.startswith("test_hostel_"))
    print("  ensure_infra('test_hostel') created:", ", ".join(hostel_tables))

    # ------------------------------------------------------------------ #
    # 2. Data isolation (repo level, scoped by tenant_scope)
    # ------------------------------------------------------------------ #
    with tenant_scope(DEFAULT):
        a_menu = {i["id"] for i in menu_repo.list_items()}
        a_orders = [o["id"] for o in orders_repo.list_orders()]
        menu_repo.create({"id": "only-in-a", "name": "Only In A",
                          "base_price": 100})
        a_menu_after = {i["id"] for i in menu_repo.list_items()}
        a_t1 = tables_repo.get("1")
        a_tables = tables_repo.list_all()
        a_staff = [s["username"] for s in staff_repo.list_all()]
    with tenant_scope("bean"):
        b_menu = {i["id"] for i in menu_repo.list_items()}
        b_orders = [o["id"] for o in orders_repo.list_orders()]
        b_tables = tables_repo.list_all()
        b_staff = [s["username"] for s in staff_repo.list_all()]
        tables_repo.occupy("9", "b-locked", taken_by="qr")
        b_t9 = tables_repo.get("9")
    with tenant_scope(DEFAULT):
        a_t9 = tables_repo.get("9")
    with tenant_scope("bean"):
        tables_repo.free("9")
    with tenant_scope("test_hostel"):
        h_menu = {i["id"] for i in menu_repo.list_items()}
        h_orders = orders_repo.list_orders()

    ok("iso: default menu = 8 demo items", len(a_menu) == 8, str(len(a_menu)))
    ok("iso: A item added, absent elsewhere",
       "only-in-a" in a_menu_after and "only-in-a" not in b_menu
       and "only-in-a" not in h_menu)
    ok("iso: B starter menu = 3", b_menu == STARTER_IDS, str(sorted(b_menu)))
    ok("iso: test_hostel starter menu = 3",
       h_menu == STARTER_IDS, str(sorted(h_menu)))
    ok("iso: A has 3 demo orders, B/test_hostel 0",
       len(a_orders) == 3 and b_orders == [] and h_orders == [],
       f"{len(a_orders)}/{len(b_orders)}/{len(h_orders)}")
    ok("iso: 10 floor tables each",
       len(a_tables) == 10 and len(b_tables) == 10)
    ok("iso: occupying B table leaves A alone",
       b_t9["status"] == "occupied" and a_t9["status"] == "empty"
       and a_t1["status"] == "empty")
    ok("iso: staff lists separate",
       "bowner" in b_staff and "owner" not in b_staff
       and "owner" in a_staff and "bowner" not in a_staff)

    # Create an item in B and prove it never shows up in A.
    with tenant_scope("bean"):
        menu_repo.create({"id": "only-in-b", "name": "Only In B",
                          "base_price": 100})
        b_menu_after = {i["id"] for i in menu_repo.list_items()}
    with tenant_scope(DEFAULT):
        a_menu_again = {i["id"] for i in menu_repo.list_items()}
    ok("iso: B item added, absent in A",
       "only-in-b" in b_menu_after and "only-in-b" not in a_menu_again)

    # loyalty (lazy per-tenant table via aws.loyalty_table())
    with tenant_scope("bean"):
        loyalty_repo.adjust("9876543210", 50, "welcome bonus")
        b_bal = loyalty_repo.balance("9876543210")
    with tenant_scope(DEFAULT):
        a_bal_before = loyalty_repo.balance("9876543210")
        loyalty_repo.adjust("9876543210", 25, "demo points")
        a_bal = loyalty_repo.balance("9876543210")
    with tenant_scope("bean"):
        b_bal_after = loyalty_repo.balance("9876543210")
    ok("iso: loyalty balances independent",
       b_bal == 50 and a_bal_before == 0 and a_bal == 25
       and b_bal_after == 50,
       f"{b_bal}/{a_bal_before}/{a_bal}/{b_bal_after}")
    ok("loyalty: per-tenant tables",
       "bean_loyalty_accounts" in table_names()
       and "loyalty_accounts" in table_names()
       and "test_hostel_loyalty_accounts" not in table_names())

    # ------------------------------------------------------------------ #
    # 3. Login scoping
    # ------------------------------------------------------------------ #
    app = create_app()
    c = app.test_client()

    login_a = c.post("/auth/login",
                     json={"username": "owner", "password": "cafe123"})
    ok("login: default tenant 200", login_a.status_code == 200,
       str(login_a.status_code))
    a_json = login_a.get_json()
    a_token = a_json["token"]
    ah = bearer(a_token)
    ok("login: default tenant claim",
       decode_token(a_token).get("tenant") == DEFAULT,
       str(decode_token(a_token)))
    ok("login: response carries tenant", a_json.get("tenant") == DEFAULT)

    login_b = c.post("/auth/login", json={
        "username": "bowner", "password": "bsecret123", "tenant": "bean"})
    ok("login: B owner 200", login_b.status_code == 200,
       str(login_b.status_code) + str(login_b.get_json()))
    b_json = login_b.get_json()
    bh = bearer(b_json["token"])
    ok("login: B token claim tenant=b",
       decode_token(b_json["token"]).get("tenant") == "bean")

    ok("login: A owner rejected in B",
       c.post("/auth/login", json={"username": "owner",
                                   "password": "cafe123",
                                   "tenant": "bean"}).status_code == 401)
    ok("login: B owner rejected in default tenant",
       c.post("/auth/login", json={"username": "bowner",
                                   "password": "bsecret123"}).status_code == 401)
    ok("login: unknown tenant 404",
       c.post("/auth/login", json={"username": "bowner",
                                   "password": "bsecret123",
                                   "tenant": "ghost"}).status_code == 404)
    ok("login: malformed tenant 400",
       c.post("/auth/login", json={"username": "bowner",
                                   "password": "bsecret123",
                                   "tenant": "Bad Slug"}).status_code == 400)

    login_h = c.post("/auth/login", json={
        "username": "howner", "password": "hsecret123",
        "tenant": "test_hostel"})
    ok("login: test_hostel owner 200", login_h.status_code == 200,
       str(login_h.status_code))

    # ------------------------------------------------------------------ #
    # 4. A B token's authenticated requests hit B's tables
    # ------------------------------------------------------------------ #
    b_tables_http = c.get("/tables", headers=bh).get_json()
    ok("b token: B's 10 tables, all empty",
       len(b_tables_http) == 10
       and all(t["status"] == "empty" for t in b_tables_http),
       str(len(b_tables_http)))
    # GET /menu carries NO guard, so it serves the default tenant for
    # everyone (a stray bearer token is ignored); B's customer menu lives
    # at /public/bean/menu, B's staff menu comes from guarded routes.
    b_menu_http = c.get("/menu", headers=bh).get_json()
    ok("GET /menu: unguarded -> default tenant for all",
       {i["id"] for i in b_menu_http} == DEMO_IDS | {"only-in-a"},
       str(sorted(i["id"] for i in b_menu_http)))
    a_menu_http = c.get("/menu").get_json()
    ok("default /menu still A's data",
       {i["id"] for i in a_menu_http} == DEMO_IDS | {"only-in-a"},
       str(sorted(i["id"] for i in a_menu_http)))

    b_staff_http = c.get("/admin/staff", headers=bh).get_json()
    ok("b token: staff list is B's",
       [s["username"] for s in b_staff_http] == ["bowner"],
       str(b_staff_http))
    a_staff_http = c.get("/admin/staff", headers=ah).get_json()
    ok("a token: staff list is A's",
       any(s["username"] == "owner" for s in a_staff_http)
       and all(s["username"] != "bowner" for s in a_staff_http))

    # Guarded report route: B's token reads B's orders table (0 orders),
    # A's token reads A's (3 seeded demo orders) — same URL, other data.
    a_daily = c.get("/admin/reports/daily", headers=ah).get_json()
    b_daily = c.get("/admin/reports/daily", headers=bh).get_json()
    ok("b token: reports read B's orders table",
       b_daily.get("order_count") == 0 and a_daily.get("order_count") == 3,
       f"{b_daily.get('order_count')}/{a_daily.get('order_count')}")

    # An order taken with the B token lands in B's orders and tables.
    b_order = c.post("/orders", headers=bh, json={
        "table_number": 2,
        "items": [{"item_id": "starter-tea", "qty": 2,
                   "selected_options": []}],
    })
    ok("b token: order 201 (B's menu item exists)", b_order.status_code == 201,
       str(b_order.status_code) + str(b_order.get_json()))
    b_order_id = (b_order.get_json() or {}).get("id")
    with tenant_scope("bean"):
        b_order_ids = [o["id"] for o in orders_repo.list_orders()]
        b_t2 = tables_repo.get("2")
    with tenant_scope(DEFAULT):
        a_order_ids = [o["id"] for o in orders_repo.list_orders()]
        a_t2 = tables_repo.get("2")
    ok("b token: order isolated in B",
       b_order_id in b_order_ids and b_order_id not in a_order_ids
       and b_t2["status"] == "occupied" and a_t2["status"] == "empty")
    ok("a token: cannot read B's order",
       c.get(f"/orders/{b_order_id}", headers=ah).status_code == 404)
    ok("b token: can read its own order",
       c.get(f"/orders/{b_order_id}", headers=bh).status_code == 200)

    # ------------------------------------------------------------------ #
    # 5. Public tenant-scoped routes
    # ------------------------------------------------------------------ #
    pub_b = c.get("/public/bean/menu")
    ok("public b: 200", pub_b.status_code == 200, str(pub_b.status_code))
    b_ids = {m["id"] for m in pub_b.get_json()}
    ok("public b: B's menu only",
       STARTER_IDS | {"only-in-b"} <= b_ids
       and "only-in-a" not in b_ids and "latte" not in b_ids,
       str(sorted(b_ids)))

    # B owner adds an item over HTTP -> shows up in /public/bean/menu only.
    made = c.post("/admin/menu", headers=bh, json={
        "name": "Hostel Special", "category": "food", "base_price": 600})
    ok("b token: menu create 201", made.status_code == 201,
       str(made.status_code) + str(made.get_json()))
    made_id = (made.get_json() or {}).get("id")
    b_ids = {m["id"] for m in c.get("/public/bean/menu").get_json()}
    a_ids = {m["id"] for m in c.get("/public/menu").get_json()}
    ok("public b: sees B's new item", made_id in b_ids, str(sorted(b_ids)))
    ok("public default: does not see B's item", made_id not in a_ids,
       str(sorted(a_ids)))

    cfg_b = c.get("/public/bean/config")
    ok("public b config: 200", cfg_b.status_code == 200,
       str(cfg_b.status_code))
    cfg = cfg_b.get_json()
    ok("public b config: branding", cfg == B_BRANDING, str(cfg))
    ok("public b config: no printer/config leak",
       "kitchen_printer_host" not in cfg
       and set(cfg) <= {"display_name", "kind", "bill_footer"})
    cfg_main = c.get(f"/public/{DEFAULT}/config").get_json()
    ok("public default config: env branding",
       cfg_main.get("display_name") == Config.CAFE_NAME, str(cfg_main))

    ok("public ghost: 404 menu",
       c.get("/public/ghost/menu").status_code == 404)
    ok("public ghost: 404 config",
       c.get("/public/ghost/config").status_code == 404)
    ok("public ghost: 404 order post",
       c.post("/public/ghost/orders", json={}).status_code == 404)
    ok("public bad slug: 404",
       c.get("/public/Bad-Slug/menu").status_code == 404)
    ok("public bad slug: 404 orders",
       c.post("/public/Bad-Slug/orders", json={}).status_code == 404)

    # QR encoding: legacy path unchanged, scoped path tenant-aware.
    legacy_qr = c.get("/public/qr/3?format=json").get_json()
    ok("qr legacy: unchanged URL",
       legacy_qr["url"] == "https://legacy.example/base/table/3",
       str(legacy_qr))
    b_qr = c.get("/public/bean/qr/1?format=json").get_json()
    ok("qr scoped: tenant qr_base_url wins",
       b_qr["url"] == "https://bean.example/t/bean/table/1", str(b_qr))
    h_qr = c.get("/public/test_hostel/qr/5?format=json").get_json()
    ok("qr scoped: falls back to QR_BASE_URL env",
       h_qr["url"] == "https://legacy.example/base/t/test_hostel/table/5",
       str(h_qr))
    ok("qr scoped: png",
       c.get("/public/bean/qr/1").headers.get("Content-Type") == "image/png")
    ok("qr scoped: unknown table 404",
       c.get("/public/bean/qr/42").status_code == 404)
    ok("qr legacy: unknown table still 404",
       c.get("/public/qr/42").status_code == 404)

    # ------------------------------------------------------------------ #
    # 6. QR order flow in B: auto-occupy + attach-to-occupied (as legacy)
    # ------------------------------------------------------------------ #
    payload = {
        "table_number": 1,
        "items": [{"item_id": "starter-tea", "qty": 1,
                   "selected_options": []}],
        "customer": {"name": "QR Guest", "phone": "9876500001"},
    }
    r1 = c.post("/public/bean/orders", json=payload)
    ok("qr b: order 201", r1.status_code == 201,
       str(r1.status_code) + str(r1.get_json()))
    qr_order = r1.get_json()
    ok("qr b: repriced server-side, source=qr",
       qr_order.get("total") == 150 and qr_order.get("source") == "qr"
       and qr_order.get("taken_by") == "qr", str(qr_order))
    with tenant_scope("bean"):
        b_t1 = tables_repo.get("1")
        b_ids = [o["id"] for o in orders_repo.list_orders()]
    with tenant_scope(DEFAULT):
        a_t1 = tables_repo.get("1")
        a_ids = [o["id"] for o in orders_repo.list_orders()]
    ok("qr b: free B table auto-occupied",
       b_t1["status"] == "occupied" and b_t1["order_id"] == qr_order["id"])
    ok("qr b: A's table 1 untouched", a_t1["status"] == "empty")
    ok("qr b: order lives in B only",
       qr_order["id"] in b_ids and qr_order["id"] not in a_ids)

    r2 = c.post("/public/bean/orders", json={
        **payload, "customer": {"name": "Second Guest",
                                "phone": "9876500002"}})
    ok("qr b: occupied table attaches (201, no 409)",
       r2.status_code == 201, str(r2.status_code))
    with tenant_scope("bean"):
        b_t1_after = tables_repo.get("1")
    ok("qr b: lock untouched by attached order",
       b_t1_after["order_id"] == qr_order["id"], str(b_t1_after))

    track = c.get(f"/public/bean/orders/{qr_order['id']}")
    ok("qr b: tracking 200", track.status_code == 200
       and track.get_json()["status"] == "received", str(track.get_json()))
    ok("qr b: tracking unknown order 404",
       c.get("/public/bean/orders/NOPE0000").status_code == 404)
    ok("qr legacy: default tenant cannot see B's order",
       c.get(f"/public/orders/{qr_order['id']}").status_code == 404)
    ok("qr legacy: default tenant tracking still works",
       c.get(f"/public/orders/{a_orders[0]}").status_code == 200)

    # ------------------------------------------------------------------ #
    # 7. Printing: receipts carry the tenant's own identity
    # ------------------------------------------------------------------ #
    with tenant_scope("bean"):
        b_info = printing.cafe_info()
        kh = printing.kitchen_printer_host()
    ok("cafe_info: tenant registry first",
       b_info["name"] == B_BRANDING["display_name"]
       and b_info["address"].startswith("4 Park Street")
       and b_info["gstin"] == "24BHOUSE0001A1Z5"
       and b_info["bill_footer"] == B_BRANDING["bill_footer"], str(b_info))
    a_info = printing.cafe_info()
    ok("cafe_info: default falls back to env/registry",
       a_info["name"] == Config.CAFE_NAME, str(a_info))
    ok("kitchen printer: tenant host wins", kh == "10.1.2.3", str(kh))

    r = c.get(f"/printing/receipt/{b_order_id}/bytes", headers=bh)
    ok("b receipt: 200", r.status_code == 200, str(r.status_code))
    if r.status_code == 200:
        data = base64.b64decode(r.get_json()["bytes_b64"], validate=True)
        ok("b receipt: B display name", b"Bean House Cafe" in data)
        ok("b receipt: B address + gstin",
           b"4 Park Street" in data and b"24BHOUSE0001A1Z5" in data)
        ok("b receipt: B bill footer", b"Wi-Fi: beanhouse-guest" in data)
        ok("b receipt: no default cafe branding",
           b"Cafe POS Demo" not in data)

    r_a = c.get(f"/printing/receipt/{a_orders[0]}/bytes", headers=ah)
    ok("a receipt: 200", r_a.status_code == 200, str(r_a.status_code))
    if r_a.status_code == 200:
        a_data = base64.b64decode(r_a.get_json()["bytes_b64"], validate=True)
        ok("a receipt: default cafe name, no B branding",
           Config.CAFE_NAME.encode() in a_data
           and b"Bean House Cafe" not in a_data)

    # ------------------------------------------------------------------ #
    # 8. Menu image keys are tenant-prefixed in the shared bucket
    # ------------------------------------------------------------------ #
    up = c.post(f"/admin/menu/{made_id}/image", headers=bh,
                content_type="multipart/form-data",
                data={"file": (io.BytesIO(b"\xff\xd8\xff\xd9"), "dish.jpg")})
    ok("image upload: 200", up.status_code == 200,
       str(up.status_code) + str(up.get_json()))
    if up.status_code == 200:
        ok("image upload: tenant-prefixed key",
           (up.get_json() or {}).get("image_key", "").startswith("bean/menu/"),
           str(up.get_json()))

    # ------------------------------------------------------------------ #
    # 9. test_hostel: clean starter tenant, fully isolated
    # ------------------------------------------------------------------ #
    h_pub = c.get("/public/test_hostel/menu").get_json()
    ok("test_hostel public menu: starter only",
       {m["id"] for m in h_pub} == STARTER_IDS,
       str(sorted(m["id"] for m in h_pub)))
    h_cfg = c.get("/public/test_hostel/config").get_json()
    ok("test_hostel config: branding",
       h_cfg == {"display_name": "Test Hostel", "kind": "hostel",
                 "bill_footer": ""}, str(h_cfg))
    ok("test_hostel: no demo orders", len(orders_of("test_hostel")) == 0)
    ok("test_hostel: isolated from B",
       "only-in-b" not in {m["id"] for m in h_pub}
       and "Hostel Special" not in {m["name"] for m in h_pub})

    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        sys.exit(1)
    print("\nALL TENANCY CHECKS PASSED")
    print(f"  default tenant '{DEFAULT}': legacy table names "
          f"({Config.ORDERS_TABLE}, {Config.MENU_TABLE}, ...)")
    print("  tenant bean      : bean_orders, bean_menu_items, bean_staff, "
          "bean_cafe_tables, bean_inventory_items, bean_loyalty_accounts")
    print("  ensure_infra('test_hostel') created: " + ", ".join(hostel_tables))
    print("  JWT tenant claim scopes every authenticated request; "
          "/public/<slug>/* serves per-tenant data + branding")


if __name__ == "__main__":
    main()
