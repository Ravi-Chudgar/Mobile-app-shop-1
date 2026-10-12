"""Accounting exports (Phase 4): Tally XML/CSV + GSTR-1/GSTR-3B.

Endpoints (all GET, all guarded with owner_or_ca — owner or cafe_ca):

  GET /export/tally?from=YYYY-MM-DD&to=YYYY-MM-DD&format=xml|csv
      -> text/xml | text/csv, attachment filename tally_sales_<from>_<to>.<ext>
  GET /export/gstr1?period=YYYY-MM&format=json|csv
      -> application/json | text/csv, attachment gstr1_<period>.<ext>
  GET /export/gstr3b?period=YYYY-MM&format=json|csv
      -> application/json | text/csv, attachment gstr3b_<period>.<ext>

Orders are read day-by-day through repositories/orders.py::list_by_date
(read-only; this module never writes). Cancelled orders are excluded
(everything in Config.SALES_STATUSES counts as a sale).

The cafe_ca (read-only CA) role is accepted here via owner_or_ca; a global
hook in ca_guard.py additionally refuses any non-GET request carrying that
role, and no mutating route ever lists cafe_ca in its guard.
"""
import calendar
import csv
import io
import json
from datetime import datetime, timedelta

from flask import Blueprint, Response, request

from ..auth import owner_or_ca
from ..config import Config
from ..repositories import orders as orders_repo
from ..services import gst_reports, tally
from ..util import ApiError

bp = Blueprint("export", __name__, url_prefix="/export")

_MAX_RANGE_DAYS = 62  # ~2 months: keeps one export from scanning forever


def _parse_date(value, label):
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except (TypeError, ValueError):
        raise ApiError(f"'{label}' must be a date like 2026-10-01")


def _parse_period(value):
    try:
        parsed = datetime.strptime(value, "%Y-%m")
    except (TypeError, ValueError):
        raise ApiError("'period' must be a month like 2026-10")
    return parsed.strftime("%Y-%m")


def _orders_between(date_from, date_to):
    """Read-only day-by-day fetch across an inclusive date range."""
    if (date_to - date_from).days + 1 > _MAX_RANGE_DAYS:
        raise ApiError(f"Date range may not exceed {_MAX_RANGE_DAYS} days")
    orders = []
    day = date_from
    while day <= date_to:
        orders.extend(orders_repo.list_by_date(day.strftime("%Y-%m-%d")))
        day += timedelta(days=1)
    return [o for o in orders
            if o.get("status") in Config.SALES_STATUSES]


def _orders_for_period(period):
    """All sale-bearing orders inside a YYYY-MM period."""
    year, month = int(period[:4]), int(period[5:7])
    last = calendar.monthrange(year, month)[1]
    return _orders_between(
        datetime(year, month, 1).date(),
        datetime(year, month, last).date(),
    )


def _attachment(body, mimetype, filename):
    return Response(body, mimetype=mimetype, headers={
        "Content-Disposition": f'attachment; filename="{filename}"',
    })


def _csv_text(rows):
    buf = io.StringIO()
    writer = csv.writer(buf)
    for row in rows:
        writer.writerow(row)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# Tally exports
# --------------------------------------------------------------------------- #

@bp.get("/tally")
@owner_or_ca
def export_tally():
    date_from = _parse_date(request.args.get("from"), "from")
    date_to = _parse_date(request.args.get("to"), "to")
    if date_to < date_from:
        raise ApiError("'to' must be on or after 'from'")
    fmt = (request.args.get("format") or "xml").lower()
    if fmt not in ("xml", "csv"):
        raise ApiError("'format' must be xml or csv")

    orders = _orders_between(date_from, date_to)
    span = f"{date_from}_{date_to}"

    if fmt == "xml":
        body = tally.build_tally_xml(
            orders,
            company=Config.CAFE_NAME,
            date_from=str(date_from),
            date_to=str(date_to),
        )
        return _attachment(body, "text/xml", f"tally_sales_{span}.xml")

    body = tally.build_tally_csv(orders)
    return _attachment(body, "text/csv", f"tally_sales_{span}.csv")


