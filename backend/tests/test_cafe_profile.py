"""Focused check for the cafe-profile feature (owner/GST/PAN/licence on bills).

Mirrors tests/test_printing_config.py's offline harness (in-memory boto3 stub +
Flask test client) but exercises only the new GET/PUT /admin/cafe/profile routes and
the receipt header that renders them. Run: python3 tests/_cafe_profile_check.py
"""
import base64
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

from app import create_app            # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402


def main():
    ensure_infra()
    seed_all()
    app = create_app()
    c = app.test_client()

    owner = c.post("/auth/login",
                   json={"username": "owner", "password": "cafe123"}).get_json()
    h = {"Authorization": "Bearer " + owner["token"]}

    fails = []

    def ok(name, cond, extra=""):
        if not cond:
            fails.append(name)
            print("FAIL:", name, extra)

    # 1. GET starts with the env-fallback GSTIN and empty new fields.
    prof = c.get("/admin/cafe/profile", headers=h).get_json()
    ok("profile GET 200", isinstance(prof, dict), str(prof))
    ok("has display_name key", "display_name" in prof)
    ok("has owner_name key", "owner_name" in prof)
    ok("has pan key", "pan" in prof)
    ok("has shop_license key", "shop_license" in prof)

    # 2. PUT new business identity.
    payload = {
        "display_name": "GTS Cafe",
        "owner_name": "Ravi Patel",
        "gstin": "24ABCDE1234F1Z5",
        "pan": "BXPP1234A",
        "shop_license": "FSSAI-112233445566",
        "address": "1 MG Road, Ahmedabad",
        "phone": "+91 98765 43210",
        "bill_footer": "WiFi: GTSCAFE",
    }
    saved = c.put("/admin/cafe/profile", headers=h, json=payload).get_json()
    ok("PUT owner_name saved", saved.get("owner_name") == "Ravi Patel", str(saved))
    ok("PUT pan saved", saved.get("pan") == "BXPP1234A")
    ok("PUT shop_license saved", saved.get("shop_license") == "FSSAI-112233445566")

    # 3. GET reflects the save.
    prof2 = c.get("/admin/cafe/profile", headers=h).get_json()
    ok("GET shows saved owner", prof2.get("owner_name") == "Ravi Patel")
    ok("GET shows saved licence", prof2.get("shop_license") == "FSSAI-112233445566")

    # 4. Unknown field is rejected (400).
    bad = c.put("/admin/cafe/profile", headers=h, json={"hacker": "x"})
    ok("PUT unknown field -> 4xx", bad.status_code >= 400, str(bad.status_code))

    # 5. Place an order and confirm the receipt prints the new identity.
    order = c.post("/orders", headers=h,
                   json={"items": [{"item_id": "croissant", "qty": 1}]}).get_json()
    oid = order["id"]
    r = c.get(f"/printing/receipt/{oid}/bytes", headers=h).get_json()
    raw = base64.b64decode(r["bytes_b64"])
    text = "".join(chr(b) if 32 <= b < 127 or b == 10 else "" for b in raw)
    ok("receipt has cafe name", "GTS Cafe" in text, text)
    ok("receipt has Prop owner", "Prop: Ravi Patel" in text)
    ok("receipt has GSTIN", "GSTIN: 24ABCDE1234F1Z5" in text)
    ok("receipt has PAN", "PAN: BXPP1234A" in text)
    ok("receipt has Licence", "Licence: FSSAI-112233445566" in text)
    ok("receipt has footer", "WiFi: GTSCAFE" in text)
    ok("receipt price still 2.50", "2.50" in text)

    if fails:
        print(f"\n{len(fails)} FAILED")
        sys.exit(1)
    print("ALL CAFE-PROFILE CHECKS PASSED")
    print("---- sample receipt ----")
    print(text)


if __name__ == "__main__":
    main()
