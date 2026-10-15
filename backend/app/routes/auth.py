"""Login + staff self-registration."""
from flask import Blueprint, request, jsonify

from ..auth import authenticate
from ..config import Config
from ..ratelimit import account_key, limit
from ..repositories import staff as staff_repo

bp = Blueprint("auth", __name__, url_prefix="/auth")


def _validate_login_data(data):
    """Validate login request data. Returns (validated_dict, error_dict).
    error_dict is None if validation passes, otherwise dict with 'error' key.
    """
    if not data or not isinstance(data, dict):
        return None, {"error": "Invalid or missing JSON body"}
    username = data.get("username", "")
    password = data.get("password", "")
    if not username or len(username) < 3:
        return None, {"error": "Username must be at least 3 characters"}
    if not password or len(password) < 6:
        return None, {"error": "Password must be at least 6 characters"}
    tenant = data.get("tenant") or Config.DEFAULT_TENANT
    return {"username": username, "password": password, "tenant": tenant}, None


@bp.post("/login")
# Brute-force protection, keyed per account (IP + username) so a shared cafe
# NAT never locks out other staff while password guessing stays capped.
@limit("20 per minute", key_func=account_key)
def login():
    """Body: {username, password, tenant?}. `tenant` is the business code
    (default Config.DEFAULT_TENANT) — the returned JWT carries it as a
    `tenant` claim so every subsequent request is tenant-scoped."""
    validated, error = _validate_login_data(request.get_json(silent=True))
    if error:
        return jsonify(error), 400
    result = authenticate(validated["username"], validated["password"],
                          tenant=validated["tenant"])
    return jsonify(result)


@bp.post("/register")
# Public self-signup — the strictest limit; owners add staff via /admin/staff
# instead, so normal operation never approaches it.
@limit("5 per minute")
def register():
    """A new staff member signs up; they stay 'pending' until the owner
    approves them."""
    data = request.get_json(silent=True)
    if not data or not isinstance(data, dict):
        return jsonify({"error": "Invalid or missing JSON body"}), 400
    username = data.get("username", "")
    password = data.get("password", "")
    name = data.get("name", "")
    if not username or len(username) < 3:
        return jsonify({"error": "Username must be at least 3 characters"}), 400
    if not password or len(password) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400
    if not name or len(name) < 2:
        return jsonify({"error": "Name must be at least 2 characters"}), 400
    member = staff_repo.register(username, password, name)
    return jsonify({
        "status": "pending",
        "message": "Account created. Ask the owner to approve your login.",
        "staff": member,
    }), 201
