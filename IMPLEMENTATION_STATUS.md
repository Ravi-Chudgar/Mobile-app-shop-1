# 🎯 Multi-Staff POS System Implementation Summary

## 🆕 Startup-Plan Phases (cafe-pos-startup-plan.md) — IMPLEMENTED (Oct 2026)

Four parallel-built phases on top of the earlier multi-staff POS work. Backend
suites: `smoke_offline`, `test_phase1_billing`, `test_phase2_ops`,
`test_phase3_growth`, `test_phase4_tally`, `test_sync`, `test_ask_offline`,
`test_recommendations_offline` — all passing. `flutter analyze` = 0 errors.

### Phase 1 — Billing engine ✅
- GST: menu `gst_rate`/`hsn_code`, tax-inclusive pricing, per-line
  `taxable_value/cgst/sgst`, order `sub_total`/`tax_total` (legacy orders = 0)
- Split payments: `payments: [{method, amount, ref?}]` (cash/upi/card/gpay/
  credit/other/loyalty), exact-sum validation, split UI in collect dialog
- Thermal ESC/POS: `app/services/printing.py` + `POST /printing/receipt|kot/<id>`
  (dry-run when `ESCPOS_PRINTER_HOST` unset); Print button on bill screen
- WhatsApp bill: `GET /orders/<id>/bill` (server-rendered GST text + wa.me link)
- Day-end Z-report: `GET /admin/reports/z` (tax breakup, by payment, cash
  expected, top items); P&L fixes (real month length, margin = net/revenue)

### Phase 2 — Cafe ops ✅
- KOT: auto-print on order create (`AUTO_PRINT_KOT=1` + printer host), manual
  Print KOT buttons on staff queue + kitchen display
- Low-stock alerts: `reorder_level` per inventory item (0 = off),
  `GET /admin/inventory/alerts`, badges + banner in inventory screen
- Floor map: table layout (`zone/x/y/w/h/shape`), owner drag editor
  (`PUT /admin/tables/<n>/layout`), staff Grid/Floor toggle

### Phase 3 — Growth hooks ✅
- QR table ordering: public menu + QR PNG (`/public/qr/<table>`), customer
  self-order flow (revived `screens/customer/*`), status tracking; occupied
  tables accept QR orders without stealing the staff lock
- Loyalty: phone-based points ledger, earn on collect, redeem as a `loyalty`
  payment row at collect (owner Growth tab + redeem UI)
- Swiggy/Zomato: `POST /integrations/{swiggy,zomato}/orders` adapter with
  `X-Integration-Key` auth, `source` on orders, Delivery section
- Staff sales report: `GET /admin/reports/staff` + Staff tab on owner reports

### Phase 4 — Accounting bridge ✅
- Tally Prime Import-Data XML (stable GUIDs, Sales/CGST/SGST/party ledgers) +
  CSV: `GET /export/tally?from&to&format=`
- GSTR-1 (B2C + HSN + rate summary) and GSTR-3B 4.1(a): `GET /export/gstr1|
  gstr3b?period=YYYY-MM&format=json|csv` (B2B skipped — no customer GSTIN)
- CA read-only login: `cafe_ca` role, global read-only guard + per-route
  allow-list; owner creates CAs via `POST /admin/staff`; mobile `CaShell`
  (Daily / Z-Report / Exports); owner Exports entry

### Universal thermal-printer configuration ✅
- Any ESC/POS printer (Epson, Xprinter, TVS, Bixolon, generic 58/80mm) is
  configurable from the app: owner → More → **Printers**
- Modes: **Network** (WiFi/LAN — direct socket from Android, backend relay
  `/printing/send` on web/fallback), **USB-OTG** (`usb_serial`, Android),
  **Bluetooth** (`print_bluetooth_thermal`, Android; pair in system settings)
- App fetches raw ESC/POS bytes (`GET /printing/{receipt,kot,test}/bytes`) and
  sends via the chosen transport; Test-print button in settings; print buttons
  in bill/staff/kitchen screens use the same service (snackbar feedback, never
  crashes). Web degrades gracefully (network only, via backend relay).
- Auto-KOT on order create still uses backend env (`ESCPOS_PRINTER_HOST`,
  `AUTO_PRINT_KOT=1` in docker-compose).

### Offline-first sync ✅
- Backend: `POST /sync/batch` (idempotent ops via `client_op_id`, per-op
  errors), `GET /sync/pull?since=` (delta orders + menu/tables/inventory)
