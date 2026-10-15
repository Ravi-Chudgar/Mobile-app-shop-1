import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:cafe_app/screens/admin/create_cafe_screen.dart';
import 'package:cafe_app/services/api_client.dart';

/// Fake http.Client so a valid submission never touches the network.
class _FakeHttp extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value('{}'.codeUnits),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Widget _host() => Provider<ApiClient>.value(
      value: ApiClient(client: _FakeHttp()),
      child: const MaterialApp(home: CreateCafeScreen()),
    );

/// The Add-cafe form is long, so give it a tall viewport to mount every field
/// (including the Create button at the bottom).
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('Add-cafe form has password + confirm-password inputs',
      (tester) async {
    _tallViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Regression guard: these are the fields an admin needs to set the owner's
    // login. Both must render.
    expect(find.text('Owner password *'), findsOneWidget);
    expect(find.text('Confirm password *'), findsOneWidget);
    // Sanity: every field of the form mounted (cafe code, name, username,
    // password, confirm, full name, GSTIN, PAN, licence, address, phone).
    expect(find.byType(TextFormField), findsNWidgets(11));
  });

  testWidgets('empty submit shows validation errors', (tester) async {
    _tallViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.pumpAndSettle();

    // Required-field errors appear (validation actually fires).
    expect(find.text('Cafe code is required'), findsOneWidget);
    expect(find.text('Owner password is required'), findsOneWidget);
    expect(find.text('Please re-enter the password'), findsOneWidget);
    // Short password is rejected too.
    expect(find.text('Owner password must be at least 6 characters'),
        findsNothing);
  });

  testWidgets('mismatched passwords are rejected', (tester) async {
    _tallViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    // index 3 = Owner password, index 4 = Confirm password.
    await tester.enterText(fields.at(3), 'secret123');
    await tester.enterText(fields.at(4), 'secret456');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.pumpAndSettle();

    expect(find.text("Passwords don't match"), findsOneWidget);
  });

  testWidgets('matching passwords do not show a mismatch error',
      (tester) async {
    _tallViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(3), 'secret123');
    await tester.enterText(fields.at(4), 'secret123');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create cafe'));
    await tester.pumpAndSettle();

    expect(find.text("Passwords don't match"), findsNothing);
    // Still blocked by other empty required fields (cafe code / name / user).
    expect(find.text('Cafe code is required'), findsOneWidget);
  });
}
