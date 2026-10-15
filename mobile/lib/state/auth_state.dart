import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_client.dart';

/// Holds the logged-in session (owner / staff / kitchen / platform admin).
/// RootGate uses [role] to pick the experience; null role means logged out.
///
/// A platform admin (`role == 'admin'`) sees every cafe. It can "act as" a
/// cafe's owner: [actAsOwner] swaps the live session to a full owner token for
/// that cafe (RootGate then shows the owner shell), keeping the admin token +
/// identity in [_adminToken]/[_adminName] so [exitToAdmin] can return to the
/// cafe list. That swap is persisted, so a cold start mid-impersonation can
/// still go back.
class AuthState extends ChangeNotifier {
  AuthState(this._api);

  final ApiClient _api;
  final _storage = const FlutterSecureStorage();
  static const _key = 'session';

  String? _token;
  String? role; // "owner" | "staff" | "kitchen" | "admin"
  String? username;
  String? name;

  /// Cafe code (tenant slug) the session belongs to — filled in by the
  /// login response and persisted so a cold start can brand the app and
  /// re-open QR previews into the same cafe. Null = default tenant.
  String? tenant;

  // Platform admin only: what to restore when leaving an "act as owner" swap.
  String? _adminToken;
  String? _adminUsername;
  String? _adminName;

  /// The cafe currently being managed while impersonating (null = not
  /// impersonating; a plain owner session is never impersonating).
  String? actingSlug;
  String? actingCafeName;

  bool _loading = true;

  bool get loading => _loading;
  bool get isLoggedIn => _token != null;
  bool get isOwner => role == 'owner';
  bool get isStaff => role == 'staff';
  bool get isKitchen => role == 'kitchen';
  bool get isAdmin => role == 'admin';
  bool get isActingAsOwner => actingSlug != null;

  Map<String, dynamic> _snapshot() => {
        'token': _token,
        'role': role,
        'username': username,
        'name': name,
        'tenant': tenant,
        'adminToken': _adminToken,
        'adminUsername': _adminUsername,
        'adminName': _adminName,
        'actingSlug': actingSlug,
        'actingCafeName': actingCafeName,
      };

  Future<void> _persist() =>
      _storage.write(key: _key, value: jsonEncode(_snapshot()));

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _token = data['token'] as String?;
      role = data['role'] as String?;
      username = data['username'] as String?;
      name = data['name'] as String?;
      tenant = data['tenant'] as String?;
      _adminToken = data['adminToken'] as String?;
      _adminUsername = data['adminUsername'] as String?;
      _adminName = data['adminName'] as String?;
      actingSlug = data['actingSlug'] as String?;
      actingCafeName = data['actingCafeName'] as String?;
      _api.token = _token;
    }
    _loading = false;
    notifyListeners();
  }

  /// [tenant] is the optional cafe code typed on the login screen; the
  /// server answers with the resolved slug (default tenant when blank),
  /// which is what we keep from here on.
  Future<void> login(String user, String password, {String? tenant}) async {
    final result = await _api.login(user, password, tenant: tenant);
    _token = result['token'] as String;
    role = result['role'] as String;
    username = result['username'] as String?;
    name = result['name'] as String?;
    this.tenant = result['tenant'] as String?;
    _api.token = _token;
    // A fresh login starts clean — it must never inherit a prior swap.
    _adminToken = null;
    _adminUsername = null;
    _adminName = null;
    actingSlug = null;
    actingCafeName = null;
    await _persist();
    notifyListeners();
  }

  /// Platform admin: swap into full owner mode for cafe [slug]. Keeps the admin
  /// token + identity so [exitToAdmin] can return to the cafe list.
  Future<void> actAsOwner(String slug, {String? cafeName}) async {
    final res = await _api.platformActAs(slug);
    _adminToken = _token;
    _adminUsername = username;
    _adminName = name;
    _token = res['token'] as String;
    role = res['role'] as String; // 'owner'
    username = res['username'] as String?;
    name = res['name'] as String?;
    tenant = res['tenant'] as String? ?? slug;
    actingSlug = slug;
    actingCafeName = cafeName ?? (res['name'] as String?) ?? slug;
    _api.token = _token;
    await _persist();
    notifyListeners();
  }

  /// Platform admin: leave an "act as owner" session and return to the cafe
  /// list. No-op when there is no stored admin token (a plain owner session).
  Future<void> exitToAdmin() async {
    if (_adminToken == null) return;
    _token = _adminToken;
    role = 'admin';
    username = _adminUsername ?? 'admin';
    name = _adminName ?? username;
    tenant = null;
    _adminToken = null;
    _adminUsername = null;
    _adminName = null;
    actingSlug = null;
    actingCafeName = null;
    _api.token = _token;
    await _persist();
    notifyListeners();
  }

  Future<void> register(String user, String password, String name) async {
    await _api.register(user, password, name);
  }

  Future<void> logout() async {
    _token = null;
    role = null;
    username = null;
    name = null;
    tenant = null;
    _adminToken = null;
    _adminUsername = null;
    _adminName = null;
    actingSlug = null;
    actingCafeName = null;
    _api.token = null;
    // Best-effort keychain cleanup. A throw or a hang here must NEVER
    // block notifyListeners(): RootGate only swaps back to the login
    // screen on that notification, and a keychain error (e.g. a stale
    // item left behind by a previous install under a different signing
    // identity) used to abort logout() early and make the button look
    // dead.
    try {
      await _storage.delete(key: _key).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Ignore — worst case the next cold start re-read a stale
      // session; all in-memory state is already cleared above.
    }
    notifyListeners();
  }
}
