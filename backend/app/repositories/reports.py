"""Sales aggregation for the admin dashboard."""
from collections import defaultdict
from datetime import datetime, timedelta

from ..config import Config
from . import orders as orders_repo
from . import inventory as inventory_repo


def daily_summary(order_date):
    """End-of-day totals for a single YYYY-MM-DD date."""
    orders = orders_repo.list_by_date(order_date)

    order_count = 0
    gross_sales = 0
    by_category = defaultdict(int)
    by_payment = defaultdict(int)
    item_qty = defaultdict(int)
    item_rev = defaultdict(int)

    for o in orders:
        if o.get("status") not in Config.SALES_STATUSES:
            continue  # skip cancelled
        order_count += 1
        gross_sales += int(o.get("total", 0))
        by_payment[o.get("payment_method", "cash")] += int(o.get("total", 0))
        for line in o.get("items", []):
            cat = line.get("category", "other")
            by_category[cat] += int(line.get("line_total", 0))
            item_qty[line["name"]] += int(line.get("qty", 0))
            item_rev[line["name"]] += int(line.get("line_total", 0))

    top_items = sorted(
        (
            {"name": n, "qty": item_qty[n], "revenue": item_rev[n]}
            for n in item_qty
        ),
        key=lambda x: x["revenue"],
        reverse=True,
    )[:5]

    return {
        "date": order_date,
        "order_count": order_count,
        "gross_sales": gross_sales,
        "by_category": dict(by_category),
        "by_payment": dict(by_payment),
        "top_items": top_items,
    }


def billing_summary(order_date=None):
    """Owner billing: collected orders grouped by day, with paid/unpaid totals.

    order_date: optional YYYY-MM-DD to restrict the view to a single day.
    """
    if order_date:
        orders = [o for o in orders_repo.list_by_date(order_date)
                  if o.get("status") == "collected"]
    else:
        orders = [o for o in orders_repo.list_orders()
                  if o.get("status") == "collected"]

    days = defaultdict(list)
    for o in orders:
        d = o.get("order_date") or (o.get("created_at") or "")[:10]
        days[d].append(o)

    def amount_paid(o):
        # New orders carry paid_amount; older ones can be inferred.
        if o.get("paid_amount") is not None:
            return int(o["paid_amount"])
        return int(o.get("total", 0)) if o.get("payment_status") == "paid" else 0

    day_list = []
    for d in sorted(days, reverse=True):
        day_orders = days[d]
        total = sum(int(o.get("total", 0)) for o in day_orders)
        paid = sum(amount_paid(o) for o in day_orders)
        by_payment = defaultdict(int)
        for o in day_orders:
            by_payment[o.get("payment_method", "cash")] += int(o.get("total", 0))
        day_list.append({
            "date": d,
            "orders": day_orders,
            "order_count": len(day_orders),
            "total": total,
            "paid": paid,
            "unpaid": total - paid,
            "by_payment": dict(by_payment),
        })

    return {
        "days": day_list,
        "summary": {
            "order_count": sum(d["order_count"] for d in day_list),
            "total": sum(d["total"] for d in day_list),
            "paid": sum(d["paid"] for d in day_list),
            "unpaid": sum(d["unpaid"] for d in day_list),
        },
    }


def amount_paid(order):
    """Cash actually recorded against an order (legacy inference kept)."""
    if order.get("paid_amount") is not None:
        return int(order.get("paid_amount") or 0)
    return int(order.get("total", 0)) if order.get("payment_status") == "paid" else 0


