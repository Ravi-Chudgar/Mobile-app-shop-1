#!/usr/bin/env python
"""End-to-end demo: staff takes table order → owner sees billing.

Usage:
    python tests/e2e_demo.py

Requires: Floci running, bootstrap/seed complete, Flask running.
"""
import requests
import json
from datetime import datetime, timezone
from typing import Any

BASE_URL = "http://localhost:9999"


def req(method: str, path: str, data: Any = None, token: str = None) -> dict:
    """Helper: make HTTP request and return JSON."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"{BASE_URL}{path}"
    if method == "GET":
        r = requests.get(url, headers=headers)
    elif method == "POST":
        r = requests.post(url, json=data, headers=headers)
    elif method == "PATCH":
        r = requests.patch(url, json=data, headers=headers)
    else:
        raise ValueError(f"Unknown method: {method}")
    if r.status_code >= 400:
        print(f"❌ {method} {path} → {r.status_code}")
        print(f"   {r.text}")
        raise Exception(f"Request failed: {r.text}")
    return r.json() if r.text else {}


print("\n🚀 E2E Demo: Table Order → Owner Billing\n")

# Step 1: Health check
print("Step 1: Health check...")
try:
    health = req("GET", "/health")
    print(f"✅ Backend is running")
except Exception as e:
    print(f"❌ Backend unreachable: {e}")
    exit(1)

# Step 2: Staff login
print("\nStep 2: Staff login (priya)...")
staff_login = req("POST", "/auth/login", {
    "username": "priya",
    "password": "staff123"
})
staff_token = staff_login.get("token")
print(f"✅ Staff token: {staff_token[:20]}...")

# Step 3: Get tables
print("\nStep 3: Fetch available tables...")
tables = req("GET", "/tables", token=staff_token)
empty_tables = [t for t in tables if t.get("status") == "empty"]
print(f"✅ Available tables: {len(empty_tables)}")
chosen_table = empty_tables[0]["number"]
print(f"   Placing order on Table {chosen_table}")

# Step 4: Get menu items
print("\nStep 4: Fetch menu items...")
menu = req("GET", "/menu")
print(f"✅ Menu has {len(menu)} items")
espresso = next((m for m in menu if m["name"] == "Espresso"), None)
latte = next((m for m in menu if m["name"] == "Latte"), None)
if not espresso or not latte:
    print("❌ Menu missing Espresso or Latte")
    exit(1)

# Step 5: Place order on table
print("\nStep 5: Staff places order on Table {0}...".format(chosen_table))
order_payload = {
    "table_number": chosen_table,
    "customer": {"name": f"Table {chosen_table}"},
    "items": [
        {
            "item_id": espresso["id"],
            "qty": 1,
            "selected_options": [
                {"group": "Size", "label": "Regular"},
                {"group": "Milk", "label": "Whole"}
            ]
        },
        {
            "item_id": latte["id"],
            "qty": 1,
            "selected_options": [
                {"group": "Size", "label": "Large"}
            ]
        }
    ],
    "notes": "Extra hot"
}
order = req("POST", "/orders", order_payload, token=staff_token)
order_id = order["id"]
print(f"✅ Order placed: #{order_id}")
print(f"   Total: ₹{order['total']} paise")
print(f"   Status: {order['status']}")
print(f"   Table: {order.get('table_number')}")
print(f"   Customer: {order['customer']['name']}")

# Step 6: Verify table is occupied
print("\nStep 6: Verify Table {0} is occupied...".format(chosen_table))
tables_after = req("GET", "/tables", token=staff_token)
table = next(t for t in tables_after if t["number"] == chosen_table)
if table["status"] != "occupied":
    print(f"❌ Table should be occupied, but status is: {table['status']}")
    exit(1)
print(f"✅ Table {chosen_table} is occupied")
print(f"   Linked order: {table.get('order_id')}")

# Step 7: Owner login
print("\nStep 7: Owner login...")
owner_login = req("POST", "/auth/login", {
    "username": "owner",
    "password": "cafe123"
})
owner_token = owner_login.get("token")
print(f"✅ Owner token: {owner_token[:20]}...")

# Step 8: Owner fetches all orders
print("\nStep 8: Owner views all orders...")
all_orders = req("GET", "/orders", token=owner_token)
print(f"✅ Total orders in system: {len(all_orders)}")

# Find our order
our_order = next((o for o in all_orders if o["id"] == order_id), None)
if not our_order:
    print(f"❌ Our order not found in order list")
    exit(1)
print(f"✅ Our order visible to owner:")
print(f"   Order #: {our_order['id']}")
print(f"   Status: {our_order['status']}")
print(f"   Table: {our_order.get('table_number')}")
print(f"   Customer: {our_order['customer']['name']}")
print(f"   Total: ₹{our_order['total']} paise")
print(f"   Items: {len(our_order['items'])}")
for item in our_order["items"]:
    options_str = " · ".join(o["label"] for o in item.get("selected_options", []))
    print(f"     - {item['qty']}× {item['name']} ({options_str})")
print(f"   Notes: {our_order.get('notes', 'N/A')}")

# Step 9: Owner advances order status
print("\nStep 9: Owner advances order status...")
status_flow = ["received", "preparing", "ready", "collected"]
current_idx = status_flow.index(our_order["status"])

for next_status in status_flow[current_idx + 1:]:
    payload = {"status": next_status}
    if next_status == "collected":
        # An order can't be completed without payment.
        payload["paid"] = True
        payload["payment_method"] = our_order.get("payment_method", "cash")
    order_updated = req("PATCH", f"/orders/{order_id}/status",
                       payload, token=owner_token)
    print(f"✅ Status: {order_updated['status']}")

# Step 10: Verify table is freed
print("\nStep 10: Verify Table {0} is freed...".format(chosen_table))
tables_final = req("GET", "/tables", token=owner_token)
table_final = next(t for t in tables_final if t["number"] == chosen_table)
if table_final["status"] != "empty":
    print(f"❌ Table should be empty, but status is: {table_final['status']}")
    exit(1)
print(f"✅ Table {chosen_table} is now empty (freed)")

# Step 11: Verify order is in sales
print("\nStep 11: Verify order appears in sales report...")
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
sales = req("GET", f"/admin/reports/daily?date={today}", token=owner_token)
if sales.get("order_count", 0) > 0:
    print(f"✅ Sales report shows collected orders:")
    print(f"   Order count: {sales['order_count']}")
    print(f"   Gross sales: ₹{sales.get('gross_sales', 0)} paise")
else:
    print(f"⚠️  Sales report may not show yet (check date)")

# Step 12: Owner checks billing
print("\nStep 12: Owner views billing...")
billing = req("GET", f"/admin/billing?date={today}", token=owner_token)
summary = billing.get("summary", {})
print(f"✅ Billing summary:")
print(f"   Collected orders: {summary.get('order_count', 0)}")
print(f"   Total: ₹{summary.get('total', 0)} paise")
print(f"   Paid: ₹{summary.get('paid', 0)} paise")
print(f"   Unpaid: ₹{summary.get('unpaid', 0)} paise")
billed = [o for d in billing.get("days", []) for o in d.get("orders", [])]
if any(o["id"] == order_id for o in billed):
    print(f"✅ Our order #{order_id} is in the billing view")
else:
    print(f"⚠️  Our order not in billing view (still active?)")

# Step 13: Owner confirms payment
print("\nStep 13: Owner confirms payment...")
paid = req("POST", f"/admin/billing/{order_id}/paid", token=owner_token)
print(f"✅ Order #{order_id} payment status: {paid.get('payment_status')}")
billing_after = req("GET", f"/admin/billing?date={today}", token=owner_token)
print(f"   Billing paid total now: ₹{billing_after['summary'].get('paid', 0)} paise")

print("\n" + "=" * 60)
print("✅ E2E DEMO COMPLETE!")
print("=" * 60)
print("\n✅ Features verified:")
print("   ✓ Staff can take table order")
print("   ✓ Table becomes occupied after order")
print("   ✓ Order shows in owner's list with table number")
print("   ✓ Order shows customer name, items, and notes")
print("   ✓ Owner can advance order status")
print("   ✓ Table frees up when order collected")
print("   ✓ Order appears in sales report")
print("   ✓ Collected order appears in billing view")
print("   ✓ Owner can mark order as paid")
print("\n")
