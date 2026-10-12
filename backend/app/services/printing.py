"""Pure-Python ESC/POS thermal printing — byte builder + TCP sender.

No third-party dependencies. Money is always passed in as integer minor units
(paise) and rendered in rupees.

Dry-run mode: when `ESCPOS_PRINTER_HOST` is empty, callers should build the
bytes but skip sending (see routes/printing.py).
"""
import logging
import os
import socket
from datetime import datetime

from ..config import Config
from ..repositories import tenants as tenants_repo
from ..tenancy import current_tenant

logger = logging.getLogger(__name__)

# 58 mm paper: 32 columns is the safe universal width.
COLS = 32

# --- ESC/POS control sequences -----------------------------------------------
INIT = b"\x1b\x40"         # reset printer
ALIGN_LEFT = b"\x1b\x61\x00"
ALIGN_CENTER = b"\x1b\x61\x01"
ALIGN_RIGHT = b"\x1b\x61\x02"
BOLD_ON = b"\x1b\x45\x01"
BOLD_OFF = b"\x1b\x45\x00"
DOUBLE_W = b"\x1b\x21\x08"     # double-width chars
DOUBLE_WH = b"\x1b\x21\x18"    # double width + height
NORMAL = b"\x1b\x21\x00"
FEED_CUT = b"\x1b\x64\x04" + b"\x1d\x56\x42\x00"  # feed 4 lines, full cut


