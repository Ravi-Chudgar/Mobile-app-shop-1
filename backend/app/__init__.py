"""Flask application factory."""
import importlib
import os
import pkgutil

from dotenv import load_dotenv
from flask import Flask, jsonify, request, make_response

from .util import ApiError
from .cache import cache_get, cache_set, cache_exists
# Per-endpoint rate limiting (login, cafe creation, ...). The previous
# in-module limiter referenced CACHE_AVAILABLE before it was defined, so the
# NameError was swallowed and rate limiting never actually ran.
from .ratelimit import init_app as _init_rate_limiter

load_dotenv()  # load backend/.env if present

# Allowed browser origins for CORS. "*" is fine for local dev (we use bearer
# tokens, not cookies) but in production this is a comma-separated allow-list:
# only those origins get an Access-Control-Allow-Origin echo back, so random
# websites cannot call the API from a visitor's browser.
#   CORS_ORIGINS=https://mobileapp.unonomercysound.online,http://192.168.1.120:9999
CORS_ORIGINS = {
    origin.strip()
    for origin in os.getenv("CORS_ORIGINS", "*").split(",")
    if origin.strip()
} or {"*"}


def create_app():
    app = Flask(__name__)

    # Attach per-endpoint rate limiting (a no-op if Flask-Limiter is absent or
    # RATE_LIMIT_ENABLED=0).
    _init_rate_limiter(app)

    # Never stay silent about the insecure default signing key — it appears in
    # docker-compose.yml, so anyone who reads it could forge admin tokens.
    from .config import Config

    if Config.JWT_SECRET == "dev-secret-change-me":
        app.logger.warning(
            "SECURITY: JWT_SECRET is still the docker-compose default "
            "('dev-secret-change-me'); set a random JWT_SECRET in .env or "
            "login tokens can be forged."
        )

    # Auto-register every blueprint in app/routes/*: each module exposes a
    # module-level `bp`. Adding a new route file needs no edit here, which
    # keeps parallel feature work conflict-free.
    from . import routes as routes_pkg

    for mod in pkgutil.iter_modules(routes_pkg.__path__):
        if mod.name.startswith("_"):
            continue
        module = importlib.import_module(f".routes.{mod.name}", __name__)
        bp = getattr(module, "bp", None)
        if bp is not None:
            app.register_blueprint(bp)

    # ---- CORS + security headers on every response ----
    @app.after_request
    def add_security_headers(resp):
        origin = request.headers.get("Origin")
        if "*" in CORS_ORIGINS:
            allow = origin or "*"
        elif origin and origin in CORS_ORIGINS:
            allow = origin
        else:
            # Origin outside the allow-list (or a non-browser client): send no
            # ACAO header at all, so the browser refuses the cross-origin read.
            allow = None

        if allow:
            resp.headers["Access-Control-Allow-Origin"] = allow
            resp.headers["Vary"] = "Origin"
            resp.headers["Access-Control-Allow-Headers"] = \
                "Content-Type, Authorization"
            resp.headers["Access-Control-Allow-Methods"] = \
                "GET, POST, PUT, PATCH, DELETE, OPTIONS"

        # Hardening: never MIME-sniff responses, never allow framing (anti
        # clickjacking), never leak the referrer.
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "no-referrer")
        # HSTS only counts over HTTPS (the Cloudflare tunnel); browsers ignore
        # it on plain-HTTP LAN access, so sending it there is harmless.
        if request.is_secure or request.headers.get("X-Forwarded-Proto") == "https":
            resp.headers.setdefault(
                "Strict-Transport-Security", "max-age=31536000; includeSubDomains"
            )
        return resp

    # Answer CORS preflight for any path.
    @app.route("/<path:_any>", methods=["OPTIONS"])
    @app.route("/", methods=["OPTIONS"])
    def cors_preflight(_any=None):
        return make_response("", 204)

    @app.get("/health")
    def health():
        return jsonify({"status": "ok"})

    @app.errorhandler(ApiError)
    def handle_api_error(err):
        return jsonify({"error": err.message}), err.status

    @app.errorhandler(404)
    def not_found(_):
        return jsonify({"error": "Not found"}), 404

    # Answer a server fault with plain JSON — never an HTML stack trace or
    # internal detail. Flask and gunicorn already log the full traceback
    # server-side; here we only shape what the client is allowed to see.
    @app.errorhandler(500)
    def internal_error(_err):
        return jsonify({"error": "Internal server error"}), 500

    return app