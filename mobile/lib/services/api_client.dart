import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/ask_result.dart';
import '../models/billing.dart';
import '../models/cafe_table.dart';
import '../models/cart.dart';
import '../models/inventory_item.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/recommendation.dart';
import '../models/sales_summary.dart';
import '../models/staff_member.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// Thin HTTP wrapper around the Flask backend. Shared via Provider; set [token]
/// after login so authorized calls carry the bearer token.
class ApiClient {
  ApiClient({http.Client? client}) : _http = client ?? http.Client();

  /// Upper bound for any single HTTP request. Without this, a backend that is
  /// unreachable but still accepts the connection can hang the UI forever on a
  /// spinner (reported as the app "sticking" on a tab).
  static const Duration _timeout = Duration(seconds: 5);

  /// AI endpoints call a local LLM on the backend host (~15-25 s per answer),
  /// so they get a much longer ceiling than normal requests.
  static const Duration _aiTimeout = Duration(seconds: 40);

  /// The agentic assistant may make two LLM calls per question (~20-30 s
  /// total on the backend host's CPU).
  static const Duration _askTimeout = Duration(seconds: 75);

  final http.Client _http;
  String? token;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final cleaned = <String, String>{};
    if (query != null) {
      query.forEach((k, v) {
        if (v != null) cleaned[k] = v.toString();
      });
    }
    return Uri.parse('${AppConfig.baseUrl}$path')
        .replace(queryParameters: cleaned.isEmpty ? null : cleaned);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  dynamic _decode(http.Response res) {
    // Decode the raw bytes as UTF-8 explicitly: Flask answers
    // `application/json` with no charset, and the http package would then
    // fall back to latin1 — which garbles any non-ASCII character (é, ₹, —)
    // in messages or menu names.
    final body = res.bodyBytes.isEmpty
        ? null
        : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final msg = (body is Map && body['error'] != null)
        ? body['error'] as String
        : 'Request failed (${res.statusCode})';
    throw ApiException(msg, statusCode: res.statusCode);
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) async {
    try {
      return _decode(await _http
          .get(_uri(path, query), headers: _headers)
          .timeout(_timeout));
    } on TimeoutException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on SocketException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on http.ClientException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    }
  }

  Future<dynamic> _send(String method, String path, Object? body,
      {Duration? timeout}) async {
    final t = timeout ?? _timeout;
    try {
      final req = http.Request(method, _uri(path))..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      final streamed = await _http.send(req).timeout(t);
      return _decode(await http.Response.fromStream(streamed).timeout(t));
    } on TimeoutException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on SocketException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on http.ClientException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    }
  }

  // ---- Auth ----
  /// Signs in. [tenant] is the optional business/cafe code: the server puts
  /// it in the JWT, so every later call is scoped to that cafe without any
  /// extra client plumbing. Blank/omitted = the server's default tenant.
  Future<Map<String, dynamic>> login(String username, String password,
      {String? tenant}) async {
    return await _send('POST', '/auth/login', {
      'username': username,
      'password': password,
      if (tenant != null && tenant.isNotEmpty) 'tenant': tenant,
    }) as Map<String, dynamic>;
  }

  Future<void> register(String username, String password, String name) async {
    await _send('POST', '/auth/register',
        {'username': username, 'password': password, 'name': name});
  }

  // ---- Attendance (staff clock in / clock out) ----
  /// Today's attendance record for the signed-in member, or null when they
  /// have not clocked in yet.
  Future<Map<String, dynamic>?> attendanceMe() async {
    final data = await _get('/attendance/me') as Map<String, dynamic>;
    return data['record'] as Map<String, dynamic>?;
  }

  /// Start today's shift. Throws [ApiException] with status 409 when one
  /// already exists — the server treats a recorded clock-in as immutable.
  Future<Map<String, dynamic>> clockIn() async {
    final data =
        await _send('POST', '/attendance/clock-in', <String, dynamic>{})
            as Map<String, dynamic>;
    return data['record'] as Map<String, dynamic>;
  }

  /// End today's shift. 400 when there is no clock-in, 409 when already out.
  Future<Map<String, dynamic>> clockOut() async {
    final data =
        await _send('POST', '/attendance/clock-out', <String, dynamic>{})
            as Map<String, dynamic>;
    return data['record'] as Map<String, dynamic>;
  }

  // ---- Menu (read is open) ----
  Future<List<MenuItem>> fetchMenu({String? category}) async {
    final data = await _get('/menu', {'category': category}) as List;
    return data
        .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<String>> fetchCategories() async {
    final data = await _get('/categories') as List;
    return data.cast<String>();
  }

  // ---- AI recommendations (staff/owner) ----
  Future<List<Suggestion>> fetchRecommendations(List<CartLine> cart) async {
    final data = await _send(
        'POST',
        '/recommend',
        {
          'cart': [
            for (final line in cart) {'item_id': line.item.id, 'qty': line.qty},
          ],
        },
        timeout: _aiTimeout) as Map<String, dynamic>;
    return ((data['suggestions'] ?? []) as List)
        .map((e) => Suggestion.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---- AI assistant (staff/owner) ----
  Future<AskResult> askQuestion(String question) async {
    final data = await _send('POST', '/ask', {'question': question},
        timeout: _askTimeout) as Map<String, dynamic>;
    return AskResult.fromJson(data);
  }

  /// Runs a previously-proposed pending action after the user confirmed it.
  Future<Map<String, dynamic>> executeAction(
      String action, Map<String, dynamic> args) async {
    return await _send('POST', '/ask/execute', {'action': action, 'args': args},
        timeout: _aiTimeout) as Map<String, dynamic>;
  }

  // ---- Orders (staff/owner) ----
  Future<CafeOrder> placeOrder(Map<String, dynamic> payload) async {
    final data =
        await _send('POST', '/orders', payload) as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  Future<CafeOrder> fetchOrder(String id) async {
    final data = await _get('/orders/$id') as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  Future<List<CafeOrder>> fetchOrders(
      {String? status, String? date, String? takenBy}) async {
    final data = await _get(
            '/orders', {'status': status, 'date': date, 'taken_by': takenBy})
        as List;
    return data
        .map((e) => CafeOrder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CafeOrder> updateOrderStatus(
    String id,
    String status, {
    bool paid = false,
    String? paymentMethod,
    String? paymentToken,
    String? razorpayOrderId,
    String? razorpayPaymentId,
    String? razorpaySignature,
    List<Map<String, dynamic>>? payments,
    int? redeemPoints,
  }) async {
    final data = await _send('PATCH', '/orders/$id/status', {
      'status': status,
      if (paid) 'paid': true,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (paymentToken != null) 'payment_token': paymentToken,
      if (razorpayOrderId != null) 'razorpay_order_id': razorpayOrderId,
      if (razorpayPaymentId != null) 'razorpay_payment_id': razorpayPaymentId,
      if (razorpaySignature != null) 'razorpay_signature': razorpaySignature,
      if (payments != null && payments.isNotEmpty) 'payments': payments,
      if (redeemPoints != null && redeemPoints > 0)
        'redeem_points': redeemPoints,
    }) as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  /// Initialize a Razorpay payment for an order.
  /// Body: {"amount": <paise>, "currency": "INR", "receipt": "<optional>"}
  Future<Map<String, dynamic>> initRazorpayPayment({
    required int amount,  // amount in paise
    String currency = "INR",
    String? receipt,
  }) async {
    final resp = await _send('POST', '/orders/payment/razorpay', {
      'amount': amount,
      'currency': currency,
      if (receipt != null) 'receipt': receipt,
    }) as Map<String, dynamic>;
    return resp;
  }

  Future<CafeOrder> reopenOrder(String id) async {
    final data =
        await _send('POST', '/orders/$id/reopen', {}) as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  Future<CafeOrder> addOrderItems(
      String id, List<Map<String, dynamic>> items) async {
    final data = await _send('POST', '/orders/$id/items', {'items': items})
        as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  // ---- Tables ----
  Future<List<CafeTable>> fetchTables() async {
    final data = await _get('/tables') as List;
    return data
        .map((e) => CafeTable.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> freeTable(String number) async {
    await _send('POST', '/tables/$number/free', {});
  }

  Future<CafeTable> addTable({int? number}) async {
    final data = await _send(
            'POST', '/admin/tables', {if (number != null) 'number': number})
        as Map<String, dynamic>;
    return CafeTable.fromJson(data);
  }

  Future<void> removeTable(String number) async {
    await _send('DELETE', '/admin/tables/$number', null);
  }

  // ---- Staff (owner) ----
  Future<List<StaffMember>> fetchStaff() async {
    final data = await _get('/admin/staff') as List;
    return data
        .map((e) => StaffMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> approveStaff(String username) async {
    await _send('POST', '/admin/staff/$username/approve', {});
  }

  Future<void> removeStaff(String username) async {
    await _send('DELETE', '/admin/staff/$username', null);
  }

  Future<void> createStaff(
      String username, String password, String name) async {
    await _send('POST', '/admin/staff',
        {'username': username, 'password': password, 'name': name});
  }

  // ---- Reports (owner) ----
  Future<SalesSummary> dailyReport(String date) async {
    final data = await _get('/admin/reports/daily', {'date': date})
        as Map<String, dynamic>;
    return SalesSummary.fromJson(data);
  }

  Future<List<SalesSummary>> rangeReport(String from, String to) async {
    final data =
        await _get('/admin/reports/range', {'from': from, 'to': to}) as List;
    return data
        .map((e) => SalesSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---- Billing (owner) ----
  Future<BillingSummary> fetchBilling({String? date}) async {
    final data =
        await _get('/admin/billing', {'date': date}) as Map<String, dynamic>;
    return BillingSummary.fromJson(data);
  }

  Future<CafeOrder> markOrderPaid(String id) async {
    final data = await _send('POST', '/admin/billing/$id/paid', {})
        as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  // ---- Menu management (owner) ----
  Future<MenuItem> createMenuItem(Map<String, dynamic> payload) async {
    final data =
        await _send('POST', '/admin/menu', payload) as Map<String, dynamic>;
    return MenuItem.fromJson(data);
  }

  Future<MenuItem> setAvailability(String id, bool available) async {
    final data = await _send(
            'PATCH', '/admin/menu/$id/availability', {'available': available})
        as Map<String, dynamic>;
    return MenuItem.fromJson(data);
  }

  Future<MenuItem> updateMenuItem(
      String id, Map<String, dynamic> payload) async {
    final data =
        await _send('PUT', '/admin/menu/$id', payload) as Map<String, dynamic>;
    return MenuItem.fromJson(data);
  }

  /// Owner's business identity printed on bills (name, GST, PAN, licence…).
  Future<Map<String, dynamic>> getCafeProfile() async {
    final data = await _get('/admin/cafe/profile') as Map<String, dynamic>;
    return data;
  }

  /// Partially update the cafe profile. Returns the saved profile.
  Future<Map<String, dynamic>> updateCafeProfile(
      Map<String, dynamic> payload) async {
    final data =
        await _send('PUT', '/admin/cafe/profile', payload) as Map<String, dynamic>;
    return data;
  }

  // ---- Platform admin (cross-cafe; role=admin) ----
  /// Every cafe with owner details + current-month profit & loss.
  Future<Map<String, dynamic>> platformListCafes() async {
    final data = await _get('/platform/tenants') as Map<String, dynamic>;
    return data;
  }

  /// Register a new cafe + its owner account. Returns {message, tenant, ...}.
  Future<Map<String, dynamic>> platformCreateCafe(
      Map<String, dynamic> payload) async {
    final data = await _send('POST', '/platform/tenants', payload)
        as Map<String, dynamic>;
    return data;
  }

  /// Ask the backend for a full OWNER token for [slug] so the admin can manage
  /// that cafe. Returns {token, role, tenant, username, name}.
  Future<Map<String, dynamic>> platformActAs(String slug) async {
    final data = await _send('POST', '/platform/tenants/$slug/act-as', {})
        as Map<String, dynamic>;
    return data;
  }

  Future<void> deleteMenuItem(String id) async {
    await _send('DELETE', '/admin/menu/$id', null);
  }

  // ---- Thermal printing (ESC/POS) ----
  /// Builds the receipt server-side. In dry-run mode (no printer configured)
  /// the backend returns the bytes base64-encoded instead of sending them.
  Future<Map<String, dynamic>> printReceipt(String orderId) async {
    final data = await _send('POST', '/printing/receipt/$orderId', {})
        as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> printKot(String orderId) async {
    final data = await _send('POST', '/printing/kot/$orderId', {})
        as Map<String, dynamic>;
    return data;
  }

  // ---- Server-rendered bill (WhatsApp) ----
  Future<Map<String, dynamic>> fetchBillText(String orderId) async {
    final data = await _get('/orders/$orderId/bill') as Map<String, dynamic>;
    return data;
  }

  // ---- Day-end Z-report (owner) ----
  Future<Map<String, dynamic>> zReport(String date) async {
    final data =
        await _get('/admin/reports/z', {'date': date}) as Map<String, dynamic>;
    return data;
  }

  // ---- Inventory (owner) ----
  Future<List<InventoryItem>> fetchInventory() async {
    final data = await _get('/admin/inventory') as List;
    return data
        .map((e) => InventoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> fetchInventorySummary() async {
    final data = await _get('/admin/inventory/summary') as Map<String, dynamic>;
    return data;
  }

  Future<InventoryItem> createInventoryItem(
      Map<String, dynamic> payload) async {
    final data = await _send('POST', '/admin/inventory', payload)
        as Map<String, dynamic>;
    return InventoryItem.fromJson(data);
  }

  Future<InventoryItem> updateInventoryItem(
      String id, Map<String, dynamic> payload) async {
    final data = await _send('PUT', '/admin/inventory/$id', payload)
        as Map<String, dynamic>;
    return InventoryItem.fromJson(data);
  }

  Future<InventoryItem> restockItem(String id, int quantity) async {
    final data = await _send(
            'POST', '/admin/inventory/$id/restock', {'quantity': quantity})
        as Map<String, dynamic>;
    return InventoryItem.fromJson(data);
  }

  Future<void> deleteInventoryItem(String id) async {
    await _send('DELETE', '/admin/inventory/$id', null);
  }

  Future<Map<String, dynamic>> calculateProfitLoss({String? month}) async {
    final date = month ??
        DateFormat('yyyy-MM-dd').format(
            DateTime.now().subtract(Duration(days: DateTime.now().day - 1)));
    final data = await _get('/admin/reports/profit-loss', {'month': date})
        as Map<String, dynamic>;
    return data;
  }

  // ---- Low-stock alerts (owner) ----
  /// Items whose reorder_level is set (> 0) and whose quantity has dropped to
  /// (or below) it, plus out-of-stock items. reorder_level 0 = never returned.
  Future<List<LowStockAlert>> fetchInventoryAlerts() async {
    final data = await _get('/admin/inventory/alerts') as List;
    return data
        .map((e) => LowStockAlert.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---- Floor map layout (owner) ----
  /// Owner-only: move/resize a table on the visual floor map.
  Future<CafeTable> updateTableLayout(
    String number, {
    String? zone,
    int? x,
    int? y,
    int? w,
    int? h,
    String? shape,
  }) async {
    final data = await _send('PUT', '/admin/tables/$number/layout', {
      if (zone != null) 'zone': zone,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (w != null) 'w': w,
      if (h != null) 'h': h,
      if (shape != null) 'shape': shape,
    }) as Map<String, dynamic>;
    return CafeTable.fromJson(data);
  }

  // ---- Phase 3: QR self-order (public endpoints, no auth) ----

  /// Builds a public QR path for a cafe code: `/public/<slug>/...` when
  /// [tenant] is set, or the legacy `/public/...` (default tenant) when it
  /// is blank. Both families are byte-identical server-side, so existing
  /// cards and flows keep working while they migrate.
  static String _publicPath(String? tenant, String suffix) {
    final slug = (tenant ?? '').trim();
    return slug.isEmpty
        ? '/public$suffix'
        : '/public/${Uri.encodeComponent(slug)}$suffix';
  }

  /// Customer menu: available items only (price/category/gst/options).
  Future<List<MenuItem>> fetchPublicMenu({String? tenant}) async {
    final data = await _get(_publicPath(tenant, '/menu')) as List;
    return data
        .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Public branding for a cafe code: {display_name, kind, bill_footer}.
  /// Never returns operator config (e.g. the kitchen printer host).
  Future<Map<String, dynamic>> fetchTenantConfig(String slug) async {
    final data =
        await _get(_publicPath(slug, '/config')) as Map<String, dynamic>;
    return data;
  }

  /// Customer places a table order from the QR flow.
  Future<CafeOrder> placePublicOrder({
    required String tableNumber,
    required List<Map<String, dynamic>> items,
    required String name,
    required String phone,
    String? tenant,
  }) async {
    final data = await _send('POST', _publicPath(tenant, '/orders'), {
      'table_number': tableNumber,
      'items': items,
      'customer': {'name': name, 'phone': phone},
    }) as Map<String, dynamic>;
    return CafeOrder.fromJson(data);
  }

  /// Customer tracking view: {id, status, items, total, table_number, ...}.
  Future<Map<String, dynamic>> fetchPublicOrder(String id,
      {String? tenant}) async {
    final data =
        await _get(_publicPath(tenant, '/orders/$id')) as Map<String, dynamic>;
    return data;
  }

  /// Table-card QR description (`?format=json`): {table_number, url}. The
  /// URL encodes `{base}/t/<slug>/table/<n>` for a cafe code, or the legacy
  /// `{base}/table/<n>` for the default tenant.
  Future<Map<String, dynamic>> publicTableQr(String tableNumber,
      {String? tenant}) async {
    final data =
        await _get(_publicPath(tenant, '/qr/$tableNumber'), {'format': 'json'})
            as Map<String, dynamic>;
    return data;
  }

  /// Raw PNG bytes for a table QR card (`Image.memory(...)`).
  Future<Uint8List> fetchTableQrPng(String tableNumber,
      {String? tenant}) async {
    final res = await _http
        .get(_uri(_publicPath(tenant, '/qr/$tableNumber')), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw ApiException('Could not load the QR code (${res.statusCode})',
          statusCode: res.statusCode);
    }
    return res.bodyBytes;
  }

  /// The URL encoded in a table's QR code ({QR_BASE_URL}/table/<n>).
  Future<String> fetchTableQrUrl(String tableNumber, {String? tenant}) async {
    final data = await publicTableQr(tableNumber, tenant: tenant);
    return (data['url'] ?? '') as String;
  }

  // ---- Phase 3: loyalty (staff lookup / owner adjust) ----

  Future<Map<String, dynamic>> fetchLoyalty(String phone) async {
    final data = await _get('/loyalty/$phone') as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> adjustLoyalty({
    required String phone,
    required int delta,
    required String reason,
  }) async {
    final data = await _send('POST', '/loyalty/adjust', {
      'phone': phone,
      'delta': delta,
      'reason': reason,
    }) as Map<String, dynamic>;
    return data;
  }

  // ---- Phase 3: growth reports (owner) ----

  /// Per-staff sales: orders taken, revenue (collected only), active count.
  Future<Map<String, dynamic>> staffSalesReport(
      {String? date, String? from, String? to}) async {
    final data = await _get('/admin/reports/staff', {
      'date': date,
      'from': from,
      'to': to,
    }) as Map<String, dynamic>;
    return data;
  }

  /// Orders as raw maps (keeps fields the typed model doesn't carry yet,
  /// e.g. `source`, which drives the delivery-orders list).
  Future<List<Map<String, dynamic>>> fetchOrdersRaw(
      {String? status, String? date, String? takenBy}) async {
    final data = await _get('/orders', {
      'status': status,
      'date': date,
      'taken_by': takenBy,
    }) as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // ---- Phase 4: accounting exports (owner + cafe_ca, read-only) ----

  /// GET a text export (Tally XML/CSV, GSTR CSV) as raw body text.
  Future<String> _getRaw(String path, Map<String, dynamic> query) async {
    try {
      final res = await _http
          .get(_uri(path, query), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) return res.body;
      dynamic body;
      try {
        body = res.body.isEmpty ? null : jsonDecode(res.body);
      } catch (_) {
        body = null;
      }
      final msg = (body is Map && body['error'] != null)
          ? body['error'] as String
          : 'Request failed (${res.statusCode})';
      throw ApiException(msg, statusCode: res.statusCode);
    } on TimeoutException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on SocketException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    } on http.ClientException {
      throw ApiException('Cannot reach the server. Is the backend running?');
    }
  }

  /// Tally Prime sales-voucher export for a date range.
  /// [format] is 'xml' (default) or 'csv'. Returns the raw file text.
  Future<String> fetchTallyExport({
    required String from,
    required String to,
    String format = 'xml',
  }) {
    return _getRaw('/export/tally', {'from': from, 'to': to, 'format': format});
  }

  /// GSTR-1 summary for a YYYY-MM period. [format] is 'json' or 'csv'.
  Future<String> fetchGstr1(String period, {String format = 'json'}) {
    return _getRaw('/export/gstr1', {'period': period, 'format': format});
  }

  /// GSTR-3B summary for a YYYY-MM period. [format] is 'json' or 'csv'.
  Future<String> fetchGstr3b(String period, {String format = 'json'}) {
    return _getRaw('/export/gstr3b', {'period': period, 'format': format});
  }

  // ---- Thermal printing — byte fetch + direct send (Phase 5) ----

  Future<Map<String, dynamic>> fetchReceiptBytes(String orderId) async {
    final data =
        await _get('/printing/receipt/$orderId/bytes') as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> fetchKotBytes(String orderId) async {
    final data =
        await _get('/printing/kot/$orderId/bytes') as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> fetchTestBytes() async {
    final data = await _get('/printing/test/bytes') as Map<String, dynamic>;
    return data;
  }

  Future<Map<String, dynamic>> sendPrinterBytes({
    required String bytesB64,
    required String host,
    int port = 9100,
  }) async {
    final data = await _send('POST', '/printing/send', {
      'bytes_b64': bytesB64,
      'host': host,
      'port': port,
    }) as Map<String, dynamic>;
    return data;
  }

  // ---- Offline-first sync (queue replay + reconnect pull) ----

  /// Replays a batch of queued offline ops on `POST /sync/batch`.
  /// Returns `{server_time, results: [{op_id, status, order_id?, error?}]}`;
  /// `status` is `applied`, `deduped` (replay of an op the server already
  /// has) or `error` (per-op rejection — the HTTP call itself still 200s).
  Future<Map<String, dynamic>> syncBatch(List<Map<String, dynamic>> ops) async {
    final data = await _send('POST', '/sync/batch', {'ops': ops})
        as Map<String, dynamic>;
    return data;
  }

  /// Pulls changes after reconnecting: orders created/updated since [since]
  /// (ISO-8601) plus full menu/tables/inventory snapshots.
  Future<Map<String, dynamic>> syncPull({String? since}) async {
    final data =
        await _get('/sync/pull', {'since': since}) as Map<String, dynamic>;
    return data;
  }
}
