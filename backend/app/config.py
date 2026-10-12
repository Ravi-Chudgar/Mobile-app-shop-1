"""Environment-driven settings. Values are read at import time; the AWS
endpoint is resolved live in aws.py so `eval $(floci env)` works without a
code change."""
import os


class Config:
    AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

    # --- Multi-tenancy (see app/tenancy.py) ---
    # Slug of the default tenant. Its tables keep the legacy unprefixed
    # names (MENU_TABLE, ORDERS_TABLE, ...) so existing demo data, env
    # overrides and tests keep working; every other tenant gets
    # "{slug}_{base}" tables (e.g. chai_point_orders).
    DEFAULT_TENANT = os.getenv("DEFAULT_TENANT", "main")
    # Global tenant registry (PK slug) — one row per tenant, holds display
    # config (name, GSTIN, address, phone, bill footer, kitchen printer).
    TENANTS_TABLE = os.getenv("TENANTS_TABLE", "cafe_tenants")

    MENU_TABLE = os.getenv("MENU_TABLE", "menu_items")
    ORDERS_TABLE = os.getenv("ORDERS_TABLE", "orders")
    STAFF_TABLE = os.getenv("STAFF_TABLE", "staff")
    TABLES_TABLE = os.getenv("TABLES_TABLE", "cafe_tables")
    INVENTORY_TABLE = os.getenv("INVENTORY_TABLE", "inventory_items")
    ORDER_DATE_INDEX = os.getenv("ORDER_DATE_INDEX", "order_date-index")
    IMAGES_BUCKET = os.getenv("IMAGES_BUCKET", "cafe-menu-images")

    JWT_SECRET = os.getenv("JWT_SECRET", "dev-secret-change-me")
    JWT_TTL_HOURS = int(os.getenv("JWT_TTL_HOURS", "12"))

    PRESIGN_TTL = int(os.getenv("PRESIGN_TTL", "3600"))

    # Number of tables created on first boot.
    DEFAULT_TABLE_COUNT = int(os.getenv("DEFAULT_TABLE_COUNT", "10"))

    # Order statuses that count toward sales (everything except cancelled).
    SALES_STATUSES = ("received", "preparing", "ready", "collected")

    # --- AI recommendations (local Ollama; see services/recommender.py) ---
    OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    # llama3.2:3b over 8b: ~3x faster on CPU; the only model that finishes
    # inside the recommendation timeout on this hardware.
    OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2:3b")
    OLLAMA_TIMEOUT_S = int(os.getenv("OLLAMA_TIMEOUT_S", "25"))
    RECOMMEND_LIMIT = int(os.getenv("RECOMMEND_LIMIT", "3"))
    RECOMMEND_CACHE_TTL = int(os.getenv("RECOMMEND_CACHE_TTL", "120"))
    POPULAR_DAYS = int(os.getenv("POPULAR_DAYS", "7"))

    # --- Agentic Q&A assistant (services/assistant.py) ---
    ASK_TIMEOUT_S = int(os.getenv("ASK_TIMEOUT_S", "25"))

    # --- Cafe identity (printed on bills / receipts) ---
    CAFE_NAME = os.getenv("CAFE_NAME", "Cafe POS Demo")
    CAFE_ADDRESS = os.getenv(
        "CAFE_ADDRESS", "12 MG Road, Ahmedabad, Gujarat 380001")
    CAFE_GSTIN = os.getenv("CAFE_GSTIN", "24ABCDE1234F1Z5")
    CAFE_PHONE = os.getenv("CAFE_PHONE", "+91 98765 43210")

    # --- Thermal (ESC/POS) printer ---
    # Empty host => dry-run mode: receipts are built but nothing is sent.
    ESCPOS_PRINTER_HOST = os.getenv("ESCPOS_PRINTER_HOST", "")
    ESCPOS_PRINTER_PORT = int(os.getenv("ESCPOS_PRINTER_PORT", "9100"))

    # Auto-print a kitchen order ticket whenever a new order is created.
    # Requires ESCPOS_PRINTER_HOST to be set; failures are logged, never raised.
    AUTO_PRINT_KOT = os.getenv("AUTO_PRINT_KOT", "0") == "1"

    # --- Phase 3: QR table ordering (public routes, no auth) ---
    # Base URL encoded into the table QR codes: "{QR_BASE_URL}/table/<n>".
    QR_BASE_URL = (os.getenv("QR_BASE_URL") or os.getenv("APP_BASE_URL")
                   or "http://localhost:9999")

    # --- Phase 3: loyalty points ---
    LOYALTY_TABLE = os.getenv("LOYALTY_TABLE", "loyalty_accounts")
    # Points earned per ₹1 spent (paid_amount is in paise).
    LOYALTY_EARN_RATE = float(os.getenv("LOYALTY_EARN_RATE", "1"))
    # Value of one point in paise (100 => 1 point = ₹1).
    LOYALTY_POINT_VALUE_PAISE = int(os.getenv("LOYALTY_POINT_VALUE_PAISE", "100"))

    # --- Phase 3: delivery partner ingestion (X-Integration-Key header) ---
    # Empty key => the endpoint rejects every request (fail closed).
    SWIGGY_API_KEY = os.getenv("SWIGGY_API_KEY", "")
    ZOMATO_API_KEY = os.getenv("ZOMATO_API_KEY", "")

    # --- Offline-first sync (routes/sync.py) ---
    # Max ops accepted in one POST /sync/batch replay from an offline client.
    SYNC_MAX_BATCH = int(os.getenv("SYNC_MAX_BATCH", "50"))
