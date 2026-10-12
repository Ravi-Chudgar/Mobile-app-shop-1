# Cafe App — Build Plan

**Stack:** Flutter app · Flask (Python) API · Floci local cloud (S3 + DynamoDB)
**v1 scope:** Browse the cafe menu, customize an item (size / milk / extras), place an order for pickup, and track its status.
**Admin:** A role-gated section of the same Flutter app + admin-only API endpoints so staff can manage the menu, work orders, and see end-of-day total sales.

---

## 1. How the pieces fit

```
┌─────────────┐   HTTPS/JSON    ┌──────────────┐   boto3    ┌──────────────────┐
│  Flutter    │  ────────────►  │  Flask API   │  ───────►  │  Floci (local)   │
│  cafe app   │  ◄────────────  │  (Python)    │  ◄───────  │  S3 + DynamoDB   │
└─────────────┘                 └──────────────┘            └──────────────────┘
   customer UI                   menu + orders               emulated AWS cloud
```

- **Flutter** is one codebase with two experiences: the **customer** flow (browse + order) and an **admin** flow (menu, orders, sales). Which one loads is decided by the logged-in role. It only talks to your Flask API — never to AWS/Floci directly.
- **Flask** is the single backend service: menu, order creation, pricing, order status, **plus admin-only endpoints** for menu management, order fulfilment, and sales reporting. The only thing that touches storage.
- **Floci** emulates AWS S3 (menu-item photos) and DynamoDB (menu + orders) locally, so the backend uses real AWS SDKs (`boto3`) while everything runs on your machine.

**One app, two roles:** keeping admin inside the same Flutter project (gated by an admin login) is the easiest to manage — shared models, one API client, one build. It can later be split into a separate admin build if you ever want that.

**Why this is easy to manage:** run `floci start && eval $(floci env)` once and `boto3` in Flask auto-picks up the local endpoints from the environment. No database to install, no cloud account for dev, and going live on real AWS later is just dropping those env vars.

---

## 2. Repository layout

```
Mobile-app-shop/
├── PLAN.md                  # this file
├── backend/                 # Flask API service
│   ├── app/
│   │   ├── __init__.py      # app factory, blueprint registration
│   │   ├── config.py        # env-driven settings (endpoints, bucket/table names)
│   │   ├── aws.py           # boto3 session + S3/DynamoDB client factory
│   │   ├── auth.py          # admin login, JWT issue/verify, @admin_required
│   │   ├── routes/
│   │   │   ├── menu.py      # GET /menu, GET /menu/<id>, GET /categories
│   │   │   ├── orders.py    # POST /orders, GET /orders/<id>, PATCH /orders/<id>/status
│   │   │   └── admin.py     # login, menu CRUD, order queue, sales reports
│   │   ├── repositories/    # data access (DynamoDB + S3 calls)
│   │   │   ├── menu.py
│   │   │   ├── orders.py
│   │   │   └── reports.py   # daily/date-range sales aggregation
│   │   ├── pricing.py       # base price + option surcharges → order total
│   │   └── schemas.py       # request/response validation
│   ├── scripts/
│   │   ├── bootstrap.py     # create S3 bucket + DynamoDB tables in Floci
│   │   └── seed.py          # load sample menu (coffee, food, drinks) + photos
│   ├── requirements.txt     # flask, boto3, python-dotenv, marshmallow, pyjwt, passlib[bcrypt]
│   ├── .env.example         # AWS_ENDPOINT_URL, region, table/bucket names
│   └── run.py               # dev entrypoint
└── mobile/                  # Flutter app
    ├── lib/
    │   ├── main.dart
    │   ├── models/          # MenuItem, OptionGroup, Order, SalesSummary (fromJson/toJson)
    │   ├── services/
    │   │   ├── api_client.dart   # base URL + HTTP calls (attaches admin token)
    │   │   └── auth_store.dart   # holds admin JWT + role, secure storage
    │   ├── screens/
    │   │   ├── customer/    # menu, item detail (customize), cart, checkout, order status
    │   │   └── admin/       # login, dashboard (daily sales), orders queue, menu editor
    │   └── state/           # cart / app / auth state (Provider or Riverpod)
    └── pubspec.yaml         # http, provider/riverpod, cached_network_image, flutter_secure_storage, fl_chart
```

