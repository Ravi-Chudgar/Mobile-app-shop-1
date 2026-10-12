"""GSTR-1 and GSTR-3B summaries computed from order tax fields.

All figures are rupees (2-decimal floats/strings) because that is what the
GST portal and a CA work with; orders store integer paise (Phase 1 contract:
`total` is tax-inclusive, each line carries taxable_value/cgst/sgst/gst_rate/
hsn_code).

Sections produced:
  gstr1_summary  - B2C invoice table (invoice no = order id, date, taxable,
                   cgst, sgst, invoice value), HSN/SAC summary per code, and
                   a rate-wise summary. B2B is intentionally skipped: POS
                   orders carry no customer GSTIN, so every invoice is B2C.
  gstr3b_summary - 4.1(a) outward taxable supplies: taxable value, CGST,
                   SGST, total value, split by GST rate.

Data source: the caller (routes/export.py) gathers orders day-by-day via
repositories/orders.py::list_by_date over the period and passes them in —
this module is pure computation and never touches the database.
"""
from collections import defaultdict

from ..config import Config
from .tally import order_date, order_totals

# Legacy (pre-Phase-1) lines have no gst_rate/hsn_code; they land in these
# buckets so totals still add up.
DEFAULT_RATE = 0
DEFAULT_HSN = "9963"  # restaurant service SAC (pricing.DEFAULT_HSN_CODE)


def _rupees(paise):
    """Integer paise -> rupees as a float rounded to 2 decimals."""
    return round(int(paise or 0) / 100.0, 2)


def _sale_orders(orders, period=None):
    """Non-cancelled orders; optionally only those in a YYYY-MM period."""
    kept = []
    for order in orders or []:
        if order.get("status") not in Config.SALES_STATUSES:
            continue
        if period is not None and not order_date(order).startswith(period):
            continue
        kept.append(order)
    kept.sort(key=lambda o: (order_date(o), str(o.get("id", ""))))
    return kept


def _line_rows(order):
    """Yield (hsn, rate, taxable, cgst, sgst) per line, paise units."""
    for line in order.get("items", []):
        taxable, cgst, sgst = _line_tax(line)
        yield (
            str(line.get("hsn_code") or DEFAULT_HSN),
            int(line.get("gst_rate", 0) or DEFAULT_RATE),
            taxable, cgst, sgst,
        )


def _line_tax(line):
    """(taxable, cgst, sgst) for one line in paise; legacy lines fall back
    to line_total with zero tax."""
    cgst = int(line.get("cgst", 0) or 0)
    sgst = int(line.get("sgst", 0) or 0)
    taxable = line.get("taxable_value")
    if taxable is None:
        taxable = int(line.get("line_total", 0) or 0) - cgst - sgst
    return int(taxable), cgst, sgst