- Mobile: durable FIFO queue (SharedPreferences), connectivity monitor,
  offline banner + pending count in `ShellAppBar`, staff cart & QR checkout
  queue orders offline and reconcile temp ids on reconnect; collect/payment
  stays online-only

### Still open
Razorpay (payments = bookkeeping + GPay test mode), real WhatsApp Business API,
real Swiggy/Zomato credentials, nightly Tally sync scheduler, Gujarati/Hindi
i18n, native QR deep-link handler, offline-hardened web PWA, GTM/validation.

---

## ✅ Completed Phases

### Phase 1: Customer Name Input ✅
**Files Created/Modified:**
- ✅ `customer_info_screen.dart` - New screen to capture customer name & phone
- ✅ `cart_state.dart` - Added `customerName` and `customerPhone` storage
- ✅ `tables_grid_screen.dart` - Updated to navigate to customer info first

**Workflow:**
```
Staff selects table → CustomerInfoScreen (asks name & phone) → TakeOrderScreen
```

**Features:**
- Name field (required)
- Phone field (optional)
- Data stored in CartState and passed to order payload
- Customer info persists through order placement

---

### Phase 2: Shared Staff Dashboard ✅
**Files Created:**
- ✅ `staff_orders_screen.dart` - Real-time shared order queue for all staff
- ✅ Updated `staff_shell.dart` - Now uses StaffOrdersScreen instead of OrdersQueueScreen

**Real-Time Features:**
- 📡 Auto-refresh every 3 seconds for live updates
- 📊 Status badges showing: New orders, Preparing, Ready
- 🔄 All staff see the same queue
- ⚡ One-click status advancement (received → preparing → ready)

**Display Includes:**
- Order #, Table #, Customer name
- Items with options
- Notes with visual formatting
- Total amount
- Active/Collected filter

---

### Phase 3: Table Locking ✅
**Files Modified:**
- ✅ `tables_grid_screen.dart` - Real staff identity + lock enforcement
- ✅ `tables.py` (backend) - `taken_by` stored on table, free guarded by lock
- ✅ `orders.py` (backend) - double-occupancy blocked (409)
- ✅ `cafe_table.dart` - `takenBy` field on table model
- ✅ `staff_orders_screen.dart` - shows who served each order

**Features Implemented:**
- Occupied tables show order ID **and the serving staff member**
- Backend stores `taken_by` on the table when an order is placed
- Creating an order on an already-occupied table → **409 rejected** (no double-booking)
- Freeing an occupied table is restricted to the serving staff or the owner → **403 otherwise**
- Staff who didn't take the order see the table as **Locked** (view-only — no advance/free)
- The shared order queue still lets all staff advance status (Phase 2 feature)

---

## 🚀 Phase 4: Billing Workflow ✅

### What Was Built:

#### 1. Owner Billing Summary Screen ✅
**Files:** `billing_screen.dart` [NEW], `owner_shell.dart` [UPDATED]
- New **Billing** tab in the owner dashboard (Sales · Billing · Orders · Tables · Staff · Menu)
- Shows **collected orders grouped by date**
- Summary cards: **Total due / Paid / Unpaid**
- Per-order payment status chips (PAID green / UNPAID orange)
- Payment method + serving staff shown per order
- **"Mark as paid"** button on unpaid orders (owner confirms payment)
- Date filter (pick a day or view all dates)

#### 2. Backend Integration ✅
- `GET /admin/billing` — collected orders grouped by day with paid/unpaid totals
- `POST /admin/billing/<order_id>/paid` — owner confirms payment
- Order becomes `payment_status: "unpaid"` on creation
- Marking an order **collected** stamps `collected_at` and starts payment tracking
- Table auto-frees on collected (already working)

#### 3. Staff Mark as Collected ✅
- **An order can't be completed without payment** — collecting without payment is rejected by the backend (400)
- Tapping **"Mark collected"** opens a **Collect order** dialog (amount + payment method), staff confirms payment → order becomes `collected` + `paid` in one step
- Table immediately freed
- Order appears in the owner's Billing tab as **PAID**
- Staff picks a **payment method** (Cash / Card / UPI) when placing an order (pre-fills the collect dialog)
- Older unpaid collected orders can still be confirmed via the Billing tab's **"Mark as paid"**

#### 4. Reopen & Add Items ✅ (customer wants more)
- Collected orders get a **"Reopen & add items"** button (staff queue + owner Orders tab)
- Reopening puts the order back to active, re-locks the table, and **keeps the already-paid amount as credit** (`paid_amount`)
- **"Add items"** reuses the take-order flow in add-mode → `POST /orders/<id>/items` appends lines and grows the total
- Re-collecting prompts for the **remaining** amount only (total − already paid)
- Orders track `paid_amount`; billing splits paid vs unpaid using it (handles legacy orders without the field)

