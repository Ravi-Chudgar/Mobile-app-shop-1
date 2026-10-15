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
# tokens, not cookies). Set CORS_ORIGINS to a comma-separated list in prod.
CORS_ORIGINS = os.getenv("CORS_ORIGINS", "*")


def create_app():
    app = Flask(__name__)

    # Attach per-endpoint rate limiting (a no-op if Flask-Limiter is absent or
    # RATE_LIMIT_ENABLED=0).
    _init_rate_limiter(app)

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

    # ---- CORS: let the Flutter web build (and any browser) call the API ----
    @app.after_request
    def add_cors_headers(resp):
        origin = request.headers.get("Origin")
        allow = CORS_ORIGINS if CORS_ORIGINS != "*" else (origin or "*")
        resp.headers["Access-Control-Allow-Origin"] = allow
        resp.headers["Vary"] = "Origin"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
        resp.headers["Access-Control-Allow-Methods"] = \
            "GET, POST, PUT, PATCH, DELETE, OPTIONS"
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

    return app