def inr(paise):
    """Integer paise -> Indian-grouped rupee string, e.g. 123456 -> '1,234.56'."""
    paise = int(paise or 0)
    sign = "-" if paise < 0 else ""
    p = abs(paise)
    whole = str(p // 100)
    frac = f"{p % 100:02d}"
    if len(whole) > 3:
        tail = whole[-3:]
        head = whole[:-3]
        groups = []
        while len(head) > 2:
            groups.insert(0, head[-2:])
            head = head[:-2]
        if head:
            groups.insert(0, head)
        whole = ",".join(groups + [tail])
    return f"{sign}{whole}.{frac}"


def _pad_line(left, right, width=COLS):
    left = str(left).encode("ascii", "replace").decode("ascii")
    right = str(right).encode("ascii", "replace").decode("ascii")
    if len(left) + len(right) + 1 > width:
        room = max(width - len(right) - 1, 1)
        left = left[:max(room - 1, 1)] + "?"
    gap = width - len(left) - len(right)
    return left + " " * max(gap, 1) + right


def _wrap(text, width=COLS):
    words = str(text).split()
    lines, cur = [], ""
    for w in words:
        cand = f"{cur} {w}".strip()
        if len(cand) <= width:
            cur = cand
        else:
            if cur:
                lines.append(cur)
            cur = w[:width]
    if cur:
        lines.append(cur)
    return lines or [""]


def _safe(text):
    """ASCII-safe text for CP437 thermal fonts (₹, emoji etc. become '?')."""
    return str(text).encode("ascii", "replace").decode("ascii")


def _tenant_entry():
    """Current tenant's registry row ({} outside Flask / unknown tenant /
    before ensure_infra created the registry table)."""
    try:
        return tenants_repo.get(current_tenant()) or {}
    except Exception:  # noqa: BLE001 — printing must never break a request
        return {}


def cafe_info(overrides=None):
    """Cafe/tenant identity used on bills/receipts.

    Registry first: the current tenant's `cafe_tenants` row supplies the
    display name, address, GSTIN, phone and bill footer. Each field falls
    back to the env-backed Config values (CAFE_NAME & co.) when the tenant
    has no row yet or leaves the field empty — so the default tenant and
    older env-configured deployments behave exactly as before.
    """
    entry = _tenant_entry()
    info = {
        "name": entry.get("display_name") or Config.CAFE_NAME,
        "address": entry.get("address") or Config.CAFE_ADDRESS,
        "gstin": entry.get("gstin") or Config.CAFE_GSTIN,
        "phone": entry.get("phone") or Config.CAFE_PHONE,
        "bill_footer": entry.get("bill_footer") or "",
    }
    if overrides:
        info.update({k: v for k, v in overrides.items() if v})
    return info


def _paid(order):
    if order.get("paid_amount") is not None:
        return int(order.get("paid_amount") or 0)
    return int(order.get("total", 0)) if order.get("payment_status") == "paid" else 0


def order_payments(order):
    """Effective payment list for an order (legacy orders synthesise one)."""
    payments = order.get("payments")
    if payments:
        return [dict(p) for p in payments]
    paid = _paid(order)
    if paid > 0:
        return [{"method": order.get("payment_method") or "cash", "amount": paid}]
    return []


def _tax_by_rate(lines):
    buckets = {}
    for line in lines or []:
        rate = int(line.get("gst_rate", 0) or 0)
        b = buckets.setdefault(rate, {"rate": rate, "taxable": 0, "cgst": 0,
                                      "sgst": 0})
        b["taxable"] += int(line.get("taxable_value", 0) or 0)
        b["cgst"] += int(line.get("cgst", 0) or 0)
        b["sgst"] += int(line.get("sgst", 0) or 0)
    return [buckets[r] for r in sorted(buckets)]


def build_receipt(order, cafe=None, payments=None):
    """Build an ESC/POS byte stream for a customer receipt.

    order:  order dict (money in paise; tax fields optional on legacy orders)
    cafe:   {name, address, gstin, phone, bill_footer} — defaults to
            cafe_info() (current tenant's registry row, env fallback)
    payments: list of {method, amount, ref?}; defaults to the order's own
    Returns bytes ready to write to a printer socket.
    """
    cafe = cafe or cafe_info()
    lines = order.get("items", [])
    if payments is None:
        payments = order_payments(order)

    sub_total = int(order.get("sub_total")
                    if order.get("sub_total") is not None
                    else order.get("total", 0) or 0)
    tax_total = int(order.get("tax_total") or 0)
    total = int(order.get("total", 0) or 0)

    out = [INIT, ALIGN_CENTER, DOUBLE_WH, BOLD_ON]
    out.append(_safe(cafe.get("name") or "Cafe").encode("ascii") + b"\n")
    out += [NORMAL, BOLD_OFF]
    for key in ("address", "phone"):
        if cafe.get(key):
            for l in _wrap(cafe[key]):
                out.append(_safe(l).encode("ascii") + b"\n")
    if cafe.get("gstin"):
        out.append(f"GSTIN: {cafe['gstin']}".encode("ascii") + b"\n")
    out += [ALIGN_LEFT, b"-" * COLS + b"\n"]

    out.append(_pad_line("Order", str(order.get("id", ""))).encode("ascii") + b"\n")
    out.append(_pad_line("Date", str(order.get("created_at", ""))[:19].replace("T", " "))
               .encode("ascii") + b"\n")
    out.append(_pad_line("Table", str(order.get("table_number") or "-"))
               .encode("ascii") + b"\n")
    out.append(_pad_line("Staff", str(order.get("taken_by") or "-"))
               .encode("ascii") + b"\n")
    customer = (order.get("customer") or {}).get("name")
    if customer:
        out.append(_pad_line("Customer", str(customer)).encode("ascii") + b"\n")
    out.append(b"-" * COLS + b"\n")

    # --- Items with HSN + GST rate per line ---
    for line in lines:
        qty = int(line.get("qty", 1) or 1)
        name = f"{line.get('name', '?')} x{qty}"
        out.append(_pad_line(name, inr(line.get("line_total", 0)))
                   .encode("ascii") + b"\n")
        meta = f"  HSN {line.get('hsn_code') or '9963'} @ {int(line.get('gst_rate', 0) or 0)}%"
        out.append(_safe(meta).encode("ascii") + b"\n")
        for sel in line.get("selected_options", []) or []:
            out.append(f"  - {sel.get('label', '')}".encode("ascii", "replace") + b"\n")

    out.append(b"-" * COLS + b"\n")
    out.append(_pad_line("Sub Total (incl.)", inr(sub_total)).encode("ascii") + b"\n")

    # --- Per-rate GST summary ---
    cgst_total = sum(int(l.get("cgst", 0) or 0) for l in lines)
    sgst_total = sum(int(l.get("sgst", 0) or 0) for l in lines)
    for b in _tax_by_rate(lines):
        out.append(_pad_line(f"GST @{b['rate']}% taxable", inr(b["taxable"]))
                   .encode("ascii") + b"\n")
        out.append(_pad_line(f"  CGST @{b['rate']}%", inr(b["cgst"]))
                   .encode("ascii") + b"\n")
        out.append(_pad_line(f"  SGST @{b['rate']}%", inr(b["sgst"]))
                   .encode("ascii") + b"\n")
    if not tax_total and (cgst_total or sgst_total):
        tax_total = cgst_total + sgst_total
    out.append(_pad_line("CGST", inr(cgst_total)).encode("ascii") + b"\n")
    out.append(_pad_line("SGST", inr(sgst_total)).encode("ascii") + b"\n")

    out += [BOLD_ON]
    out.append(_pad_line("TOTAL", inr(total)).encode("ascii") + b"\n")
    out += [BOLD_OFF]
    out.append(b"-" * COLS + b"\n")

    # --- Payments ---
    paid = sum(int(p.get("amount", 0) or 0) for p in payments)
    for p in payments:
        out.append(_pad_line(str(p.get("method", "cash")).upper(),
                             inr(p.get("amount", 0))).encode("ascii") + b"\n")
    if paid > total:
        out.append(_pad_line("CHANGE", inr(paid - total)).encode("ascii") + b"\n")
    elif not payments:
        out.append(_pad_line("Status",
                             str(order.get("payment_status", "")).upper())
                   .encode("ascii") + b"\n")

    out.append(b"-" * COLS + b"\n")
    out.append(ALIGN_CENTER)
    # Tenant-configured footer line (bill_footer), e.g. WiFi name or
    # "Includes all taxes". Empty for tenants that do not set one.
    for l in _wrap(cafe.get("bill_footer") or ""):
        if l:
            out.append(_safe(l).encode("ascii") + b"\n")
    for l in ("Prices inclusive of GST", "Thank you! Visit again."):
        out.append(_safe(l).encode("ascii") + b"\n")
    out += [NORMAL, ALIGN_LEFT, FEED_CUT]
    return b"".join(out)


def kot_source_label(order):
    """Kitchen-facing SOURCE label for a KOT, from order.source + table.

    counter -> "COUNTER", qr -> "QR TABLE 5" (or "QR SELF-ORDER" without a
    table), swiggy/zomato/... -> the partner name in upper case. Anything
    unknown is passed through upper-cased so the kitchen still sees *some*
    channel. Truncated to the 58 mm paper width.
    """
    source = str(order.get("source") or "counter").strip().lower() or "counter"
    if source == "qr":
        table = str(order.get("table_number") or "").strip()
        label = f"QR TABLE {table}" if table else "QR SELF-ORDER"
    elif source == "counter":
        label = "COUNTER"
    else:
        label = source.upper()
    return _safe(label)[:max(COLS - len("SOURCE: "), 1)]


def kot_customer(order):
    """Compact customer line for a KOT: name, plus phone last-4 when set.

    Empty string when the order carries no customer name (the kitchen only
    needs it for QR/delivery tickets — a counter walk-up may have none).
    """
    customer = order.get("customer") or {}
    name = str(customer.get("name") or "").strip()
    if not name:
        return ""
    digits = "".join(ch for ch in str(customer.get("phone") or "")
                     if ch.isdigit())
    if digits:
        return f"{name} ({digits[-4:]})"
    return name


def build_kot(order, cafe=None):
    """Kitchen order ticket: source, customer, id, table, items, notes.

    NO prices. Layout (58 mm / 32 cols, bold title + dashed separators)::

        KITCHEN TICKET            <- double-width bold, centred
        <cafe name>
        --------------------------------
        SOURCE: QR TABLE 5        <- bold, what the kitchen asks first
        Customer Asha (4321)
        Order    A1B2C3
        Table    5
        Staff    qr
        Time     2026-10-11 21:04:10
        --------------------------------
        1 x Latte
            - Regular
        --------------------------------
        Notes:
        ...
        --------------------------------
            *** KOT ***
        <tenant bill_footer>

    Both reprint paths (POST /printing/kot/<id> and GET .../bytes) build
    through here, so they pick up the SOURCE/customer lines for free.
    """
    cafe = cafe or cafe_info()
    out = [INIT, ALIGN_CENTER, DOUBLE_W, BOLD_ON]
    out.append(b"KITCHEN TICKET" + b"\n")
    out += [NORMAL, BOLD_OFF]
    out.append(_safe(cafe.get("name") or "Cafe").encode("ascii") + b"\n")
    out += [ALIGN_LEFT, b"-" * COLS + b"\n"]
    out += [BOLD_ON]
    out.append(f"SOURCE: {kot_source_label(order)}".encode("ascii") + b"\n")
    out += [BOLD_OFF]
    customer = kot_customer(order)
    if customer:
        out.append(_pad_line("Customer", customer).encode("ascii") + b"\n")
    out.append(_pad_line("Order", str(order.get("id", ""))).encode("ascii") + b"\n")
    out.append(_pad_line("Table", str(order.get("table_number") or "-"))
               .encode("ascii") + b"\n")
    out.append(_pad_line("Staff", str(order.get("taken_by") or "-"))
               .encode("ascii") + b"\n")
    out.append(_pad_line("Time", str(order.get("created_at", ""))[:19].replace("T", " "))
               .encode("ascii") + b"\n")
    out.append(b"-" * COLS + b"\n")
    for line in order.get("items", []) or []:
        qty = int(line.get("qty", 1) or 1)
        out.append(_pad_line(f"{qty} x {line.get('name', '?')}", "")
                   .encode("ascii") + b"\n")
        for sel in line.get("selected_options", []) or []:
            out.append(f"    - {sel.get('label', '')}".encode("ascii", "replace") + b"\n")
    notes = order.get("notes")
    if notes:
        out.append(b"-" * COLS + b"\n")
        out.append(b"Notes:" + b"\n")
        for l in _wrap(str(notes)):
            out.append(_safe(l).encode("ascii") + b"\n")
    out.append(b"-" * COLS + b"\n")
    out += [ALIGN_CENTER]
    out.append(b"*** KOT ***" + b"\n")
    # Tenant-configured footer line (bill_footer), same as the receipt.
    for l in _wrap(cafe.get("bill_footer") or ""):
        if l:
            out.append(_safe(l).encode("ascii") + b"\n")
    out += [NORMAL, ALIGN_LEFT, FEED_CUT]
    return b"".join(out)


def build_test(cafe=None):
    """Printer test page: cafe header, big title, date/time, sample GST.

    Same builder style as build_receipt/build_kot — returns bytes ready to
    write to a printer socket. Used by GET /printing/test/bytes so the app
    can push a self-test sheet to any printer it can reach.
    """
    cafe = cafe or cafe_info()
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    out = [INIT, ALIGN_CENTER, DOUBLE_WH, BOLD_ON]
    out.append(_safe(cafe.get("name") or "Cafe").encode("ascii") + b"\n")
    out += [NORMAL, BOLD_OFF]
    for key in ("address", "phone"):
        if cafe.get(key):
            for l in _wrap(cafe[key]):
                out.append(_safe(l).encode("ascii") + b"\n")
    if cafe.get("gstin"):
        out.append(f"GSTIN: {cafe['gstin']}".encode("ascii") + b"\n")
    out += [ALIGN_LEFT, b"-" * COLS + b"\n"]

    out += [ALIGN_CENTER, DOUBLE_WH, BOLD_ON]
    out.append(b"PRINTER TEST" + b"\n")
    out += [NORMAL, BOLD_OFF]
    out.append(_safe("Configured by Café POS").encode("ascii") + b"\n")
    out.append(_safe(stamp).encode("ascii") + b"\n")

    out += [ALIGN_LEFT, b"-" * COLS + b"\n"]
    out.append(_pad_line("Sample taxable", inr(10000)).encode("ascii") + b"\n")
    out.append(_pad_line("CGST @ 2.5%", inr(250)).encode("ascii") + b"\n")
    out.append(_pad_line("SGST @ 2.5%", inr(250)).encode("ascii") + b"\n")
    out += [BOLD_ON]
    out.append(_pad_line("TOTAL", inr(10500)).encode("ascii") + b"\n")
    out += [BOLD_OFF, b"-" * COLS + b"\n", ALIGN_CENTER]
    out.append(_safe("End of test page").encode("ascii") + b"\n")
    out += [NORMAL, ALIGN_LEFT, FEED_CUT]
    return b"".join(out)


def send(host, port, data, timeout=3.0):
    """Send raw bytes to a TCP printer (port 9100 by default). Raises OSError."""
    with socket.create_connection((host, int(port)), timeout=timeout) as sock:
        sock.sendall(data)
    logger.info("Sent %d bytes to printer %s:%s", len(data), host, port)
    return True


# --- Auto-print KOT ----------------------------------------------------------

def auto_print_enabled():
    """True when AUTO_PRINT_KOT is on (env wins over the import-time Config)."""
    raw = os.environ.get("AUTO_PRINT_KOT")
    if raw is None:
        raw = Config.AUTO_PRINT_KOT
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def kitchen_printer_host():
    """Printer host used for auto-KOTs of the CURRENT tenant.

    Precedence: the tenant registry's `kitchen_printer_host` (per-tenant
    kitchen printer) when set, otherwise the env-configured
    `ESCPOS_PRINTER_HOST` (global fallback / dry-run when empty). The port
    is always the global ESCPOS_PRINTER_PORT.
    """
    host = _tenant_entry().get("kitchen_printer_host")
    return host or Config.ESCPOS_PRINTER_HOST


def maybe_auto_print_kot(order):
    """Best-effort auto-print of a kitchen order ticket.

    No-op (returns False) unless AUTO_PRINT_KOT is enabled AND a printer host
    is configured — the host comes from the tenant's registry
    (kitchen_printer_host) or falls back to ESCPOS_PRINTER_HOST, see
    kitchen_printer_host(). Any failure is logged and swallowed — this is
    called from the order-create path and must never break order creation.
    """
    if not order or not auto_print_enabled():
        return False
    host = kitchen_printer_host()
    if not host:
        logger.debug("AUTO_PRINT_KOT on but no printer host configured for "
                     "tenant %s — skipping KOT for order %s",
                     current_tenant(), order.get("id"))
        return False
    try:
        data = build_kot(order, cafe=cafe_info())
        send(host, Config.ESCPOS_PRINTER_PORT, data)
        return True
    except Exception as exc:  # noqa: BLE001 — never raise into the request path
        logger.warning("Auto KOT print failed for order %s: %s",
                       order.get("id"), exc)
        return False