# --------------------------------------------------------------------------- #
# GST returns
# --------------------------------------------------------------------------- #

def _gstr1_csv(summary):
    """B2C invoices + HSN + rate summaries as labelled CSV sections."""
    rows = [
        ["section", "invoice_number", "date", "taxable_value", "cgst",
         "sgst", "invoice_value"],
    ]
    for inv in summary["invoices"]:
        rows.append(["b2c", inv["invoice_number"], inv["date"],
                     f"{inv['taxable_value']:.2f}", f"{inv['cgst']:.2f}",
                     f"{inv['sgst']:.2f}", f"{inv['invoice_value']:.2f}"])
    t = summary["totals"]
    rows.append(["b2c_total", "", "",
                 f"{t['taxable_value']:.2f}", f"{t['cgst']:.2f}",
                 f"{t['sgst']:.2f}", f"{t['invoice_value']:.2f}"])

    rows.append(["section", "hsn_code", "", "taxable_value", "cgst", "sgst", ""])
    for h in summary["hsn_summary"]:
        rows.append(["hsn", h["hsn_code"], "",
                     f"{h['taxable_value']:.2f}", f"{h['cgst']:.2f}",
                     f"{h['sgst']:.2f}", ""])

    rows.append(["section", "gst_rate", "", "taxable_value", "cgst", "sgst", ""])
    for r in summary["rate_summary"]:
        rows.append(["rate", f"{r['gst_rate']}%", "",
                     f"{r['taxable_value']:.2f}", f"{r['cgst']:.2f}",
                     f"{r['sgst']:.2f}", ""])
    return _csv_text(rows)


def _gstr3b_csv(summary):
    s = summary["outward_taxable_supplies"]
    rows = [
        ["table", "description", "taxable_value", "cgst", "sgst", "total_value"],
        ["4.1(a)", "Outward taxable supplies",
         f"{s['taxable_value']:.2f}", f"{s['cgst']:.2f}",
         f"{s['sgst']:.2f}", f"{s['total_value']:.2f}"],
    ]
    for r in summary["by_rate"]:
        rows.append(["4.1(a) by rate", f"GST @ {r['gst_rate']}%",
                     f"{r['taxable_value']:.2f}", f"{r['cgst']:.2f}",
                     f"{r['sgst']:.2f}", f"{r['total_value']:.2f}"])
    return _csv_text(rows)


@bp.get("/gstr1")
@owner_or_ca
def export_gstr1():
    period = _parse_period(request.args.get("period"))
    fmt = (request.args.get("format") or "json").lower()
    if fmt not in ("json", "csv"):
        raise ApiError("'format' must be json or csv")

    summary = gst_reports.gstr1_summary(_orders_for_period(period), period)
    if fmt == "json":
        return Response(
            json.dumps(summary, indent=2),
            mimetype="application/json",
            headers={"Content-Disposition":
                     f'attachment; filename="gstr1_{period}.json"'})
    return _attachment(_gstr1_csv(summary), "text/csv",
                       f"gstr1_{period}.csv")


@bp.get("/gstr3b")
@owner_or_ca
def export_gstr3b():
    period = _parse_period(request.args.get("period"))
    fmt = (request.args.get("format") or "json").lower()
    if fmt not in ("json", "csv"):
        raise ApiError("'format' must be json or csv")

    summary = gst_reports.gstr3b_summary(_orders_for_period(period), period)
    if fmt == "json":
        return Response(
            json.dumps(summary, indent=2),
            mimetype="application/json",
            headers={"Content-Disposition":
                     f'attachment; filename="gstr3b_{period}.json"'})
    return _attachment(_gstr3b_csv(summary), "text/csv",
                       f"gstr3b_{period}.csv")