---

## 3. Backend + Floci integration

### 3.1 Local cloud startup
Run once per session before starting Flask:

```bash
floci start                 # boots the local S3 + DynamoDB emulators
eval $(floci env)           # exports AWS_ENDPOINT_URL / credentials into your shell
```

`eval $(floci env)` sets env vars (endpoint URL, dummy AWS keys, region) that `boto3` reads automatically. Flask inherits the shell environment, so no endpoint URLs are hard-coded.

### 3.2 boto3 client factory (`backend/app/aws.py`)

```python
import os, boto3

def _endpoint():
    # Floci sets this via `eval $(floci env)`; unset in production = real AWS
    return os.getenv("AWS_ENDPOINT_URL") or None

def dynamodb():
    return boto3.resource("dynamodb", endpoint_url=_endpoint(),
                          region_name=os.getenv("AWS_REGION", "us-east-1"))

def s3():
    return boto3.client("s3", endpoint_url=_endpoint(),
                        region_name=os.getenv("AWS_REGION", "us-east-1"))
```

### 3.3 Data model (cafe-specific)

**DynamoDB — `menu_items` table**
- Partition key: `id` (string)
- Attributes:
  - `name`, `description`, `category` (`coffee` / `tea` / `food` / `cold_drinks` / `pastries`)
  - `base_price` (number)
  - `image_key` (S3 object key)
  - `available` (bool — barista can flip an item off when sold out)
  - `options` — list of option groups, e.g.
    ```json
    [
      {"group":"Size","required":true,"choices":[
        {"label":"Small","price_delta":0},
        {"label":"Regular","price_delta":50},
        {"label":"Large","price_delta":90}]},
      {"group":"Milk","required":false,"choices":[
        {"label":"Whole","price_delta":0},
        {"label":"Oat","price_delta":40},
        {"label":"Almond","price_delta":40}]},
      {"group":"Extras","required":false,"multi":true,"choices":[
        {"label":"Extra shot","price_delta":50},
        {"label":"Vanilla syrup","price_delta":30}]}
    ]
    ```
- Optional secondary index on `category` for fast per-category listing.

**DynamoDB — `orders` table**
- Partition key: `id` (string, generated — also the pickup number shown to the customer)
- Attributes:
  - `items` — list of `{item_id, name, qty, selected_options:[...], line_total}`
  - `total`, `customer` (name + optional phone)
  - `pickup_type` (`counter` / `table` — table number optional)
  - `status` — `received` → `preparing` → `ready` → `collected`
  - `created_at`, `notes` (e.g. "oat milk, extra hot")

**S3 — `cafe-menu-images` bucket** — menu item photos; API returns a (presigned) URL the app loads.

**DynamoDB — `admins` table** (tiny)
- Partition key: `username`
- Attributes: `password_hash` (bcrypt via passlib), `role` (`admin`). Seeded with one owner account.

**Making end-of-day sales fast to query.** Add an `order_date` attribute (`YYYY-MM-DD`) to every order plus a Global Secondary Index on it. The report then does a single indexed query for "all orders on 2026-08-05" instead of scanning the whole table — cheap and correct even as orders grow.

### 3.x Admin auth (`auth.py`)
- `POST /admin/login` checks username + bcrypt password against the `admins` table and returns a short-lived **JWT** (PyJWT).
- `@admin_required` decorator verifies the `Authorization: Bearer <token>` header on every admin route. Customer endpoints stay open (anonymous pickup).
- The Flutter app stores the token in `flutter_secure_storage` and attaches it to admin calls; presence of a valid admin token is what routes the app into the admin experience.

