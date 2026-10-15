"""Platform-admin feature checks: separate admin login, cross-cafe list,
cafe creation, act-as-owner, and the tenant-scoped cache fix.

Mirrors tests/test_cafe_profile.py's offline harness (in-memory boto3 stub +
Flask test client). Needs a reachable Redis for the cache-isolation check.
Run: REDIS_URL=redis://127.0.0.1:6379/3 python3 tests/test_platform_admin.py
"""
import base64  # noqa: F401  (kept for parity with the cafe-profile harness)
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ.pop("ESCPOS_PRINTER_HOST", None)
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"
os.environ["PLATFORM_ADMIN_USER"] = "admin"
os.environ["PLATFORM_ADMIN_PASSWORD"] = "admin@2026"
os.environ.setdefault("REDIS_URL", "redis://127.0.0.1:6379/3")

from app import create_app                       # noqa: E402
from app.cache import cache_get, cache_set, get_redis  # noqa: E402
from app.infra import ensure_infra, seed_all     # noqa: E402
from app.tenancy import tenant_scope             # noqa: E402


def main():
    get_redis().flushdb()  # start clean so a prior run can't poison results
    ensure_infra()
    seed_all()
    app = create_app()
    c = app.test_client()

    fails = []

    def ok(name, cond, extra=""):
        if not cond:
            fails.append(name)
            print("FAIL:", name, extra)

    # --- 1. Separate platform-admin login ---
    adm = c.post("/auth/login",
                 json={"username": "admin", "password": "admin@2026"}).get_json()
    ok("admin login role=admin", adm.get("role") == "admin", str(adm))
    ok("admin token issued", bool(adm.get("token")))
    ah = {"Authorization": "Bearer " + adm["token"]}

    # Wrong password must NOT fall through to a cafe account.
    bad = c.post("/auth/login",
                 json={"username": "admin", "password": "wrongpass"})
    ok("admin wrong password -> 401", bad.status_code == 401,
       str(bad.status_code))

    # --- 2. A cafe owner token is rejected on platform routes ---
    owner = c.post("/auth/login",
                   json={"username": "owner", "password": "cafe123"}).get_json()
    oh = {"Authorization": "Bearer " + owner["token"]}
    r = c.get("/platform/tenants", headers=oh)
    ok("owner rejected on /platform/tenants (403)", r.status_code == 403,
       str(r.status_code))

    # --- 3. Admin lists cafes (default cafe present, with a P&L block) ---
    listing = c.get("/platform/tenants", headers=ah).get_json()
    slugs = [x["slug"] for x in listing.get("cafes", [])]
    ok("list has default cafe 'main'", "main" in slugs, str(slugs))
    ok("list count matches", listing.get("count") == len(slugs))

    # --- 4. Create a brand-new cafe with an owner account ---
    created = c.post("/platform/tenants", headers=ah, json={
        "slug": "bistro", "display_name": "Bistro One",
        "owner_name": "Nita Rao", "owner_username": "bistro_owner",
        "owner_password": "bistro123", "gstin": "24AAA1111B1Z1",
        "pan": "AAAAA1111A", "shop_license": "LIC-1",
    })
    ok("create cafe -> 201", created.status_code == 201,
       str(created.status_code))
    body = created.get_json()
    ok("create returns owner_user", body.get("owner_user") == "bistro_owner",
       str(body))

    # New owner logs in scoped to bistro.
    bh = None
    blogin = c.post("/auth/login", json={
        "username": "bistro_owner", "password": "bistro123",
        "tenant": "bistro"}).get_json()
    ok("new owner login role=owner", blogin.get("role") == "owner", str(blogin))
    ok("new owner tenant=bistro", blogin.get("tenant") == "bistro")
    bh = {"Authorization": "Bearer " + blogin["token"]}

    # It sees its OWN cafe profile, not the default's.
    prof = c.get("/admin/cafe/profile", headers=bh).get_json()
    ok("bistro owner sees own profile", prof.get("display_name") == "Bistro One",
       str(prof))

    # --- 5. Duplicate slug refused ---
    dup = c.post("/platform/tenants", headers=ah, json={
        "slug": "bistro", "display_name": "Dup",
        "owner_username": "abc", "owner_password": "abcdef"})
    ok("duplicate slug -> 409", dup.status_code == 409, str(dup.status_code))

    # --- 6. act-as: admin gets a full owner token for bistro ---
    act = c.post("/platform/tenants/bistro/act-as", headers=ah).get_json()
    ok("act-as role=owner", act.get("role") == "owner", str(act))
    ok("act-as tenant=bistro", act.get("tenant") == "bistro")
    xh = {"Authorization": "Bearer " + act["token"]}
    xp = c.get("/admin/cafe/profile", headers=xh).get_json()
    ok("act-as token opens bistro as owner",
       xp.get("display_name") == "Bistro One", str(xp))

    # --- 7. Cache isolation regression (tenant-scoped keys) ---
    with tenant_scope("main"):
        cache_set("iso:test", ["main-row"])
    with tenant_scope("bistro"):
        leaked = cache_get("iso:test")
    ok("cache NOT leaked across tenants", leaked is None, str(leaked))
    with tenant_scope("main"):
        ok("cache hit within same tenant",
           cache_get("iso:test") == ["main-row"])

    # --- 8. P&L isolation through the endpoint ---
    # Give 'main' a fresh order, then confirm bistro's P&L stays at 0 even
    # though both share the same date (this is the bug the cache fix repairs).
    c.post("/orders", headers=oh, json={"items": [{"item_id": "croissant",
                                                   "qty": 1}]})
    main_pl = c.get("/platform/tenants/main", headers=ah).get_json().get("pnl") or {}
    bist_pl = c.get("/platform/tenants/bistro", headers=ah).get_json().get("pnl") or {}
    ok("main P&L has revenue", (main_pl.get("revenue") or 0) > 0, str(main_pl))
    ok("bistro P&L isolated (0 revenue)", (bist_pl.get("revenue") or 0) == 0,
       str(bist_pl))

    if fails:
        print(f"\n{len(fails)} FAILED")
        sys.exit(1)
    print("ALL PLATFORM-ADMIN CHECKS PASSED")


if __name__ == "__main__":
    main()
