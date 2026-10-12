"""Owner-only growth reports (Phase 3).

GET /admin/reports/staff?date=YYYY-MM-DD   (or ?from=YYYY-MM-DD&to=...)

Per-staff performance for a day or a range: orders taken, revenue
(collected orders only), open/active count — plus a grand total.
Aggregation lives in repositories/reports.py::staff_sales_report.
Lives here (not admin.py) so parallel work on admin.py stays conflict-free.
"""
from datetime import datetime, timezone

from flask import Blueprint, request, jsonify

from ..auth import owner_or_ca
from ..repositories import reports as reports_repo
from ..util import ApiError

bp = Blueprint("growth_reports", __name__)

_DATE_FMT = "%Y-%m-%d"


def _parse_date(value, label):
    try:
        return datetime.strptime(value, _DATE_FMT).strftime(_DATE_FMT)
    except (TypeError, ValueError):
        raise ApiError(f"'{label}' must be a date like 2026-10-09")


@bp.get("/admin/reports/staff")
@owner_or_ca  # read-only report: owner OR cafe_ca (Phase 4)
def staff_report():
    date = request.args.get("date")
    date_from = request.args.get("from")
    date_to = request.args.get("to")

    if date:
        date_from = date_to = _parse_date(date, "date")
    elif date_from or date_to:
        today = datetime.now(timezone.utc).strftime(_DATE_FMT)
        date_from = _parse_date(date_from or today, "from")
        date_to = _parse_date(date_to or today, "to")
    else:
        date_from = date_to = datetime.now(timezone.utc).strftime(_DATE_FMT)

    return jsonify(reports_repo.staff_sales_report(date_from, date_to))
