"""Tally Prime export: Import-Data XML and a flat per-order CSV.

Money travels through this app as integer paise; Tally and spreadsheets work
in rupees, so every figure here is converted with paise_to_rupees() (2-decimal
string, e.g. 123456 -> "1234.56").

XML structure (Tally Prime "Import Data" request):

    <ENVELOPE>
      <HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER>
      <BODY><IMPORTDATA>
        <REQUESTDESC>
          <REPORTNAME>Vouchers</REPORTNAME>
          <STATICVARIABLES><SVCURRENTCOMPANY>...</SVCURRENTCOMPANY></STATICVARIABLES>
        </REQUESTDESC>
        <REQUESTDATA>
          <TALLYMESSAGE>
            <VOUCHER VCHTYPE="Sales" ACTION="Create">
              <DATE>YYYYMMDD</DATE> <GUID>...</GUID> <NARRATION>...</NARRATION>
              <PARTYLEDGERNAME>...</PARTYLEDGERNAME>
              <ALLINVENTORYENTRIES.LIST> ITEMNAME/QTY/RATE/AMOUNT (taxable) </...>
              <ALLLEDGERENTRIES.LIST> Sales / CGST / SGST / party </...>
            </VOUCHER>
          </TALLYMESSAGE>
        </REQUESTDATA>
      </IMPORTDATA></BODY>
    </ENVELOPE>

Sign convention: Tally records credits as negative amounts and debits as
positive (ISDEEMEDPOSITIVE flags which is which), so Sales/CGST/SGST are
negative and the party/cash line is positive for each voucher.
"""
import csv
import io
import uuid
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from ..config import Config

# Namespace for GUID derivation: a stable UUIDv5 per order id so re-importing
# the same date range twice de-duplicates instead of double-posting.
_GUID_NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

# Ledger names Tally is expected to already have (created on first import or
# by the CA): the sales ledger, the two GST ledgers, and the cash party.
SALES_LEDGER = "Sales"
CGST_LEDGER = "CGST"
SGST_LEDGER = "SGST"
DEFAULT_PARTY_LEDGER = "Cash Sales"

# Inventory unit Tally shows next to QTY/RATE.
UNIT = "Nos"


def paise_to_rupees(paise):
    """Integer paise -> "1234.56" rupees string (what Tally/CSV expect)."""
    try:
        value = int(paise or 0)
    except (TypeError, ValueError):
        value = 0
    return f"{value / 100:.2f}"


def _xml(value):
    return escape(str(value if value is not None else ""))


def order_date(order):
    """Order day as YYYY-MM-DD (falls back to created_at's date prefix)."""
    date = order.get("order_date")
    if date:
        return str(date)[:10]
    return str(order.get("created_at", ""))[:10]


def _tally_date(order):
    """YYYY-MM-DD -> YYYYMMDD (Tally's DATE format)."""
    return order_date(order).replace("-", "")


def order_guid(order):
    """Stable GUID for an order: same id in, same GUID out, every export."""
    return str(uuid.uuid5(_GUID_NS, f"cafe-order-{order.get('id', '')}"))


def party_name(order):
    """PARTYLEDGERNAME: the customer's name, or the cash-ledger fallback."""
    customer = order.get("customer") or {}
    name = str(customer.get("name") or "").strip()
    if not name or name.lower() in ("guest", "walk-in", "walkin"):
        return DEFAULT_PARTY_LEDGER
    return name


def order_payment(order):
    """Human payment label: split payments are joined, legacy single method
    otherwise."""
    payments = order.get("payments") or []
    if payments:
        return "+".join(str(p.get("method", "other")) for p in payments)
    return str(order.get("payment_method") or "cash")


def order_totals(order):
    """(taxable, cgst, sgst, total) in paise, summed from per-line GST fields.

    Legacy lines without tax fields count as 0 tax and their line_total as
    taxable so the voucher still balances (taxable + tax == total).
    """
    taxable = cgst = sgst = total = 0
    for line in order.get("items", []):
        line_total = int(line.get("line_total", 0) or 0)
        line_taxable = line.get("taxable_value")
        line_cgst = int(line.get("cgst", 0) or 0)
        line_sgst = int(line.get("sgst", 0) or 0)
        if line_taxable is None:
            # Legacy (pre-Phase-1) line: taxable is whatever is left after tax.
            line_taxable = line_total - line_cgst - line_sgst
        taxable += int(line_taxable)
        cgst += line_cgst
        sgst += line_sgst
        total += line_total
    if total == 0:
        total = int(order.get("total", 0) or 0)
    return taxable, cgst, sgst, total


def narration(order):
    """Voucher narration: order id + source channel + payment method.

    Swiggy/Zomato orders are ordinary sales; the channel is called out so
    the CA can reconcile against partner settlements.
    """
    parts = [f"Order {order.get('id', '')}"]
    source = str(order.get("source") or "counter")
    if source in ("swiggy", "zomato"):
        parts.append(f"{source.capitalize()} channel")
    elif source == "qr":
        parts.append("QR self-order")
    elif source == "counter":
        parts.append("Counter")
    parts.append(f"Payment: {order_payment(order)}")
    notes = str(order.get("notes") or "").strip()
    if notes:
        parts.append(notes)
    return " | ".join(parts)


def _append(parent, tag, text=None):
    child = ET.SubElement(parent, tag)
    if text is not None:
        child.text = str(text)
    return child


