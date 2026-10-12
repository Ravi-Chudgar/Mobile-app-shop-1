"""Phase 4 — Accounting bridge: Tally XML/CSV export, GSTR-1/GSTR-3B,
read-only cafe_ca (CA) login.

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network, no printer.

Run:  python3 tests/test_phase4_tally.py
"""
import csv
import io
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"

from app import create_app  # noqa: E402
from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.services.tally import order_guid, paise_to_rupees  # noqa: E402


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

    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    period = now.strftime("%Y-%m")

    # ------------------------------------------------------------------ #
    # 0. Seed orders: collected + open + a Swiggy channel order + a
    #    cancelled one (must NOT appear in any export), plus a customer
    #    name with XML metacharacters.
    # ------------------------------------------------------------------ #
    a = c.post("/orders", headers=sauth, json={
        "table_number": 1,
        "customer": {"name": "Aisha"},
        "payment_method": "cash",
        "items": [{"item_id": "latte", "qty": 2, "selected_options": [
            {"group": "Size", "label": "Large"}, {"group": "Milk", "label": "Oat"}]}],
    }).get_json()
    c.patch(f"/orders/{a['id']}/status", headers=sauth,
            json={"status": "collected", "paid": True})

    b = c.post("/orders", headers=sauth, json={
        "table_number": 2,
        "customer": {"name": "Tom & Jerry <Cafe>"},
        "items": [{"item_id": "croissant", "qty": 1, "selected_options": []}],
    }).get_json()

    sw = c.post("/orders", headers=sauth, json={
        "source": "swiggy",
        "customer": {"name": "Asha"},
        "payment_method": "upi",
        "items": [{"item_id": "espresso", "qty": 1, "selected_options": [
            {"group": "Size", "label": "Small"}]}],
    }).get_json()

    dead = c.post("/orders", headers=sauth, json={
        "table_number": 3,
        "customer": {"name": "Cancelled"},
        "items": [{"item_id": "muffin", "qty": 1, "selected_options": []}],
    }).get_json()
    c.patch(f"/orders/{dead['id']}/status", headers=sauth,
            json={"status": "cancelled"})

    # Truth source: every non-cancelled order of the day, straight from the API.
    def sale_orders():
        return [o for o in c.get("/orders", headers=sauth).get_json()
                if (o.get("order_date") or o.get("created_at", "")[:10]) == today
                and o.get("status") in Config.SALES_STATUSES]

    expected = sale_orders()
    expected_ids = {o["id"] for o in expected}
    ok("seed: cancelled order excluded from truth set",
       dead["id"] not in expected_ids, str(expected_ids))

    def order_tax(order):
        taxable = cgst = sgst = total = 0
        for line in order["items"]:
            taxable += int(line.get("taxable_value", 0) or 0)
            cgst += int(line.get("cgst", 0) or 0)
            sgst += int(line.get("sgst", 0) or 0)
            total += int(line.get("line_total", 0) or 0)
        return taxable, cgst, sgst, total

    exp_taxable = exp_cgst = exp_sgst = exp_total = 0
    for o in expected:
        t, g, s_, tot = order_tax(o)
        exp_taxable += t
        exp_cgst += g
        exp_sgst += s_
        exp_total += tot

    # ------------------------------------------------------------------ #
    # 1. Tally XML export
    # ------------------------------------------------------------------ #
    url = f"/export/tally?from={today}&to={today}&format=xml"
    ok("tally xml: staff 403", c.get(url, headers=sauth).status_code == 403)
    ok("tally xml: no auth 401", c.get(url).status_code == 401)

    r = c.get(url, headers=oauth)
    ok("tally xml: owner 200", r.status_code == 200, str(r.status_code))
    ok("tally xml: content-type",
       (r.headers.get("Content-Type") or "").startswith("text/xml"),
       r.headers.get("Content-Type", ""))
    ok("tally xml: attachment filename",
       r.headers.get("Content-Disposition")
       == f'attachment; filename="tally_sales_{today}_{today}.xml"',
       r.headers.get("Content-Disposition", ""))

    xml_text = r.get_data(as_text=True)
    # Well-formed?
    try:
        root = ET.fromstring(xml_text)
        parse_ok = True
    except ET.ParseError as e:
        root = None
        parse_ok = False
        print("  xml parse error:", e)
    ok("tally xml: well-formed", parse_ok)

    if parse_ok:
        ok("tally xml: ENVELOPE root", root.tag == "ENVELOPE", root.tag)
        ok("tally xml: TALLYREQUEST Import Data",
           root.findtext("HEADER/TALLYREQUEST") == "Import Data",
           str(root.findtext("HEADER/TALLYREQUEST")))
        ok("tally xml: company",
           root.findtext("BODY/IMPORTDATA/REQUESTDESC/"
                         "STATICVARIABLES/SVCURRENTCOMPANY") == Config.CAFE_NAME)
        vouchers = root.findall(".//VOUCHER")
        ok("tally xml: one voucher per sale order",
           len(vouchers) == len(expected),
           f"{len(vouchers)} vs {len(expected)}")

        by_ref = {v.findtext("VOUCHERNUMBER"): v for v in vouchers}
        ok("tally xml: no voucher for cancelled order",
           dead["id"] not in by_ref, str(sorted(by_ref)))
        ok("tally xml: swiggy order exported",
           sw["id"] in by_ref, str(sorted(by_ref)))

        for order in expected:
            v = by_ref.get(order["id"])
            if v is None:
                ok(f"tally xml: voucher for {order['id']}", False)
                continue
            ok(f"tally xml: VCHTYPE/ACTION {order['id']}",
               v.get("VCHTYPE") == "Sales" and v.get("ACTION") == "Create",
               f"{v.get('VCHTYPE')}/{v.get('ACTION')}")
            ok(f"tally xml: DATE {order['id']}",
               v.findtext("DATE") == today.replace("-", ""),
               str(v.findtext("DATE")))
            ok(f"tally xml: GUID stable {order['id']}",
               v.findtext("GUID") == order_guid(order),
               str(v.findtext("GUID")))
            ok(f"tally xml: narration has order id",
               order["id"] in (v.findtext("NARRATION") or ""),
               str(v.findtext("NARRATION")))
            ok(f"tally xml: party ledger",
               v.findtext("PARTYLEDGERNAME") ==
               (order["customer"]["name"] or "Cash Sales"),
               str(v.findtext("PARTYLEDGERNAME")))

            taxable, cgst, sgst, total = order_tax(order)
            # Inventory entries carry the TAXABLE value, signed as a credit
            # (negative) like every real Tally sales-voucher export.
            inv_amount = sum(float(e.findtext("AMOUNT") or 0)
                             for e in v.findall("ALLINVENTORYENTRIES.LIST"))
            ok(f"tally xml: inventory amount == -taxable {order['id']}",
               abs(inv_amount + taxable / 100.0) < 0.005,
               f"{inv_amount} vs {-taxable / 100.0}")
            inv_names = [e.findtext("ITEMNAME")
                         for e in v.findall("ALLINVENTORYENTRIES.LIST")]
            ok(f"tally xml: item names {order['id']}",
               inv_names == [l["name"] for l in order["items"]],
               str(inv_names))

            ledgers = {e.findtext("LEDGERNAME"): float(e.findtext("AMOUNT") or 0)
                       for e in v.findall("ALLLEDGERENTRIES.LIST")}
            party = order["customer"]["name"]
            ok(f"tally xml: sales credit {order['id']}",
               abs(ledgers.get("Sales", 0) + taxable / 100.0) < 0.005,
               str(ledgers.get("Sales")))
            if cgst:
                ok(f"tally xml: cgst credit {order['id']}",
                   abs(ledgers.get("CGST", 0) + cgst / 100.0) < 0.005,
                   str(ledgers.get("CGST")))
            if sgst:
                ok(f"tally xml: sgst credit {order['id']}",
                   abs(ledgers.get("SGST", 0) + sgst / 100.0) < 0.005,
                   str(ledgers.get("SGST")))
            ok(f"tally xml: party debit {order['id']}",
               abs(ledgers.get(party, 0) - total / 100.0) < 0.005,
               str(ledgers))
            # Credits + debits balance to zero.
            ok(f"tally xml: voucher balances {order['id']}",
               abs(sum(ledgers.values())) < 0.005, str(sum(ledgers.values())))

        sw_v = by_ref[sw["id"]]
        ok("tally xml: swiggy narration notes channel",
           "Swiggy" in (sw_v.findtext("NARRATION") or ""),
           str(sw_v.findtext("NARRATION")))

        # Escaping: the customer name round-trips through the parser intact.
        amp_v = by_ref[b["id"]]
        ok("tally xml: special chars escaped/preserved",
           amp_v.findtext("PARTYLEDGERNAME") == "Tom & Jerry <Cafe>",
           str(amp_v.findtext("PARTYLEDGERNAME")))

        # GUID stability across a second export (re-import dedupes on GUID).
        r2 = c.get(url, headers=oauth)
        root2 = ET.fromstring(r2.get_data(as_text=True))
        guid1 = sorted(v.findtext("GUID") for v in root.findall(".//VOUCHER"))
        guid2 = sorted(v.findtext("GUID") for v in root2.findall(".//VOUCHER"))
        ok("tally xml: GUIDs stable across exports", guid1 == guid2)

        # Header echo of the range.
        ok("tally xml: FROMDATE/TODATE echoed",
           root.findtext("BODY/IMPORTDATA/REQUESTDESC/"
                         "STATICVARIABLES/FROMDATE") == today
           and root.findtext("BODY/IMPORTDATA/REQUESTDESC/"
                             "STATICVARIABLES/TODATE") == today)

    # ------------------------------------------------------------------ #
    # 2. Tally CSV export
    # ------------------------------------------------------------------ #
    r = c.get(f"/export/tally?from={today}&to={today}&format=csv",
              headers=oauth)
    ok("tally csv: owner 200", r.status_code == 200, str(r.status_code))
    ok("tally csv: content-type",
       (r.headers.get("Content-Type") or "").startswith("text/csv"),
       r.headers.get("Content-Type", ""))
    ok("tally csv: attachment filename",
       r.headers.get("Content-Disposition")
       == f'attachment; filename="tally_sales_{today}_{today}.csv"',
       r.headers.get("Content-Disposition", ""))
    rows = list(csv.DictReader(io.StringIO(r.get_data(as_text=True))))
    ok("tally csv: header",
       list(rows[0].keys()) == ["order_id", "date", "party", "taxable",
                                "cgst", "sgst", "total", "payment"],
       str(list(rows[0].keys()) if rows else rows))
    ok("tally csv: one row per sale order",
       len(rows) == len(expected), f"{len(rows)} vs {len(expected)}")
    ok("tally csv: no cancelled row",
       all(row["order_id"] != dead["id"] for row in rows))
    csv_by_id = {row["order_id"]: row for row in rows}
    a_row = csv_by_id[a["id"]]
    t, g, s_, tot = order_tax(a)
    ok("tally csv: taxable matches (rupees)",
       a_row["taxable"] == f"{t / 100:.2f}", str(a_row))
    ok("tally csv: cgst matches", a_row["cgst"] == f"{g / 100:.2f}", str(a_row))
    ok("tally csv: sgst matches", a_row["sgst"] == f"{s_ / 100:.2f}", str(a_row))
    ok("tally csv: total matches", a_row["total"] == f"{tot / 100:.2f}", str(a_row))
    ok("tally csv: all rows dated today",
       all(row["date"] == today for row in rows), str(rows[:1]))
    ok("tally csv: sum of totals matches truth",
       abs(sum(float(row["total"]) for row in rows) - exp_total / 100.0) < 0.01,
       f"{sum(float(row['total']) for row in rows)} vs {exp_total / 100.0}")

    # Bad request params
    ok("tally: missing from -> 400",
       c.get(f"/export/tally?to={today}", headers=oauth).status_code == 400)
    ok("tally: bad date -> 400",
       c.get("/export/tally?from=2026-13-99&to=2026-01-01",
             headers=oauth).status_code == 400)
    ok("tally: to before from -> 400",
       c.get(f"/export/tally?from={today}&to=2020-01-01",
             headers=oauth).status_code == 400)
    ok("tally: bad format -> 400",
       c.get(f"/export/tally?from={today}&to={today}&format=json",
             headers=oauth).status_code == 400)

    # ------------------------------------------------------------------ #
    # 3. GSTR-1
    # ------------------------------------------------------------------ #
    g1 = c.get(f"/export/gstr1?period={period}&format=json", headers=oauth)
    ok("gstr1: owner 200", g1.status_code == 200, str(g1.status_code))
    ok("gstr1: content-type json",
       (g1.headers.get("Content-Type") or "").startswith("application/json"),
       g1.headers.get("Content-Type", ""))
    g1j = g1.get_json()
    ok("gstr1: period", g1j["period"] == period, str(g1j.get("period")))
    ok("gstr1: gstin", g1j["gstin"] == Config.CAFE_GSTIN, str(g1j.get("gstin")))
    ok("gstr1: B2C invoice count",
       g1j["invoice_count"] == len(expected)
       and len(g1j["invoices"]) == len(expected),
       f"{g1j['invoice_count']} vs {len(expected)}")
    ok("gstr1: invoice numbers are order ids",
       {i["invoice_number"] for i in g1j["invoices"]} == expected_ids,
       str({i["invoice_number"] for i in g1j["invoices"]} ^ expected_ids))
    ok("gstr1: invoice dates",
       all(i["date"] == today for i in g1j["invoices"]),
       str(g1j["invoices"][:1]))
    t1 = g1j["totals"]
    ok("gstr1: taxable matches order tax fields",
       abs(t1["taxable_value"] - exp_taxable / 100.0) < 0.01,
       f"{t1['taxable_value']} vs {exp_taxable / 100.0}")
    ok("gstr1: cgst matches",
       abs(t1["cgst"] - exp_cgst / 100.0) < 0.01,
       f"{t1['cgst']} vs {exp_cgst / 100.0}")
    ok("gstr1: sgst matches",
       abs(t1["sgst"] - exp_sgst / 100.0) < 0.01,
       f"{t1['sgst']} vs {exp_sgst / 100.0}")
    ok("gstr1: invoice value matches",
       abs(t1["invoice_value"] - exp_total / 100.0) < 0.01,
       f"{t1['invoice_value']} vs {exp_total / 100.0}")
    ok("gstr1: invoice rows sum to totals",
       abs(sum(i["taxable_value"] for i in g1j["invoices"])
           - t1["taxable_value"]) < 0.01,
       str(sum(i["taxable_value"] for i in g1j["invoices"])))
    ok("gstr1: B2B documented empty",
       g1j["b2b"] == [] and "GSTIN" in g1j["notes"], str(g1j.get("notes")))

    hsn = g1j["hsn_summary"]
    ok("gstr1: hsn summary non-empty", len(hsn) >= 1, str(hsn))
    ok("gstr1: hsn taxable sums to total",
       abs(sum(h["taxable_value"] for h in hsn) - t1["taxable_value"]) < 0.01,
       str(hsn))
    ok("gstr1: hsn codes present",
       all(h["hsn_code"] for h in hsn), str(hsn))
    rates = g1j["rate_summary"]
    ok("gstr1: rate summary sums to total",
       abs(sum(r_["taxable_value"] for r_ in rates) - t1["taxable_value"]) < 0.01,
       str(rates))
    ok("gstr1: rate summary cgst sums to total",
       abs(sum(r_["cgst"] for r_ in rates) - t1["cgst"]) < 0.01, str(rates))

    # GSTR-1 CSV
    r = c.get(f"/export/gstr1?period={period}&format=csv", headers=oauth)
    ok("gstr1 csv: 200", r.status_code == 200, str(r.status_code))
    ok("gstr1 csv: content-type",
       (r.headers.get("Content-Type") or "").startswith("text/csv"),
       r.headers.get("Content-Type", ""))
    ok("gstr1 csv: filename",
       r.headers.get("Content-Disposition")
       == f'attachment; filename="gstr1_{period}.csv"',
       r.headers.get("Content-Disposition", ""))
    crows = list(csv.reader(io.StringIO(r.get_data(as_text=True))))
    csv_ids = {row[1] for row in crows if row and row[0] == "b2c"}
    ok("gstr1 csv: invoice ids present", csv_ids == expected_ids,
       str(csv_ids ^ expected_ids))
    ok("gstr1 csv: has b2c_total row",
       any(row and row[0] == "b2c_total" for row in crows), str(crows[:2]))
    ok("gstr1 csv: has hsn + rate sections",
       any(row and row[0] == "hsn" for row in crows)
       and any(row and row[0] == "rate" for row in crows))

    ok("gstr1: staff 403",
       c.get(f"/export/gstr1?period={period}", headers=sauth).status_code == 403)
    ok("gstr1: bad period 400",
       c.get("/export/gstr1?period=2026-13", headers=oauth).status_code == 400)
    ok("gstr1: missing period 400",
       c.get("/export/gstr1", headers=oauth).status_code == 400)
    ok("gstr1: bad format 400",
       c.get(f"/export/gstr1?period={period}&format=xml",
             headers=oauth).status_code == 400)

    # ------------------------------------------------------------------ #
    # 4. GSTR-3B
    # ------------------------------------------------------------------ #
    g3 = c.get(f"/export/gstr3b?period={period}&format=json", headers=oauth)
    ok("gstr3b: owner 200", g3.status_code == 200, str(g3.status_code))
    g3j = g3.get_json()
    out = g3j["outward_taxable_supplies"]
    ok("gstr3b: taxable matches truth",
       abs(out["taxable_value"] - exp_taxable / 100.0) < 0.01,
       f"{out['taxable_value']} vs {exp_taxable / 100.0}")
    ok("gstr3b: cgst matches truth",
       abs(out["cgst"] - exp_cgst / 100.0) < 0.01,
       f"{out['cgst']} vs {exp_cgst / 100.0}")
    ok("gstr3b: sgst matches truth",
       abs(out["sgst"] - exp_sgst / 100.0) < 0.01,
       f"{out['sgst']} vs {exp_sgst / 100.0}")
    ok("gstr3b: total value matches truth",
       abs(out["total_value"] - exp_total / 100.0) < 0.01,
       f"{out['total_value']} vs {exp_total / 100.0}")
    ok("gstr3b: total == taxable + cgst + sgst",
       abs(out["total_value"]
           - (out["taxable_value"] + out["cgst"] + out["sgst"])) < 0.02,
       str(out))
    ok("gstr3b: agrees with gstr1 totals",
       abs(out["taxable_value"] - t1["taxable_value"]) < 0.01
       and abs(out["total_value"] - t1["invoice_value"]) < 0.01,
       f"{out} vs {t1}")
    ok("gstr3b: by_rate sums to total",
       abs(sum(r_["taxable_value"] for r_ in g3j["by_rate"])
           - out["taxable_value"]) < 0.01, str(g3j["by_rate"]))
    ok("gstr3b: by_rate rows carry all four fields",
       all(set(r_) >= {"gst_rate", "taxable_value", "cgst", "sgst",
                       "total_value"} for r_ in g3j["by_rate"]),
       str(g3j["by_rate"]))

    r = c.get(f"/export/gstr3b?period={period}&format=csv", headers=oauth)
    ok("gstr3b csv: 200", r.status_code == 200, str(r.status_code))
    ok("gstr3b csv: filename",
       r.headers.get("Content-Disposition")
       == f'attachment; filename="gstr3b_{period}.csv"',
       r.headers.get("Content-Disposition", ""))
    g3rows = list(csv.reader(io.StringIO(r.get_data(as_text=True))))
    ok("gstr3b csv: 4.1(a) row",
       any(row and row[0] == "4.1(a)" for row in g3rows), str(g3rows[:2]))
    ok("gstr3b csv: rate rows",
       sum(1 for row in g3rows if row and row[0] == "4.1(a) by rate")
       == len(g3j["by_rate"]), str(g3rows))
    ok("gstr3b: staff 403",
       c.get(f"/export/gstr3b?period={period}", headers=sauth).status_code == 403)
    ok("gstr3b: bad period 400",
       c.get("/export/gstr3b?period=nope", headers=oauth).status_code == 400)

    # ------------------------------------------------------------------ #
    # 5. cafe_ca login: creation, read access, mutation blocked
    # ------------------------------------------------------------------ #
    ok("ca: owner creates CA user 201",
       c.post("/admin/staff", headers=oauth, json={
           "username": "ca1", "password": "capass1",
           "name": "Meera the CA", "role": "cafe_ca",
       }).status_code == 201)
    ok("ca: bogus role rejected 400",
       c.post("/admin/staff", headers=oauth, json={
           "username": "ca2", "password": "x", "role": "wizard",
       }).status_code == 400)
    ok("ca: owner role not assignable 400",
       c.post("/admin/staff", headers=oauth, json={
           "username": "ca3", "password": "x", "role": "owner",
       }).status_code == 400)

    ca_login = c.post("/auth/login",
                      json={"username": "ca1", "password": "capass1"})
    ok("ca: login 200", ca_login.status_code == 200, str(ca_login.status_code))
    ca = ca_login.get_json()
    ok("ca: role cafe_ca", ca.get("role") == "cafe_ca", str(ca.get("role")))
    cauth = bearer(ca["token"])

    # Read-only exports + reports the CA is granted
    ok("ca: tally xml 200",
       c.get(url, headers=cauth).status_code == 200)
    ok("ca: tally csv 200",
       c.get(f"/export/tally?from={today}&to={today}&format=csv",
             headers=cauth).status_code == 200)
    ok("ca: gstr1 200",
       c.get(f"/export/gstr1?period={period}", headers=cauth).status_code == 200)
    ok("ca: gstr1 csv 200",
       c.get(f"/export/gstr1?period={period}&format=csv",
             headers=cauth).status_code == 200)
    ok("ca: gstr3b 200",
       c.get(f"/export/gstr3b?period={period}",
             headers=cauth).status_code == 200)
    ok("ca: daily report 200",
       c.get("/admin/reports/daily", headers=cauth).status_code == 200)
    ok("ca: z report 200",
       c.get(f"/admin/reports/z?date={today}",
             headers=cauth).status_code == 200)
    ok("ca: staff report 200",
       c.get(f"/admin/reports/staff?date={today}",
             headers=cauth).status_code == 200)
    ok("ca: billing 200",
       c.get("/admin/billing", headers=cauth).status_code == 200)

    # Per-route: routes the CA is NOT granted stay 403 even for GET.
    ok("ca: inventory GET still 403",
       c.get("/admin/inventory", headers=cauth).status_code == 403)
    ok("ca: list orders GET 403 (any_required keeps exact roles)",
       c.get("/orders", headers=cauth).status_code == 403)
    ok("ca: menu edit GET(put) blocked",
       c.put("/admin/menu/latte", headers=cauth,
             json={"base_price": 1}).status_code == 403)
    ok("ca: range report GET 403 (not granted)",
       c.get("/admin/reports/range",
             headers=cauth).status_code == 403)

    # Mutations: blocked globally, whatever the route.
    ok("ca: create menu 403",
       c.post("/admin/menu", headers=cauth, json={
           "name": "Hack", "base_price": 1}).status_code == 403)
    ok("ca: place order 403",
       c.post("/orders", headers=cauth, json={
           "items": [{"item_id": "latte", "qty": 1,
                      "selected_options": []}]}).status_code == 403)
    ok("ca: collect order 403",
       c.patch(f"/orders/{a['id']}/status", headers=cauth,
               json={"status": "collected", "paid": True}).status_code == 403)
    ok("ca: approve staff 403",
       c.post("/admin/staff/priya/approve",
              headers=cauth).status_code == 403)
    ok("ca: delete menu 403",
       c.delete("/admin/menu/muffin", headers=cauth).status_code == 403)
    ok("ca: mark paid 403",
       c.post(f"/admin/billing/{a['id']}/paid",
              headers=cauth).status_code == 403)
    ok("ca: reorder still possible after blocked attempts",
       len(c.get("/orders", headers=sauth).get_json()) > 0)

    # Owner can still do everything the CA cannot.
    ok("owner: create menu 201",
       c.post("/admin/menu", headers=oauth, json={
           "name": "Phase 4 Special", "base_price": 450}).status_code == 201)
    ok("owner: exports 200", c.get(url, headers=oauth).status_code == 200)

    # Staff stays out of all of it.
    ok("staff: gstr3b 403",
       c.get(f"/export/gstr3b?period={period}",
             headers=sauth).status_code == 403)
    ok("staff: daily report 403",
       c.get("/admin/reports/daily", headers=sauth).status_code == 403)
    ok("staff: billing 403",
       c.get("/admin/billing", headers=sauth).status_code == 403)

    # ------------------------------------------------------------------ #
    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL PHASE 4 ACCOUNTING BRIDGE CHECKS PASSED")
    print(f"  {len(expected)} sale orders on {today}: "
          f"taxable={paise_to_rupees(exp_taxable)} "
          f"cgst={paise_to_rupees(exp_cgst)} "
          f"sgst={paise_to_rupees(exp_sgst)} "
          f"total={paise_to_rupees(exp_total)}")
    print(f"  GSTR-1 {period}: {len(g1j['invoices'])} B2C invoices, "
          f"{len(hsn)} HSN rows, {len(rates)} rate rows")
    print("  cafe_ca: read-only (exports + 4 reports), mutations 403")


if __name__ == "__main__":
    main()
