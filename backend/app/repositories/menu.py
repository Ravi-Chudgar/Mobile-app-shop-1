"""Menu item data access (DynamoDB) + image URLs (S3) + Redis cache."""
import uuid

from boto3.dynamodb.conditions import Attr

from ..aws import menu_table, s3
from ..cache import cache_get, cache_set, cache_exists
from ..config import Config
from ..pricing import (DEFAULT_GST_RATE, DEFAULT_HSN_CODE, item_gst_rate,
                       normalize_gst_rate)
from ..util import plain, ApiError


def _image_url(image_key):
    if not image_key:
        return None
    try:
        return s3().generate_presigned_url(
            "get_object",
            Params={"Bucket": Config.IMAGES_BUCKET, "Key": image_key},
            ExpiresIn=Config.PRESIGN_TTL,
        )
    except Exception:
        return None


def present(item):
    """Shape a stored menu item into the API response."""
    item = plain(item)
    item["image_url"] = _image_url(item.get("image_key"))
    # Legacy items stored before Phase 1 get the restaurant-standard defaults.
    item["gst_rate"] = item_gst_rate(item)
    item["hsn_code"] = str(item.get("hsn_code") or DEFAULT_HSN_CODE)
    return item


def get_raw(item_id):
    resp = menu_table().get_item(Key={"id": item_id})
    return plain(resp["Item"]) if "Item" in resp else None


def get(item_id):
    cache_key = f"menu:item:{item_id}"
    cached = cache_get(cache_key)
    if cached is not None:
        return cached
    raw = get_raw(item_id)
    result = present(raw) if raw else None
    cache_set(cache_key, result, ttl=300)
    return result


def list_items(category=None):
    cache_key = f"menu:category:{category or 'all'}"
    cached = cache_get(cache_key)
    if cached is not None:
        return cached
    kwargs = {}
    if category:
        kwargs["FilterExpression"] = Attr("category").eq(category)
    items = menu_table().scan(**kwargs).get("Items", [])
    items = [present(i) for i in items]
    items.sort(key=lambda x: (x.get("category", ""), x.get("name", "")))
    cache_set(cache_key, items, ttl=300)
    return items


def categories():
    cache_key = "menu:categories"
    cached = cache_get(cache_key)
    if cached is not None:
        return cached
    cats = {i.get("category", "other") for i in menu_table().scan().get("Items", [])}
    result = sorted(cats)
    cache_set(cache_key, result, ttl=600)
    return result


def _gst_fields(data):
    """Extract validated {gst_rate, hsn_code} from a create/update payload."""
    out = {}
    if "gst_rate" in data and data["gst_rate"] is not None:
        out["gst_rate"] = normalize_gst_rate(data["gst_rate"])
    if "hsn_code" in data:
        code = str(data.get("hsn_code") or "").strip()
        out["hsn_code"] = code or DEFAULT_HSN_CODE
    return out


def create(data):
    item = {
        "id": data.get("id") or uuid.uuid4().hex[:8],
        "name": data["name"],
        "description": data.get("description", ""),
        "category": data.get("category", "other"),
        "base_price": int(data["base_price"]),
        "image_key": data.get("image_key"),
        "available": bool(data.get("available", True)),
        "options": data.get("options", []),
        "ingredients": data.get("ingredients", []),
        # GST is tax-inclusive: 5% is the Indian restaurant standard.
        "gst_rate": DEFAULT_GST_RATE,
        "hsn_code": DEFAULT_HSN_CODE,
    }
    item.update(_gst_fields(data))
    menu_table().put_item(Item=item)
    return present(item)


def update(item_id, data):
    existing = get_raw(item_id)
    if not existing:
        raise ApiError("Menu item not found", 404)
    for field in ("name", "description", "category", "options", "image_key", "ingredients"):
        if field in data:
            existing[field] = data[field]
    if "base_price" in data:
        existing["base_price"] = int(data["base_price"])
    if "available" in data:
        existing["available"] = bool(data["available"])
    existing.update(_gst_fields(data))
    menu_table().put_item(Item=existing)
    return present(existing)


def set_availability(item_id, available):
    existing = get_raw(item_id)
    if not existing:
        raise ApiError("Menu item not found", 404)
    existing["available"] = bool(available)
    menu_table().put_item(Item=existing)
    return present(existing)


def set_image_key(item_id, image_key):
    return update(item_id, {"image_key": image_key})


def delete(item_id):
    if not get_raw(item_id):
        raise ApiError("Menu item not found", 404)
    menu_table().delete_item(Key={"id": item_id})
    return {"deleted": item_id}
