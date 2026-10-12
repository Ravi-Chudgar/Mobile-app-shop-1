"""Offline-first sync layer tests (POST /sync/batch + GET /sync/pull).

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network.

Run:  python3 tests/test_sync.py
"""
import os
import sys
import time
import uuid
from urllib.parse import quote
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ.pop("ESCPOS_PRINTER_HOST", None)
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"
os.environ["SYNC_MAX_BATCH"] = "50"

from app import create_app  # noqa: E402
from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402


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

    def order_count():
        return len(c.get("/orders", headers=sauth).get_json())

    def op_id():
        return str(uuid.uuid4())

    def order_op(table, name="Sync Tester", source=None, **extra):
        payload = {
            "table_number": table,
            "customer": {"name": name},
            "items": [{"item_id": "latte", "qty": 1,
                       "selected_options": [{"group": "Size",
                                             "label": "Regular"}]}],
        }
        if source:
            payload["source"] = source
        payload.update(extra)
        return {"op_id": op_id(), "type": "order_create", "payload": payload}

    owner = c.post("/auth/login",
                   json={"username": "owner", "password": "cafe123"}).get_json()
    oauth = bearer(owner["token"])
    staff = c.post("/auth/login",
                   json={"username": "priya", "password": "staff123"}).get_json()
    sauth = bearer(staff["token"])
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ------------------------------------------------------------------ #
    # 1. Auth required
    # ------------------------------------------------------------------ #
    ok("auth: batch without token 401",
       c.post("/sync/batch", json={"ops": []}).status_code == 401)
    ok("auth: pull without token 401",
       c.get("/sync/pull").status_code == 401)
    ok("auth: batch with token 200",
       c.post("/sync/batch", headers=sauth, json={"ops": []}).status_code == 200)

    # ------------------------------------------------------------------ #
    # 2. order_create applied -> order is a normal order (no markers)
    # ------------------------------------------------------------------ #
    before = order_count()
    op1 = order_op(8)
    res = c.post("/sync/batch", headers=sauth, json={"ops": [op1]})
    ok("batch: 200", res.status_code == 200, str(res.status_code))
    results = res.get_json()["results"]
    ok("batch: one result", len(results) == 1, str(results))
    r1 = results[0]
    ok("applied: status", r1.get("status") == "applied", str(r1))
    oid1 = r1.get("order_id")
    ok("applied: order_id", bool(oid1), str(r1))
    ok("applied: exactly one order added", order_count() == before + 1,
       f"{order_count()} vs {before + 1}")

    listed = c.get("/orders", headers=sauth).get_json()
    match = [o for o in listed if o["id"] == oid1]
    ok("applied: visible in normal list", len(match) == 1, str(match[:1]))
    ok("applied: order is a real order (items/total present)",
       bool(match) and isinstance(match[0].get("items"), list)
       and "total" in match[0])
    ok("applied: client_op_id stored",
       bool(match) and match[0].get("client_op_id") == op1["op_id"],
       str(match[0].get("client_op_id") if match else None))
    ok("applied: unpaid (payments never queued)",
       bool(match) and match[0].get("payment_status") == "unpaid")
    ok("applied: table occupied like a normal order", any(
        t["number"] == "8" and t["status"] == "occupied"
        for t in c.get("/tables", headers=sauth).get_json()))

    # Payment fields sent by mistake are stripped (collect is online-only).
    op_pay = order_op(9)
    op_pay["payload"]["payments"] = [{"method": "cash", "amount": 900}]
    op_pay["payload"]["paid"] = True
    rp = c.post("/sync/batch", headers=sauth,
                json={"ops": [op_pay]}).get_json()["results"][0]
    paid_order = c.get(f"/orders/{rp['order_id']}", headers=sauth).get_json()
    ok("payments stripped: still unpaid",
       rp.get("status") == "applied"
       and paid_order.get("payment_status") == "unpaid"
       and not paid_order.get("payments"), str(paid_order.get("payments")))

    # ------------------------------------------------------------------ #
    # 3. Replay of the same op_id -> deduped, no duplicate order
    # ------------------------------------------------------------------ #
    before = order_count()
    replay = c.post("/sync/batch", headers=sauth, json={"ops": [op1]})
    rr = replay.get_json()["results"][0]
    ok("replay: status deduped", rr.get("status") == "deduped", str(rr))
    ok("replay: deduped flag true", rr.get("deduped") is True, str(rr))
    ok("replay: original order_id", rr.get("order_id") == oid1, str(rr))
    ok("replay: no duplicate order", order_count() == before,
       f"{order_count()} vs {before}")

    # Duplicate inside a single batch: apply once, then dedupe the copy.
    before = order_count()
    op2 = order_op(1)
    dup = c.post("/sync/batch", headers=sauth,
                 json={"ops": [op2, dict(op2)]}).get_json()["results"]
    ok("in-batch dup: two results", len(dup) == 2, str(dup))
    ok("in-batch dup: applied then deduped",
       dup[0].get("status") == "applied" and dup[1].get("status") == "deduped",
       str(dup))
    ok("in-batch dup: same order_id",
       dup[0].get("order_id") == dup[1].get("order_id"), str(dup))
    ok("in-batch dup: only one order created", order_count() == before + 1,
       f"{order_count()} vs {before + 1}")

    # ------------------------------------------------------------------ #
    # 4. Mixed batch: unknown type / bad ops -> per-op errors, no 500
    # ------------------------------------------------------------------ #
    before = order_count()
    op_ok = order_op(10)
    mixed = c.post("/sync/batch", headers=sauth, json={"ops": [
        op_ok,
        {"op_id": op_id(), "type": "does_not_exist", "payload": {}},
        {"type": "order_create", "payload": {}},           # missing op_id
        {"op_id": op_id(), "type": "order_create",        # bad payload
         "payload": {"items": []}},
        "not-an-object",
    ]})
    ok("mixed: 200 (never a whole-batch 500)", mixed.status_code == 200,
       str(mixed.status_code))
    mr = mixed.get_json()["results"]
    ok("mixed: five results", len(mr) == 5, str(mr))
    ok("mixed: statuses",
       [r["status"] for r in mr] == ["applied", "error", "error", "error",
                                     "error"], str([r["status"] for r in mr]))
    ok("mixed: applied order_id present", bool(mr[0].get("order_id")))
    ok("mixed: unknown type error message",
       "Unsupported op type" in mr[1].get("error", ""), str(mr[1]))
    ok("mixed: missing op_id error",
       "op_id" in mr[2].get("error", ""), str(mr[2]))
    ok("mixed: payload error",
       "at least one item" in mr[3].get("error", ""), str(mr[3]))
    ok("mixed: non-object op error", bool(mr[4].get("error")), str(mr[4]))
    ok("mixed: exactly one order added", order_count() == before + 1,
       f"{order_count()} vs {before + 1}")

    # Unknown ops still echo their op_id for client-side bookkeeping.
    ok("mixed: unknown type echoes op_id", bool(mr[1].get("op_id")), str(mr[1]))

    # ------------------------------------------------------------------ #
    # 5. Occupied table -> per-op error entry (same rule as POST /orders)
    # ------------------------------------------------------------------ #
    before = order_count()
    occ = order_op(8)  # table 8 was taken by op1 above
    occ_res = c.post("/sync/batch", headers=sauth, json={"ops": [occ]})
    ok("occupied: batch still 200", occ_res.status_code == 200,
       str(occ_res.status_code))
    orr = occ_res.get_json()["results"][0]
    ok("occupied: per-op error", orr.get("status") == "error", str(orr))
    ok("occupied: message says occupied",
       "occupied" in orr.get("error", "").lower(), str(orr))
    ok("occupied: echo op_id", orr.get("op_id") == occ["op_id"], str(orr))
    ok("occupied: no order persisted", order_count() == before,
       f"{order_count()} vs {before}")

    # ------------------------------------------------------------------ #
    # 6. Batch size limit
    # ------------------------------------------------------------------ #
    big = [order_op(2) for _ in range(Config.SYNC_MAX_BATCH + 1)]
    too_big = c.post("/sync/batch", headers=sauth, json={"ops": big})
    ok("limit: oversized batch 400", too_big.status_code == 400,
       str(too_big.status_code))
    ok("limit: message", "too large" in too_big.get_json().get("error", "").lower(),
       str(too_big.get_json()))
    ok("limit: nothing applied", order_count() == before,
       f"{order_count()} vs {before}")
    ok("limit: config default 50", Config.SYNC_MAX_BATCH == 50,
       str(Config.SYNC_MAX_BATCH))
    ok("limit: malformed ops rejected 400",
       c.post("/sync/batch", headers=sauth, json={"ops": "nope"}).status_code == 400)

    # ------------------------------------------------------------------ #
    # 7. GET /sync/pull — orders since <since>, snapshot of the rest
    # ------------------------------------------------------------------ #
    time.sleep(0.05)
    t_mark = datetime.now(timezone.utc).isoformat()
    time.sleep(0.05)

    order_a = c.post("/orders", headers=sauth, json={
        "table_number": 2,
        "customer": {"name": "Before Mark"},
        "items": [{"item_id": "chai", "qty": 1, "selected_options": [
            {"group": "Size", "label": "Regular"}]}],
    }).get_json()

    time.sleep(0.05)
    t_mark2 = datetime.now(timezone.utc).isoformat()
    time.sleep(0.05)

    op_b = order_op(3, name="After Mark")
    rb = c.post("/sync/batch", headers=sauth, json={"ops": [op_b]})
    oid_b = rb.get_json()["results"][0]["order_id"]

    # since = right between A and B -> only B
    pull = c.get(f"/sync/pull?since={quote(t_mark2)}", headers=sauth)
    ok("pull: 200", pull.status_code == 200, str(pull.status_code))
    pj = pull.get_json()
    pulled_ids = [o["id"] for o in pj["orders"]]
    ok("pull: only orders since", pulled_ids == [oid_b],
       f"{pulled_ids} vs [{oid_b}]")
    ok("pull: server_time present", bool(pj.get("server_time")))
    ok("pull: menu snapshot present",
       isinstance(pj.get("menu"), list) and len(pj["menu"]) > 0)
    ok("pull: tables snapshot present",
       isinstance(pj.get("tables"), list) and len(pj["tables"]) > 0)
    ok("pull: inventory snapshot present",
       isinstance(pj.get("inventory"), list) and len(pj["inventory"]) > 0)
    ok("pull: sync order carries client_op_id for reconciliation",
       pj["orders"] and pj["orders"][0].get("client_op_id") == op_b["op_id"],
       str(pj["orders"][:1]))

    # since = before A -> both A and B, but nothing seeded earlier
    pj2 = c.get(f"/sync/pull?since={quote(t_mark)}", headers=sauth).get_json()
    ids2 = [o["id"] for o in pj2["orders"]]
    ok("pull: window includes A and B",
       ids2 == [order_a["id"], oid_b], str(ids2))

    # no since -> everything (seeds included)
    allp = c.get("/sync/pull", headers=sauth).get_json()
    all_ids = [o["id"] for o in allp["orders"]]
    ok("pull: no since returns all orders",
       set(all_ids) == {o["id"] for o in
                        c.get("/orders", headers=sauth).get_json()},
       f"{len(all_ids)} orders")
    ok("pull: future since -> empty",
       c.get("/sync/pull?since=" + quote("2999-01-01T00:00:00+00:00"),
             headers=sauth).get_json()["orders"] == [])
    ok("pull: bad since 400",
       c.get("/sync/pull?since=not-a-date", headers=sauth).status_code == 400)
    ok("pull: date-only since accepted",
       c.get(f"/sync/pull?since={quote(today)}", headers=sauth).status_code == 200)

    # ------------------------------------------------------------------ #
    # 8. No marker pollution in lists / reports
    # ------------------------------------------------------------------ #
    listed = c.get("/orders", headers=sauth).get_json()
    ok("pollution: every listed row is a real order",
       all(isinstance(o.get("items"), list) and "total" in o
           and o.get("order_date") for o in listed),
       str([o.get("id") for o in listed if "total" not in o]))
    ok("pollution: applied op count matches orders added",
       len(listed) == before + 2,  # order_a + synced order_b
       f"{len(listed)} vs {before + 2}")

    daily = c.get("/admin/reports/daily", headers=oauth).get_json()
    sales_statuses = ("received", "preparing", "ready", "collected")
    todays = [o for o in listed
              if o.get("order_date") == today and o.get("status") in sales_statuses]
    ok("pollution: daily report counts only real orders",
       daily["order_count"] == len(todays),
       f"{daily['order_count']} vs {len(todays)}")
    expected_gross = sum(int(o.get("total", 0)) for o in todays)
    ok("pollution: daily gross matches",
       daily["gross_sales"] == expected_gross,
       f"{daily['gross_sales']} vs {expected_gross}")

    # ------------------------------------------------------------------ #
    # 9. A replayed op AFTER the table is freed still dedupes (no 2nd order)
    # ------------------------------------------------------------------ #
    c.patch(f"/orders/{oid1}/status", headers=sauth,
            json={"status": "collected", "paid": True})
    ok("replay after collect: still deduped",
       c.post("/sync/batch", headers=sauth,
              json={"ops": [op1]}).get_json()["results"][0]["status"] == "deduped")

    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL SYNC CHECKS PASSED")
    print(f"  dedupe via client_op_id on the order (no marker rows)")
    print(f"  batch idempotent: applied/deduped/error per op, never a 500")
    print(f"  pull: orders since + full menu/tables/inventory snapshot")


if __name__ == "__main__":
    main()
