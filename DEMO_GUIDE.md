# 🚀 End-to-End Demo: Staff Order → Owner Billing

This guide demonstrates the complete workflow: **staff takes a table order → owner sees it with billing details**.

---

## Setup (Terminal 1)

```bash
cd /home/ravi/Desktop/project/Mobile-app-shop
source backend/.venv/bin/activate
eval $(floci env)
python backend/scripts/bootstrap.py
python backend/scripts/seed.py
```

Expected output:
```
Infrastructure ready:
  DynamoDB tables : menu_items, orders, staff, cafe_tables
  Orders GSI      : order_date-index
  Default tables  : 10
  S3 bucket       : cafe-menu-images
Seed complete:
  Menu items seeded
  Owner login     : owner / cafe123
  Staff login     : priya / staff123  (approved)
```

---

## Start Backend (Terminal 1 - continued)

```bash
flask --app app run --debug --host 0.0.0.0
```

Expected output:
```
 * Running on http://127.0.0.1:9999
 * Debug mode: on
```

---

## Start Flutter App (Terminal 2)

```bash
cd mobile
flutter run
```

The app opens to a **login screen**.

---

## 📱 Demo Workflow

### Step 1: Staff Login

**On mobile app:**
- Username: `priya`
- Password: `staff123`
- Tap "Login"

**You see:** Staff dashboard with two tabs: **Tables** (grid) and **Orders** (queue)

---

### Step 2: Staff Takes Order on Table 1

1. **Tables tab** → Tap on an empty table (e.g., **Table 1** - green card)
2. You're now in **"Table 1 • New order"**
3. **Browse menu** by category:
   - Tap on **"Coffee"** section
   - Choose **Espresso**
   - Select: Size=Regular, Milk=Whole, Extras=Extra shot
   - Tap "Add to cart"
4. Repeat: Add **Latte** with size=Large
5. Tap **"Review • 2 item(s) • ₹XXX"** button at the bottom
6. **Optional:** Add notes like "extra hot"
7. Tap **"Place order for Table 1"**

**Success:** Popup shows "Order #ABC placed for Table 1"

**Result in backend:**
- Table 1 is now marked **occupied**
- Order stored in DynamoDB with `table_number: "1"` and `customer: {name: "Table 1"}`

---

### Step 3: Check Order Queue (Staff View)

1. Tap **Orders tab** on staff screen
2. You see the new order:
   - Order #ABC · Status: **received** · ₹XXX
   - Customer: Table 1
   - 1× Espresso (Regular · Whole · Extra shot)
   - 1× Latte (Large)

---

### Step 4: Owner Logs In

**On mobile app (log out staff first):**
1. Tap the **logout button** (top-right user icon)
2. Login as owner:
   - Username: `owner`
   - Password: `cafe123`

**You see:** Owner dashboard with 6 tabs: **Sales, Billing, Orders, Tables, Staff, Menu**

---

### Step 4b: Table Locking (multi-staff)

1. Log in as a second staff member (e.g. another approved account)
2. **Tables tab** → find the table the first staff took (red card)
3. It shows **"Served by priya"** on the card
4. Tap it → you see the order details but **no advance / free buttons** — just a **"Locked"** notice
5. As `priya` (or the owner), the same table shows **Start preparing / Mark ready / Mark collected / Free table**

---

### Step 5: Owner Views Orders with Billing

1. Tap **Orders tab**
2. **Top section shows:**
   - ✅ **Total Sales**: ₹XXX (sum of collected orders)
   - ✅ **Active Orders**: 1

3. **Scroll down to see the order card:**
   ```
   Order #ABC    [received]    [Table 1]    ₹XXX
   ───────────────────────────────────────────
   Customer: Table 1
   
   1× Espresso
     Regular · Whole · Extra shot
                                   ₹XXX
   
   1× Latte
     Large
                                   ₹XXX
   ───────────────────────────────────────────
   Total:                          ₹XXX
   
   [Start preparing] button
   ```

✅ **Features visible:**
- Table number (orange chip)
- Customer name (from table)
- Line-by-line items with options
- Individual line totals
- Order total
- Status workflow button

---

### Step 6: Advance Order Status & Collect Payment

1. On the order card, tap **"Start preparing"**
   - Status changes: **received** → **preparing**
2. Tap **"Mark ready"**
   - Status changes: **preparing** → **ready**
3. Tap **"Collect & take payment"**
   - A **"Collect order"** dialog appears:
     ```
     Collect order
     Order #ABC
     Amount to collect: ₹XXX
     Payment method: [GPay] [Cash] [Card] [UPI]
     [Cancel]            [Confirm & collect]
     ```
   - Choose **GPay** to run a Google Pay charge (opens the Google Pay sheet on
     an Android device — TEST mode by default, no real money). Cash/Card/UPI
     are recorded manually.
   - Confirm and tap **"Confirm & collect"**
   - Status changes: **ready** → **collected**

**An order can't be completed without payment** — if you try to mark it
collected without confirming payment, the backend rejects it.

**Result:**
- Table 1 automatically marked **empty** (freed)
- Order moves to **Total Sales** (collected orders)
- Order appears in the **Billing** tab as **PAID**

