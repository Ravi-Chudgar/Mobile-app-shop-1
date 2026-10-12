"""Thermal print endpoints (ESC/POS): customer receipt + kitchen ticket.

Two families of routes:

* Legacy POSTs (`/printing/receipt|kot/<id>`) send to the env-configured
  printer (`ESCPOS_PRINTER_HOST`) and fall back to dry-run bytes when no
  host is set. Auto-KOT and older clients keep using these.
* Printer-agnostic GETs (`/printing/receipt|kot/<id>/bytes`,
  `/printing/test/bytes`) only BUILD the byte stream and hand it to the
  app base64-encoded — the Flutter client prints it itself (TCP/USB/
  Bluetooth from the phone, proxy via POST /printing/send on the web).
  `POST /printing/send` is the LAN proxy: an arbitrary-target send, so it
  is deliberately restricted to owner/staff.
"""
import base64
import binascii
import logging

from flask import Blueprint, jsonify, request

from ..auth import staff_required, any_required
from ..config import Config
from ..repositories import orders as orders_repo
from ..services import printing
from ..util import ApiError

bp = Blueprint("printing", __name__)
logger = logging.getLogger(__name__)

DEFAULT_SEND_PORT = 9100


def _cafe():
    return printing.cafe_info()


def _order_or_404(order_id):
    order = orders_repo.get(order_id)
    if not order:
        raise ApiError("Order not found", 404)
    return order


def _respond(order_id, data):
    """Send bytes to the printer, or return them in dry-run mode."""
    host = Config.ESCPOS_PRINTER_HOST
    if not host:
        logger.info("ESCPOS_PRINTER_HOST not set — dry-run print for %s",
                    order_id)
        return jsonify({
            "order_id": order_id,
            "dry_run": True,
            "bytes_len": len(data),
            "bytes_b64": base64.b64encode(data).decode("ascii"),
        })
    try:
        printing.send(host, Config.ESCPOS_PRINTER_PORT, data)
    except OSError as e:
        raise ApiError(
            f"Could not reach printer at {host}:{Config.ESCPOS_PRINTER_PORT} — {e}",
            502)
    return jsonify({
        "order_id": order_id,
        "dry_run": False,
        "sent": True,
        "bytes_len": len(data),
    })


def _b64(data):
    return base64.b64encode(data).decode("ascii")


def _bytes_page(order_id, data):
    """Build-only response: raw bytes for the app to print itself."""
    return jsonify({
        "order_id": order_id,
        "bytes_b64": _b64(data),
        "length": len(data),
    })


# --------------------------------------------------------------------------- #
# Legacy send/dry-run POSTs (env-configured printer)
# --------------------------------------------------------------------------- #

@bp.post("/printing/receipt/<order_id>")
@staff_required
def print_receipt(order_id):
    order = _order_or_404(order_id)
    data = printing.build_receipt(order, cafe=_cafe())
    return _respond(order_id, data)


@bp.post("/printing/kot/<order_id>")
# Kitchen users may reprint their own KOTs (receipts stay staff/owner-only).
@any_required
def print_kot(order_id):
    order = _order_or_404(order_id)
    data = printing.build_kot(order, cafe=_cafe())
    return _respond(order_id, data)


# --------------------------------------------------------------------------- #
# Printer-agnostic byte endpoints (build only — never sent by the backend)
# --------------------------------------------------------------------------- #

@bp.get("/printing/receipt/<order_id>/bytes")
@staff_required
def receipt_bytes(order_id):
    """Receipt bytes for direct printing from the app (nothing is sent)."""
    order = _order_or_404(order_id)
    return _bytes_page(order_id, printing.build_receipt(order, cafe=_cafe()))


@bp.get("/printing/kot/<order_id>/bytes")
# Kitchen users may fetch their own KOTs (receipts stay staff/owner-only).
@any_required
def kot_bytes(order_id):
    """Kitchen ticket bytes for direct printing from the app (nothing is sent)."""
    order = _order_or_404(order_id)
    return _bytes_page(order_id, printing.build_kot(order, cafe=_cafe()))


@bp.get("/printing/test/bytes")
@staff_required
def test_bytes():
    """Printer self-test page bytes (nothing is sent)."""
    data = printing.build_test(cafe=_cafe())
    return jsonify({"bytes_b64": _b64(data), "length": len(data)})


# --------------------------------------------------------------------------- #
# LAN proxy: send app-built bytes to an arbitrary printer (owner/staff only)
# --------------------------------------------------------------------------- #

def _send_port(body):
    raw = body.get("port", DEFAULT_SEND_PORT)
    if raw is None:
        raw = DEFAULT_SEND_PORT
    if isinstance(raw, bool) or not isinstance(raw, (int, str)):
        raise ApiError("'port' must be an integer between 1 and 65535", 400)
    try:
        port = int(str(raw).strip())
    except ValueError:
        raise ApiError("'port' must be an integer between 1 and 65535", 400)
    if not 1 <= port <= 65535:
        raise ApiError("'port' must be between 1 and 65535", 400)
    return port


@bp.post("/printing/send")
# Arbitrary-target LAN proxy: owner/staff only (kitchen must not aim prints).
@staff_required
def send_bytes():
    """Forward base64 bytes built by the app to a printer over TCP.

    Body: {"bytes_b64": str, "host": str, "port": int optional, 9100}.
    Returns {"sent": true, "host", "port"}; unreachable target -> 502.
    """
    body = request.get_json(silent=True) or {}

    raw = body.get("bytes_b64")
    if not isinstance(raw, str) or not raw.strip():
        raise ApiError("'bytes_b64' is required (non-empty base64 string)", 400)
    try:
        data = base64.b64decode(raw.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise ApiError("'bytes_b64' is not valid base64", 400)
    if not data:
        raise ApiError("'bytes_b64' must decode to non-empty bytes", 400)

    host = body.get("host")
    if not isinstance(host, str) or not host.strip():
        raise ApiError("'host' is required (non-empty string)", 400)
    host = host.strip()

    port = _send_port(body)
    try:
        printing.send(host, port, data)
    except OSError as e:
        raise ApiError(f"Could not reach printer at {host}:{port} — {e}", 502)
    return jsonify({"sent": True, "host": host, "port": port})
