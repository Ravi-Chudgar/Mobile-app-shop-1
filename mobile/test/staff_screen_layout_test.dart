import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:cafe_app/main.dart';
import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/screens/owner/staff_screen.dart';

/// Fake http.Client returning canned staff JSON — no real network.
class _FakeHttp extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    const body = '[{"username":"owner","name":"Owner","role":"owner",'
        '"status":"approved","last_login":"2026-08-20T00:00:00+00:00"},'
        '{"username":"priya","name":"Priya","role":"staff","status":"approved",'
        '"last_login":"2026-08-17T00:00:00+00:00"},'
        '{"username":"sam","name":"Sam","role":"staff","status":"pending",'
        '"last_login":null}]';
    final res = http.StreamedResponse(
      Stream.value(body.codeUnits),
      200,
      headers: {'content-type': 'application/json'},
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return res;
  }
}

Widget _host({ApiClient? api}) {
  final client = api ?? (ApiClient(client: _FakeHttp())..token = 't');
  return Provider<ApiClient>.value(
    value: client,
    child: MaterialApp(
      // The REAL app theme. Regression guard: SizedButtonTheme min-width
      // used to be Size.fromHeight (infinite) -> the Approve FilledButton
      // inside a Row crashed with "BoxConstraints forces an infinite width".
      theme: buildAppTheme(),
      home: const Scaffold(body: StaffScreen()),
    ),
  );
}

void main() {
  testWidgets('StaffScreen renders pending + team with real theme',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // No layout exception should have been thrown.
    expect(tester.takeException(), isNull);

    expect(find.text('Pending approval'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Owner'), findsWidgets);
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('Add staff dialog opens without layout error', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // FAB label + dialog title both say "Add staff"; the dialog action
    // button must be a FilledButton and must NOT throw on layout.
    expect(find.text('Add staff'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);
  });
}