---

### Step 6b: Owner Views Billing

1. Tap the **Billing tab**
2. **Top cards show:** Total due / Paid / Unpaid
3. Collected orders are grouped by date, each showing:
   - Order #, customer, table, payment method (Cash/Card/UPI)
   - Serving staff · payment status chip
4. Orders collected going forward are already **PAID**. Any older unpaid
   orders still show **UNPAID** — tap **"Mark as paid"** to confirm them

---

### Step 6c: Customer Wants to Add More Items

1. In the **Orders tab**, turn off **"Active orders only"** to see collected orders
2. On the completed order, tap **"Reopen & add items"**
   - Confirm: the order goes back to active, the table is locked again, and the
     already-paid amount stays as **credit**
3. **"Add items"** screen opens (Order #ABC • Add items) — browse the menu and
   add the new item(s)
4. Tap **Review** → **"Add items to Order #ABC"**
   - The order total grows; only the new amount is unpaid
5. Advance the order again and tap **"Mark collected"**
   - The collect dialog shows the **remaining amount** to collect (total − already paid)
6. Confirm payment → the order is collected and fully paid again

**Example:** a ₹370 order was paid and collected. The customer adds a ₹260
muffin → reopen, add item, re-collect **₹260** (not the full ₹630).

---

### Step 7: Staff Order History

Each staff member has their own **History** tab (third tab on the staff screen).

1. Tap **History**
2. **Top stats** for this staff member only:
   - Orders taken · Revenue · Active now
3. **Filter chips**: All / Active / Completed
4. Every order this staff member took is listed with:
   - Order #, status chip, customer, table, time, item count, total

Log in as a different staff member (e.g. `sam` after the owner approves them)
and their History shows only *their* orders.

---

## 🔄 Repeat for Multiple Orders

Try placing orders on different tables:
- Staff logs in → Table 2 → Chai + Croissant
- Staff logs in → Table 5 → Cappuccino
- Owner views all orders grouped with table info
- Owner sees total sales growing

---

## ✅ Checklist

During the demo, verify:

- [ ] Staff can select an empty table
- [ ] Table turns red (occupied) right after order placed
- [ ] Occupied tables show which staff is serving them
- [ ] Another staff sees a locked table (no advance/free)
- [ ] Order shows in owner's Orders tab with table number
- [ ] Owner sees table number in orange chip
- [ ] Owner sees customer name as "Table X"
- [ ] Line items show quantities and options
- [ ] Total sales updates when order is collected
- [ ] Owner can advance order status
- [ ] Collecting an order prompts for payment confirmation
- [ ] Table frees up (turns green) when order is collected
- [ ] Collected order appears in Billing tab as paid
- [ ] A collected order can be reopened to add more items
- [ ] Reopen keeps already-paid amount as credit (only the difference is re-collected)
- [ ] GPay option appears in the collect dialog and shows billing refs (Android)
- [ ] Staff History tab shows only that staff member's orders and revenue

---

## 🐛 Troubleshooting

**"Cannot reach the server" error?**
- Ensure Flask is running: `python backend/scripts/bootstrap.py` must complete first
- Check: `curl http://localhost:9999/health`

**Orders not showing table number?**
- Verify Flutter app is using the latest code
- Check in browser DevTools: `curl http://localhost:9999/orders` should show `table_number` field

**Table not getting occupied?**
- Backend: Check `orders_repo.create()` calls `tables_repo.occupy()`
- Frontend: Verify `OrderCartScreen` is passing `tableNumber: widget.tableNumber`

---

## 📊 API Endpoints Used in Demo

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/auth/login` | Staff/Owner login |
| GET | `/tables` | Staff sees all tables (includes `taken_by`) |
| POST | `/orders` | Place order (with `table_number`, `payment_method`) |
| POST | `/tables/<n>/free` | Free a table (blocked if locked by another staff) |
| GET | `/orders?taken_by=priya` | Orders taken by one staff member (their history) |
| PATCH | `/orders/<id>/status` | Advance status (collect requires `paid: true`, stores `payment_token`) |
| POST | `/orders/<id>/reopen` | Reopen a collected order to add more items |
| POST | `/orders/<id>/items` | Append items to an open order |
| GET | `/admin/billing` | Owner billing (collected orders grouped by date) |
| POST | `/admin/billing/<id>/paid` | Owner confirms payment |

**Order object includes:**
```json
{
  "id": "ABC123",
  "customer": {"name": "Table 1", "phone": null},
  "table_number": "1",
  "items": [...],
  "total": 2500,
  "status": "received",
  "payment_method": "cash",
  "payment_status": "unpaid",
  "taken_by": "priya",
  "created_at": "2026-08-07T12:00:00"
}
```

---

## Next Steps

- Go live for Google Pay: set `GOOGLE_PAY_ENV=PRODUCTION` with your real
  merchant id, gateway and business name via `--dart-define`
- Decrypt/verify Google Pay tokens server-side with a payment processor (Stripe)
- Barista display screen
- Mobile ordering (counter/takeaway flow)
- Receipt printing / PDF export per billing day
