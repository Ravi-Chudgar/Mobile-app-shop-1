"""Per-IP rate limiting for the sensitive endpoints.

Only the routes that matter for abuse are limited — cafe creation, login,
staff signup and act-as-owner. The POS's normal traffic (menu, orders, tables,
reports) is deliberately left unlimited so a busy cafe can never trip its own
limiter (the old global default of "200 per day" would have throttled it).

Flask-Limiter is optional: if the package is missing, or RATE_LIMIT_ENABLED=0
(used when a test needs unlimited headroom), `limit()` becomes an identity
decorator and the app behaves exactly as if rate limiting were never wired in.
"""
import os

from flask import jsonify, request

# The backend test suite hits these routes many times inside a single process,
# so tests can switch limiting off with RATE_LIMIT_ENABLED=0 if they outgrow a
# limit. Default is ON.
_ENABLED = os.getenv("RATE_LIMIT_ENABLED", "1").strip().lower() not in (
    "0", "false", "no")


def _client_key():
    """Best-effort client IP used as the limiter's key.

    In production the app sits behind Cloudflare's tunnel, where
    `request.remote_addr` is the proxy address shared by every user — keying on
    it would put all cafes into a single bucket and let one busy cafe lock out
    the rest. Prefer Cloudflare's `Cf-Connecting-Ip` (set by Cloudflare, not the
    client), then a generic `X-Forwarded-For`, and finally the socket address
    for direct/LAN use.
    """
    ip = (request.headers.get("Cf-Connecting-Ip", "").strip()
          or request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
          or request.remote_addr
          or "?")
    return ip


def account_key():
    """Rate-limit key of client IP **plus** the username in the JSON body.

    One budget per account means a shared cafe NAT (all staff behind one IP)
    never locks out colleagues, while password guessing against a single
    account is still capped.
    """
    try:
        data = request.get_json(silent=True) or {}
        user = str(data.get("username") or "")
    except Exception:  # pragma: no cover - malformed body
        user = ""
    return f"{_client_key()}|{user}"


try:
    from flask_limiter import Limiter

    _limiter = Limiter(
        key_func=_client_key,
        # In-memory storage works everywhere (host tests, Docker) without
        # needing Redis reachable; limits are best-effort per process.
        storage_uri=os.getenv("RATE_LIMIT_STORAGE", "memory://"),
    )
except Exception:  # pragma: no cover - flask-limiter not installed
    _limiter = None


def init_app(app):
    """Attach the limiter and a JSON 429 body to the Flask app."""
    if _limiter is None or not _ENABLED:
        return
    _limiter.init_app(app)

    @app.errorhandler(429)
    def _too_many(_err):
        # Flask-Limiter's default breach body is plain text; the app's clients
        # expect the same {"error": ...} JSON shape as every other failure.
        return jsonify({
            "error": "Too many requests — please wait a moment and try again."
        }), 429


def limit(spec, **kwargs):
    """Rate-limit the decorated view to `spec` (e.g. "10 per minute").

    Returns the view unchanged when limiting is disabled or unavailable, so
    routes can decorate unconditionally.
    """
    if _limiter is None or not _ENABLED:
        def _identity(fn):
            return fn
        return _identity
    return _limiter.limit(spec, **kwargs)
