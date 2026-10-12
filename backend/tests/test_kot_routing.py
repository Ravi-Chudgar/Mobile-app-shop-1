"""KOT routing: auto-print on EVERY order path + SOURCE/customer content.

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). The printer is either a spy (records the attempt,
no socket) or an unreachable loopback port 1 (proves a dead kitchen printer
is swallowed by maybe_auto_print_kot and never breaks order creation).

Covers:
  * QR self-order prints exactly ONE KOT — legacy /public/orders and the
    tenant-scoped /public/<slug>/orders (one shared handler body);
  * the scoped print goes to THAT tenant's `kitchen_printer_host`, not the
    env printer, and carries the tenant's display name + bill_footer;
  * staff POST /orders, Swiggy and Zomato ingestion -> one KOT each;
  * POST /sync/batch: an `applied` op prints once; replaying the same
    op_id (`deduped`, in-batch or cross-batch) prints NOTHING more —
    exactly-once per client_op_id;
  * build_kot bytes: SOURCE line (COUNTER / QR TABLE 5 / SWIGGY / ZOMATO),
    customer name + phone last-4, tenant bill_footer, no prices;
  * kitchen-display reprints (GET /printing/kot/<id>/bytes and the legacy
    POST) build through build_kot, so they carry the same lines.

Run:  /usr/bin/python3 tests/test_kot_routing.py
"""
import base64
import os
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "_stubs"))
sys.path.insert(0, BACKEND)

os.environ["AWS_REGION"] = "us-east-1"
os.environ.pop("AWS_ENDPOINT_URL", None)
os.environ.pop("ESCPOS_PRINTER_HOST", None)
os.environ.pop("AUTO_PRINT_KOT", None)          # off by default; suite flips it
os.environ["SEED_ADMIN_USER"] = "owner"
os.environ["SEED_ADMIN_PASSWORD"] = "cafe123"
# Webhook secrets (Config reads the environment at import time, so these
# must be set before `from app import ...`).
os.environ["SWIGGY_API_KEY"] = "test-swiggy-key"
os.environ["ZOMATO_API_KEY"] = "test-zomato-key"

from app import create_app  # noqa: E402
from app.config import Config  # noqa: E402
from app.infra import ensure_infra, seed_all  # noqa: E402
from app.repositories import tenants as tenants_repo  # noqa: E402
from app.services import printing  # noqa: E402
from app.tenancy import tenant_scope  # noqa: E402

# A second tenant with its OWN kitchen printer + bill footer: the scoped QR
# path must print to it, never to the env/default printer.
TENANT = "kq"
TENANT_HOST = "10.9.9.9"
TENANT_FOOTER = "KQ Wi-Fi: free"
ENV_HOST = "10.0.0.9"        # stands in for ESCPOS_PRINTER_HOST (spy only)
DEAD_HOST, DEAD_PORT = "127.0.0.1", 1   # nothing listens here: refused fast


def qr_payload(table, name, phone, item_id="croissant"):
    return {
        "table_number": table,
        "items": [{"item_id": item_id, "qty": 1, "selected_options": []}],
        "customer": {"name": name, "phone": phone},
    }


def text_lines(data):
    """Printable-ASCII lines of an ESC/POS stream (control codes stripped)."""
    return ["".join(chr(b) for b in raw if 32 <= b < 127)
            for raw in data.split(b"\n")]


def line(data, prefix):
    """First printable line of `data` starting with `prefix` (or None).

    ESC/POS runs inline before a line's text (BOLD_ON etc.), so the raw
    bytes look like b"\\x1bE\\x01SOURCE: ..." — we re-sync on the prefix.
    """
    for text in text_lines(data):
        if prefix in text:
            return text[text.index(prefix):]
    return None


def sync_op(table, op_id=None, source=None, name="Sync Guest", phone=None):
    payload = {
        "table_number": table,
        "customer": {"name": name},
        "items": [{"item_id": "latte", "qty": 1, "selected_options": [
            {"group": "Size", "label": "Regular"}]}],
    }
    if phone:
        payload["customer"]["phone"] = phone
    if source:
        payload["source"] = source
    return {"op_id": op_id or str(uuid.uuid4()),
            "type": "order_create", "payload": payload}


