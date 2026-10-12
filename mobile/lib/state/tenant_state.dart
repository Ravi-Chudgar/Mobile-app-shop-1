import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import 'auth_state.dart';

/// Per-cafe branding for the tenant currently in scope.
///
/// Backed by `GET /public/<slug>/config`, which returns the public subset
/// `{display_name, kind, bill_footer}`. It is loaded:
///   * after login and on a cold start — [attach] follows [AuthState], so
///     the cafe code comes straight from the session (restored sessions
///     written before multi-tenancy fall back to [defaultSlug]), and
///   * in the public QR flow — a customer menu opened from a cafe's table
///     card calls [loadFor] with that card's code.
///
/// Everything here is best effort: a failed lookup leaves the branding
/// empty and the UI simply falls back to its generic copy.
class TenantState extends ChangeNotifier {
  TenantState(this._api);

  /// Slug the backend falls back to when no cafe code is given — the value
  /// of its `DEFAULT_TENANT` env ("main" out of the box).
  static const String defaultSlug = 'main';

  final ApiClient _api;
  AuthState? _auth;

  /// Cafe code the branding belongs to ("" until loaded).
  String slug = '';

  /// Public cafe name shown in headers, e.g. "Bean House Cafe".
  String displayName = '';

  /// Business kind (`cafe`, `hostel`, …) — "" until loaded.
  String kind = '';

  /// Footer line printed on customer bills — "" until loaded.
  String billFooter = '';

  /// True once a display name is known (headers can be branded).
  bool get hasBranding => displayName.isNotEmpty;

  /// Follows the session: every time a cafe code becomes known (login or
  /// restored session) the branding is reloaded for it. Call once at start.
  void attach(AuthState auth) {
    if (identical(_auth, auth)) return;
    _auth?.removeListener(_onAuthChanged);
    _auth = auth;
    auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  void _onAuthChanged() {
    final auth = _auth;
    // Logged out = login screen, nothing to brand yet; the next sign-in
    // brings its own cafe code.
    if (auth == null || !auth.isLoggedIn) return;
    unawaited(loadFor(auth.tenant));
  }

  /// Loads branding for [slug]; null/blank means [defaultSlug]. Failures are
  /// swallowed — branding is decoration, never a reason to block the UI.
  Future<void> loadFor(String? slug) async {
    final target = (slug ?? '').trim();
    final effective = target.isEmpty ? defaultSlug : target;
    if (effective == this.slug && hasBranding) return; // already loaded

    // Moving to a different cafe: drop the old name first, so a failed
    // lookup can never leave another business's branding on screen.
    if (this.slug.isNotEmpty && this.slug != effective) {
      this.slug = effective;
      displayName = '';
      kind = '';
      billFooter = '';
      notifyListeners();
    }
    this.slug = effective;
    try {
      final config = await _api.fetchTenantConfig(effective);
      displayName = '${config['display_name'] ?? ''}';
      kind = '${config['kind'] ?? ''}';
      billFooter = '${config['bill_footer'] ?? ''}';
      notifyListeners();
    } catch (_) {
      // Offline / unknown cafe code — keep the (empty) fallback branding.
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    _auth = null;
    super.dispose();
  }
}

/// Looks the branding up from [context] without throwing when no
/// [TenantState] was provided above (a bare `MaterialApp` in widget tests).
/// Returns null in that case so callers fall back to date-only subtitles.
TenantState? tenantStateOf(BuildContext context) {
  try {
    return Provider.of<TenantState>(context);
  } on ProviderNotFoundException catch (_) {
    return null;
  }
}
