"""Authentication for owner + staff + kitchen + cafe_ca: password hashing +
JWT + role guards.

Roles (Phase 4):
    owner    - full management
    staff    - take/serve orders
    kitchen  - order display
    cafe_ca  - chartered accountant, READ-ONLY (accounting bridge).
    admin    - platform admin: owns no cafe, SEES & CONTROLS ALL cafes
               (separate env-seeded login; /platform/* routes).

Multi-tenancy: `authenticate` scopes the login to one tenant's staff table
and the issued JWT carries a `tenant` claim; `_guard` restores it onto
`g.tenant` for the rest of the request (see app/tenancy.py).

Guards match roles EXACTLY: a cafe_ca token is rejected by `owner_required`,
`staff_required`, `kitchen_required` and `any_required` unless a route
explicitly opts in with `cafe_ca_required` / `owner_ca_required`. On top of
that, app/routes/ca_guard.py installs a global before-request hook that
refuses every non-GET request made with a cafe_ca token, so the CA login can
never perform a mutation even if a route forgot to check.
"""
import hmac
import time
from functools import wraps

import jwt
from flask import request, jsonify, g
from passlib.hash import pbkdf2_sha256

from .config import Config
from .tenancy import current_tenant, is_valid_slug, set_tenant, reset_tenant
from .util import ApiError


# Valid account roles. `cafe_ca` is the read-only chartered-accountant login
# added in Phase 4 (accounting bridge). `admin` is the platform admin: it owns
# no cafe and sees/controls ALL of them (separate env-seeded login).
VALID_ROLES = ("owner", "staff", "kitchen", "cafe_ca", "admin")
# Roles that must never perform a write (enforced globally by ca_guard.py).
READ_ONLY_ROLES = ("cafe_ca",)


def hash_password(password):
    return pbkdf2_sha256.hash(password)


def verify_password(password, hashed):
    try:
        return pbkdf2_sha256.verify(password, hashed)
    except (ValueError, TypeError):
        return False


def issue_token(username, role, tenant=None):
    """Sign a JWT. The `tenant` claim scopes every request made with it:
    default = the current/default tenant (existing callers unchanged)."""
    payload = {
        "sub": username,
        "role": role,
        "tenant": tenant or current_tenant(),
        "iat": int(time.time()),
        "exp": int(time.time()) + Config.JWT_TTL_HOURS * 3600,
    }
    return jwt.encode(payload, Config.JWT_SECRET, algorithm="HS256")


def decode_token(token):
    return jwt.decode(token, Config.JWT_SECRET, algorithms=["HS256"])


def _platform_admin_matches(username, password):
    """True when (username, password) equal the env-seeded platform admin.

    The platform admin belongs to no cafe: it is configured in the server env
    (PLATFORM_ADMIN_USER / PLATFORM_ADMIN_PASSWORD) and, when the password is
    empty, the login is disabled. Both fields are compared in constant time so
    neither can be guessed by timing.
    """
    puser = (Config.PLATFORM_ADMIN_USER or "").strip().lower()
    ppwd = Config.PLATFORM_ADMIN_PASSWORD or ""
    if not puser or not ppwd:
        return False
    user_ok = hmac.compare_digest(username.encode("utf-8"),
                                  puser.encode("utf-8"))
    pwd_ok = hmac.compare_digest(str(password or "").encode("utf-8"),
                                 ppwd.encode("utf-8"))
    return user_ok and pwd_ok


def authenticate(username, password, tenant=None):
    """Validate credentials against `tenant`'s staff table.

    tenant=None -> Config.DEFAULT_TENANT (existing callers/tests unchanged).
    The staff lookup, the last-login write and the issued token are all
    scoped to that tenant, so an account that exists in one business can
    never authenticate against another's.

    Raises ApiError(400) for a malformed tenant code, ApiError(404) when the
    tenant is not registered, ApiError(401) on bad credentials, ApiError(403)
    if a staff account is still awaiting owner approval.
    """
    from .repositories import staff as staff_repo
    from .repositories import tenants as tenants_repo

    username = (username or "").strip().lower()

    # Platform admin: an env-seeded login that owns no cafe. Checked first so
    # it works with no tenant context; returns a role=admin token. The platform
    # routes it uses resolve tenants explicitly, never g.tenant.
    if _platform_admin_matches(username, password):
        return {
            "token": issue_token(username, "admin"),
            "role": "admin",
            "name": username,
            "username": username,
            "tenant": None,
        }

    slug = tenant or Config.DEFAULT_TENANT
    slug = str(slug).strip()
    if not is_valid_slug(slug):
        raise ApiError("Invalid tenant code", 400)
    # The default tenant is implicitly valid (env-driven); every other slug
    # must exist in the registry before we go looking for accounts in it.
    if slug != Config.DEFAULT_TENANT and not tenants_repo.get(slug):
        raise ApiError("Unknown tenant", 404)

    token_owner = set_tenant(slug)
    try:
        username = (username or "").strip().lower()
        member = staff_repo.get(username)
        if not member or not verify_password(password,
                                              member.get("password_hash", "")):
            raise ApiError("Invalid username or password", 401)
        if member.get("role") not in ("owner",) and member.get("status") != "approved":
            raise ApiError("Your account is awaiting owner approval", 403)

        staff_repo.record_login(username)
        return {
            "token": issue_token(username, member["role"], tenant=slug),
            "role": member["role"],
            "name": member.get("name", username),
            "username": username,
            "tenant": slug,
        }
    finally:
        reset_tenant(token_owner)


def _claims_from_request():
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        raise ApiError("Missing bearer token", 401)
    try:
        return decode_token(header.split(" ", 1)[1])
    except jwt.ExpiredSignatureError:
        raise ApiError("Session expired, please log in again", 401)
    except jwt.InvalidTokenError:
        raise ApiError("Invalid token", 401)


def _guard(allowed_roles):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            try:
                claims = _claims_from_request()
            except ApiError as e:
                return jsonify({"error": e.message}), e.status
            if claims.get("role") not in allowed_roles:
                return jsonify({"error": "Not permitted for your role"}), 403
            # Bind the tenant BEFORE g.user so every repo call made by the
            # handler (orders, sync, export, printing, loyalty, ...) reads
            # the tables of the tenant named in the token. Tokens issued
            # before multi-tenancy have no `tenant` claim -> default tenant.
            g.tenant = claims.get("tenant") or Config.DEFAULT_TENANT
            g.user = claims
            return fn(*args, **kwargs)

        return wrapper

    return decorator


# Owner-only (management). Staff-or-owner (day-to-day operations).
# These keep EXACT role sets: a cafe_ca token is rejected by all of them
# unless a route explicitly opts in below.
owner_required = _guard({"owner"})
staff_required = _guard({"owner", "staff"})
kitchen_required = _guard({"owner", "kitchen"})
any_required = _guard({"owner", "staff", "kitchen"})

# Phase 4 — accounting bridge. Export/GST routes and the read-only report
# routes the CA needs are guarded with owner_or_ca; cafe_ca_required is for
# CA-only routes (none today, kept for symmetry).
cafe_ca_required = _guard({"cafe_ca"})
owner_or_ca = _guard({"owner", "cafe_ca"})

# Platform admin — cross-cafe management (list/create cafes, act as any cafe's
# owner). Its token is never scoped to one cafe's data: the /platform/* routes
# resolve tenants explicitly with tenant_scope(slug).
admin_required = _guard({"admin"})
