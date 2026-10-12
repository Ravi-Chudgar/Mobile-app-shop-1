"""Server-rendered plain-text bill (GST breakdown) + WhatsApp share link.

GET /orders/<id>/bill -> {"order_id", "text", "wa_link", "phone", "cafe"}
The text is formatted on the server so every client (Flutter, web, WhatsApp)
shows the identical GST-aware bill.
"""
import urllib.parse

from flask import Blueprint, jsonify

from ..auth import any_required
from ..config import Config
from ..repositories import orders as orders_repo
from ..services import printing
from ..util import ApiError

bp = Blueprint("bills", __name__)


def _rupees(paise):
    return printing.inr(paise)


def _phone_digits(phone):
    digits = "".join(c for c in str(phone or "") if c.isdigit())
    if not digits:
        return None
    if digits.startswith("0091"):
        digits = digits[4:]
    if len(digits) == 12 and digits.startswith("91"):
        return digits
    if len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]
    if len(digits) == 10:
        return "91" + digits
    return digits


def _paid(order):
    if order.get("paid_amount") is not None:
        return int(order.get("paid_amount") or 0)
    return int(order.get("total", 0)) if order.get("payment_status") == "paid" else 0


def render_bill_text(order):
    """Plain-text bill with the full GST breakdown (money in paise)."""
    cafe = printing.cafe_info()
    lines = order.get("items", [])
    sub_total = order.get("sub_total")
    sub_total = int(order.get("total", 0) or 0) if sub_total is None else int(sub_total)
    cgst_total = sum(int(l.get("cgst", 0) or 0) for l in lines)
    sgst_total = sum(int(l.get("sgst", 0) or 0) for l in lines)
    total = int(order.get("total", 0) or 0)

    out = []
    out.append(cafe["name"])
    if cafe.get("address"):
        out.append(cafe["address"])
    if cafe.get("gstin"):
        out.append(f"GSTIN: {cafe['gstin']}")
    if cafe.get("phone"):
        out.append(f"Phone: {cafe['phone']}")
    out.append("=" * 32)
    out.append(f"Bill No : {order.get('id', '')}")
    out.append(f"Date    : {str(order.get('created_at', ''))[:19].replace('T', ' ')}")
    customer = (order.get("customer") or {})
    if customer.get("name"):
        out.append(f"Customer: {customer['name']}")
    out.append(f"Table   : {order.get('table_number') or '-'}   "
               f"Staff: {order.get('taken_by') or '-'}")
    out.append("-" * 32)
    out.append(f"{'ITEM':20} {'QTY':>3} {'AMOUNT':>9}")
    for i, line in enumerate(lines, 1):
        qty = int(line.get("qty", 1) or 1)
        name = str(line.get("name", "?"))
        out.append(f"{i}. {name[:18]:18} {qty:>3} "
                   f"{_rupees(line.get('line_total', 0)):>9}")
        opts = ", ".join(s.get("label", "") for s in (line.get("selected_options") or []))
        meta = (f"   HSN {line.get('hsn_code') or '9963'}"
                f" @ {int(line.get('gst_rate', 0) or 0)}%")
        if opts:
            meta += f" [{opts}]"
        out.append(meta)
    out.append("-" * 32)
    out.append(f"{'Sub Total (incl.)':22}{_rupees(sub_total):>10}")
    for b in _tax_buckets(lines):
        rate = b["rate"]
        out.append(f"{('GST @%s%% taxable' % rate):22}{_rupees(b['taxable']):>10}")
        out.append(f"{('  CGST @%s%%' % rate):22}{_rupees(b['cgst']):>10}")
        out.append(f"{('  SGST @%s%%' % rate):22}{_rupees(b['sgst']):>10}")
    out.append(f"{'CGST':22}{_rupees(cgst_total):>10}")
    out.append(f"{'SGST':22}{_rupees(sgst_total):>10}")
    out.append(f"{'TOTAL':22}{_rupees(total):>10}")
    out.append("-" * 32)

    payments = order.get("payments")
    if payments:
        for p in payments:
            out.append(f"{str(p.get('method', 'cash')).upper():14}"
                       f"{_rupees(p.get('amount', 0)):>10}")
        paid = sum(int(p.get("amount", 0) or 0) for p in payments)
        if paid > total:
            out.append(f"{'CHANGE':14}{_rupees(paid - total):>10}")
    elif _paid(order) > 0:
        out.append(f"Paid via {str(order.get('payment_method') or 'cash').upper()}")
    out.append(f"Status: {str(order.get('payment_status', '')).upper()}")
    out.append("=" * 32)
    out.append("Thank you for visiting!")
    return "\n".join(out)


def _tax_buckets(lines):
    buckets = {}
    for line in lines or []:
        rate = int(line.get("gst_rate", 0) or 0)
        b = buckets.setdefault(rate, {"rate": rate, "taxable": 0,
                                      "cgst": 0, "sgst": 0})
        b["taxable"] += int(line.get("taxable_value", 0) or 0)
        b["cgst"] += int(line.get("cgst", 0) or 0)
        b["sgst"] += int(line.get("sgst", 0) or 0)
    return [buckets[r] for r in sorted(buckets)]


@bp.get("/orders/<order_id>/bill")
@any_required
def order_bill(order_id):
    order = orders_repo.get(order_id)
    if not order:
        raise ApiError("Order not found", 404)
    text = render_bill_text(order)
    phone = _phone_digits((order.get("customer") or {}).get("phone"))
    wa_link = None
    if phone:
        wa_link = f"https://wa.me/{phone}?text={urllib.parse.quote(text)}"
    return jsonify({
        "order_id": order_id,
        "text": text,
        "wa_link": wa_link,
        "phone": phone,
        "cafe": printing.cafe_info(),
        "total": int(order.get("total", 0) or 0),
        "tax_total": int(order.get("tax_total") or 0),
        "gstin": Config.CAFE_GSTIN,
    })
