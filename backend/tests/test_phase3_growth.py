"""Phase 3 — Growth hooks: QR table ordering, loyalty points, Swiggy/Zomato
ingestion, per-staff sales report.

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network, no printer.

Run:  python3 tests/test_phase3_growth.py
"""
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
# Integration webhook secrets (Config reads the environment at import time,
# so these must be set before `from app import ...`).
os.environ["SWIGGY_API_KEY"] = "test-swiggy-key"
os.environ["ZOMATO_API_KEY"] = "test-zomato-key"
# Loyalty economics: 1 point per ₹1, 1 point = ₹1 (100 paise).
os.environ["LOYALTY_EARN_RATE"] = "1"
os.environ["LOYALTY_POINT_VALUE_PAISE"] = "100"
os.environ["QR_BASE_URL"] = "https://cafe.example/table-base"

from app import create_app  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def main():
    ensure_infra()
    seed_all()

    app = create_app()
    c = app.test_client()
    fails = []

    def ok(name, cond, extra=""):
        if not cond:
            fails.append(name)
            print("FAIL:", name, extra)

    def bearer(token):
        return {"Authorization": "Bearer " + token}

    owner = c.post("/auth/login",
                   json={"username": "owner", "password": "cafe123"}).get_json()
    oauth = bearer(owner["token"])
    staff = c.post("/auth/login",
                   json={"username": "priya", "password": "staff123"}).get_json()
    sauth = bearer(staff["token"])

    # ------------------------------------------------------------------ #
    # 1. Public menu (no auth, available items only)
    # ------------------------------------------------------------------ #
    resp = c.get("/public/menu")
    ok("public menu: 200 without auth", resp.status_code == 200,
       str(resp.status_code))
    menu = resp.get_json()
    ok("public menu: non-empty", isinstance(menu, list) and len(menu) >= 8)
    sample = menu[0]
    ok("public menu: fields",
       all(k in sample for k in ("id", "name", "price", "category",
                                 "gst_rate", "options")),
       str(sample))
    ok("public menu: price mirrors base_price",
       all(m["price"] == m["base_price"] for m in menu))
    ok("public menu: gst_rate present",
       all(isinstance(m["gst_rate"], int) for m in menu))

    # an unavailable item disappears from the customer menu
    c.patch("/admin/menu/muffin/availability", headers=oauth,
            json={"available": False})
    ok("public menu: hides unavailable",
       all(m["id"] != "muffin" for m in c.get("/public/menu").get_json()))
    c.patch("/admin/menu/muffin/availability", headers=oauth,
            json={"available": True})

    # ------------------------------------------------------------------ #
    # 2. Table QR PNG
    # ------------------------------------------------------------------ #
    qr = c.get("/public/qr/3")
    ok("qr: 200", qr.status_code == 200, str(qr.status_code))
    ok("qr: png content type", qr.headers["Content-Type"] == "image/png",
       qr.headers.get("Content-Type", ""))
    body = qr.get_data()
    ok("qr: png magic bytes", body.startswith(PNG_MAGIC), repr(body[:8]))
    ok("qr: png is a real image", len(body) > 400, str(len(body)))

    qrj = c.get("/public/qr/3?format=json").get_json()
    ok("qr: json url", qrj["url"] == "https://cafe.example/table-base/table/3",
       str(qrj))
    ok("qr: unknown table 404", c.get("/public/qr/42").status_code == 404)

    # ------------------------------------------------------------------ #
    # 3. QR order on a FREE table -> occupies it (like a staff order)
    # ------------------------------------------------------------------ #
    def table(number):
        return next(t for t in c.get("/tables", headers=sauth).get_json()
                    if t["number"] == str(number))

    ok("qr order: table 4 starts empty", table(4)["status"] == "empty")

    qr_payload = {
        "table_number": 4,
        "items": [{"item_id": "croissant", "qty": 1, "selected_options": []}],
        "customer": {"name": "QR Guest", "phone": "9876500002"},
    }
    r = c.post("/public/orders", json=qr_payload)
    ok("qr order: 201", r.status_code == 201,
       str(r.status_code) + str(r.get_json()))
    qr_order = r.get_json()
    ok("qr order: source=qr", qr_order["source"] == "qr")
    ok("qr order: taken_by=qr", qr_order["taken_by"] == "qr")
    ok("qr order: table linked", qr_order["table_number"] == "4")
    ok("qr order: starts unpaid",
       qr_order["payment_status"] == "unpaid" and qr_order["status"] == "received")
    ok("qr order: repriced by server", qr_order["total"] == 250,
       str(qr_order["total"]))

    t4 = table(4)
    ok("qr order: free table occupied", t4["status"] == "occupied")
    ok("qr order: table locked to this order", t4["order_id"] == qr_order["id"])
    ok("qr order: table taken_by qr", t4["taken_by"] == "qr")

    # the existing staff double-booking guard still applies
    blocked = c.post("/orders", headers=sauth, json={
        "table_number": 4,
        "items": [{"item_id": "muffin", "qty": 1, "selected_options": []}],
    })
    ok("qr order: staff double-booking still 409", blocked.status_code == 409,
       str(blocked.status_code))

    # validation: table_number / customer required
    ok("qr order: missing table 400",
       c.post("/public/orders", json={"items": qr_payload["items"],
                                      "customer": qr_payload["customer"]}
              ).status_code == 400)
    ok("qr order: unknown table 404",
       c.post("/public/orders", json={**qr_payload, "table_number": 42}
              ).status_code == 404)
    ok("qr order: phone required 400",
       c.post("/public/orders", json={
           "table_number": 4,
           "items": qr_payload["items"],
           "customer": {"name": "No Phone"}},
           ).status_code == 400)

    # ------------------------------------------------------------------ #
    # 4. QR order on an OCCUPIED table -> linked, lock untouched
    # ------------------------------------------------------------------ #
    r2 = c.post("/public/orders", json={
        **qr_payload,
        "customer": {"name": "Second Guest", "phone": "9876500004"},
    })
    ok("occupied qr: still 201 (no 409)", r2.status_code == 201,
       str(r2.status_code) + str(r2.get_json()))
    second = r2.get_json()
    ok("occupied qr: linked to the same table", second["table_number"] == "4")
    t4b = table(4)
    ok("occupied qr: lock NOT stolen", t4b["order_id"] == qr_order["id"],
       str(t4b))
    ok("occupied qr: lock taken_by unchanged", t4b["taken_by"] == "qr")

    # collecting the non-owner QR order must not free the table
    c.patch(f"/orders/{second['id']}/status", headers=sauth,
            json={"status": "collected", "paid": True, "payment_method": "upi"})
    t4c = table(4)
    ok("occupied qr: table stays locked for owner order",
       t4c["status"] == "occupied" and t4c["order_id"] == qr_order["id"],
       str(t4c))

    # the order that owns the lock frees it on collect
    c.patch(f"/orders/{qr_order['id']}/status", headers=sauth,
            json={"status": "collected", "paid": True, "payment_method": "cash"})
    ok("occupied qr: owner order frees table", table(4)["status"] == "empty")

    # ------------------------------------------------------------------ #
    # 5. Public status lookup (customer tracking)
    # ------------------------------------------------------------------ #
    track = c.post("/public/orders", json={
        "table_number": 5,
        "items": [{"item_id": "muffin", "qty": 2, "selected_options": []}],
        "customer": {"name": "Tracker", "phone": "9876500005"},
    }).get_json()
    st = c.get(f"/public/orders/{track['id']}")
    ok("public status: 200", st.status_code == 200, str(st.status_code))
    sj = st.get_json()
    ok("public status: status field", sj["status"] == "received")
    ok("public status: items present",
       len(sj["items"]) == 1 and sj["items"][0]["name"] == "Blueberry Muffin")
    ok("public status: total", sj["total"] == 520, str(sj["total"]))
    ok("public status: no payment internals",
       "payments" not in sj and "paid_amount" not in sj)
    ok("public status: 404 unknown",
       c.get("/public/orders/ZZZZZZ").status_code == 404)
    # free table 5 again so later sections see a clean slate
    c.patch(f"/orders/{track['id']}/status", headers=sauth,
            json={"status": "collected", "paid": True})
    ok("public status: table freed on collect", table(5)["status"] == "empty")

    # ------------------------------------------------------------------ #
    # 6. Loyalty: earn on collect
    # ------------------------------------------------------------------ #
    loyalty_phone = "9876511111"
    earn_order = c.post("/orders", headers=sauth, json={
        "table_number": 1,
        "customer": {"name": "Loyal", "phone": loyalty_phone},
        "items": [{"item_id": "croissant", "qty": 1, "selected_options": []}],
    }).get_json()  # 250 paise = Rs 2.50 -> floor 2 points
    ok("loyalty earn: staff order is source=counter",
       earn_order["source"] == "counter", str(earn_order.get("source")))

    before = c.get(f"/loyalty/{loyalty_phone}", headers=sauth).get_json()
    ok("loyalty lookup: staff allowed", before["points"] == 0,
       str(before))
    ok("loyalty lookup: no auth -> 401",
       c.get(f"/loyalty/{loyalty_phone}").status_code == 401)

    col = c.patch(f"/orders/{earn_order['id']}/status", headers=sauth,
                  json={"status": "collected", "paid": True,
                        "payment_method": "cash"})
    ok("loyalty earn: collect 200", col.status_code == 200,
       str(col.status_code) + str(col.get_json()))
    acct = c.get(f"/loyalty/{loyalty_phone}", headers=sauth).get_json()
    ok("loyalty earn: 250 paise -> 2 points", acct["points"] == 2,
       str(acct))
    ok("loyalty earn: ledger entry",
       acct["ledger"] and acct["ledger"][0]["reason"] == f"earned {earn_order['id']}",
       str(acct["ledger"][:1]))
    ok("loyalty earn: ledger delta", acct["ledger"][0]["delta"] == 2)

    # a retried collect must not earn twice
    c.patch(f"/orders/{earn_order['id']}/status", headers=sauth,
            json={"status": "collected", "paid": True, "payment_method": "cash"})
    acct2 = c.get(f"/loyalty/{loyalty_phone}", headers=sauth).get_json()
    ok("loyalty earn: no double earn on retry", acct2["points"] == 2,
       str(acct2["points"]))

    # phone normalisation: +91 prefix addresses the same account
    intl = c.get("/loyalty/+919876511111", headers=sauth).get_json()
    ok("loyalty lookup: +91 normalised", intl["points"] == 2, str(intl))

    # ------------------------------------------------------------------ #
    # 7. Loyalty: redemption validation + payment row
    # ------------------------------------------------------------------ #
    def take_order(item_id, qty=1, options=None, phone=loyalty_phone, table=None):
        return c.post("/orders", headers=sauth, json={
            **({"table_number": table} if table else {}),
            "customer": {"name": "Redeemer", "phone": phone},
            "items": [{"item_id": item_id, "qty": qty,
                       "selected_options": options or []}],
        }).get_json()

    # (a) insufficient balance -> 400, order untouched
    short = take_order("muffin")  # 260 paise, balance is 2
    r = c.patch(f"/orders/{short['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True, "redeem_points": 3})
    ok("redeem: insufficient balance 400", r.status_code == 400,
       str(r.status_code) + str(r.get_json()))
    ok("redeem: error mentions balance",
       "points available" in (r.get_json() or {}).get("error", ""),
       str(r.get_json()))
    still = c.get(f"/orders/{short['id']}", headers=sauth).get_json()
    ok("redeem: failed collect left order open",
       still["status"] == "received" and still["payment_status"] == "unpaid")

    # (b) a loyalty payment row without redeem_points is rejected
    r = c.patch(f"/orders/{short['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "loyalty", "amount": 260}]})
    ok("redeem: bare loyalty row 400", r.status_code == 400,
       str(r.status_code) + str(r.get_json()))

    # (c) valid redemption with an explicit split (cash + loyalty)
    points_before = c.get(f"/loyalty/{loyalty_phone}",
                          headers=sauth).get_json()["points"]
    redeem_order = take_order("chai",
                              options=[{"group": "Size", "label": "Regular"}])
    ok("redeem: chai due 270", redeem_order["total"] == 270,
       str(redeem_order["total"]))
    r = c.patch(f"/orders/{redeem_order['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True, "redeem_points": 2,
        "payments": [{"method": "cash", "amount": 70},
                     {"method": "loyalty", "amount": 200}]})
    ok("redeem: valid split 200", r.status_code == 200,
       str(r.status_code) + str(r.get_json()))
    paid = r.get_json()
    ok("redeem: loyalty row stored",
       {"method": "loyalty", "amount": 200} in paid.get("payments", []),
       str(paid.get("payments")))
    ok("redeem: primary method stays cash", paid["payment_method"] == "cash")
    ok("redeem: paid in full", paid["payment_status"] == "paid"
       and paid["paid_amount"] == 270)
    points_after = c.get(f"/loyalty/{loyalty_phone}",
                         headers=sauth).get_json()["points"]
    # -2 redeemed + floor(270/100) = 2 earned on this collect
    ok("redeem: balance -redeem +earn",
       points_after == points_before - 2 + 2,
       f"{points_before} -> {points_after}")
    led = c.get(f"/loyalty/{loyalty_phone}", headers=sauth).get_json()["ledger"]
    ok("redeem: ledger has redeem entry",
       any(l["reason"] == f"redeemed {redeem_order['id']}" and l["delta"] == -2
           for l in led), str(led[:2]))

    # (d) legacy collect path: backend builds the loyalty row itself
    points_before = c.get(f"/loyalty/{loyalty_phone}",
                          headers=sauth).get_json()["points"]
    legacy = take_order("espresso",
                        options=[{"group": "Size", "label": "Small"}])
    ok("redeem: espresso due 200", legacy["total"] == 200,
       str(legacy["total"]))
    r = c.patch(f"/orders/{legacy['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True, "payment_method": "upi",
        "redeem_points": 1})
    ok("redeem: legacy path 200", r.status_code == 200,
       str(r.status_code) + str(r.get_json()))
    rows = r.get_json().get("payments", [])
    ok("redeem: legacy rows = upi remainder + loyalty",
       [{"method": "upi", "amount": 100},
        {"method": "loyalty", "amount": 100}] == rows, str(rows))
    ok("redeem: primary method upi", r.get_json()["payment_method"] == "upi")
    points_after = c.get(f"/loyalty/{loyalty_phone}",
                         headers=sauth).get_json()["points"]
    ok("redeem: legacy balance math",
       points_after == points_before - 1 + 2,
       f"{points_before} -> {points_after}")

    # (e) negative / non-integer redeem_points
    bad = take_order("muffin")
    ok("redeem: negative rejected 400",
       c.patch(f"/orders/{bad['id']}/status", headers=sauth, json={
           "status": "collected", "paid": True,
           "redeem_points": -1}).status_code == 400)
    ok("redeem: non-integer rejected 400",
       c.patch(f"/orders/{bad['id']}/status", headers=sauth, json={
           "status": "collected", "paid": True,
           "redeem_points": "many"}).status_code == 400)
    # (f) redemption without a customer phone
    nophone = c.post("/orders", headers=sauth, json={
        "table_number": 2,
        "items": [{"item_id": "muffin", "qty": 1, "selected_options": []}],
    }).get_json()
    ok("redeem: no phone 400",
       c.patch(f"/orders/{nophone['id']}/status", headers=sauth, json={
           "status": "collected", "paid": True,
           "redeem_points": 1}).status_code == 400)
    # clean these two up so the report section sees collected orders only
    for oid in (bad["id"], nophone["id"]):
        c.patch(f"/orders/{oid}/status", headers=sauth,
                json={"status": "collected", "paid": True})
    # the clean-up collect earns normally (muffin 260 paise -> 2 points)
    ok("redeem: plain collect still earns",
       c.get(f"/loyalty/{loyalty_phone}",
             headers=sauth).get_json()["points"] == points_after + 2,
       str(c.get(f"/loyalty/{loyalty_phone}", headers=sauth).get_json()))

    # owner-only manual adjustment (balance may have moved with the clean-up
    # collects above, so read it fresh)
    points_now = c.get(f"/loyalty/{loyalty_phone}",
                       headers=sauth).get_json()["points"]
    r = c.post("/loyalty/adjust", headers=oauth, json={
        "phone": loyalty_phone, "delta": 5, "reason": "goodwill"})
    ok("loyalty adjust: owner 200", r.status_code == 200,
       str(r.status_code) + str(r.get_json()))
    ok("loyalty adjust: applied",
       r.get_json()["points"] == points_now + 5, str(r.get_json()))
    ok("loyalty adjust: staff 403",
       c.post("/loyalty/adjust", headers=sauth, json={
           "phone": loyalty_phone, "delta": 1, "reason": "x"}
           ).status_code == 403)
    ok("loyalty adjust: no reason 400",
       c.post("/loyalty/adjust", headers=oauth, json={
           "phone": loyalty_phone, "delta": 1}).status_code == 400)
    ok("loyalty adjust: cannot go negative 400",
       c.post("/loyalty/adjust", headers=oauth, json={
           "phone": loyalty_phone, "delta": -99999, "reason": "oops"}
           ).status_code == 400)

    # ------------------------------------------------------------------ #
    # 8. Swiggy / Zomato ingestion
    # ------------------------------------------------------------------ #
    swiggy_payload = {
        "order_id": "SW-9981",
        "items": [
            {"name": "Butter Croissant", "qty": 1, "price": 25000},
            {"name": "Latte", "qty": 1, "price": 32000},
        ],
        "customer": {"name": "Asha", "phone": "9876500003"},
        "total": 99999,  # ignored: the POS reprices from the menu
        "address": "B-402, Riverdale, Ahmedabad",
    }
    ok("swiggy: no key -> 401",
       c.post("/integrations/swiggy/orders", json=swiggy_payload
              ).status_code == 401)
    ok("swiggy: wrong key -> 401",
       c.post("/integrations/swiggy/orders", json=swiggy_payload,
              headers={"X-Integration-Key": "nope"}).status_code == 401)
    ok("swiggy: owner JWT is not enough",
       c.post("/integrations/swiggy/orders", json=swiggy_payload,
              headers=oauth).status_code == 401)

    ok("zomato: no key -> 401",
       c.post("/integrations/zomato/orders", json=swiggy_payload
              ).status_code == 401)

    swiggy_key = {"X-Integration-Key": "test-swiggy-key"}
    r = c.post("/integrations/swiggy/orders", json=swiggy_payload,
               headers=swiggy_key)
    ok("swiggy: with key -> 201", r.status_code == 201,
       str(r.status_code) + str(r.get_json()))
    sw = r.get_json()
    ok("swiggy: source field", sw["source"] == "swiggy", str(sw["source"]))
    ok("swiggy: pickup_type delivery", sw["pickup_type"] == "delivery")
    ok("swiggy: no table", sw["table_number"] is None)
    ok("swiggy: taken_by partner", sw["taken_by"] == "swiggy")
    # croissant 250 + latte (Size auto-filled with Small = 0 delta) 320
    ok("swiggy: repriced from menu (570)", sw["total"] == 570,
       str(sw["total"]))
    ok("swiggy: partner ref in notes", "SW-9981" in sw["notes"], sw["notes"])
    ok("swiggy: address in notes", "Riverdale" in sw["notes"], sw["notes"])
    ok("swiggy: status reuses normal flow", sw["status"] == "received")
    ok("swiggy: customer captured",
       sw["customer"]["name"] == "Asha" and sw["customer"]["phone"] == "9876500003")
    ok("swiggy: GST line fields present",
       all("cgst" in l and "gst_rate" in l for l in sw["items"]))

    r = c.post("/integrations/zomato/orders", json={
        "order_id": "ZM-7",
        "items": [{"name": "Avocado Toast", "qty": 1}],
        "customer": {"name": "Rohan", "phone": "9876500006"},
        "total": 100,
    }, headers={"X-Integration-Key": "test-zomato-key"})
    ok("zomato: with key -> 201", r.status_code == 201,
       str(r.status_code) + str(r.get_json()))
    zm = r.get_json()
    ok("zomato: source field", zm["source"] == "zomato")
    ok("zomato: repriced (480)", zm["total"] == 480, str(zm["total"]))

    r = c.post("/integrations/swiggy/orders", json={
        "order_id": "SW-BAD",
        "items": [{"name": "Unobtainium Toast", "qty": 1}],
        "customer": {"name": "Ghost"},
    }, headers=swiggy_key)
    ok("swiggy: unknown menu item 400", r.status_code == 400,
       str(r.status_code) + str(r.get_json()))
    ok("swiggy: customer.name required 400",
       c.post("/integrations/swiggy/orders", json={
           "items": [{"name": "Butter Croissant", "qty": 1}]},
           headers=swiggy_key).status_code == 400)

    # delivery orders are visible to staff (source drives the owner UI)
    all_orders = c.get("/orders", headers=sauth).get_json()
    ok("integrations: visible in staff queue",
       any(o["id"] == sw["id"] and o.get("source") == "swiggy"
           for o in all_orders))

    # ------------------------------------------------------------------ #
    # 9. Per-staff sales report
    # ------------------------------------------------------------------ #
    ok("staff report: staff 403",
       c.get("/admin/reports/staff", headers=sauth).status_code == 403)
    ok("staff report: no auth 401",
       c.get("/admin/reports/staff").status_code == 401)
    ok("staff report: bad date 400",
       c.get("/admin/reports/staff?date=2026-13-99",
             headers=oauth).status_code == 400)

    from datetime import datetime, timezone
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    rep = c.get(f"/admin/reports/staff?date={today}", headers=oauth)
    ok("staff report: 200", rep.status_code == 200, str(rep.status_code))
    report = rep.get_json()

    # recompute the truth from the order list (same rules as the repo)
    def expected_rows():
        rows = {}
        for o in c.get("/orders", headers=sauth).get_json():
            if (o.get("order_date") or o.get("created_at", "")[:10]) != today:
                continue
            if o.get("status") not in ("received", "preparing", "ready",
                                       "collected"):
                continue
            who = o.get("taken_by") or "unassigned"
            row = rows.setdefault(who, {"orders": 0, "collected": 0,
                                        "revenue": 0, "active": 0})
            row["orders"] += 1
            if o["status"] == "collected":
                row["collected"] += 1
                row["revenue"] += int(o.get("paid_amount") or o.get("total") or 0)
            else:
                row["active"] += 1
        return rows

    expected = expected_rows()
    got = {r["taken_by"]: r for r in report["staff"]}
    ok("staff report: same staff set",
       set(got) == set(expected), f"{sorted(got)} vs {sorted(expected)}")
    for who, exp in expected.items():
        ok(f"staff report: {who} numbers",
           got[who]["orders"] == exp["orders"]
           and got[who]["collected"] == exp["collected"]
           and got[who]["revenue"] == exp["revenue"]
           and got[who]["active"] == exp["active"],
           f"{got[who]} vs {exp}")
    ok("staff report: grand total orders",
       report["total"]["orders"] == sum(e["orders"] for e in expected.values()))
    ok("staff report: grand total revenue",
       report["total"]["revenue"] == sum(e["revenue"] for e in expected.values()))
    ok("staff report: grand total active",
       report["total"]["active"] == sum(e["active"] for e in expected.values()))
    ok("staff report: channels appear as rows",
       "qr" in got and "swiggy" in got, str(sorted(got)))
    ok("staff report: collected-only revenue",
       all(got[w]["revenue"] == expected[w]["revenue"] for w in got))

    # ?from&to must behave like ?date for a single day
    range_rep = c.get(f"/admin/reports/staff?from={today}&to={today}",
                      headers=oauth).get_json()
    ok("staff report: from/to equals date",
       range_rep == report, f"{range_rep} vs {report}")

    # ------------------------------------------------------------------ #
    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL PHASE 3 GROWTH CHECKS PASSED")


if __name__ == "__main__":
    main()
