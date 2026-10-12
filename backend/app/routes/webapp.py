"""Serve the built Flutter web app from the backend.

Mount the release build (`mobile/build/web`) into the container and set
WEB_DIST (docker-compose does both). Any public URL pointing at this API —
Cloudflare tunnel, LAN, localhost:9999 — then loads the actual app UI:
the API keeps living under its own prefixes, everything else is handled
as a single-page-app route (index.html).

API paths are never shadowed: they return the normal JSON 404, and the
SPA fallback only answers GET/HEAD for non-API paths.
"""
import os
from pathlib import Path

from flask import Blueprint, current_app, jsonify, send_from_directory
from werkzeug.security import safe_join

bp = Blueprint("webapp", __name__)

# Path prefixes owned by the API — never serve SPA files for these. Every
# top-level segment a blueprint can answer under; anything else is app UI.
_API_PREFIXES = (
    "/admin", "/ask", "/auth", "/billing", "/categories", "/export",
    "/gstr", "/health", "/integrations", "/inventory", "/kitchen",
    "/loyalty", "/menu", "/orders", "/printing", "/public", "/qr",
    "/recommend", "/reports", "/staff", "/sync", "/tables", "/tally",
)

_MIMES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".json": "application/json",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webmanifest": "application/manifest+json",
    ".ttf": "font/ttf",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".map": "application/json",
    ".bmp": "image/bmp",
}


def _dist():
    """Web dist dir from env, or None when not mounted/not built."""
    raw = os.getenv("WEB_DIST", "")
    if not raw:
        return None
    path = Path(raw)
    if not (path / "index.html").is_file():
        return None
    return path


def _api_path(path):
    return any(path == p or path.startswith(p + "/") for p in _API_PREFIXES)


def _serve_file(directory, rel):
    target = safe_join(str(directory), rel)
    if target is None or not os.path.isfile(target):
        return None
    mime = _MIMES.get(os.path.splitext(target)[1].lower(), "application/octet-stream")
    resp = current_app.response_class(
        open(target, "rb").read(), mimetype=mime)
    if rel == "index.html":
        resp.headers["Cache-Control"] = "no-cache"
    elif not rel.startswith(("assets/", "icons/")):
        resp.headers["Cache-Control"] = "no-cache"
    else:
        # Flutter's build fingerprints assets/ — safe to cache hard.
        resp.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    return resp


@bp.get("/")
def spa_root():
    dist = _dist()
    if dist is None:
        return jsonify({"error": "Web app not built/mounted (see WEB_DIST)"}), 404
    return _serve_file(dist, "index.html")


@bp.get("/<path:rest>")
def spa_route(rest):
    dist = _dist()
    if dist is None or _api_path("/" + rest):
        return jsonify({"error": "Not found"}), 404
    # Real file (asset, favicon, manifest, splash) -> serve it.
    resp = _serve_file(dist, rest)
    if resp is not None:
        return resp
    # Deep-link style path (/t/<slug>/table/<n>) -> hand the SPA its shell.
    if "." not in rest.rsplit("/", 1)[-1]:
        return _serve_file(dist, "index.html")
    return jsonify({"error": "Not found"}), 404