### 3.y Sales reporting (`repositories/reports.py`)
- **End-of-day total:** query the `order_date` GSI for today, sum `total` across orders that were `collected`/`ready` (exclude cancelled). Return `{date, order_count, gross_sales, by_category, by_payment, top_items}`.
- **Date range:** same query per day for a from/to range → daily series for a chart.
- Amounts are the server-computed order totals, so reports always reconcile with what customers were charged.

### 3.4 Pricing rule (`pricing.py`)
Order total is computed **server-side**: `base_price + sum(price_delta of selected options)` per line × qty. The client's total is never trusted — the server recalculates from current menu prices at order time and rejects unavailable items.

### 3.5 Bootstrap + seed
- `bootstrap.py` (idempotent): create `cafe-menu-images` bucket, `menu_items` + `orders` (with `order_date` GSI) + `admins` tables if missing.
- `seed.py`: insert a sample menu — e.g. Espresso, Latte, Cappuccino, Cold Brew, Chai, Croissant, Avocado Toast, Blueberry Muffin — each with options and a photo uploaded to S3; also seed one **admin owner account** (username + bcrypt hash) and a few sample orders so the sales dashboard has data on first run.

### 3.6 API endpoints (contract the app depends on)

| Method | Path                      | Purpose                        | Returns |
|--------|---------------------------|--------------------------------|---------|
| GET    | `/health`                 | liveness check                 | `{status:"ok"}` |
| GET    | `/categories`             | menu categories                | `[string]` |
| GET    | `/menu`                   | full menu (optional `?category=`) | `[MenuItem]` |
| GET    | `/menu/<id>`              | one item with options          | `MenuItem` |
| POST   | `/orders`                 | place a pickup order           | `Order` (with `id`/pickup no., `status`) |
| GET    | `/orders/<id>`            | order + live status            | `Order` |
| PATCH  | `/orders/<id>/status`     | barista updates status         | `Order` |

**Admin-only (require `Authorization: Bearer <jwt>`)**

| Method | Path                              | Purpose                              | Returns |
|--------|-----------------------------------|--------------------------------------|---------|
| POST   | `/admin/login`                    | log in, get token                    | `{token, role}` |
| GET    | `/admin/orders?status=&date=`     | order queue / history                | `[Order]` |
| GET    | `/admin/reports/daily?date=YYYY-MM-DD` | **end-of-day total sales**      | `SalesSummary` |
| GET    | `/admin/reports/range?from=&to=`  | sales over a date range (chart)      | `[SalesSummary]` |
| POST   | `/admin/menu`                     | add a menu item                      | `MenuItem` |
| PUT    | `/admin/menu/<id>`                | edit item / price / options          | `MenuItem` |
| PATCH  | `/admin/menu/<id>/availability`   | mark sold-out / back in stock        | `MenuItem` |
| POST   | `/admin/menu/<id>/image`          | upload item photo to S3              | `{image_url}` |

`MenuItem = {id, name, description, category, base_price, image_url, available, options:[OptionGroup]}`
`Order = {id, items:[...], total, customer, pickup_type, status, created_at, order_date, notes}`
`SalesSummary = {date, order_count, gross_sales, by_category:{...}, by_payment:{...}, top_items:[{name, qty, revenue}]}`

---

## 4. Flutter app (customer)

- **Menu screen** — items grouped by category (tabs or sections), photos via `cached_network_image`, sold-out items greyed out.
- **Item detail / customize** — pick size, milk, extras; live price updates as options change; add to cart.
- **Cart** — local state (Provider or Riverpod), edit qty/options, running total, order notes.
- **Checkout** — name + optional phone, pickup type (counter/table), `POST /orders`.
- **Order status** — shows the pickup number and live status (`received → preparing → ready → collected`) via `GET /orders/<id>`, refreshed on pull-to-refresh or a short poll.

