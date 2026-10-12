import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_client.dart';

/// Holds the logged-in session (owner or staff). RootGate uses [role] to pick
/// the owner vs staff experience; null role means logged out. [tenant] names
/// the cafe (business) the session belongs to on a multi-tenant backend.
class AuthState extends ChangeNotifier {
  AuthState(this._api);

  final ApiClient _api;
  final _storage = const FlutterSecureStorage();
  static const _key = 'session';

  String? _token;
  String? role; // "owner" | "staff" | "kitchen"
  String? username;
  String? name;

  /// Cafe code (tenant slug) the session belongs to — filled in by the
  /// login response and persisted so a cold start can brand the app and
  /// re-open QR previews into the same cafe. Null = default tenant.
  String? tenant;
  bool _loading = true;

  bool get loading => _loading;
  bool get isLoggedIn => _token != null;
  bool get isOwner => role == 'owner';
  bool get isStaff => role == 'staff';
  bool get isKitchen => role == 'kitchen';

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _token = data['token'] as String?;
      role = data['role'] as String?;
      username = data['username'] as String?;
      name = data['name'] as String?;
      tenant = data['tenant'] as String?;
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
    await _storage.write(
      key: _key,
      value: jsonEncode({
        'token': _token,
        'role': role,
        'username': username,
        'name': name,
        'tenant': this.tenant,
      }),
    );
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
    _api.token = null;
    await _storage.delete(key: _key);
    notifyListeners();
  }
}
