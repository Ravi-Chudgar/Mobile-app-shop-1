// Generates investor-demo screenshots (goldens) of the real app UI with real
// fonts loaded. Run with: flutter test test/generate_demo_shots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:cafe_app/main.dart';
import 'package:cafe_app/screens/auth/login_screen.dart';
import 'package:cafe_app/screens/admin/dashboard_screen.dart';
import 'package:cafe_app/screens/owner/staff_screen.dart';
import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/state/auth_state.dart';
import 'package:cafe_app/widgets/shell_app_bar.dart';

const _fontsDir = '/opt/aquaos/flutter/bin/cache/artifacts/material_fonts';

Future<void> _loadFonts() async {
  Future<void> face(String family, String path) async {
    final data = File(path).readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(data.buffer)));
    await loader.load();
  }

  // Roboto family (weights used by the app theme).
  await face('Roboto', '$_fontsDir/Roboto-Regular.ttf');
  await face('Roboto', '$_fontsDir/Roboto-Medium.ttf');
  await face('Roboto', '$_fontsDir/Roboto-Bold.ttf');
  await face('Roboto', '$_fontsDir/Roboto-Black.ttf');
  // Material icons.
  await face('MaterialIcons', '$_fontsDir/MaterialIcons-Regular.otf');
  // DejaVu Sans provides the ₹ glyph (per-glyph fallback).
  await face('DejaVu', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
}

/// Fake http.Client serving canned JSON for the two endpoints the rendered
/// screens actually call: daily reports (dashboard) and staff list.
class _FakeHttp extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    late final String body;
    if (path == '/admin/reports/daily') {
      body = '''
      {"date":"2026-08-21","order_count":42,"gross_sales":45820,
       "by_category":{"coffee":21840,"tea":6540,"pastries":9620,"food":6820},
       "by_payment":{"cash":18200,"card":15820,"upi":11800},
       "top_items":[
         {"name":"Latte","qty":28,"revenue":8960},
         {"name":"Espresso","qty":34,"revenue":6800},
         {"name":"Butter Croissant","qty":22,"revenue":5500},
         {"name":"Masala Chai","qty":20,"revenue":4400},
         {"name":"Avocado Toast","qty":14,"revenue":6720}]}''';
    } else if (path == '/admin/staff') {
      body = '''
      [{"username":"owner","name":"Owner","role":"owner","status":"approved",
        "last_login":"2026-08-21T08:00:00+00:00"},
       {"username":"priya","name":"Priya","role":"staff","status":"approved",
        "last_login":"2026-08-21T09:15:00+00:00"},
       {"username":"sam","name":"Sam","role":"staff","status":"pending",
        "last_login":null}]''';
    } else {
      body = '[]';
    }
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  setUp(() async {
    await _loadFonts();
  });

  testWidgets('login screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 860));
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const LoginScreen()),
    );
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/login.png'));
  });

  Widget shell(ApiClient api, AuthState auth, String title, Widget body) =>
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AuthState>.value(value: auth),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            appBar:
                ShellAppBar(title: title, userName: 'Owner', onLogout: () {}),
            body: body,
          ),
        ),
      );

  testWidgets('owner sales dashboard', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1180));
    final api = ApiClient(client: _FakeHttp())..token = 't';
    final auth = AuthState(api)..name = 'Owner';
    await tester.pumpWidget(shell(api, auth, 'Sales', const DashboardScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/dashboard.png'));
  });

  testWidgets('owner staff management', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1180));
    final api = ApiClient(client: _FakeHttp())..token = 't';
    final auth = AuthState(api)..name = 'Owner';
    await tester.pumpWidget(shell(api, auth, 'Staff', const StaffScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/staff.png'));
  });
}