---

## 📱 Phase 5: Google Pay + Staff History ✅

### Google Pay (payments)
- Google `pay ^3.3` plugin integrated via `PaymentService` (`lib/services/payment_service.dart`)
- **GPay** added as a payment method in the collect dialog (and order cart); choosing it opens the Google Pay sheet on Android
- Runs in Google's **TEST environment** by default (no real money); production is enabled with `--dart-define` flags (merchant id, gateway, business name)
- Graceful fallback: devices without Google Pay / Play services show a message and staff records Cash/Card/UPI as before — the POS never blocks
- The returned `payment_token` is stored on the order and shown as a **GPay ref** in the owner's Billing tab for reconciliation

### Staff order history
- New **History** tab in the staff shell — each staff member sees **only their own** orders
- `GET /orders?taken_by=<username>` backend filter added
- Top stats: orders taken · revenue (completed) · active now
- Filter chips (All / Active / Completed); per-order cards show id, status, customer, table, time, item count, total

---

## 📋 Files Changed/Created

```
✅ lib/screens/staff/customer_info_screen.dart          [NEW]
✅ lib/screens/staff/staff_orders_screen.dart           [UPDATED - served-by, collect requires payment]
✅ lib/screens/staff/tables_grid_screen.dart            [UPDATED - locking, refresh after order]
✅ lib/screens/staff/order_cart_screen.dart             [UPDATED - payment method, add-items mode]
✅ lib/screens/staff/take_order_screen.dart             [UPDATED - add-items mode for reopened orders]
✅ lib/screens/staff/staff_shell.dart                   [UPDATED - History tab]
✅ lib/screens/staff/staff_history_screen.dart          [NEW - per-staff order history]
✅ lib/widgets/collect_payment_dialog.dart              [NEW - collect = confirm payment, GPay option]
✅ lib/widgets/collect_order_flow.dart                  [NEW - unified collect + Google Pay flow]
✅ lib/services/payment_service.dart                    [NEW - Google Pay wrapper]
✅ lib/config.dart                                      [UPDATED - Google Pay dart-defines, INR]
✅ pubspec.yaml                                         [UPDATED - pay ^3.3, intl ^0.20]
✅ lib/screens/admin/orders_queue_screen.dart           [UPDATED - collect requires payment, reopen button]
✅ lib/state/cart_state.dart                            [UPDATED - payment_method, itemsJson, tablesTick]
✅ lib/screens/owner/billing_screen.dart                [NEW - shows GPay refs]
✅ lib/screens/owner/owner_shell.dart                   [UPDATED - Billing tab]
✅ lib/models/order.dart                                [UPDATED - takenBy, payment fields, paidAmount, paymentToken]
✅ lib/models/cafe_table.dart                           [UPDATED - takenBy]
✅ lib/models/billing.dart                              [NEW]
✅ lib/services/api_client.dart                         [UPDATED - billing, reopen, addItems, takenBy filter, token]
✅ lib/screens/owner/tables_admin_screen.dart           [UPDATED]
✅ test/widget_test.dart                                [FIXED - money util test, added flutter_test dep]

UI redesign:
✅ lib/main.dart                                        [UPDATED - modern Material 3 theme: soft surfaces, rounded cards, filled inputs, nav bar, dialogs]
✅ lib/screens/auth/login_screen.dart                   [REDESIGNED - gradient hero, brand mark, glassy form card]
✅ lib/screens/auth/register_screen.dart                [REDESIGNED - matching modern form]
✅ lib/screens/staff/staff_shell.dart                   [UPDATED - user avatar chip in app bar]
✅ lib/screens/owner/owner_shell.dart                   [UPDATED - user avatar chip in app bar]
✅ lib/screens/staff/tables_grid_screen.dart            [UPDATED - soft theme table fills]
✅ lib/screens/owner/tables_admin_screen.dart           [UPDATED - soft theme table fills, banner]
✅ lib/screens/staff/staff_orders_screen.dart           [UPDATED - themed status banner]
✅ lib/screens/staff/staff_history_screen.dart          [UPDATED - themed stats banner]
✅ lib/screens/admin/orders_queue_screen.dart           [UPDATED - themed summary banner]
✅ lib/screens/admin/dashboard_screen.dart               [REDESIGNED³ - live header, hero with animated counter + glass KPI strip + sparkline + delta, best-seller callout, gradient area trend, payments donut, category bars, ranked top sellers]
✅ pubspec.yaml                                         [UPDATED - fl_chart 0.68 → 1.0.0 (fixes chart layout asserts on newer Flutter)]
✅ lib/screens/staff/tables_grid_screen.dart            [FIXED - tile vertical overflow → FittedBox]
✅ lib/screens/owner/tables_admin_screen.dart           [FIXED - tile vertical overflow → FittedBox]
✅ lib/screens/owner/billing_screen.dart                [FIXED - row overflows → flexible/ellipsis]
✅ lib/screens/staff/staff_orders_screen.dart           [FIXED - total + customer overflow → FittedBox]
✅ lib/screens/admin/orders_queue_screen.dart           [FIXED - total overflow → FittedBox]
✅ lib/screens/staff/staff_history_screen.dart          [FIXED - total overflow → FittedBox]
✅ lib/screens/auth/login_screen.dart                   [FIXED - footer row overflow → FittedBox]

Backend:
✅ app/repositories/orders.py                           [UPDATED - payment_status/paid_amount, reopen, add_items, taken_by filter]
✅ app/repositories/tables.py                           [UPDATED - taken_by on occupy/free]
✅ app/repositories/reports.py                          [UPDATED - billing_summary uses paid_amount]
✅ app/routes/admin.py                                  [UPDATED - /admin/billing, /billing/<id>/paid]
✅ app/routes/orders.py                                 [UPDATED - status accepts paid/token, /reopen, /items, taken_by]
✅ app/routes/tables.py                                 [UPDATED - free guarded by table lock]
✅ app/infra.py                                         [UPDATED - seed orders collect with payment]
✅ tests/smoke_offline.py                               [UPDATED - Phase 3 + 4 + reopen + history checks]
✅ tests/e2e_demo.py                                    [UPDATED - billing steps, collect with payment]
```