def gstr1_summary(orders, period):
    """GSTR-1 for a YYYY-MM period.

    Returns:
      {
        "period": "2026-10",
        "gstin": ..., "legal_name": ...,       # filed by this cafe
        "invoice_count": n,
        "invoices": [{invoice_number, date, taxable_value, cgst, sgst,
                      invoice_value}],          # B2C (CR) table, rupees
        "totals": {taxable_value, cgst, sgst, invoice_value},   # rupees
        "hsn_summary": [{hsn_code, taxable_value, cgst, sgst}], # rupees
        "rate_summary": [{gst_rate, taxable_value, cgst, sgst}],# rupees
        "b2b": [],                              # always empty, see note
        "notes": "...",
      }

    B2B is skipped on purpose: POS orders have no customer GSTIN field, so
    every invoice is a B2C (CR) entry.
    """
    rows = _sale_orders(orders, period)

    invoices = []
    hsn = defaultdict(lambda: {"taxable": 0, "cgst": 0, "sgst": 0})
    rates = defaultdict(lambda: {"taxable": 0, "cgst": 0, "sgst": 0})
    t_taxable = t_cgst = t_sgst = t_value = 0

    for order in rows:
        taxable, cgst, sgst, total = order_totals(order)
        invoices.append({
            "invoice_number": str(order.get("id", "")),
            "date": order_date(order),
            "taxable_value": _rupees(taxable),
            "cgst": _rupees(cgst),
            "sgst": _rupees(sgst),
            "invoice_value": _rupees(total),
        })
        t_taxable += taxable
        t_cgst += cgst
        t_sgst += sgst
        t_value += total

        for hsn_code, rate, l_taxable, l_cgst, l_sgst in _line_rows(order):
            hsn[hsn_code]["taxable"] += l_taxable
            hsn[hsn_code]["cgst"] += l_cgst
            hsn[hsn_code]["sgst"] += l_sgst
            rates[rate]["taxable"] += l_taxable
            rates[rate]["cgst"] += l_cgst
            rates[rate]["sgst"] += l_sgst

    return {
        "period": period,
        "gstin": Config.CAFE_GSTIN,
        "legal_name": Config.CAFE_NAME,
        "invoice_count": len(invoices),
        "invoices": invoices,
        "totals": {
            "taxable_value": _rupees(t_taxable),
            "cgst": _rupees(t_cgst),
            "sgst": _rupees(t_sgst),
            "invoice_value": _rupees(t_value),
        },
        "hsn_summary": [
            {
                "hsn_code": code,
                "taxable_value": _rupees(v["taxable"]),
                "cgst": _rupees(v["cgst"]),
                "sgst": _rupees(v["sgst"]),
            }
            for code, v in sorted(hsn.items())
        ],
        "rate_summary": [
            {
                "gst_rate": rate,
                "taxable_value": _rupees(v["taxable"]),
                "cgst": _rupees(v["cgst"]),
                "sgst": _rupees(v["sgst"]),
            }
            for rate, v in sorted(rates.items())
        ],
        "b2b": [],
        "notes": (
            "B2C (CR) only: POS orders do not capture a customer GSTIN, so "
            "there are no B2B invoices to report."
        ),
    }


def gstr3b_summary(orders, period):
    """GSTR-3B table 4.1(a) — outward taxable supplies for a YYYY-MM period.

    Returns:
      {
        "period": "2026-10",
        "gstin": ..., "legal_name": ...,
        "outward_taxable_supplies": {taxable_value, cgst, sgst, total_value},
        "by_rate": [{gst_rate, taxable_value, cgst, sgst, total_value}],
        "invoice_count": n,
        "notes": "...",
      }
    All values are rupees.
    """
    rows = _sale_orders(orders, period)

    t_taxable = t_cgst = t_sgst = t_total = 0
    rates = defaultdict(lambda: {"taxable": 0, "cgst": 0, "sgst": 0,
                                 "total": 0})

    for order in rows:
        taxable, cgst, sgst, total = order_totals(order)
        t_taxable += taxable
        t_cgst += cgst
        t_sgst += sgst
        t_total += total
        for _, rate, l_taxable, l_cgst, l_sgst in _line_rows(order):
            rates[rate]["taxable"] += l_taxable
            rates[rate]["cgst"] += l_cgst
            rates[rate]["sgst"] += l_sgst
            rates[rate]["total"] += l_taxable + l_cgst + l_sgst

    return {
        "period": period,
        "gstin": Config.CAFE_GSTIN,
        "legal_name": Config.CAFE_NAME,
        "invoice_count": len(rows),
        "outward_taxable_supplies": {
            "taxable_value": _rupees(t_taxable),
            "cgst": _rupees(t_cgst),
            "sgst": _rupees(t_sgst),
            "total_value": _rupees(t_total),
        },
        "by_rate": [
            {
                "gst_rate": rate,
                "taxable_value": _rupees(v["taxable"]),
                "cgst": _rupees(v["cgst"]),
                "sgst": _rupees(v["sgst"]),
                "total_value": _rupees(v["total"]),
            }
            for rate, v in sorted(rates.items())
        ],
        "notes": (
            "Table 4.1(a) outward taxable supplies (excluding exports/SEZ "
            "and zero-rated nil-rated supplies, which the POS does not emit)."
        ),
    }
