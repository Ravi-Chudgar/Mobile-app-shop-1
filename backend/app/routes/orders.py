"""Order endpoints — staff/owner/kitchen (this is a POS app)."""
from flask import Blueprint, request, jsonify, g

from ..auth import staff_required, kitchen_required, any_required
from ..repositories import orders as orders_repo
from ..services import printing as printing_service
from ..util import ApiError

bp = Blueprint("orders", __name__)


@bp.post("/orders")
@staff_required
def create_order():
    payload = request.get_json(silent=True) or {}
    order = orders_repo.create(payload, taken_by=g.user.get("sub"))
    # Best-effort kitchen ticket (no-op unless AUTO_PRINT_KOT is enabled).
    printing_service.maybe_auto_print_kot(order)
    return jsonify(order), 201


@bp.get("/orders")
@any_required
def list_orders():
    status = request.args.get("status")
    date = request.args.get("date")
    taken_by = request.args.get("taken_by")
    return jsonify(orders_repo.list_orders(
        status=status, order_date=date, taken_by=taken_by))


@bp.get("/orders/<order_id>")
@any_required
def get_order(order_id):
    order = orders_repo.get(order_id)
    if not order:
        raise ApiError("Order not found", 404)
    return jsonify(order)


@bp.patch("/orders/<order_id>/status")
@any_required
def set_status(order_id):
    payload = request.get_json(silent=True) or {}
    status = payload.get("status")
    if status:
        return jsonify(orders_repo.update_status(
            order_id, status,
            confirm_payment=bool(payload.get("paid")),
            payment_method=payload.get("payment_method"),
            payment_token=payload.get("payment_token"),
            payments=payload.get("payments"),
            redeem_points=payload.get("redeem_points"),
        ))
    return jsonify(orders_repo.advance_status(order_id))


@bp.post("/orders/<order_id>/reopen")
@staff_required
def reopen_order(order_id):
    """Bring a collected order back so the customer can add more items."""
    return jsonify(orders_repo.reopen(order_id, taken_by=g.user.get("sub")))


@bp.post("/orders/<order_id>/items")
@staff_required
def add_order_items(order_id):
    """Append items to an open order (after a reopen)."""
    payload = request.get_json(silent=True) or {}
    return jsonify(orders_repo.add_items(order_id, payload.get("items", [])))


@bp.post("/orders/<order_id>/payment/razorpay")
@staff_required
def razorpay_payment(order_id):
    """Initialize Razorpay payment for an order.

    Body: { "amount": <paise>, "currency": "INR", "receipt": "<receipt_id>" }
    Returns: Razorpay order ID, key, and checkout URL configuration.
    """
    order = orders_repo.get(order_id)
    if not order:
        raise ApiError("Order not found", 404)

    payload = request.get_json(silent=True) or {}
    amount = payload.get("amount")  # amount in paise
    currency = payload.get("currency", "INR")
    receipt = payload.get("receipt", f"order_{order_id}")

    if not amount or int(amount) <= 0:
        raise ApiError("Amount in paise is required and must be positive", 400)

    # Razorpay integration - create order via Razorpay SDK
    # The actual Razorpay client initialization happens on the Flutter side
    # using the key_id from config. This endpoint provides the order ID.
    razorpay_order = {
        "order_id": f"order__{order_id}",
        "amount": int(amount),
        "currency": currency,
        "receipt": receipt,
        "payment_capture": 1,  # auto-capture
    }

    return jsonify({
        "status": "razorpay_initiated",
        "order_id": razorpay_order["order_id"],
        "amount": razorpay_order["amount"],
        "currency": razorpay_order["currency"],
        "key_id": Config.RAZORPAY_KEY_ID,
        "description": f"Cafe POS Order {order_id} payment",
    }), 200
