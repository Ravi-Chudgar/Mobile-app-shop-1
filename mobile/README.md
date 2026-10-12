# Cafe POS — Flutter app

The single Flutter codebase for the whole cafe: counter staff, kitchen, owner,
CA, and customers ordering from a table QR. It talks only to the Flask backend
in [`../backend`](../backend/README.md) over HTTPS/JSON with a JWT per role.

Material 3, coffee-brown brand (`#6F4E37`), assets in `assets/images/`
(`logo.png` is the source for all launcher/splash icons).

## Roles

| Role (JWT) | Shell | What they do |
|------------|-------|--------------|
| `owner` | `OwnerShell` | Bottom tabs **Sales · Orders · Tables · Billing · Vendors**, plus **More**: Reports (incl. day-end Z-report), Growth (loyalty, delivery orders, table QRs), Exports (Tally XML/CSV, GSTR-1/3B), **Printers**, Staff, Menu, Inventory |
| `staff` | `StaffShell` | **Tables** (take orders, table locking), **Orders** (shared live queue), **History** (own sales) |
| `kitchen` | `KitchenShell` | Kitchen display: **Active** and **Ready** views, advance order status, print KOT |
| `cafe_ca` | `CaShell` | Read-only chartered-accountant login: **Daily**, **Z-Report**, **Exports** (all non-GETs are rejected server-side) |
| customer (no login) | `screens/customer/` | QR self-order: public menu → cart → checkout → order tracking; orders land in the staff queue with `source: qr` |

Seeded logins (first backend boot): `owner` / `cafe123`,
`priya` / `staff123` (approved staff), `sam` / `staff123` (pending, to demo
approval). Kitchen and CA accounts are created by the owner from the Staff
screen. New staff self-register on the login screen and stay `pending` until
approved.

## Multi-cafe (tenants) & per-cafe branding

One backend can host several businesses (cafes, hostels); the app scopes
itself to one of them via a **cafe code**:

- **Login** — optional *Cafe code* field under the password (blank = the
  server's default tenant, `DEFAULT_TENANT`, `main` out of the box). It is
  sent as `tenant` to `POST /auth/login`, echoed back in the response and
  stored with the session, and lands inside the JWT — so every later
  staff/owner/kitchen/CA call is tenant-scoped automatically.
- **Branding** — `state/tenant_state.dart` loads
  `GET /public/<slug>/config` (`{display_name, kind, bill_footer}`) after
  login and on a cold start. `ShellAppBar` prefixes the date with the cafe
  name ("Bean House Cafe · Sat, 10 Oct"); the customer menu greets with the
  scanned cafe's name. Failures are silent — the UI falls back to its
  generic copy.
- **Table QRs** — the owner's Growth → *Table QRs* tab fetches
  `/public/<slug>/qr/<n>` for the signed-in cafe, so the printed link is
  `{base}/t/<slug>/table/<n>` (legacy cards stay `{base}/table/<n>`), and
  **Preview** opens the menu in that same cafe.
- **Web deep link** — `RootGate` parses `Uri.base` on web:
  `/t/<slug>/table/<n>` (or the legacy `/table/<n>`) opens
  `CustomerMenuScreen` straight away, no login needed, with all public
  calls (`menu`, `orders`, `orders/<id>`) hitting the scoped endpoints.
- **Gap**: native Android/iOS deep links are *not* wired up (that needs an
  intent-filter/Universal-Link plugin); on a phone the QR must be opened in
  a browser, which then serves the same web app.

## Screen map

```
auth/       login, register (staff request)
owner/      owner shell, billing, bill, reports, growth (loyalty/QR/delivery),
            exports, printer settings, staff mgmt, tables admin, vendor message
staff/      staff shell, tables grid, customer info, take order, order cart,
            order detail, staff orders queue, staff history, "Ask" panel
kitchen/    kitchen shell + display (active/ready)
ca/         CA shell: daily, z-report, exports
admin/      shared owner tabs: dashboard (charts), orders queue, menu editor,
            inventory
customer/   QR self-order: menu, item sheet, cart, checkout, order status,
            order lookup
```

## Setup

Prerequisites: Flutter 3.10+ (`flutter --version`) and the backend running —
quickest is `docker compose up -d --build` from the repo root (see the root
README), or the Floci + venv setup in `../backend/README.md`.

```bash
cd mobile
flutter pub get
flutter run                            # Android emulator -> http://10.0.2.2:9999
flutter run -d chrome                  # web build
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:9999   # physical device
```

`lib/config.dart` picks the base URL: the Android emulator maps the host to
`10.0.2.2`; web/desktop/iOS-simulator default to the hosted demo API, so pass
`API_BASE_URL` for anything else (LAN IP for a phone, or your
`docker compose --profile tunnel` URL).

### Build-time flags (`--dart-define`)

| Flag | Default | Purpose |
|------|---------|---------|
| `API_BASE_URL` | emulator → `http://10.0.2.2:9999`, else hosted demo URL | Backend base URL |
| `GOOGLE_PAY_ENV` | `TEST` | Google Pay environment (test mode = no real money) |
| `GOOGLE_PAY_MERCHANT_ID` | empty | Production merchant id |
| `GOOGLE_PAY_GATEWAY` | `example` | Payment gateway name (e.g. `stripe/`) |
| `GOOGLE_PAY_GATEWAY_MERCHANT_ID` | `exampleGatewayMerchant` | Gateway account |
| `GOOGLE_PAY_MERCHANT_NAME` | `Cafe POS` | Business name on the pay sheet |

Google Pay needs Android with Play services; other devices fall back to manual
payment recording (Cash/Card/UPI) automatically.

## Printing

Any ESC/POS thermal printer is configured from the app:
**owner → More → Printers**. Modes:

- **Network** (WiFi/LAN) — direct socket from Android, backend relay on web
- **USB-OTG** — via `usb_serial` (Android)
- **Bluetooth** — via `print_bluetooth_thermal` (pair in system settings first)

The app fetches raw ESC/POS bytes from the backend
(`GET /printing/{receipt,kot,test}/bytes`) and sends them over the chosen
transport; a **Test print** button validates the setup. Print buttons on the
bill, staff and kitchen screens share the same service and never crash the POS
(snackbar feedback instead). Auto-KOT on order create is backend-side
(`ESCPOS_PRINTER_HOST`, `AUTO_PRINT_KOT=1` in docker-compose).

## Offline behavior

Offline-first by design (Indian 4G reality):

- Mutations go into a durable FIFO queue (SharedPreferences) with a
  connectivity monitor triggering flush; ops are idempotent server-side via
  `client_op_id`.
- Offline banner + pending-count in the app bar (`ShellAppBar`).
- Staff orders and QR checkouts are placed offline and reconciled (temp ids →
  server ids) on reconnect; payment collection stays online-only.
- The menu is cached locally so browsing keeps working; `GET /sync/pull?since=`
  refreshes orders/menu/tables/inventory deltas.

## Project structure

```
lib/
├── config.dart              # API base URL, currency, Google Pay dart-defines
├── main.dart                # Material 3 theme + RootGate (role → shell routing)
├── models/                  # MenuItem, Cart, Order, CafeTable, Billing,
│                            # InventoryItem, StaffMember, SalesSummary, ...
├── state/                   # AuthState (secure token storage + cafe code),
│                            # CartState, TenantState (per-cafe branding)
├── services/
│   ├── api_client.dart      # typed REST client for every endpoint
│   ├── offline/             # offline_queue, connectivity_monitor, menu_cache
│   ├── printer_*.dart       # transports (network/USB/Bluetooth) + settings/models
│   ├── printing_service.dart
│   ├── payment_service.dart # Google Pay wrapper
│   └── notification_service.dart
├── screens/                 # auth/ owner/ staff/ kitchen/ ca/ admin/ customer/
└── widgets/                 # collect payment flow, menu picker, ui_kit, ...
```

Money is handled in minor units (paise) end-to-end and formatted for display;
order totals at checkout are recomputed and confirmed by the server.

## Tests

```bash
flutter analyze     # lint + type checks (kept at 0 issues)
flutter test        # widget, layout and offline-queue tests + golden screenshots
```

Golden tests compare against PNGs in `test/goldens/`; after a UI change refresh
them with `flutter test --update-goldens` (currently the three goldens in
`test/generate_demo_shots_test.dart` — login, owner dashboard, staff management —
need a refresh).

Platform build notes: `iOS_SETUP.md` (signing) and `IOS_CI_SETUP.md` (unsigned
CI IPA via `.github/workflows/build-ios*.yml`).