def main():
    ensure_infra()
    seed_all()
    tenants_repo.create(slug=TENANT, display_name="KQ Cafe",
                        bill_footer=TENANT_FOOTER,
                        kitchen_printer_host=TENANT_HOST)
    ensure_infra(TENANT)
    seed_all(TENANT, owner_user="kqowner", owner_password="kqsecret123")

    app = create_app()
    c = app.test_client()
    fails = []

    def ok(name, cond, extra=""):
        if not cond:
            fails.append(name)
            print("FAIL:", name, extra)

    def bearer(token):
        return {"Authorization": "Bearer " + token}

    staff = c.post("/auth/login",
                   json={"username": "priya", "password": "staff123"}).get_json()
    sauth = bearer(staff["token"])

    # --- Spies ----------------------------------------------------------- #
    # `sent`  : every printing.send attempt  (host, port, bytes)
    # `calls` : every printing.maybe_auto_print_kot call  (order_id, result)
    # Both routes and the helper live on the same module object, so patching
    # the module attributes intercepts every flow (staff/QR/swiggy/sync).
    sent = []
    calls = []
    real_send = printing.send
    real_helper = printing.maybe_auto_print_kot

    def spy_send(host, port, data, timeout=3.0):
        sent.append({"host": host, "port": int(port), "data": data})
        return True

    def spy_helper(order):
        result = real_helper(order)          # still talks to spy_send
        calls.append({"order_id": (order or {}).get("id"), "result": result})
        return result

    def reset():
        sent.clear()
        calls.clear()

    printing.send = spy_send
    printing.maybe_auto_print_kot = spy_helper
    try:
        # ------------------------------------------------------------------ #
        # 1. AUTO_PRINT_KOT off (default) -> no attempt, helper returns False
        # ------------------------------------------------------------------ #
        Config.ESCPOS_PRINTER_HOST = ENV_HOST   # a host IS configured ...
        os.environ.pop("AUTO_PRINT_KOT", None)
        r = c.post("/public/orders", json=qr_payload(7, "Off Guest",
                                                     "9000000007"))
        ok("flag off: QR order still 201", r.status_code == 201,
           str(r.status_code) + str(r.get_json()))
        # The route still CALLS the helper (it decides internally); with the
        # flag off every call must no-op: False return, zero sends.
        ok("flag off: helper called but no-op, nothing sent",
           len(calls) == 1 and calls[0]["result"] is False and not sent,
           f"calls={calls} sent={len(sent)}")
        ok("flag off: helper returns False",
           real_helper({"id": "X", "items": []}) is False)
        reset()

        os.environ["AUTO_PRINT_KOT"] = "1"

        # ------------------------------------------------------------------ #
        # 2. QR self-order, LEGACY path -> exactly one KOT to the env printer
        # ------------------------------------------------------------------ #
        r = c.post("/public/orders", json=qr_payload(5, "Asha Menon",
                                                     "9876543210"))
        ok("qr legacy: order 201", r.status_code == 201,
           str(r.status_code) + str(r.get_json()))
        legacy_id = (r.get_json() or {}).get("id")
        ok("qr legacy: exactly one print attempt",
           len(calls) == 1 and calls[0]["result"] is True, str(calls))
        ok("qr legacy: exactly one send", len(sent) == 1, str(len(sent)))
        if len(sent) == 1:
            shot = sent[0]
            ok("qr legacy: sent to env printer",
               shot["host"] == ENV_HOST and shot["port"] == 9100,
               f"{shot['host']}:{shot['port']}")
            data = shot["data"]
            ok("qr legacy: KOT header", b"KITCHEN TICKET" in data)
            ok("qr legacy: SOURCE line", b"SOURCE: QR TABLE 5" in data,
               str(data[:200]))
            ok("qr legacy: customer name + phone last-4",
               b"Asha Menon" in data and b"3210" in data)
            ok("qr legacy: no prices", b"TOTAL" not in data)
        reset()

        # ------------------------------------------------------------------ #
        # 3. QR self-order, TENANT-SCOPED path -> that tenant's own printer
        # ------------------------------------------------------------------ #
        r = c.post(f"/public/{TENANT}/orders",
                   json=qr_payload(2, "Kiran Shah", "9800001111",
                                   item_id="starter-tea"))
        ok("qr scoped: order 201", r.status_code == 201,
           str(r.status_code) + str(r.get_json()))
        ok("qr scoped: exactly one print attempt",
           len(calls) == 1 and calls[0]["result"] is True, str(calls))
        ok("qr scoped: exactly one send", len(sent) == 1, str(len(sent)))
        if len(sent) == 1:
            shot = sent[0]
            ok("qr scoped: sent to the TENANT's kitchen printer",
               shot["host"] == TENANT_HOST, shot["host"])
            data = shot["data"]
            ok("qr scoped: SOURCE line", b"SOURCE: QR TABLE 2" in data)
            ok("qr scoped: customer on ticket",
               b"Kiran Shah" in data and b"1111" in data)
            ok("qr scoped: tenant brand + bill_footer",
               b"KQ Cafe" in data and TENANT_FOOTER.encode() in data,
               str(data[-120:]))
            ok("qr scoped: never the env cafe brand", b"Cafe POS Demo" not in data)
        reset()

        # ------------------------------------------------------------------ #
        # 4. Kitchen-display reprints go through the same build_kot
        # ------------------------------------------------------------------ #
        k = c.get(f"/printing/kot/{legacy_id}/bytes", headers=sauth)
        ok("reprint bytes: 200", k.status_code == 200, str(k.status_code))
        kdata = base64.b64decode((k.get_json() or {}).get("bytes_b64", ""),
                                 validate=True)
        ok("reprint bytes: SOURCE + customer",
           b"SOURCE: QR TABLE 5" in kdata and b"Asha Menon" in kdata)
        ok("reprint bytes: build-only (nothing sent)",
           not sent and not calls, f"sent={len(sent)} calls={len(calls)}")

        # legacy push reprint still sends once, to the env printer
        lk = c.post(f"/printing/kot/{legacy_id}", headers=sauth)
        ok("reprint push: 200 + sent", lk.status_code == 200
           and (lk.get_json() or {}).get("sent") is True, str(lk.get_json()))
        ok("reprint push: exactly one send, same bytes",
           len(sent) == 1 and sent[0]["host"] == ENV_HOST
           and sent[0]["data"] == kdata, str(len(sent)))
        reset()

        # ------------------------------------------------------------------ #
        # 5. Staff order (source=counter) -> one KOT, SOURCE: COUNTER
        # ------------------------------------------------------------------ #
        r = c.post("/orders", headers=sauth, json={
            "table_number": 3,
            "items": [{"item_id": "latte", "qty": 2, "selected_options": [
                {"group": "Size", "label": "Regular"}]}],
        })
        ok("staff: order 201", r.status_code == 201, str(r.status_code))
        ok("staff: exactly one print attempt",
           len(calls) == 1 and calls[0]["result"] is True, str(calls))
        ok("staff: exactly one send", len(sent) == 1, str(len(sent)))
        if len(sent) == 1:
            ok("staff: SOURCE line", b"SOURCE: COUNTER" in sent[0]["data"],
               str(sent[0]["data"][:200]))
            ok("staff: items on ticket", b"Latte" in sent[0]["data"])
        reset()

        # ------------------------------------------------------------------ #
        # 6. Delivery ingestion (Swiggy / Zomato) -> one KOT each
        # ------------------------------------------------------------------ #
        for partner, key in (("swiggy", "test-swiggy-key"),
                             ("zomato", "test-zomato-key")):
            r = c.post(f"/integrations/{partner}/orders",
                       headers={"X-Integration-Key": key}, json={
                           "order_id": f"{partner[:2].upper()}-9981",
                           "items": [{"item_id": "latte", "qty": 1,
                                      "selected_options": [
                                          {"group": "Size",
                                           "label": "Regular"}]}],
                           "customer": {"name": "Rohan Iyer",
                                        "phone": "9812345678"},
                           "address": "B-402, Riverdale",
                       })
            ok(f"{partner}: order 201", r.status_code == 201,
               str(r.status_code) + str(r.get_json()))
            ok(f"{partner}: exactly one print attempt",
               len(calls) == 1 and calls[0]["result"] is True, str(calls))
            ok(f"{partner}: exactly one send", len(sent) == 1, str(len(sent)))
            if len(sent) == 1:
                data = sent[0]["data"]
                ok(f"{partner}: SOURCE line",
                   f"SOURCE: {partner.upper()}".encode() in data,
                   str(data[:200]))
                ok(f"{partner}: customer name + phone last-4",
                   b"Rohan Iyer" in data and b"5678" in data)
                table_line = line(data, "Table")
                ok(f"{partner}: delivery order shows no table",
                   table_line == "Table" + " " * 26 + "-",
                   str(table_line))
            reset()

        # ------------------------------------------------------------------ #
        # 7. Sync: applied prints ONCE, deduped replay prints NEVER again
        # ------------------------------------------------------------------ #
        op1 = sync_op(9, name="First Replay")
        r1 = c.post("/sync/batch", headers=sauth, json={"ops": [op1]})
        res1 = (r1.get_json() or {}).get("results", [{}])[0]
        ok("sync: first replay applied", res1.get("status") == "applied",
           str(res1))
        ok("sync: first replay prints once",
           len(calls) == 1 and calls[0]["result"] is True, str(calls))
        ok("sync: first replay sends once", len(sent) == 1, str(len(sent)))

        # same op_id again (client retried the batch) -> deduped, NO 2nd KOT
        r2 = c.post("/sync/batch", headers=sauth, json={"ops": [op1]})
        res2 = (r2.get_json() or {}).get("results", [{}])[0]
        ok("sync: replay is deduped", res2.get("status") == "deduped"
           and res2.get("order_id") == res1.get("order_id"), str(res2))
        ok("sync: deduped replay does NOT print again",
           len(calls) == 1 and len(sent) == 1,
           f"calls={len(calls)} sent={len(sent)}")
        reset()

        # duplicate INSIDE one batch: applied once, then deduped in-batch
        op2 = sync_op(10, name="In Batch Dup")
        dup = c.post("/sync/batch", headers=sauth,
                     json={"ops": [op2, dict(op2)]}).get_json()["results"]
        ok("sync in-batch: applied then deduped",
           [e.get("status") for e in dup] == ["applied", "deduped"], str(dup))
        ok("sync in-batch: still exactly one KOT",
           len(calls) == 1 and len(sent) == 1,
           f"calls={len(calls)} sent={len(sent)}")
        reset()

        # QR-source sync op prints one KOT too — and its replay does not
        op3 = sync_op(6, source="qr", name="Offline QR", phone="9876500066")
        r3 = c.post("/sync/batch", headers=sauth, json={"ops": [op3]})
        ok("sync qr: applied", r3.get_json()["results"][0]["status"] == "applied",
           str(r3.get_json()))
        ok("sync qr: one KOT with SOURCE line",
           len(sent) == 1 and b"SOURCE: QR TABLE 6" in sent[0]["data"],
           f"sent={len(sent)}")
        c.post("/sync/batch", headers=sauth, json={"ops": [op3]})
        ok("sync qr: deduped replay does NOT print again",
           len(calls) == 1 and len(sent) == 1,
           f"calls={len(calls)} sent={len(sent)}")
        reset()

        # ------------------------------------------------------------------ #
        # 8. Unreachable printer: swallowed, order creation unaffected
        # ------------------------------------------------------------------ #
        printing.send = real_send                # really try the socket
        Config.ESCPOS_PRINTER_HOST = DEAD_HOST
        Config.ESCPOS_PRINTER_PORT = DEAD_PORT
        r = c.post("/public/orders", json=qr_payload(8, "Dead Guest",
                                                     "9000000008"))
        ok("dead printer: QR order still 201", r.status_code == 201,
           str(r.status_code) + str(r.get_json()))
        ok("dead printer: attempt made, failure swallowed",
           len(calls) == 1 and calls[0]["result"] is False, str(calls))
        ok("dead printer: nothing actually sent", not sent, str(len(sent)))
        ok("dead printer: direct helper call returns False, never raises",
           real_helper(r.get_json()) is False)
        printing.send = spy_send
        Config.ESCPOS_PRINTER_HOST = ENV_HOST
        Config.ESCPOS_PRINTER_PORT = 9100
        reset()

        # ------------------------------------------------------------------ #
        # 9. build_kot content: SOURCE + customer + tenant footer, no prices
        # ------------------------------------------------------------------ #
        base = {"id": "KOT42", "taken_by": "priya",
                "created_at": "2026-10-11T10:00:00+00:00",
                "items": [{"name": "Latte", "qty": 2,
                           "selected_options": [{"group": "Size",
                                                 "label": "Regular"}]}]}
        variants = [
            ("counter", "3", {"name": "Walk In", "phone": None},
             b"SOURCE: COUNTER", b"Walk In", None),
            ("qr", "5", {"name": "Asha Menon", "phone": "+91 98765 43210"},
             b"SOURCE: QR TABLE 5", b"Asha Menon", b"3210"),
            ("swiggy", None, {"name": "Rohan Iyer", "phone": "9812345678"},
             b"SOURCE: SWIGGY", b"Rohan Iyer", b"5678"),
            ("zomato", None, {"name": "Neha Rao", "phone": None},
             b"SOURCE: ZOMATO", b"Neha Rao", None),
        ]
        for source, table, customer, want_src, want_name, want_last4 in variants:
            order = dict(base, source=source, table_number=table,
                         customer=dict(customer))
            data = printing.build_kot(order, cafe=printing.cafe_info())
            ok(f"kot[{source}]: SOURCE line", want_src in data,
               str(data[:220]))
            ok(f"kot[{source}]: customer name", want_name in data)
            if want_last4:
                ok(f"kot[{source}]: phone last-4", want_last4 in data)
            cust_line = line(data, "Customer")
            if customer.get("phone"):
                ok(f"kot[{source}]: customer line carries last-4",
                   bool(cust_line) and cust_line.rstrip().endswith(")"),
                   str(cust_line))
            else:
                ok(f"kot[{source}]: customer line has no phone suffix",
                   bool(cust_line) and "(" not in cust_line, str(cust_line))
            src_line = line(data, "SOURCE:")
            ok(f"kot[{source}]: exactly one SOURCE line within 32 cols",
               data.count(b"SOURCE:") == 1
               and src_line == "SOURCE: " + printing.kot_source_label(order)
               and len(src_line) <= 32, str(src_line))
            ok(f"kot[{source}]: no prices", b"TOTAL" not in data
               and b"Sub Total" not in data)
            ok(f"kot[{source}]: init + feed/cut framing",
               data.startswith(b"\x1b\x40")
               and data.endswith(b"\x1b\x64\x04\x1d\x56\x42\x00"))

        # legacy orders with no source at all still read as COUNTER
        legacy_order = dict(base, customer=None)
        data = printing.build_kot(legacy_order, cafe=printing.cafe_info())
        ok("kot[legacy]: missing source -> COUNTER", b"SOURCE: COUNTER" in data)
        ok("kot[legacy]: no customer line", b"Customer" not in data)

        # tenant bill_footer + brand resolve per tenant
        with tenant_scope(TENANT):
            tenant_data = printing.build_kot(dict(base, source="qr",
                                                  table_number="2"))
        ok("kot[tenant]: tenant bill_footer + brand",
           TENANT_FOOTER.encode() in tenant_data and b"KQ Cafe" in tenant_data,
           str(tenant_data[-160:]))
        ok("kot[tenant]: default brand absent",
           b"Cafe POS Demo" not in tenant_data)
        reset()

        # ------------------------------------------------------------------ #
        # 10. Flag off again -> everything silent
        # ------------------------------------------------------------------ #
        os.environ.pop("AUTO_PRINT_KOT", None)
        c.post("/orders", headers=sauth, json={
            "table_number": 1,
            "items": [{"item_id": "muffin", "qty": 1, "selected_options": []}],
        })
        c.post("/public/orders", json=qr_payload(4, "Quiet Guest",
                                                 "9000000004"))
        ok("flag off again: every call no-op, zero sends across two paths",
           len(calls) == 2 and all(x["result"] is False for x in calls)
           and not sent, f"calls={calls} sent={len(sent)}")
    finally:
        printing.send = real_send
        printing.maybe_auto_print_kot = real_helper
        os.environ.pop("AUTO_PRINT_KOT", None)
        Config.ESCPOS_PRINTER_HOST = ""
        Config.ESCPOS_PRINTER_PORT = 9100

    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("\nALL KOT ROUTING CHECKS PASSED")
    print("  staff / QR legacy / QR scoped / swiggy / zomato / sync-applied "
          "-> exactly ONE KOT each")
    print("  sync deduped replay (in-batch + cross-batch) -> zero extra KOTs")
    print("  scoped QR prints to the tenant's kitchen_printer_host; dead "
          "printer swallowed (201, returns False)")
    print("  KOT: SOURCE line + customer name/phone last-4 + tenant footer, "
          "no prices")


if __name__ == "__main__":
    main()
