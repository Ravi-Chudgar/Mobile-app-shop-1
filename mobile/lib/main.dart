import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/api_client.dart';
import 'services/notification_service.dart';
import 'state/auth_state.dart';
import 'state/cart_state.dart';
import 'state/tenant_state.dart';
import 'screens/auth/login_screen.dart';
import 'screens/ca/ca_shell.dart';
import 'screens/customer/menu_screen.dart';
import 'screens/owner/owner_shell.dart';
import 'screens/staff/staff_shell.dart';
import 'screens/kitchen/kitchen_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await NotificationService.init();
  } catch (_) {
    // Notification setup failed — app still works, just no push alerts.
  }
  runApp(const CafeApp());
}

class CafeApp extends StatefulWidget {
  const CafeApp({super.key});

  @override
  State<CafeApp> createState() => _CafeAppState();
}

class _CafeAppState extends State<CafeApp> {
  // One session / one branding holder for the whole app: they must survive
  // rebuilds, so they live here (not recreated inside build()).
  late final ApiClient _api = ApiClient();
  late final AuthState _auth = AuthState(_api);
  late final TenantState _tenant = TenantState(_api)..attach(_auth);

  @override
  void initState() {
    super.initState();
    // Restores the stored session (and, with it, the cafe code); branding
    // then follows via [TenantState.attach]. Best effort: it never blocks
    // or throws, it just leaves the headers unbranded on failure.
    unawaited(_auth.load());
  }

  @override
  void dispose() {
    _tenant.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: _api),
        ChangeNotifierProvider(create: (_) => CartState()),
        ChangeNotifierProvider<AuthState>.value(value: _auth),
        ChangeNotifierProvider<TenantState>.value(value: _tenant),
      ],
      child: MaterialApp(
        title: 'Cafe POS',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const RootGate(),
      ),
    );
  }
}

ThemeData buildAppTheme() {
  const seed = Color(0xFF6F4E37); // coffee brown
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final softBorder = BorderSide(
    color: Colors.black.withValues(alpha: 0.05),
  );

  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFFF6F4F1),
    // Warm coffee hover/focus tint so cards and tiles feel alive on
    // pointer devices instead of the default neutral grey wash.
    hoverColor: const Color(0x146F4E37),
    focusColor: const Color(0x1F6F4E37),
    highlightColor: const Color(0x0F6F4E37),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFFF6F4F1),
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: softBorder,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFFAF9F7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      prefixIconColor: scheme.onSurfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: softBorder,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? scheme.primary : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primaryContainer
            : Colors.black.withValues(alpha: 0.1),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: Colors.black.withValues(alpha: 0.06),
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      iconColor: scheme.onSurfaceVariant,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF4E3626), // espresso
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    splashFactory: InkSparkle.splashFactory,
  );
}

/// A table-QR deep link parsed from the launch URL.
///
/// Cards encode `{base}/t/<slug>/table/<n>` (tenant-scoped) and the legacy
/// format `{base}/table/<n>` (default tenant); a web host may mount the app
/// under a path prefix, so the pattern is matched off the path's tail.
class QrDeepLink {
  const QrDeepLink({this.tenant, required this.tableNumber});

  /// Cafe code from the URL, or null for a legacy (default-tenant) card.
  final String? tenant;

  /// Table number the card belongs to.
  final String tableNumber;
}

/// Parses `Uri.base` on web: `/t/<slug>/table/<n>` -> scoped cafe code,
/// `/table/<n>` -> legacy default tenant. The route is matched off the
/// path's tail (a web host may mount the app under a prefix) and, when the
/// path has no match, off the fragment, for hash-based hosting.
/// Returns null for every other URL (and on native platforms, where
/// Android/iOS deep links are still a documented gap — no plugin is wired
/// up yet).
QrDeepLink? parseQrDeepLink(Uri uri) {
  try {
    final direct = _parseQrPath(uri.pathSegments);
    if (direct != null) return direct;
    final fragment = uri.fragment;
    if (fragment.isEmpty) return null;
    return _parseQrPath(Uri.parse(fragment).pathSegments);
  } catch (_) {
    return null; // Malformed URL — never let a QR link break startup.
  }
}

QrDeepLink? _parseQrPath(List<String> pathSegments) {
  final segments =
      pathSegments.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  final tableAt = segments.indexOf('table');
  if (tableAt < 0 || tableAt + 1 >= segments.length) return null;
  final tableNumber = segments[tableAt + 1];
  // Keep the match tight: an unrecognised token (a file name, a slug with
  // dots, an over-long path fragment) must never hijack the app.
  if (!RegExp(r'^[0-9A-Za-z_-]{1,16}$').hasMatch(tableNumber)) {
    return null;
  }
  final scoped = tableAt >= 2 && segments[tableAt - 2] == 't';
  return QrDeepLink(
    tenant: scoped ? segments[tableAt - 1] : null,
    tableNumber: tableNumber,
  );
}

/// Evaluated once, lazily: the QR deep link the app was launched with.
/// Native platforms always resolve to null (see [parseQrDeepLink]).
final QrDeepLink? qrLaunchDeepLink = kIsWeb ? parseQrDeepLink(Uri.base) : null;

/// Login-first routing: logged out -> login; owner/staff/kitchen -> their
/// shell; cafe_ca (read-only CA) -> the accounting-bridge shell.
///
/// A table-QR deep link skips all of that: the customer self-order flow is
/// public, so `/t/<slug>/table/<n>` opens straight into the menu for that
/// cafe without asking anyone to sign in.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final qr = qrLaunchDeepLink;
    if (qr != null) {
      return CustomerMenuScreen(tenant: qr.tenant, tableNumber: qr.tableNumber);
    }
    final auth = context.watch<AuthState>();
    if (auth.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!auth.isLoggedIn) return const LoginScreen();
    if (auth.isOwner) return const OwnerShell();
    if (auth.role == 'cafe_ca') return const CaShell();
    if (auth.isKitchen) return const KitchenShell();
    return const StaffShell();
  }
}
