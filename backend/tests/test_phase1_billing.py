"""Phase 1 — Billing engine tests (GST, split payments, printing, Z-report).

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network, no printer.

Run:  python3 tests/test_phase1_billing.py
"""
import base64
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ.pop("ESCPOS_PRINTER_HOST", None)  # force dry-run printing
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"

from app import create_app  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.pricing import split_line_tax, tax_by_rate  # noqa: E402


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

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ------------------------------------------------------------------ #
    # 1. Menu GST fields
    # ------------------------------------------------------------------ #
    menu = c.get("/menu").get_json()
    ok("menu: default gst_rate 5",
       all(m.get("gst_rate") == 5 for m in menu))
    ok("menu: default hsn 9963",
       all(m.get("hsn_code") == "9963" for m in menu))

    created = c.post("/admin/menu", headers=oauth, json={
        "name": "Gujarati Thali", "category": "food", "base_price": 25000,
        "gst_rate": 12, "hsn_code": "9983",
    })
    ok("menu: create with gst fields 201", created.status_code == 201)
    thali = created.get_json()
    ok("menu: gst_rate returned", thali.get("gst_rate") == 12, str(thali))
    ok("menu: hsn returned", thali.get("hsn_code") == "9983")

    bad = c.post("/admin/menu", headers=oauth, json={
        "name": "Bad GST", "base_price": 100, "gst_rate": 7})
    ok("menu: invalid gst_rate 400", bad.status_code == 400, str(bad.status_code))

    # ------------------------------------------------------------------ #
    # 2. Tax computation (tax-inclusive, invariant per line)
    # ------------------------------------------------------------------ #
    o1 = c.post("/orders", headers=sauth, json={
        "table_number": 1,
        "customer": {"name": "Tax Tester", "phone": "9876543210"},
        "items": [{"item_id": "latte", "qty": 2, "selected_options": [
            {"group": "Size", "label": "Large"}, {"group": "Milk", "label": "Oat"}]}],
    })
    ok("tax: order created 201", o1.status_code == 201)
    order = o1.get_json()
    line = order["items"][0]

    ok("tax: total unchanged by tax (900)", order["total"] == 900,
       str(order["total"]))
    ok("tax: sub_total == total", order.get("sub_total") == order["total"])
    ok("tax: line invariant taxable+cgst+sgst == line_total",
       line["taxable_value"] + line["cgst"] + line["sgst"] == line["line_total"],
       str(line))
    ok("tax: line gst_rate 5", line.get("gst_rate") == 5)
    ok("tax: line hsn 9963", line.get("hsn_code") == "9963")
    ok("tax: cgst == sgst", line["cgst"] == line["sgst"])
    ok("tax: positive tax on 5% line", line["cgst"] + line["sgst"] > 0)
    ok("tax: order tax_total == sum of line taxes",
       order.get("tax_total") == line["cgst"] + line["sgst"],
       f"{order.get('tax_total')} vs {line['cgst'] + line['sgst']}")
    ok("tax: sub_total + tax_total != total double count",
       order["sub_total"] == order["total"])  # inclusive pricing

    # unit-level check of the helper (1000 paise @5% incl. -> 952/24/24)
    t, cgs, sgs = split_line_tax(1000, 5)
    ok("tax: split_line_tax invariant", t + cgs + sgs == 1000)
    ok("tax: split_line_tax zero rate", split_line_tax(999, 0) == (999, 0, 0))

    # a 12% menu item flows its rate + HSN onto the line
    o12 = c.post("/orders", headers=sauth, json={
        "table_number": 2,
        "items": [{"item_id": thali["id"], "qty": 1, "selected_options": []}],
    }).get_json()
    l12 = o12["items"][0]
    ok("tax: 12% rate on line", l12["gst_rate"] == 12, str(l12.get("gst_rate")))
    ok("tax: 12% invariant",
       l12["taxable_value"] + l12["cgst"] + l12["sgst"] == l12["line_total"])
    ok("tax: 12% hsn from menu", l12["hsn_code"] == "9983", str(l12.get("hsn_code")))

    # owner can update the GST fields afterwards
    upd = c.put(f"/admin/menu/{thali['id']}", headers=oauth,
                json={"gst_rate": 5, "hsn_code": "9963"})
    ok("menu: update gst fields 200", upd.status_code == 200
       and upd.get_json()["gst_rate"] == 5
       and upd.get_json()["hsn_code"] == "9963", str(upd.get_json()))

    # ------------------------------------------------------------------ #
    # 3. Split / multi payments
    # ------------------------------------------------------------------ #
    o2 = c.post("/orders", headers=sauth, json={
        "table_number": 3,
        "customer": {"name": "Splitter", "phone": "9000000000"},
        "items": [{"item_id": "avocado-toast", "qty": 2, "selected_options": []}],
    }).get_json()
    due = o2["total"]
    ok("split: due 960", due == 960, str(due))

    short = c.patch(f"/orders/{o2['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "cash", "amount": 500}],
    })
    ok("split: wrong sum rejected 400", short.status_code == 400,
       str(short.status_code) + str(short.get_json()))
    ok("split: error message mentions sum",
       "must equal" in (short.get_json() or {}).get("error", ""))

    bad_method = c.patch(f"/orders/{o2['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "bitcoin", "amount": due}],
    })
    ok("split: bad method rejected 400", bad_method.status_code == 400)

    good = c.patch(f"/orders/{o2['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "cash", "amount": 460},
                     {"method": "upi", "amount": 500, "ref": "UPI-1"}],
    })
    ok("split: good sum accepted 200", good.status_code == 200,
       str(good.status_code) + str(good.get_json()))
    got = good.get_json()
    ok("split: payments stored (2)", len(got.get("payments", [])) == 2)
    ok("split: payment amounts",
       [p["amount"] for p in got.get("payments", [])] == [460, 500])
    ok("split: ref kept", got["payments"][1].get("ref") == "UPI-1")
    ok("split: primary method = first", got["payment_method"] == "cash")
    ok("split: paid in full", got["paid_amount"] == due
       and got["payment_status"] == "paid")

    # legacy payload without payments still works (single payment_method)
    o3 = c.post("/orders", headers=sauth, json={
        "table_number": 4,
        "customer": {"name": "Legacy", "phone": "9111111111"},
        "payment_method": "card",
        "items": [{"item_id": "chai", "qty": 1, "selected_options": [
            {"group": "Size", "label": "Regular"}]}],
    }).get_json()
    legacy = c.patch(f"/orders/{o3['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True, "payment_method": "card"})
    ok("legacy: single method collect 200", legacy.status_code == 200)
    lg = legacy.get_json()
    ok("legacy: no payments list created", not lg.get("payments"))
    ok("legacy: payment_method kept", lg["payment_method"] == "card")

    # reopen -> add items -> re-collect only the remaining due (split again)
    c.post(f"/orders/{o3['id']}/reopen", headers=sauth)
    grown = c.post(f"/orders/{o3['id']}/items", headers=sauth, json={
        "items": [{"item_id": "muffin", "qty": 1, "selected_options": []}]
    }).get_json()
    ok("reopen: total grows to 530", grown["total"] == 530, str(grown["total"]))
    ok("reopen: sub_total tracks total", grown["sub_total"] == grown["total"])
    ok("reopen: tax_total re-summed",
       grown["tax_total"] == sum(l["cgst"] + l["sgst"] for l in grown["items"]))

    remaining = grown["total"] - grown["paid_amount"]
    ok("reopen: remaining due 260", remaining == 260, str(remaining))
    bad_recollect = c.patch(f"/orders/{o3['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "cash", "amount": remaining + 1}],
    })
    ok("reopen: overpay (sum != due) rejected 400", bad_recollect.status_code == 400)
    rec = c.patch(f"/orders/{o3['id']}/status", headers=sauth, json={
        "status": "collected", "paid": True,
        "payments": [{"method": "cash", "amount": remaining}],
    })
    ok("reopen: re-collect exact remaining 200", rec.status_code == 200)
    ok("reopen: paid in full after re-collect",
       rec.get_json()["paid_amount"] == grown["total"])
    ok("reopen: payments accumulate across collects",
       len(rec.get_json().get("payments", [])) == 1)  # legacy collect had none

    # ------------------------------------------------------------------ #
    # 4. Bill text endpoint (server-rendered WhatsApp bill)
    # ------------------------------------------------------------------ #
    bill = c.get(f"/orders/{o2['id']}/bill", headers=sauth)
    ok("bill: 200", bill.status_code == 200, str(bill.status_code))
    bj = bill.get_json()
    text = bj.get("text", "")
    ok("bill: cafe name", "Cafe POS Demo" in text)
    ok("bill: GSTIN", "GSTIN" in text)
    ok("bill: CGST line", "CGST" in text)
    ok("bill: SGST line", "SGST" in text)
    ok("bill: per-rate table", "GST @5% taxable" in text)
    ok("bill: HSN per line", "HSN 9963" in text)
    ok("bill: total present", "TOTAL" in text and "9.60" in text)
    ok("bill: wa.me link with 91-prefix",
       (bj.get("wa_link") or "").startswith("https://wa.me/919000000000"),
       str(bj.get("wa_link")))
    ok("bill: link encodes text", "text=" in bj["wa_link"])

    # legacy order (no phone) still renders the text, just no share link
    no_phone = c.post("/orders", headers=sauth, json={
        "items": [{"item_id": "espresso", "qty": 1,
                   "selected_options": [{"group": "Size", "label": "Small"}]}],
    }).get_json()
    b2 = c.get(f"/orders/{no_phone['id']}/bill", headers=sauth).get_json()
    ok("bill: text without phone", "Espresso" in b2["text"])
    ok("bill: no wa link when phone missing", b2["wa_link"] is None)
    ok("bill: 404 unknown order",
       c.get("/orders/NOPE0/bill", headers=sauth).status_code == 404)
    ok("bill: auth required", c.get(f"/orders/{o2['id']}/bill").status_code == 401)

    # ------------------------------------------------------------------ #
    # 5. Receipt / KOT printing (dry-run)
    # ------------------------------------------------------------------ #
    r = c.post(f"/printing/receipt/{o2['id']}", headers=sauth)
    ok("print: receipt 200", r.status_code == 200, str(r.status_code))
    rj = r.get_json()
    ok("print: dry_run true", rj.get("dry_run") is True)
    data = base64.b64decode(rj.get("bytes_b64", ""))
    ok("print: bytes non-empty", len(data) > 100 and len(data) == rj["bytes_len"])
    ok("print: init sequence", data.startswith(b"\x1b\x40"))
    ok("print: cafe name on receipt", b"Cafe POS Demo" in data)
    ok("print: GSTIN on receipt", b"GSTIN" in data)
    ok("print: order id on receipt", o2["id"].encode() in data)
    ok("print: CGST on receipt", b"CGST" in data)
    ok("print: HSN on receipt", b"HSN 9963" in data)
    ok("print: payment methods on receipt", b"CASH" in data and b"UPI" in data)

    k = c.post(f"/printing/kot/{o2['id']}", headers=sauth)
    ok("print: kot 200", k.status_code == 200, str(k.status_code))
    kdata = base64.b64decode(k.get_json().get("bytes_b64", ""))
    ok("print: kot header", b"KITCHEN TICKET" in kdata)
    ok("print: kot has items", b"Avocado Toast" in kdata)
    ok("print: kot has table", b"Table" in kdata)
    ok("print: kot has NO prices", b"TOTAL" not in kdata and b"Sub Total" not in kdata)

    ok("print: 404 unknown order",
       c.post("/printing/receipt/NOPE0", headers=sauth).status_code == 404)
    ok("print: auth required",
       c.post(f"/printing/receipt/{o2['id']}").status_code == 401)
    c.post("/admin/kitchen", headers=oauth,
           json={"username": "kit1", "password": "pw123", "name": "Kitchen"})
    ktok = c.post("/auth/login",
                  json={"username": "kit1", "password": "pw123"}).get_json()["token"]
    ok("print: kitchen role blocked",
       c.post(f"/printing/receipt/{o2['id']}",
              headers=bearer(ktok)).status_code == 403)

    # ------------------------------------------------------------------ #
    # 6. Z-report
    # ------------------------------------------------------------------ #
    z = c.get("/admin/reports/z?date=" + today, headers=oauth)
    ok("z: 200", z.status_code == 200, str(z.status_code))
    zj = z.get_json()
    orders = c.get("/orders", headers=sauth).get_json()
    sales = [o for o in orders if o.get("status") in
             ("received", "preparing", "ready", "collected")]
    expected_gross = sum(o["total"] for o in sales)
    ok("z: gross sales", zj["gross_sales"] == expected_gross,
       f"{zj['gross_sales']} vs {expected_gross}")
    ok("z: order count", zj["order_count"] == len(sales))
    ok("z: paid + unpaid == gross",
       zj["paid_sales"] + zj["unpaid_sales"] == zj["gross_sales"])
    ok("z: cgst == sgst (symmetric split)",
       zj["cgst_total"] == zj["sgst_total"],
       f"{zj['cgst_total']} vs {zj['sgst_total']}")
    ok("z: tax_total == cgst+sgst",
       zj["tax_total"] == zj["cgst_total"] + zj["sgst_total"])
    ok("z: tax_by_rate has 5% bucket",
       any(b["rate"] == 5 and b["taxable"] > 0 and b["cgst"] > 0
           for b in zj["tax_by_rate"]), str(zj["tax_by_rate"]))
    for b in zj["tax_by_rate"]:
        ok(f"z: rate {b['rate']} invariant",
           b["taxable"] + b["cgst"] + b["sgst"]
           >= sum(l["line_total"] for o in sales for l in o["items"]
                  if l.get("gst_rate") == b["rate"]) - 2 * b["lines"],
           str(b))
    ok("z: by_payment uses split payments",
       zj["by_payment"].get("cash", 0) > 0 and zj["by_payment"].get("upi", 0) > 0,
       str(zj["by_payment"]))
    ok("z: payments sum to paid sales",
       sum(zj["by_payment"].values()) == zj["paid_sales"],
       f"{sum(zj['by_payment'].values())} vs {zj['paid_sales']}")
    ok("z: cash expected", zj["cash_expected"] == zj["by_payment"].get("cash", 0))
    ok("z: top items present", len(zj["top_items"]) > 0)
    ok("z: cogs fields present",
       "cogs_total" in zj and "gross_profit" in zj and "cogs_estimated" in zj)
    ok("z: bad date 400",
       c.get("/admin/reports/z?date=2026-13-99", headers=oauth).status_code == 400)
    ok("z: staff blocked 403",
       c.get("/admin/reports/z?date=" + today, headers=sauth).status_code == 403)

    # ------------------------------------------------------------------ #
    # 7. Legacy orders (no tax fields) still load/display
    # ------------------------------------------------------------------ #
    from app.aws import orders_table  # noqa: E402  (stub-backed)
    from app.util import plain  # noqa: E402

    raw = orders_table().get_item(Key={"id": no_phone["id"]})["Item"]
    legacy_order = plain(raw)
    for f in ("sub_total", "tax_total"):
        legacy_order.pop(f, None)
    for l in legacy_order["items"]:
        for f in ("taxable_value", "cgst", "sgst", "gst_rate", "hsn_code"):
            l.pop(f, None)
    orders_table().put_item(Item=legacy_order)

    ok("legacy: order still loads 200",
       c.get(f"/orders/{no_phone['id']}", headers=sauth).status_code == 200)
    lb = c.get(f"/orders/{no_phone['id']}/bill", headers=sauth)
    ok("legacy: bill renders with zero tax", lb.status_code == 200
       and "CGST" in lb.get_json()["text"])
    lr = c.post(f"/printing/receipt/{no_phone['id']}", headers=sauth)
    ok("legacy: receipt builds", lr.status_code == 200)

    # ------------------------------------------------------------------ #
    # 8. P&L fixes (calendar days, margin = net/revenue)
    # ------------------------------------------------------------------ #
    pl = c.get("/admin/reports/profit-loss", headers=oauth)
    ok("pl: 200", pl.status_code == 200)
    plj = pl.get_json()
    ok("pl: days_in_month is real calendar days",
       plj.get("days_in_month") in (28, 29, 30, 31), str(plj.get("days_in_month")))
    feb = c.get("/admin/reports/profit-loss?month=2026-02-01",
                headers=oauth).get_json()
    ok("pl: Feb 2026 has 28 days", feb.get("days_in_month") == 28,
       str(feb.get("days_in_month")))
    if plj.get("revenue", 0) > 0:
        expect_margin = round(
            (plj["net_profit"] / plj["revenue"]) * 100, 1)
        ok("pl: margin = net / revenue",
           plj["profit_margin"] == expect_margin,
           f"{plj['profit_margin']} vs {expect_margin}")
    ok("pl: markup exposed separately", "markup" in plj)
    ok("pl: cogs labelled as estimate when falling back",
       "cogs_estimated" in plj and "cogs_source" in plj)

    # ------------------------------------------------------------------ #
    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL PHASE 1 BILLING CHECKS PASSED")


if __name__ == "__main__":
    main()
