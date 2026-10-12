"""Redis cache layer for frequently accessed data."""
import json
import os
import time
from typing import Optional, Any, List, Dict

import redis

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
_redis: Optional[redis.Redis] = None


def get_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        _redis = redis.from_url(REDIS_URL, decode_responses=True)
    return _redis


def _serialize_value(value: Any) -> str:
    """Automatically serialize lists/dicts to JSON strings for Redis storage.
    
    Redis cannot store Python lists/dicts directly - they must be strings.
    Other types (str, int, float, bool) are returned as-is.
    """
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    return str(value)


def cache_get(key: str, namespace: str = "pos") -> Optional[Any]:
    """Get a value from the cache. Returns None if not found."""
    r = get_redis()
    full_key = f"pos:{namespace}:{key}"
    raw = r.get(full_key)
    if raw is None:
        return None
    # Try to deserialize JSON back to list/dict
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return raw


def cache_set(key: str, value: Any, ttl: int = 300, namespace: str = "pos") -> None:
    """Set a value in the cache with optional TTL (seconds).
    
    Automatically serializes lists/dicts to JSON strings since Redis
    cannot store Python collections directly.
    """
    r = get_redis()
    full_key = f"pos:{namespace}:{key}"
    serialized = _serialize_value(value)
    r.setex(full_key, ttl, serialized)


def cache_del(key: str, namespace: str = "pos") -> None:
    """Delete a key from the cache."""
    r = get_redis()
    full_key = f"pos:{namespace}:{key}"
    r.delete(full_key)


def cache_exists(key: str, namespace: str = "pos") -> bool:
    """Check if a key exists in the cache."""
    r = get_redis()
    full_key = f"pos:{namespace}:{key}"
    return r.exists(full_key)


def cache_incr(key: str, amount: int = 1, namespace: str = "pos") -> int:
    """Increment a counter in the cache."""
    r = get_redis()
    full_key = f"pos:{namespace}:{key}"
    return r.incr(full_key, amount)


def cache_keys(pattern: str, namespace: str = "pos") -> List[str]:
    """Get all keys matching a pattern in a namespace."""
    r = get_redis()
    full_pattern = f"pos:{namespace}:{pattern}"
    return r.keys(full_pattern)


def clear_namespace(namespace: str = "pos") -> int:
    """Clear all keys in a namespace."""
    r = get_redis()
    full_pattern = f"pos:{namespace}:*"
    keys = r.keys(full_pattern)
    if keys:
        r.delete(*keys)
    return len(keys)