def z_report(order_date):
    """Day-end Z-report: totals, tax breakup, sales by payment method.

    Uses the `payments` list when present (split payments); legacy orders
    fall back to their single `payment_method`. Missing tax fields (orders
    stored before Phase 1) count as 0.
    """
    orders = [o for o in orders_repo.list_by_date(order_date)
              if o.get("status") in Config.SALES_STATUSES]

    order_count = 0
    gross_sales = 0
    paid_sales = 0
    unpaid_sales = 0
    cgst_total = 0
    sgst_total = 0
    by_payment = defaultdict(int)
    rate_buckets = {}
    item_qty = defaultdict(int)
    item_rev = defaultdict(int)
    cogs_total = 0

    for o in orders:
        order_count += 1
        total = int(o.get("total", 0) or 0)
        gross_sales += total
        paid = amount_paid(o)
        paid_sales += paid
        unpaid_sales += total - paid

        # --- sales by payment method (split payments when present) ---
        payments = o.get("payments")
        recorded = 0
        if payments:
            for p in payments:
                by_payment[str(p.get("method", "other"))] += int(p.get("amount", 0) or 0)
                recorded += int(p.get("amount", 0) or 0)
        if paid > recorded:
            # legacy single-method collections (or a mark-paid straggler)
            by_payment[str(o.get("payment_method") or "cash")] += paid - recorded

        # --- tax breakup from per-line GST fields ---
        for line in o.get("items", []):
            rate = int(line.get("gst_rate", 0) or 0)
            b = rate_buckets.setdefault(rate, {
                "rate": rate, "taxable": 0, "cgst": 0, "sgst": 0, "lines": 0})
            b["taxable"] += int(line.get("taxable_value", 0) or 0)
            b["cgst"] += int(line.get("cgst", 0) or 0)
            b["sgst"] += int(line.get("sgst", 0) or 0)
            b["lines"] += 1
            cgst_total += int(line.get("cgst", 0) or 0)
            sgst_total += int(line.get("sgst", 0) or 0)

            name = line.get("name", "?")
            item_qty[name] += int(line.get("qty", 0) or 0)
            item_rev[name] += int(line.get("line_total", 0) or 0)

        if "cogs" in o:
            cogs_total += int(o.get("cogs") or 0)

    top = sorted(
        ({"name": n, "qty": item_qty[n], "revenue": item_rev[n]}
         for n in item_qty),
        key=lambda x: x["revenue"],
        reverse=True,
    )[:5]

    # COGS: per-order when tracked, else estimate from inventory value.
    cogs_estimated = False
    if cogs_total <= 0:
        cogs_total = int(inventory_repo.summary().get("total_value", 0) or 0)
        cogs_estimated = cogs_total > 0
        cogs_source = "inventory_estimate" if cogs_total > 0 else "none"
    else:
        cogs_source = "orders"
    gross_profit = gross_sales - cogs_total if cogs_source != "none" else None

    return {
        "date": order_date,
        "order_count": order_count,
        "gross_sales": gross_sales,
        "paid_sales": paid_sales,
        "unpaid_sales": unpaid_sales,
        "tax_total": cgst_total + sgst_total,
        "cgst_total": cgst_total,
        "sgst_total": sgst_total,
        "tax_by_rate": [rate_buckets[r] for r in sorted(rate_buckets)],
        "by_payment": dict(by_payment),
        "cash_expected": by_payment.get("cash", 0),
        "top_items": top,
        "cogs_total": cogs_total if cogs_source != "none" else None,
        "cogs_source": cogs_source,
        "cogs_estimated": cogs_estimated,
        "gross_profit": gross_profit,
    }


def top_items(days=7, top_n=10):
    """Most-ordered items over the last N days, by item_id.

    Used by the AI recommender as a popularity signal and fallback.
    Returns [{"item_id", "name", "qty"}], best first; [] when there is
    no sales history yet.
    """
    today = datetime.now().date()
    qty = defaultdict(int)
    name_by_id = {}
    for offset in range(days):
        day = (today - timedelta(days=offset)).strftime("%Y-%m-%d")
        for o in orders_repo.list_by_date(day):
            if o.get("status") not in Config.SALES_STATUSES:
                continue  # skip cancelled
            for line in o.get("items", []):
                item_id = line.get("item_id")
                if not item_id:
                    continue
                qty[item_id] += int(line.get("qty", 0))
                name_by_id.setdefault(item_id, line.get("name", item_id))

    ranked = sorted(
        ({"item_id": i, "name": name_by_id[i], "qty": q} for i, q in qty.items()),
        key=lambda x: x["qty"],
        reverse=True,
    )
    return ranked[:top_n]


def range_summary(date_from, date_to):
    """A daily series between two YYYY-MM-DD dates (inclusive)."""
    start = datetime.strptime(date_from, "%Y-%m-%d").date()
    end = datetime.strptime(date_to, "%Y-%m-%d").date()
    if end < start:
        start, end = end, start

    series = []
    day = start
    while day <= end:
        series.append(daily_summary(day.strftime("%Y-%m-%d")))
        day += timedelta(days=1)
    return series


def staff_sales_report(date_from, date_to):
    """Per-staff sales between two YYYY-MM-DD dates (inclusive).

    One row per `taken_by` value (a row can be a person, "qr" or a delivery
    partner — the channel the order came in on):
        orders   - non-cancelled orders taken in the range
        collected- orders that reached 'collected'
        revenue  - paise actually collected (collected orders only)
        active   - still open (received/preparing/ready) right now
    Plus a `total` row aggregating everything (grand total).

    Cancelled orders are excluded, matching Config.SALES_STATUSES.
    """
    start = datetime.strptime(date_from, "%Y-%m-%d").date()
    end = datetime.strptime(date_to, "%Y-%m-%d").date()
    if end < start:
        start, end = end, start

    orders = []
    day = start
    while day <= end:
        orders.extend(orders_repo.list_by_date(day.strftime("%Y-%m-%d")))
        day += timedelta(days=1)

    rows = {}
    for o in orders:
        status = o.get("status")
        if status not in Config.SALES_STATUSES:
            continue  # skip cancelled
        who = o.get("taken_by") or "unassigned"
        row = rows.setdefault(who, {
            "taken_by": who, "orders": 0, "collected": 0,
            "revenue": 0, "active": 0,
        })
        row["orders"] += 1
        if status == "collected":
            row["collected"] += 1
            row["revenue"] += amount_paid(o)
        else:
            row["active"] += 1

    staff = sorted(rows.values(), key=lambda r: (-r["revenue"], r["taken_by"]))
    total = {
        "orders": sum(r["orders"] for r in staff),
        "collected": sum(r["collected"] for r in staff),
        "revenue": sum(r["revenue"] for r in staff),
        "active": sum(r["active"] for r in staff),
    }
    return {
        "from": date_from,
        "to": date_to,
        "staff": staff,
        "total": total,
    }