---

## 🧪 How to Test Current Implementation

### Test Phase 1+2+3:
1. **Flutter rebuild:**
   ```bash
   cd /home/ravi/Desktop/project/Mobile-app-shop/mobile
   flutter clean && flutter pub get && flutter run
   ```

2. **Staff login:**
   - Username: `priya`
   - Password: `staff123`

3. **Test workflow:**
   ```
   ✓ Tables tab → Click empty table
   ✓ Enter customer name: "John"
   ✓ Enter phone: "9876543210"
   ✓ Browse menu & add items
   ✓ Review & place order → table flips to occupied right away
   ✓ See order in "Order Queue" tab (real-time updates)
   ✓ Advance status: received → preparing → ready
   ✓ Mark collected → payment dialog → Confirm & collect
   ✓ Owner Billing tab shows the order as PAID
   ```

4. **Payment-required check:** an order cannot be marked collected without
   confirming payment (backend rejects it with 400).

4. **Multi-staff demo:**
   - Open app twice (or in two browsers)
   - Staff #1: Takes order on Table 1
   - Staff #2: Sees same order in shared queue
   - Both advance status together in real-time

---

## 📊 Current User Flow

```
STAFF                          OWNER
├─ Login                       ├─ Login
├─ Tables tab                  ├─ Tables tab (see occupied tables & staff)
│  ├─ Select empty table       ├─ Click table → View order details
│  ├─ Enter customer name      ├─ See customer name, items, total
│  ├─ Browse menu              │
│  └─ Place order              │
│    (table → occupied)        │
│                              │
├─ Order Queue tab (shared)    ├─ Orders tab
│  ├─ See order appear         │  ├─ View all orders
│  ├─ Real-time updates        │  ├─ See table & customer info
│  ├─ Start preparing          │  ├─ Advance status
│  ├─ Mark ready               │  └─ Collect (requires payment)
│  └─ Mark collected           │
│     (payment dialog)         ├─ Billing tab
│     (table auto-frees)       │  ├─ Collected orders by date
│                              │  ├─ Total / Paid / Unpaid
│                              │  └─ Confirm payment for old unpaid orders
```

---

## ✨ Next Steps (all complete)

1. ✅ **Test current implementation** - Customer name → Shared queue → Real-time
2. ✅ **Create billing screen** for owner showing collected orders
3. ✅ **Add payment status tracking** in backend
4. ✅ **Implement collection confirmation** for staff
5. ✅ **Add revenue dashboard** for owner

### Possible future work
- Google Pay production go-live (merchant id, gateway, token decryption via a processor like Stripe)
- Barista display screen
- Mobile ordering (counter/takeaway flow)
- Receipt printing / PDF export per billing day

---

## 📞 Questions?

- Note: Google Pay only runs on Android with Play services — other platforms
  fall back to manual payment recording automatically.
