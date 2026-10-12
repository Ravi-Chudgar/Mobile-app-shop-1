"""boto3 client/resource factory.

The endpoint URL is read from the environment on every call so the same code
talks to Floci locally (AWS_ENDPOINT_URL set by `eval $(floci env)`) or to real
AWS in production (variable unset)."""
import os
import boto3

from . import tenancy
from .config import Config


def _kwargs():
    endpoint = os.getenv("AWS_ENDPOINT_URL") or None
    return {
        "endpoint_url": endpoint,
        "region_name": os.getenv("AWS_REGION", Config.AWS_REGION),
    }


def dynamodb():
    return boto3.resource("dynamodb", **_kwargs())


def dynamodb_client():
    return boto3.client("dynamodb", **_kwargs())


def s3():
    return boto3.client("s3", **_kwargs())


# --------------------------------------------------------------------------- #
# Tenant-scoped tables: the name depends on the tenant that owns the current
# request/script (app/tenancy.py). Repositories import these accessors and
# need no tenant awareness of their own.
# --------------------------------------------------------------------------- #

def menu_table():
    return dynamodb().Table(tenancy.tenant_table_name(Config.MENU_TABLE))


def orders_table():
    return dynamodb().Table(tenancy.tenant_table_name(Config.ORDERS_TABLE))


def staff_table():
    return dynamodb().Table(tenancy.tenant_table_name(Config.STAFF_TABLE))


def tables_table():
    return dynamodb().Table(tenancy.tenant_table_name(Config.TABLES_TABLE))


def inventory_table():
    return dynamodb().Table(tenancy.tenant_table_name(Config.INVENTORY_TABLE))


def loyalty_table_name():
    """Physical name of the current tenant's loyalty table (the repository
    creates it lazily, so infra needs the name too)."""
    return tenancy.tenant_table_name(Config.LOYALTY_TABLE)


def loyalty_table():
    return dynamodb().Table(loyalty_table_name())


def tenants_table():
    """GLOBAL tenant registry (`cafe_tenants`, PK slug) — deliberately not
    tenant-scoped: it is the map from slug to tenant."""
    return dynamodb().Table(Config.TENANTS_TABLE)
