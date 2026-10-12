"""Tenant context: which business (cafe / hostel / ...) owns this work.

Multi-tenancy model
-------------------
Each tenant owns its OWN set of DynamoDB tables named after its slug —
``{slug}_{base}``, e.g. ``chai_point_orders``, ``city_hostel_menu_items`` —
plus one row in the global ``cafe_tenants`` registry holding its config
(display name, GSTIN, address, phone, bill footer, kitchen printer, ...).

Table naming rule (see :func:`tenant_table_name`):

* slug == ``Config.DEFAULT_TENANT``  -> legacy unprefixed name (``orders``,
  ``menu_items``, ...) so existing demo data, env-overridden ``*_TABLE``
  names and the current tests keep working unchanged;
* any other slug                     -> ``f"{slug}_{base}"``.

Resolution order for :func:`current_tenant`:

1. ``g.tenant`` — set by the auth guard (JWT ``tenant`` claim) or by the
   tenant-scoped public routes after the registry says the slug exists;
2. the process-level binding installed by :func:`set_tenant` /
   :func:`tenant_scope` when there is no Flask app context (scripts, tests);
3. ``Config.DEFAULT_TENANT`` (env ``DEFAULT_TENANT``, default ``"main"``).

Nothing here talks to DynamoDB — repositories resolve their table *names*
through app/aws.py, which calls :func:`tenant_table_name` on every accessor.
"""
import re
from contextlib import contextmanager

from flask import g

from .config import Config
from .util import ApiError

# Tenant slug format, used both when creating a tenant and when parsing it
# out of a URL (public routes 404 on anything that does not match).
SLUG_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,30}$")

# Process-level tenant for callers OUTSIDE a Flask app context (scripts,
# tests, `python -c`). Only ever read when `g` is unavailable; requests
# always win via `g.tenant`.
_FALLBACK = None


def is_valid_slug(slug):
    """True when `slug` matches SLUG_PATTERN (lowercase code, 2-31 chars)."""
    return bool(slug) and bool(SLUG_PATTERN.match(str(slug)))


def validate_slug(slug):
    """Check a tenant slug, raising ApiError(400) with the rule on failure.

    Used at tenant creation (repositories/tenants.create); URL parsing uses
    :func:`is_valid_slug` and 404s instead of exposing validation errors.
    """
    if not is_valid_slug(slug):
        raise ApiError(
            "Invalid tenant code: use 2-31 characters, start with a "
            "lowercase letter, then lowercase letters, digits or "
            "underscores (e.g. chai_point)")
    return str(slug)


def current_tenant():
    """Slug of the tenant that owns the current work (see module docstring)."""
    try:
        slug = getattr(g, "tenant", None)
    except RuntimeError:  # outside an application context
        slug = None
    return slug or _FALLBACK or Config.DEFAULT_TENANT


def set_tenant(slug):
    """Bind `slug` as the current tenant.

    Inside Flask it is stored on `g` (per request); outside an application
    context it is stored process-level so scripts/tests can scope repository
    calls too. Returns a token for :func:`reset_tenant`.
    """
    global _FALLBACK
    try:
        prev = g.pop("tenant", None)
        g.tenant = slug
        return ("ctx", prev)
    except RuntimeError:  # no application context
        prev = _FALLBACK
        _FALLBACK = slug
        return ("proc", prev)


def reset_tenant(token):
    """Undo a :func:`set_tenant` call using the token it returned."""
    global _FALLBACK
    kind, prev = token
    if kind == "ctx":
        if prev is None:
            g.pop("tenant", None)
        else:
            g.tenant = prev
    else:
        _FALLBACK = prev


@contextmanager
def tenant_scope(slug):
    """Run a block as `slug` (repo calls inside resolve that tenant's tables).

    Restores the previous tenant afterwards, so a script that seeds tenant B
    does not leak "B" into later default-tenant work in the same process.
    """
    token = set_tenant(slug)
    try:
        yield slug
    finally:
        reset_tenant(token)


def tenant_table_name(base, slug=None):
    """Physical DynamoDB table name for `base` under `slug`.

    ``tenant_table_name("orders")``            -> current tenant
    ``tenant_table_name("orders", "b")``       -> "b_orders"
    ``tenant_table_name("orders")`` on default -> "orders" (legacy names).
    """
    slug = slug or current_tenant()
    if slug == Config.DEFAULT_TENANT:
        return base
    return f"{slug}_{base}"


def tenant_prefix(slug=None):
    """S3 object-key prefix for tenant-owned files (always ``"<slug>/"``,
    the default tenant included — S3 keys are not table names, there is no
    legacy data to preserve)."""
    return f"{slug or current_tenant()}/"