def _voucher(parent, order):
    """One <VOUCHER VCHTYPE="Sales" ACTION="Create"> per order."""
    voucher = ET.SubElement(parent, "VOUCHER", {
        "VCHTYPE": "Sales",
        "ACTION": "Create",
    })
    _append(voucher, "DATE", _tally_date(order))
    _append(voucher, "GUID", order_guid(order))
    _append(voucher, "VOUCHERTYPENAME", "Sales")
    _append(voucher, "NARRATION", narration(order))
    _append(voucher, "PARTYLEDGERNAME", party_name(order))
    # Keep the POS order id visible to Tally as a reference/voucher number.
    _append(voucher, "REFERENCE", order.get("id", ""))
    _append(voucher, "VOUCHERNUMBER", order.get("id", ""))

    taxable, cgst, sgst, total = order_totals(order)

    # ---- Inventory entries: one per line, at TAXABLE value ----
    for line in order.get("items", []):
        qty = int(line.get("qty", 0) or 0)
        line_taxable = line.get("taxable_value")
        line_cgst = int(line.get("cgst", 0) or 0)
        line_sgst = int(line.get("sgst", 0) or 0)
        line_total = int(line.get("line_total", 0) or 0)
        if line_taxable is None:
            line_taxable = line_total - line_cgst - line_sgst
        line_taxable = int(line_taxable)
        rate = (line_taxable / qty) if qty else line_taxable

        entry = ET.SubElement(voucher, "ALLINVENTORYENTRIES.LIST")
        _append(entry, "ITEMNAME", line.get("name", ""))
        if line.get("hsn_code"):
            _append(entry, "HSNCODE", line["hsn_code"])
        # Inventory sits on the credit side of a sales voucher, so its
        # AMOUNT is negative (same convention as the Sales ledger entry);
        # RATE and QTY stay positive, exactly as Tally exports them.
        _append(entry, "ISDEEMEDPOSITIVE", "No")
        _append(entry, "QTY", f"{qty} {UNIT}")
        _append(entry, "RATE", f"{rate / 100:.2f}/{UNIT}")
        _append(entry, "AMOUNT", "-" + paise_to_rupees(line_taxable))

    # ---- Ledger entries: Sales + GST (credit) and party/cash (debit) ----
    def ledger(name, amount, debit):
        entry = ET.SubElement(voucher, "ALLLEDGERENTRIES.LIST")
        _append(entry, "LEDGERNAME", name)
        # Tally convention: debit = positive amount + ISDEEMEDPOSITIVE Yes.
        _append(entry, "ISDEEMEDPOSITIVE", "Yes" if debit else "No")
        _append(entry, "AMOUNT", paise_to_rupees(amount))
        return entry

    ledger(SALES_LEDGER, -taxable, debit=False)   # credit: taxable value
    if cgst:
        ledger(CGST_LEDGER, -cgst, debit=False)   # credit: CGST
    if sgst:
        ledger(SGST_LEDGER, -sgst, debit=False)   # credit: SGST
    ledger(party_name(order), total, debit=True)  # debit: invoice total
    return voucher


def build_tally_xml(orders, company=None, date_from=None, date_to=None):
    """Tally Prime Import Data XML for `orders` (list of order dicts).

    company    -> SVCURRENTCOMPANY (defaults to Config.CAFE_NAME)
    date_from/date_to -> echoed into the REQUESTDESC STATICVARIABLES as
    FROMDATE/TODATE (YYYY-MM-DD); voucher dates come from each order.
    """
    company = company or Config.CAFE_NAME

    envelope = ET.Element("ENVELOPE")
    header = ET.SubElement(envelope, "HEADER")
    _append(header, "TALLYREQUEST", "Import Data")

    body = ET.SubElement(envelope, "BODY")
    importdata = ET.SubElement(body, "IMPORTDATA")
    desc = ET.SubElement(importdata, "REQUESTDESC")
    _append(desc, "REPORTNAME", "Vouchers")
    statics = ET.SubElement(desc, "STATICVARIABLES")
    _append(statics, "SVCURRENTCOMPANY", company)
    if date_from:
        _append(statics, "FROMDATE", date_from)
    if date_to:
        _append(statics, "TODATE", date_to)

    data = ET.SubElement(importdata, "REQUESTDATA")
    message = ET.SubElement(data, "TALLYMESSAGE")
    for order in sorted(orders, key=lambda o: (order_date(o), str(o.get("id", "")))):
        _voucher(message, order)

    ET.indent(envelope, space="  ")
    xml_body = ET.tostring(envelope, encoding="unicode")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + xml_body + "\n"


def build_tally_csv(orders):
    """Flat one-row-per-order CSV (rupees, 2 decimals).

    Columns: order_id, date, party, taxable, cgst, sgst, total, payment —
    ready for a spreadsheet or a CA's import mapping.
    """
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow([
        "order_id", "date", "party", "taxable", "cgst", "sgst",
        "total", "payment",
    ])
    for order in sorted(orders, key=lambda o: (order_date(o), str(o.get("id", "")))):
        taxable, cgst, sgst, total = order_totals(order)
        writer.writerow([
            order.get("id", ""),
            order_date(order),
            party_name(order),
            paise_to_rupees(taxable),
            paise_to_rupees(cgst),
            paise_to_rupees(sgst),
            paise_to_rupees(total),
            order_payment(order),
        ])
    return buf.getvalue()
