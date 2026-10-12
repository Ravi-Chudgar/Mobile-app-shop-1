"""Server-side pricing. The client's total is never trusted: every order line
is recomputed from the current menu item and its selected options.

All money values are integers in minor currency units (e.g. paise/cents).

`selected` is a list of {"group": str, "label": str}. A group marked `multi`
may appear more than once; a required group must appear at least once.

Pricing is TAX-INCLUSIVE (Indian GST): the menu price is the price the
customer pays, GST included. Each line carries its tax breakdown
(`taxable_value`, `cgst`, `sgst`, `gst_rate`) computed with half-up rounding
so that taxable_value + cgst + sgst == line_total exactly.
"""
from decimal import Decimal, ROUND_HALF_UP

from .util import ApiError

# GST rates allowed on menu items (percent). 5% is the Indian restaurant
# service standard and the default when a menu item has no gst_rate yet.
VALID_GST_RATES = (0, 5, 12, 18)
DEFAULT_GST_RATE = 5
# Restaurant service SAC (Indian HSN equivalent for services).
DEFAULT_HSN_CODE = "9963"


def _half_up(value):
    """Round a Decimal/number to the nearest int, halves away from zero."""
    return int(Decimal(value).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def normalize_gst_rate(rate):
    """Validate a GST rate: int in {0, 5, 12, 18}. Raises ApiError(400)."""
    try:
        rate = int(rate)
    except (TypeError, ValueError):
        raise ApiError("'gst_rate' must be an integer percent (0, 5, 12, 18)")
    if rate not in VALID_GST_RATES:
        raise ApiError(f"'gst_rate' must be one of {list(VALID_GST_RATES)}")
    return rate


def item_gst_rate(item):
    """GST rate for a stored menu item, defaulting to 5% when absent."""
    rate = item.get("gst_rate")
    if rate is None:
        return DEFAULT_GST_RATE
    try:
        rate = int(rate)
    except (TypeError, ValueError):
        return DEFAULT_GST_RATE
    return rate if rate in VALID_GST_RATES else DEFAULT_GST_RATE


def item_hsn_code(item):
    """HSN/SAC code for a stored menu item, defaulting to 9963."""
    return str(item.get("hsn_code") or DEFAULT_HSN_CODE)


def split_line_tax(line_total, gst_rate):
    """Split one tax-INCLUSIVE line total into (taxable, cgst, sgst).

    GST is extracted from the gross amount: tax = gross * rate / (100 + rate),
    split equally between CGST and SGST with half-up rounding per line.
    taxable_value is the remainder so the invariant
    taxable + cgst + sgst == line_total holds exactly.
    """
    line_total = int(line_total)
    rate = int(gst_rate or 0)
    if rate <= 0:
        return line_total, 0, 0
    gross = Decimal(line_total)
    denom = Decimal(2 * (100 + rate))  # half the tax, inclusive base
    cgst = _half_up(gross * Decimal(rate) / denom)
    sgst = _half_up(gross * Decimal(rate) / denom)
    taxable = line_total - cgst - sgst
    return taxable, cgst, sgst


def compute_line(item, selected, qty):
    """Return (unit_price, line_total, normalized_selection) for one line."""
    if qty is None or int(qty) < 1:
        raise ApiError("qty must be >= 1")
    qty = int(qty)

    groups = {g["group"]: g for g in item.get("options", [])}
    chosen = {}
    delta = 0

    for sel in selected or []:
        g = sel.get("group")
        label = sel.get("label")
        if g not in groups:
            raise ApiError(f"Unknown option group '{g}'")
        choice = next((c for c in groups[g]["choices"] if c["label"] == label), None)
        if choice is None:
            raise ApiError(f"Unknown choice '{label}' for '{g}'")
        chosen.setdefault(g, []).append(label)
        delta += int(choice.get("price_delta", 0))

    for g in item.get("options", []):
        name = g["group"]
        picked = chosen.get(name, [])
        if g.get("required") and not picked:
            raise ApiError(f"Option '{name}' is required")
        if not g.get("multi", False) and len(picked) > 1:
            raise ApiError(f"Only one '{name}' may be selected")

    unit = int(item["base_price"]) + delta
    return unit, unit * qty, list(selected or [])


def price_order(items_in, menu_lookup):
    """Validate and price a whole order.

    items_in: list of {item_id, qty, selected_options}
    menu_lookup: callable(item_id) -> menu item dict or None

    Returns (lines, total) where each line is a snapshot stored on the order.
    Each line additionally carries the GST breakdown:
      gst_rate, hsn_code, taxable_value, cgst, sgst
    `total` is the tax-inclusive grand total (unchanged by the tax fields).
    """
    if not items_in:
        raise ApiError("Order must contain at least one item")

    lines = []
    total = 0
    for entry in items_in:
        item = menu_lookup(entry.get("item_id"))
        if item is None:
            raise ApiError(f"Menu item '{entry.get('item_id')}' not found", 404)
        if not item.get("available", True):
            raise ApiError(f"'{item['name']}' is currently unavailable", 409)

        unit, line_total, selection = compute_line(
            item, entry.get("selected_options", []), entry.get("qty", 1)
        )
        rate = item_gst_rate(item)
        taxable, cgst, sgst = split_line_tax(line_total, rate)
        lines.append(
            {
                "item_id": item["id"],
                "name": item["name"],
                "category": item.get("category", "other"),
                "qty": int(entry.get("qty", 1)),
                "unit_price": unit,
                "selected_options": selection,
                "line_total": line_total,
                "gst_rate": rate,
                "hsn_code": item_hsn_code(item),
                "taxable_value": taxable,
                "cgst": cgst,
                "sgst": sgst,
            }
        )
        total += line_total

    return lines, total


def order_tax_totals(lines):
    """(sub_total, tax_total) for a list of priced lines.

    Missing tax fields (legacy lines stored before Phase 1) count as 0.
    sub_total is the sum of line totals — identical to the order total for
    tax-inclusive pricing.
    """
    sub_total = 0
    tax_total = 0
    for line in lines or []:
        sub_total += int(line.get("line_total", 0) or 0)
        tax_total += int(line.get("cgst", 0) or 0)
        tax_total += int(line.get("sgst", 0) or 0)
    return sub_total, tax_total


def tax_by_rate(lines):
    """Aggregate a per-rate GST table from priced lines.

    Returns a list of {rate, taxable, cgst, sgst, tax, lines, qty} sorted by
    rate. Legacy lines without tax fields land under rate 0 with zeros.
    """
    buckets = {}
    for line in lines or []:
        rate = int(line.get("gst_rate", 0) or 0)
        b = buckets.setdefault(rate, {
            "rate": rate, "taxable": 0, "cgst": 0, "sgst": 0,
            "tax": 0, "lines": 0, "qty": 0,
        })
        b["taxable"] += int(line.get("taxable_value", 0) or 0)
        b["cgst"] += int(line.get("cgst", 0) or 0)
        b["sgst"] += int(line.get("sgst", 0) or 0)
        b["tax"] = b["cgst"] + b["sgst"]
        b["lines"] += 1
        b["qty"] += int(line.get("qty", 0) or 0)
    return [buckets[r] for r in sorted(buckets)]
