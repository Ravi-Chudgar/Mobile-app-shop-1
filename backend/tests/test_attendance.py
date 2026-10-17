"""Attendance feature checks: staff clock in / clock out, with the rule that
a recorded clock-in can never be changed — no edit endpoint exists, and any
second attempt gets a 409 — plus per-cafe isolation of the records.

Mirrors tests/test_platform_admin.py's offline harness (in-memory boto3 stub
+ Flask test client). Needs a reachable Redis for the cache layer.
Run: REDIS_URL=redis://127.0.0.1:6379/3 python3 tests/test_attendance.py
"""
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
from app.cache import get_redis                  # noqa: E402
from app.infra import ensure_infra, seed_all     # noqa: E402


def main():
    get_redis().flushdb()
    ensure_infra()
    seed_all()
    app = create_app()
    c = app.test_client()

    fails = []

    def ok(name, cond, extra=""):
        if not cond:
            fails.append(name)
            print("FAIL:", name, extra)

    # --- staff session (priya is the seeded, approved staff of 'main') ---
    priya = c.post("/auth/login",
                   json={"username": "priya", "password": "staff123"}
                   ).get_json()
    ok("priya login role=staff", priya.get("role") == "staff", str(priya))
    ph = {"Authorization": "Bearer " + priya["token"]}

    # --- 1. fresh day: nothing recorded yet ---
    me = c.get("/attendance/me", headers=ph).get_json()
    ok("GET /attendance/me starts with no record", me.get("record") is None,
       str(me))

    # --- 2. clock in ---
    ci = c.post("/attendance/clock-in", headers=ph)
    ok("clock-in -> 201", ci.status_code == 201, str(ci.status_code))
    rec = ci.get_json()["record"]
    ok("record carries a local HH:MM stamp", bool(rec.get("clock_in_local")),
       str(rec))
    ok("record status is 'in'", rec.get("status") == "in", str(rec))
    ok("record clock_out is null", rec.get("clock_out") is None, str(rec))
    first_stamp = rec.get("clock_in")

    # --- 3. the clock-in is IMMUTABLE ---
    again = c.post("/attendance/clock-in", headers=ph)
    ok("second clock-in -> 409", again.status_code == 409,
       str(again.status_code))
    err = (again.get_json() or {}).get("error") or ""
    ok("409 explains the rule", "cannot be changed" in err, err)

    # ... and there is no verb that could rewrite a stored stamp
    for method in ("put", "patch", "delete"):
        r1 = getattr(c, method)("/attendance/clock-in", headers=ph)
        ok(f"no {method.upper()} /attendance/clock-in", r1.status_code in (404, 405),
           str(r1.status_code))
        r2 = getattr(c, method)("/attendance/me", headers=ph)
        ok(f"no {method.upper()} /attendance/me", r2.status_code in (404, 405),
           str(r2.status_code))

    me2 = c.get("/attendance/me", headers=ph).get_json()["record"]
    ok("clock_in stamp unchanged after all attempts",
       me2.get("clock_in") == first_stamp, str(me2))

    # --- 4. clock out ---
    co = c.post("/attendance/clock-out", headers=ph)
    ok("clock-out -> 200", co.status_code == 200, str(co.status_code))
    out = co.get_json()["record"]
    ok("status flips to 'out'", out.get("status") == "out", str(out))
    ok("clock_out_local set", bool(out.get("clock_out_local")), str(out))
    ok("clock_in preserved through clock-out",
       out.get("clock_in") == first_stamp, str(out))

    # --- 5. both stamps are one-shot ---
    co2 = c.post("/attendance/clock-out", headers=ph)
    ok("second clock-out -> 409", co2.status_code == 409, str(co2.status_code))
    ci2 = c.post("/attendance/clock-in", headers=ph)
    ok("clock-in after clock-out -> 409", ci2.status_code == 409,
       str(ci2.status_code))

    # --- 6. clock-out without any clock-in (owner never clocked in) ---
    owner = c.post("/auth/login",
                   json={"username": "owner", "password": "cafe123"}).get_json()
    oh = {"Authorization": "Bearer " + owner["token"]}
    co_no = c.post("/attendance/clock-out", headers=oh)
    ok("clock-out with no clock-in -> 400", co_no.status_code == 400,
       str(co_no.status_code))

    # --- 7. anonymous access refused ---
    anon = c.post("/attendance/clock-in")
    ok("clock-in requires a token (401)", anon.status_code == 401,
       str(anon.status_code))

    # --- 8. per-cafe isolation: another cafe gets its OWN records ---
    adm = c.post("/auth/login",
                 json={"username": "admin", "password": "admin@2026"}).get_json()
    ah = {"Authorization": "Bearer " + adm["token"]}
    created = c.post("/platform/tenants", headers=ah, json={
        "slug": "shiftlab", "display_name": "Shift Lab",
        "owner_username": "shift_owner", "owner_password": "shift123"})
    ok("second cafe created", created.status_code == 201, str(created.status_code))
    sh_login = c.post("/auth/login", json={
        "username": "shift_owner", "password": "shift123",
        "tenant": "shiftlab"}).get_json()
    sh = {"Authorization": "Bearer " + sh_login["token"]}
    sh_ci = c.post("/attendance/clock-in", headers=sh)
    ok("shiftlab owner can clock in", sh_ci.status_code == 201,
       str(sh_ci.status_code))

    # ... and none of that touched the default cafe's records
    main_owner = c.get("/attendance/me", headers=oh).get_json()["record"]
    ok("main owner still has no record (isolated)", main_owner is None,
       str(main_owner))
    main_staff = c.get("/attendance/me", headers=ph).get_json()["record"]
    ok("main staff record untouched by shiftlab",
       main_staff.get("clock_out") is not None, str(main_staff))

    if fails:
        print(f"\n{len(fails)} FAILED")
        sys.exit(1)
    print("ALL ATTENDANCE CHECKS PASSED")


if __name__ == "__main__":
    main()
