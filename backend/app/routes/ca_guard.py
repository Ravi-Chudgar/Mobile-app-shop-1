"""Global read-only guard for the cafe_ca (chartered accountant) role.

The app factory auto-registers every module in app/routes/ that exposes a
`bp`, so this blueprint is the only place Phase 4 can hang a hook without
editing app/__init__.py. `before_app_request` (unlike a blueprint-level
`before_request`) runs for EVERY request in the app, so a cafe_ca token can
never hit a mutating handler even if some route forgot to check the role.

Read-only means: only GET/HEAD/OPTIONS are allowed for cafe_ca. Routes are
still validated per-endpoint — cafe_ca is only *granted* access to the
explicit allow-list below; everywhere else the role guards reject it.

Routes that accept cafe_ca (all GET-only handlers):
    GET /export/tally, /export/gstr1, /export/gstr3b   (this phase)
    GET /admin/reports/daily, /admin/reports/z,
        /admin/reports/staff, /admin/billing           (read-only reports)
"""
from flask import Blueprint, jsonify, request

from ..auth import READ_ONLY_ROLES, decode_token

bp = Blueprint("ca_guard", __name__)


@bp.before_app_request
def enforce_read_only_roles():
    """Reject any non-read request that carries a read-only role's JWT.

    An absent/invalid token is left alone: the route's own guard answers
    401/403 with the usual message. This hook only adds a hard ceiling so
    cafe_ca can never mutate, regardless of which blueprint serves the route.
    """
    if request.method in ("GET", "HEAD", "OPTIONS"):
        return None
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    try:
        claims = decode_token(header.split(" ", 1)[1])
    except Exception:
        return None  # invalid/expired token -> the route guard handles it
    if claims.get("role") in READ_ONLY_ROLES:
        return jsonify({"error": "Your account is read-only"}), 403
    return None
