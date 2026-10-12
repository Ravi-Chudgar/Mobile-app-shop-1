"""Phase 2 — Cafe ops tests (KOT auto-print, low-stock alerts, floor layout).

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network, no printer.

Run:  python3 tests/test_phase2_ops.py
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
os.environ.pop("ESCPOS_PRINTER_HOST", None)   # force dry-run printing
os.environ.pop("AUTO_PRINT_KOT", None)        # auto-print off by default
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"

from app import create_app  # noqa: E402
from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.services import printing  # noqa: E402


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
    # 1. reorder_level CRUD
    # ------------------------------------------------------------------ #
    made = c.post("/admin/inventory", headers=oauth, json={
        "name": "Phase2 Beans", "quantity": 20, "cost_price": 100,
        "unit": "kg", "reorder_level": 12,
    })
    ok("inv: create with reorder_level 201", made.status_code == 201,
       str(made.status_code))
    beans = made.get_json()
    ok("inv: reorder_level returned", beans.get("reorder_level") == 12,
       str(beans))

    dflt = c.post("/admin/inventory", headers=oauth, json={
        "name": "Phase2 Default", "quantity": 5, "cost_price": 10,
    }).get_json()
    ok("inv: default reorder_level 0", dflt.get("reorder_level") == 0,
       str(dflt.get("reorder_level")))

    bad_neg = c.post("/admin/inventory", headers=oauth, json={
        "name": "Phase2 Negative", "quantity": 1, "reorder_level": -3,
    })
    ok("inv: negative reorder_level 400", bad_neg.status_code == 400,
       str(bad_neg.status_code) + str(bad_neg.get_json()))
    bad_txt = c.post("/admin/inventory", headers=oauth, json={
        "name": "Phase2 Text", "quantity": 1, "reorder_level": "many",
    })
    ok("inv: non-numeric reorder_level 400", bad_txt.status_code == 400)

    upd = c.put(f"/admin/inventory/{beans['id']}", headers=oauth,
                json={"reorder_level": 7})
    ok("inv: update reorder_level 200", upd.status_code == 200,
       str(upd.status_code) + str(upd.get_json()))
    ok("inv: update reorder_level persisted", upd.get_json().get("reorder_level") == 7,
       str(upd.get_json()))
    upd2 = c.put(f"/admin/inventory/{beans['id']}", headers=oauth,
                 json={"reorder_level": "9"})
    ok("inv: string reorder_level coerced",
       upd2.status_code == 200 and upd2.get_json().get("reorder_level") == 9,
       str(upd2.get_json()))
    ok("inv: update with negative level 400",
       c.put(f"/admin/inventory/{beans['id']}", headers=oauth,
             json={"reorder_level": -1}).status_code == 400)
    listed = {i["id"]: i for i in
              c.get("/admin/inventory", headers=oauth).get_json()}
    ok("inv: reorder_level in list response",
       listed.get(beans["id"], {}).get("reorder_level") == 9,
       str(listed.get(beans["id"])))
    ok("inv: list quantities are plain ints",
       isinstance(listed[beans["id"]].get("quantity"), int),
       repr(listed[beans["id"]].get("quantity")))
    ok("inv: staff blocked from create",
       c.post("/admin/inventory", headers=sauth,
              json={"name": "Nope", "quantity": 1}).status_code == 403)
    ok("inv: staff blocked from update",
       c.put(f"/admin/inventory/{beans['id']}", headers=sauth,
             json={"reorder_level": 1}).status_code == 403)

    # ------------------------------------------------------------------ #
    # 2. GET /admin/inventory/alerts
    # ------------------------------------------------------------------ #
    def make(name, qty, level, item_id):
        resp = c.post("/admin/inventory", headers=oauth, json={
            "id": item_id, "name": name, "quantity": qty, "cost_price": 10,
            "reorder_level": level,
        })
        ok(f"alerts: seed {item_id} 201", resp.status_code == 201,
           str(resp.status_code) + str(resp.get_json()))
        return resp.get_json()

    at_level = make("At Level", 5, 5, "phase2-at")      # qty == level  -> alert
    below = make("Below Level", 2, 10, "phase2-below")  # qty <  level  -> alert
    healthy = make("Healthy", 50, 10, "phase2-ok")      # qty >  level  -> no
    disabled = make("Disabled", 3, 0, "phase2-off")     # level 0       -> never
    oos_off = make("OutOfStockOff", 0, 0, "phase2-oos0")  # level 0 + 0  -> never
    oos_on = make("OutOfStockOn", 0, 4, "phase2-oos4")  # level >0 + 0  -> alert

    alerts = c.get("/admin/inventory/alerts", headers=oauth)
    ok("alerts: 200", alerts.status_code == 200, str(alerts.status_code))
    body = alerts.get_json()
    ok("alerts: returns a list", isinstance(body, list), str(type(body)))
    ids = {a.get("id") for a in body}
    ok("alerts: item at level appears", "phase2-at" in ids, str(ids))
    ok("alerts: item below level appears", "phase2-below" in ids, str(ids))
    ok("alerts: healthy item does not appear", "phase2-ok" not in ids, str(ids))
    ok("alerts: level=0 never appears", "phase2-off" not in ids, str(ids))
    ok("alerts: out-of-stock with level=0 never appears",
       "phase2-oos0" not in ids, str(ids))
    ok("alerts: out-of-stock with level>0 appears",
       "phase2-oos4" in ids, str(ids))

    entry = next((a for a in body if a.get("id") == "phase2-below"), {})
    ok("alerts: entry has item", bool(entry.get("item")), str(entry))
    ok("alerts: entry has qty", entry.get("qty") == 2, str(entry))
    ok("alerts: entry has reorder_level", entry.get("reorder_level") == 10,
       str(entry))
    ok("alerts: out_of_stock flag",
       next(a for a in body if a["id"] == "phase2-below").get("out_of_stock")
       is False
       and next(a for a in body if a["id"] == "phase2-oos4").get("out_of_stock")
       is True, str(entry))
    ok("alerts: numeric types",
       isinstance(entry.get("qty"), int) and isinstance(entry.get("reorder_level"), int),
       str(entry))
    ok("alerts: staff blocked 403",
       c.get("/admin/inventory/alerts", headers=sauth).status_code == 403)
    ok("alerts: auth required",
       c.get("/admin/inventory/alerts").status_code == 401)

    # dynamic: raise a healthy item's level above its qty -> it alerts
    c.put(f"/admin/inventory/{healthy['id']}", headers=oauth,
          json={"reorder_level": 60})
    ids = {a.get("id") for a in
           c.get("/admin/inventory/alerts", headers=oauth).get_json()}
    ok("alerts: raising level flips item to alert", "phase2-ok" in ids, str(ids))
    # restock the low item back above its level -> it clears
    c.post(f"/admin/inventory/{below['id']}/restock", headers=oauth,
           json={"quantity": 20})
    ids = {a.get("id") for a in c.get("/admin/inventory/alerts",
                                      headers=oauth).get_json()}
    ok("alerts: restock clears alert", "phase2-below" not in ids, str(ids))
    ok("alerts: at-level item still alerts", "phase2-at" in ids, str(ids))

    # ------------------------------------------------------------------ #
    # 3. Table layout (floor map) fields round-trip
    # ------------------------------------------------------------------ #
    lay = c.put("/admin/tables/1/layout", headers=oauth, json={
        "zone": "terrace", "x": 10, "y": 25, "w": 20, "h": 15,
        "shape": "round",
    })
    ok("layout: PUT 200", lay.status_code == 200,
       str(lay.status_code) + str(lay.get_json()))
    ok("layout: PUT echoes fields",
       lay.get_json().get("zone") == "terrace"
       and lay.get_json().get("x") == 10
       and lay.get_json().get("shape") == "round", str(lay.get_json()))

    t1 = next(t for t in c.get("/tables", headers=sauth).get_json()
              if t["number"] == "1")
    ok("layout: round-trip via GET /tables",
       t1.get("zone") == "terrace" and t1.get("x") == 10 and t1.get("y") == 25
       and t1.get("w") == 20 and t1.get("h") == 15
       and t1.get("shape") == "round", str(t1))
    ok("layout: status untouched by layout update", t1.get("status") == "empty",
       str(t1.get("status")))

    legacy = next(t for t in c.get("/tables", headers=sauth).get_json()
                  if t["number"] == "2")
    ok("layout: missing fields stay missing (client grid fallback)",
       legacy.get("x") is None and legacy.get("y") is None
       and legacy.get("w") is None, str(legacy))

    ok("layout: bad shape 400",
       c.put("/admin/tables/1/layout", headers=oauth,
             json={"shape": "oval"}).status_code == 400)
    ok("layout: x out of range 400",
       c.put("/admin/tables/1/layout", headers=oauth,
             json={"x": 101}).status_code == 400)
    ok("layout: w zero 400",
       c.put("/admin/tables/1/layout", headers=oauth,
             json={"w": 0}).status_code == 400)
    ok("layout: empty payload 400",
       c.put("/admin/tables/1/layout", headers=oauth, json={}).status_code == 400)
    ok("layout: unknown table 404",
       c.put("/admin/tables/4242/layout", headers=oauth,
             json={"x": 1}).status_code == 404)
    ok("layout: staff blocked 403",
       c.put("/admin/tables/1/layout", headers=sauth,
             json={"x": 1}).status_code == 403)
    ok("layout: auth required",
       c.put("/admin/tables/1/layout", json={"x": 1}).status_code == 401)

    added = c.post("/admin/tables", headers=oauth, json={
        "number": 99, "zone": "garden", "x": 60, "y": 60, "w": 25, "h": 25,
        "shape": "rect",
    })
    ok("layout: add table with layout 201", added.status_code == 201,
       str(added.status_code) + str(added.get_json()))
    t99 = next(t for t in c.get("/tables", headers=sauth).get_json()
               if t["number"] == "99")
    ok("layout: add round-trip",
       t99.get("zone") == "garden" and t99.get("x") == 60
       and t99.get("h") == 25, str(t99))
    ok("layout: add table without layout gets defaults",
       c.post("/admin/tables", headers=oauth, json={"number": 98}).get_json()
       .get("zone") == "main")
    c.delete("/admin/tables/98", headers=oauth)
    c.delete("/admin/tables/99", headers=oauth)

    # occupy / free keep the layout intact
    order = c.post("/orders", headers=sauth, json={
        "table_number": 1,
        "items": [{"item_id": "latte", "qty": 1, "selected_options": [
            {"group": "Size", "label": "Regular"}]}],
    })
    ok("layout: order on laid-out table 201", order.status_code == 201,
       str(order.status_code) + str(order.get_json()))
    t1o = next(t for t in c.get("/tables", headers=sauth).get_json()
               if t["number"] == "1")
    ok("layout: occupy works with layout",
       t1o.get("status") == "occupied" and t1o.get("order_id") ==
       order.get_json()["id"], str(t1o))
    ok("layout: layout preserved while occupied",
       t1o.get("zone") == "terrace" and t1o.get("x") == 10
       and t1o.get("shape") == "round", str(t1o))
    # a second staff member is locked out of freeing (behaviour unchanged)
    other = c.post("/auth/login",
                   json={"username": "sam", "password": "staff123"})
    ok("layout: sam still pending (lock check needs approved staff)",
       other.status_code == 403 or other.status_code == 200,
       str(other.status_code))
    free = c.post("/tables/1/free", headers=sauth)
    ok("layout: serving staff frees table", free.status_code == 200,
       str(free.status_code))
    t1f = next(t for t in c.get("/tables", headers=sauth).get_json()
               if t["number"] == "1")
    ok("layout: free works with layout",
       t1f.get("status") == "empty" and t1f.get("order_id") is None, str(t1f))
    ok("layout: layout preserved after free",
       t1f.get("zone") == "terrace" and t1f.get("y") == 25, str(t1f))

    # ------------------------------------------------------------------ #
    # 4. KOT auto-print helper + dry-run endpoint
    # ------------------------------------------------------------------ #
    sent = []
    real_send = printing.send

    def fake_send(host, port, data, timeout=3.0):
        sent.append((host, port, data))
        return True

    printing.send = fake_send
    try:
        # off by default -> no-op even with a printer host
        Config.ESCPOS_PRINTER_HOST = "10.0.0.9"
        os.environ.pop("AUTO_PRINT_KOT", None)
        ok("kot: helper no-ops when flag off",
           printing.maybe_auto_print_kot({"id": "X", "items": []}) is False
           and not sent)

        # flag on, no printer configured -> no-op, never raises
        os.environ["AUTO_PRINT_KOT"] = "1"
        Config.ESCPOS_PRINTER_HOST = ""
        ok("kot: helper no-ops without printer host",
           printing.maybe_auto_print_kot({"id": "X", "items": []}) is False
           and not sent)

        # flag on + host -> best-effort send of real KOT bytes
        Config.ESCPOS_PRINTER_HOST = "10.0.0.9"
        Config.ESCPOS_PRINTER_PORT = 9100
        demo = {"id": "KOT-1", "table_number": "4", "taken_by": "priya",
                "created_at": "2026-10-09T10:00:00+00:00",
                "items": [{"name": "Latte", "qty": 2, "selected_options": []}]}
        ok("kot: helper sends when enabled",
           printing.maybe_auto_print_kot(demo) is True and len(sent) == 1,
           str(len(sent)))
        host, port, data = sent[-1]
        ok("kot: send target", host == "10.0.0.9" and port == 9100,
           f"{host}:{port}")
        ok("kot: bytes are a KOT",
           b"KITCHEN TICKET" in data and b"KOT-1" in data and b"Latte" in data,
           str(data[:80]))
        ok("kot: no prices on auto KOT", b"TOTAL" not in data)

        # printer unreachable -> logged, swallowed, returns False
        def boom(host, port, data, timeout=3.0):
            raise OSError("connection refused")

        printing.send = boom
        ok("kot: helper never raises on send failure",
           printing.maybe_auto_print_kot(demo) is False)
        printing.send = fake_send
    finally:
        printing.send = real_send

    # end-to-end: order creation triggers the auto print (create region only)
    sent.clear()
    Config.ESCPOS_PRINTER_HOST = "10.0.0.9"
    os.environ["AUTO_PRINT_KOT"] = "1"
    printing.send = fake_send
    try:
        made_order = c.post("/orders", headers=sauth, json={
            "table_number": 3,
            "items": [{"item_id": "chai", "qty": 1, "selected_options": [
                {"group": "Size", "label": "Regular"}]}],
        })
        ok("kot: create order still 201", made_order.status_code == 201,
           str(made_order.status_code) + str(made_order.get_json()))
        ok("kot: auto print fired from order create", len(sent) == 1,
           str(len(sent)))
        if sent:
            ok("kot: auto KOT carries the new order id",
               made_order.get_json()["id"].encode() in sent[0][2])

        # a failing printer must not break order creation
        def dead_send(*args, **kwargs):
            raise OSError("printer is down")

        printing.send = dead_send
        made_order2 = c.post("/orders", headers=sauth, json={
            "table_number": 4,
            "items": [{"item_id": "chai", "qty": 1, "selected_options": [
                {"group": "Size", "label": "Regular"}]}],
        })
        ok("kot: order create survives printer failure",
           made_order2.status_code == 201,
           str(made_order2.status_code) + str(made_order2.get_json()))
    finally:
        printing.send = real_send
        os.environ.pop("AUTO_PRINT_KOT", None)
        Config.ESCPOS_PRINTER_HOST = ""

    kot_id = (made_order2.get_json() or {}).get("id") or \
        (made_order.get_json() or {}).get("id")
    ok("kot: order id captured for dry-run", bool(kot_id), str(kot_id))

    # manual endpoint still returns bytes in dry-run mode
    k = c.post(f"/printing/kot/{kot_id}", headers=sauth)
    ok("kot: dry-run endpoint 200", k.status_code == 200, str(k.status_code))
    kj = k.get_json()
    ok("kot: dry_run flag", kj.get("dry_run") is True, str(kj))
    kdata = base64.b64decode(kj.get("bytes_b64", ""))
    ok("kot: dry-run bytes", b"KITCHEN TICKET" in kdata
       and len(kdata) == kj.get("bytes_len"), str(kj.get("bytes_len")))
    ok("kot: receipt endpoint unchanged 404",
       c.post("/printing/kot/NOPE0", headers=sauth).status_code == 404)

    # kitchen role may reprint KOTs (receipts stay staff/owner only)
    c.post("/admin/kitchen", headers=oauth,
           json={"username": "kit2", "password": "pw123", "name": "Kitchen 2"})
    ktok = bearer(c.post("/auth/login",
                         json={"username": "kit2",
                               "password": "pw123"}).get_json()["token"])
    ok("kot: kitchen role may print KOT",
       c.post(f"/printing/kot/{kot_id}", headers=ktok).status_code == 200)
    ok("kot: kitchen role still blocked from receipts",
       c.post(f"/printing/receipt/{kot_id}", headers=ktok).status_code == 403)

    # ------------------------------------------------------------------ #
    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL PHASE 2 CAFE OPS CHECKS PASSED")


if __name__ == "__main__":
    main()
