"""Printer-agnostic printing endpoints — bytes GETs, test page, LAN proxy send.

Offline: in-memory boto3 stub + Flask test client (same pattern as
tests/smoke_offline.py). No network, no printer: the only TCP used is a
loopback listener inside this process to prove POST /printing/send works.

Run:  python3 tests/test_printing_config.py
"""
import base64
import os
import socket
import sys
import threading
from datetime import datetime

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
from app.repositories import orders as orders_repo  # noqa: E402
from app.services import printing  # noqa: E402


def decode_ok(raw):
    """Strict base64 decode — raises if `raw` is not canonical base64."""
    return base64.b64decode(raw, validate=True)


def start_listener():
    """One-shot loopback TCP sink standing in for a network printer."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    box = {}

    def serve():
        conn, _ = srv.accept()
        with conn:
            chunks = []
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            box["data"] = b"".join(chunks)

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    return srv, port, box, t


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

    c.post("/admin/kitchen", headers=oauth,
           json={"username": "kit1", "password": "pw123", "name": "Kitchen"})
    kitchen = c.post("/auth/login",
                     json={"username": "kit1", "password": "pw123"}).get_json()
    kauth = bearer(kitchen["token"])

    order = c.post("/orders", headers=sauth, json={
        "table_number": 3,
        "items": [{"item_id": "latte", "qty": 2, "selected_options": [
            {"group": "Size", "label": "Regular"}]}],
    }).get_json()
    oid = order["id"]
    stored = orders_repo.get(oid)
    cafe = printing.cafe_info()

    # ------------------------------------------------------------------ #
    # 1. GET receipt bytes — build only, exact shape
    # ------------------------------------------------------------------ #
    r = c.get(f"/printing/receipt/{oid}/bytes", headers=sauth)
    ok("receipt-bytes: 200", r.status_code == 200, str(r.status_code))
    rj = r.get_json()
    ok("receipt-bytes: exact keys",
       set(rj) == {"order_id", "bytes_b64", "length"}, str(sorted(rj)))
    ok("receipt-bytes: order_id", rj.get("order_id") == oid)
    data = decode_ok(rj.get("bytes_b64", ""))
    ok("receipt-bytes: valid base64", bool(data))
    ok("receipt-bytes: length matches", rj.get("length") == len(data))
    ok("receipt-bytes: matches build_receipt",
       data == printing.build_receipt(stored, cafe=cafe))
    ok("receipt-bytes: init sequence", data.startswith(b"\x1b\x40"))
    ok("receipt-bytes: cafe name", b"Cafe POS Demo" in data)
    ok("receipt-bytes: order id", oid.encode() in data)

    ok("receipt-bytes: 401 unauthenticated",
       c.get(f"/printing/receipt/{oid}/bytes").status_code == 401)
    ok("receipt-bytes: 404 unknown order",
       c.get("/printing/receipt/NOPE0/bytes",
             headers=sauth).status_code == 404)

    # ------------------------------------------------------------------ #
    # 2. GET KOT bytes
    # ------------------------------------------------------------------ #
    k = c.get(f"/printing/kot/{oid}/bytes", headers=sauth)
    ok("kot-bytes: 200", k.status_code == 200, str(k.status_code))
    kj = k.get_json()
    ok("kot-bytes: exact keys",
       set(kj) == {"order_id", "bytes_b64", "length"}, str(sorted(kj)))
    kdata = decode_ok(kj.get("bytes_b64", ""))
    ok("kot-bytes: valid base64", bool(kdata))
    ok("kot-bytes: length matches", kj.get("length") == len(kdata))
    ok("kot-bytes: matches build_kot",
       kdata == printing.build_kot(stored, cafe=cafe))
    ok("kot-bytes: header", b"KITCHEN TICKET" in kdata)
    ok("kot-bytes: no prices", b"TOTAL" not in kdata and b"Sub Total" not in kdata)
    ok("kot-bytes: 404 unknown order",
       c.get("/printing/kot/NOPE0/bytes", headers=sauth).status_code == 404)

    # ------------------------------------------------------------------ #
    # 3. GET test page bytes
    # ------------------------------------------------------------------ #
    t = c.get("/printing/test/bytes", headers=sauth)
    ok("test-bytes: 200", t.status_code == 200, str(t.status_code))
    tj = t.get_json()
    ok("test-bytes: exact keys",
       set(tj) == {"bytes_b64", "length"}, str(sorted(tj)))
    tdata = decode_ok(tj.get("bytes_b64", ""))
    ok("test-bytes: valid base64", bool(tdata))
    ok("test-bytes: length matches", tj.get("length") == len(tdata))
    ok("test-bytes: matches build_test", tdata == printing.build_test(cafe=cafe))
    ok("test-bytes: PRINTER TEST", b"PRINTER TEST" in tdata)
    ok("test-bytes: configured-by line", b"Configured by" in tdata)
    ok("test-bytes: cafe header", b"Cafe POS Demo" in tdata)
    ok("test-bytes: address", b"MG Road" in tdata)
    ok("test-bytes: phone", b"+91" in tdata)
    ok("test-bytes: gstin", b"GSTIN" in tdata)
    ok("test-bytes: today", datetime.now().strftime("%Y-%m-%d").encode() in tdata)
    ok("test-bytes: sample GST",
       b"CGST @ 2.5%" in tdata and b"SGST @ 2.5%" in tdata)
    ok("test-bytes: dashed separator", b"-" * 32 in tdata)
    ok("test-bytes: init + feed/cut",
       tdata.startswith(b"\x1b\x40") and tdata.endswith(b"\x1b\x64\x04\x1d\x56\x42\x00"))
    ok("test-bytes: owner 200",
       c.get("/printing/test/bytes", headers=oauth).status_code == 200)

    # ------------------------------------------------------------------ #
    # 4. Role matrix
    # ------------------------------------------------------------------ #
    ok("roles: kitchen may fetch KOT bytes",
       c.get(f"/printing/kot/{oid}/bytes", headers=kauth).status_code == 200)
    ok("roles: kitchen blocked from receipt bytes",
       c.get(f"/printing/receipt/{oid}/bytes",
             headers=kauth).status_code == 403)
    ok("roles: kitchen blocked from test bytes",
       c.get("/printing/test/bytes", headers=kauth).status_code == 403)
    ok("roles: kitchen blocked from send",
       c.post("/printing/send", headers=kauth, json={}).status_code == 403)
    ok("roles: staff receipt bytes 200",
       c.get(f"/printing/receipt/{oid}/bytes",
             headers=sauth).status_code == 200)
    ok("roles: staff kot bytes 200",
       c.get(f"/printing/kot/{oid}/bytes", headers=sauth).status_code == 200)
    ok("roles: staff test bytes 200",
       c.get("/printing/test/bytes", headers=sauth).status_code == 200)

    # ------------------------------------------------------------------ #
    # 5. POST /printing/send — validation (400)
    # ------------------------------------------------------------------ #
    good_b64 = base64.b64encode(tdata).decode("ascii")

    def send(payload, headers=None):
        return c.post("/printing/send", headers=headers or sauth, json=payload)

    ok("send: missing bytes_b64 -> 400",
       send({"host": "127.0.0.1"}).status_code == 400)
    ok("send: empty bytes_b64 -> 400",
       send({"bytes_b64": "", "host": "127.0.0.1"}).status_code == 400)
    ok("send: bad base64 -> 400",
       send({"bytes_b64": "!!!not-base64!!!", "host": "127.0.0.1"}).status_code == 400)
    ok("send: missing host -> 400",
       send({"bytes_b64": good_b64}).status_code == 400)
    ok("send: blank host -> 400",
       send({"bytes_b64": good_b64, "host": "   "}).status_code == 400)
    ok("send: port 0 -> 400",
       send({"bytes_b64": good_b64, "host": "127.0.0.1", "port": 0}).status_code == 400)
    ok("send: port 70000 -> 400",
       send({"bytes_b64": good_b64, "host": "127.0.0.1",
             "port": 70000}).status_code == 400)
    ok("send: port 'abc' -> 400",
       send({"bytes_b64": good_b64, "host": "127.0.0.1",
             "port": "abc"}).status_code == 400)
    ok("send: 401 unauthenticated",
       c.post("/printing/send", json={}).status_code == 401)

    # ------------------------------------------------------------------ #
    # 6. POST /printing/send — unreachable target -> 502
    # ------------------------------------------------------------------ #
    dead = send({"bytes_b64": good_b64, "host": "127.0.0.1", "port": 1})
    ok("send: unreachable -> 502", dead.status_code == 502, str(dead.status_code))
    ok("send: 502 message names target",
       "Could not reach printer at 127.0.0.1:1" in
       (dead.get_json() or {}).get("error", ""), str(dead.get_json()))

    # ------------------------------------------------------------------ #
    # 7. POST /printing/send — success against a loopback listener
    # ------------------------------------------------------------------ #
    srv, port, box, thread = start_listener()
    try:
        sent = send({"bytes_b64": good_b64, "host": "127.0.0.1", "port": port})
        ok("send: 200", sent.status_code == 200, str(sent.status_code))
        sj = sent.get_json() or {}
        ok("send: response shape",
           sj.get("sent") is True and sj.get("host") == "127.0.0.1"
           and sj.get("port") == port, str(sj))
        thread.join(timeout=5)
        ok("send: bytes arrived intact", box.get("data") == tdata,
           f"{len(box.get('data', b''))} bytes")
    finally:
        srv.close()

    # default port 9100 when `port` is omitted
    dflt = send({"bytes_b64": good_b64, "host": "127.0.0.1"})
    dj = dflt.get_json() or {}
    ok("send: port omitted -> 9100",
       (dflt.status_code == 200 and dj.get("port") == 9100)
       or (dflt.status_code == 502 and "127.0.0.1:9100" in dj.get("error", "")),
       f"{dflt.status_code} {dj}")

    # ------------------------------------------------------------------ #
    # 8. Legacy POSTs unchanged — env host unset -> dry-run bytes
    # ------------------------------------------------------------------ #
    legacy = c.post(f"/printing/receipt/{oid}", headers=sauth)
    ok("legacy: receipt 200", legacy.status_code == 200, str(legacy.status_code))
    lj = legacy.get_json()
    ok("legacy: dry_run true", lj.get("dry_run") is True, str(lj))
    ok("legacy: bytes_len", lj.get("bytes_len") == len(data))
    ok("legacy: bytes match GET endpoint", lj.get("bytes_b64") == rj.get("bytes_b64"))

    lk = c.post(f"/printing/kot/{oid}", headers=sauth)
    ok("legacy: kot dry_run", (lk.get_json() or {}).get("dry_run") is True)
    ok("legacy: kot bytes match GET endpoint",
       (lk.get_json() or {}).get("bytes_b64") == kj.get("bytes_b64"))
    ok("legacy: kitchen may POST KOT",
       c.post(f"/printing/kot/{oid}", headers=kauth).status_code == 200)
    ok("legacy: kitchen blocked from receipt POST",
       c.post(f"/printing/receipt/{oid}", headers=kauth).status_code == 403)

    if fails:
        print(f"\n{len(fails)} CHECK(S) FAILED")
        sys.exit(1)
    print("\nALL PRINTING CONFIG CHECKS PASSED")
    print(f"  receipt/kot/test bytes endpoints build-only (no send)")
    print(f"  staff: all 200 | kitchen: kot 200, receipt/test/send 403")
    print(f"  send: 400 validation, 502 unreachable, 200 via loopback")


if __name__ == "__main__":
    main()
