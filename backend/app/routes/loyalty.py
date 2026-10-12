"""Loyalty endpoints (staff/owner JWT).

GET  /loyalty/<phone>   balance + recent ledger (staff lookup screen)
POST /loyalty/adjust    owner-only manual +/- adjustment

Earn/redeem happen automatically on collect — see
app/repositories/orders.py::update_status. Env: LOYALTY_EARN_RATE (points
per ₹1) and LOYALTY_POINT_VALUE_PAISE (1 point = that many paise).
"""
from flask import Blueprint, request, jsonify

from ..auth import staff_required, owner_required
from ..config import Config
from ..repositories import loyalty as loyalty_repo
from ..util import ApiError

bp = Blueprint("loyalty", __name__)


def _present(account):
    """Response shape shared by lookup + adjust. Carries the economics
    (point value / earn rate) so clients never hard-code them."""
    return {
        "phone": account.get("phone"),
        "points": int(account.get("points", 0)),
        "updated_at": account.get("updated_at"),
        "ledger": list(reversed(account.get("ledger") or []))[:20],
        "point_value_paise": Config.LOYALTY_POINT_VALUE_PAISE,
        "earn_rate": Config.LOYALTY_EARN_RATE,
    }


@bp.get("/loyalty/<phone>")
@staff_required
def lookup(phone):
    """Balance + ledger for a phone. Unknown phones return zero/empty so
    the lookup screen can show "no points yet" instead of a 404."""
    account = loyalty_repo.get(phone) or {
        "phone": loyalty_repo.normalize_phone(phone),
        "points": 0,
        "updated_at": None,
        "ledger": [],
    }
    return jsonify(_present(account))


@bp.post("/loyalty/adjust")
@owner_required
def adjust():
    """Manual correction/top-up: {phone, delta: <int, + or ->, reason}."""
    payload = request.get_json(silent=True) or {}
    phone = payload.get("phone")
    if not str(phone or "").strip():
        raise ApiError("phone is required")
    reason = payload.get("reason")
    if not str(reason or "").strip():
        raise ApiError("reason is required")
    account = loyalty_repo.adjust(
        phone=phone,
        delta=payload.get("delta"),
        reason=reason,
        order_id=payload.get("order_id"),
    )
    return jsonify(_present(account))
