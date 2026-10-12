# Cafe Backend (Flask + Floci)

Flask API for the cafe app. Uses `boto3` against **Floci** (local AWS emulator)
for DynamoDB (menu, orders, admins) and S3 (menu photos). The same code runs on
real AWS by leaving `AWS_ENDPOINT_URL` unset.

## Setup

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # tweak JWT_SECRET etc. if you like
```

## Run (with Floci)

```bash
# 1. start the local cloud and export its endpoint/creds
floci start
eval $(floci env)

# 2. create tables + bucket, then seed sample data
python scripts/bootstrap.py
python scripts/seed.py       # prints the admin login (default owner / cafe123)

# 3. run the API
flask --app run run --debug  # http://localhost:9999
```

## Run with Docker (whole stack)

From the **repo root** — brings up Floci + the API, creates resources and
seeds sample data on first boot:

```bash
cp .env.example .env            # optional; defaults work without it
docker compose up -d --build
curl localhost:9999/health
docker compose logs -f backend  # first boot prints the seed logins
```

- Data persists across `compose down/up` in the `floci-data` volume;
  `docker compose down -v` wipes it and the next boot re-seeds.
- Ollama stays on the host as before; the container reaches it at
  `host.docker.internal:11434` (host-gateway).
- Public demo URL: `docker compose --profile tunnel up -d tunnel`, then run the
  app with `--dart-define=API_BASE_URL=https://<the-url-from-the-logs>`
  (see `mobile/lib/config.dart`). Stable URL: named-tunnel token in `.env`,
  profile `tunnel-token`.
- Don't also run `floci start` while the stack is up — both want port 4566.

## Roles

This is a **point-of-sale** backend with two roles:

- **owner** — full access: sales reports, staff approval, table + menu management.
- **staff** — day-to-day: view tables/menu, take orders, advance/free orders.

Staff **self-register** (`POST /auth/register`) and stay `pending` until the
owner approves them. Seeded logins: `owner` / `cafe123`, `priya` / `staff123`
(approved), `sam` / `staff123` (pending, to demo approval).

## Endpoints

Open: `GET /health`, `GET /menu[?category=]`, `GET /menu/<id>`, `GET /categories`,
`POST /auth/login`, `POST /auth/register`.

Staff or owner (`Authorization: Bearer <token>`): `GET /tables`,
`POST /tables/<n>/free`, `POST /orders`, `GET /orders`, `GET /orders/<id>`,
`PATCH /orders/<id>/status`.

Owner only: `GET /admin/reports/daily?date=`, `GET /admin/reports/range?from=&to=`,
`GET /admin/staff`, `POST /admin/staff`, `POST /admin/staff/<user>/approve`,
`DELETE /admin/staff/<user>`, `POST /admin/tables`, `DELETE /admin/tables/<n>`,
`POST /admin/menu`, `PUT /admin/menu/<id>`, `PATCH /admin/menu/<id>/availability`,
`DELETE /admin/menu/<id>`, `POST /admin/menu/<id>/image`.

**Tables**: 10 are created on first boot. A table becomes `occupied` when an order
is placed for it and frees automatically when that order is `collected` (or via
`POST /tables/<n>/free`).

Money is stored as integers in minor units (paise/cents). Order totals are always
recomputed server-side from current menu prices — the client total is never trusted.

## Tests

```bash
python tests/smoke_offline.py   # full POS flow, in-memory AWS stub, no network
python tests/smoke_test.py      # same flow against moto (needs: pip install moto)
```

`smoke_offline.py` verifies this build: owner login, staff register→approve→login,
role guards, 10 tables, order → table 5 occupied → collected → table freed,
menu add/delete, table add/remove, and end-of-day sales (4 orders → 2700).
