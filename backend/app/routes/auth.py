"""Login + staff self-registration."""
from flask import Blueprint, request, jsonify

from ..auth import authenticate
from ..config import Config
from ..repositories import staff as staff_repo

bp = Blueprint("auth", __name__, url_prefix="/auth")


@bp.post("/login")
def login():
    """Body: {username, password, tenant?}. `tenant` is the business code
    (default Config.DEFAULT_TENANT) — the returned JWT carries it as a
    `tenant` claim so every subsequent request is tenant-scoped."""
    data = request.get_json(silent=True) or {}
    result = authenticate(data.get("username", ""),
                          data.get("password", ""),
                          tenant=data.get("tenant") or Config.DEFAULT_TENANT)
    return jsonify(result)


@bp.post("/register")
def register():
    """A new staff member signs up; they stay 'pending' until the owner
    approves them."""
    data = request.get_json(silent=True) or {}
    member = staff_repo.register(
        data.get("username", ""),
        data.get("password", ""),
        data.get("name", ""),
    )
    return jsonify({
        "status": "pending",
        "message": "Account created. Ask the owner to approve your login.",
        "staff": member,
    }), 201