`api_client.dart` holds one base URL (`http://10.0.2.2:9999` for Android emulator, `http://localhost:9999` for iOS sim) so switching environments is a one-line change.

## 4b. Flutter admin (same app, admin login)

A **root gate** on app launch: if a valid admin token exists → admin experience; otherwise → customer experience. An "Staff login" entry (e.g. long-press the logo, or a menu item) opens the admin login screen.

- **Admin login** — username + password → `POST /admin/login`, token saved to `flutter_secure_storage`.
- **Dashboard (end-of-day sales)** — the headline screen. Calls `GET /admin/reports/daily?date=today` and shows:
  - big **Total sales today** number + order count,
  - a `fl_chart` bar/line of the last 7 days (`/admin/reports/range`),
  - breakdown by category and top-selling items,
  - a date picker to view any past day, and an **End of day** button that shows the final day total to reconcile the till.
- **Orders queue** — live list from `GET /admin/orders`, tap to advance status (`received → preparing → ready → collected`) via the existing `PATCH /orders/<id>/status`.
- **Menu editor** — add/edit items, set price and options, toggle sold-out (`/admin/menu/*`), and upload a photo (`/admin/menu/<id>/image`).

Because it shares the customer app's models and `api_client`, there's a single build to ship and maintain.

---

## 5. Phased roadmap

**Phase 0 — Foundation (day 1)**
Scaffold `backend/` and `mobile/`. Confirm `floci start && eval $(floci env)` works and `boto3` can list buckets against Floci.

**Phase 1 — Menu backend (days 2–3)**
App factory, `aws.py`, bootstrap + seed, `/categories` and `/menu` endpoints with options. Verify with `curl`.

**Phase 2 — Orders + pricing (day 4)**
`/orders` create/get, server-side pricing from selected options, availability checks, status field.

**Phase 3 — Flutter menu (days 5–6)**
Models, API client, menu screen by category, item-detail customization with live pricing.

**Phase 4 — Cart + checkout + status (days 7–8)**
Cart state, checkout, order confirmation with pickup number, order-status screen.

**Phase 5 — Admin backend (days 9–10)**
`admins` table + seed owner account, `auth.py` (login/JWT/`@admin_required`), `order_date` GSI, `reports.py` daily + range aggregation, admin menu CRUD and image upload endpoints. Verify totals with `curl` against seeded orders.

**Phase 6 — Flutter admin (days 11–12)**
Root role gate, admin login, **end-of-day sales dashboard** with `fl_chart`, orders queue, menu editor.

**Phase 7 — Polish & verify (day 13)**
Loading/empty/error states, sold-out handling, presigned image URLs, token expiry handling. End-to-end test: launch Floci → seed → run Flask → place several custom orders across the day → open admin → confirm the **daily total** matches the sum of those orders in DynamoDB.

---

## 6. Daily dev workflow (the "easy to manage" loop)

```bash
# Terminal 1 — local cloud
floci start
eval $(floci env)
python backend/scripts/bootstrap.py     # first run only / after reset
python backend/scripts/seed.py          # first run only

# Terminal 2 — backend
cd backend && flask --app run run --debug

# Terminal 3 — app
cd mobile && flutter run
```

One command brings the cloud up, one the API, one the app. Storage lives in Floci and config comes from env vars, so there's nothing to reconfigure between machines, and moving to real AWS later just means pointing at real endpoints.

---

## 7. Open decisions for later
- **Accounts:** v1 is anonymous pickup (name + phone). Add login + saved favorites/reorder when needed.
- **Payments:** v1 = pay at counter (order is intent). Add Stripe/UPI/card gateway in a later phase.
- **Barista workflow:** start with the `PATCH /status` endpoint + manual calls; build the barista screen once the customer flow is solid.
- **Loyalty / promos:** stamp cards, discounts — future phase.
- **Production hosting:** ECS/Fargate, Lambda, or a simple VM — decide once the API stabilizes.
