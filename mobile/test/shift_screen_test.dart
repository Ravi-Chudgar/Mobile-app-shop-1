import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cafe_app/screens/staff/shift_screen.dart';
import 'package:cafe_app/services/api_client.dart';

/// Mock response built the way a real server delivers JSON: UTF-8 bytes with
/// an explicit charset. Plain `http.Response(String)` would latin1-encode the
/// body and throw on non-ASCII characters (the em-dash in the 409 message),
/// which is exactly the encoding bug the API client's UTF-8 decoding fixes.
http.Response _json(Object? data, int status) => http.Response(
      jsonEncode(data),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _record({required String status, String? clockOutLocal}) =>
    {
      'record': {
        'username': 'priya',
        'date': '2026-10-17',
        'clock_in': '2026-10-17T04:33:00+00:00',
        'clock_in_local': '10:03',
        'clock_out':
            clockOutLocal == null ? null : '2026-10-17T12:00:00+00:00',
        'clock_out_local': clockOutLocal,
        'status': status,
      },
    };

Widget _wrap(ApiClient api) => MaterialApp(
      home: Scaffold(
        body: Provider<ApiClient>.value(
          value: api,
          child: const ShiftScreen(),
        ),
      ),
    );

void main() {
  testWidgets('not clocked in -> Clock in button; tapping it flips to the '
      'locked state with a Clock out button', (tester) async {
    var clockedIn = false;
    final api = ApiClient(client: MockClient((request) async {
      if (request.method == 'GET') {
        return _json(
            clockedIn ? _record(status: 'in') : {'record': null}, 200);
      }
      if (request.url.path.endsWith('/attendance/clock-in')) {
        clockedIn = true;
        return _json(_record(status: 'in'), 201);
      }
      return _json({'error': 'unexpected route'}, 500);
    }));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Clock in'), findsOneWidget);
    expect(find.text('Clock out'), findsNothing);

    await tester.tap(find.text('Clock in'));
    await tester.pumpAndSettle();
    // Let the confirmation SnackBar fade so only the card's copy remains.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Immutable state: the start button is gone, only Clock out remains.
    expect(find.text('Clock in'), findsNothing);
    expect(find.text('Clock out'), findsOneWidget);
    expect(find.text('Clocked in at 10:03'), findsOneWidget);
    expect(find.textContaining('cannot be edited'), findsOneWidget);
  });

  testWidgets('server refuses a duplicate clock-in (409): error is shown and '
      'the existing record takes over', (tester) async {
    var loads = 0;
    final api = ApiClient(client: MockClient((request) async {
      if (request.method == 'GET') {
        loads += 1;
        return _json(
            loads == 1 ? {'record': null} : _record(status: 'in'), 200);
      }
      if (request.url.path.endsWith('/attendance/clock-in')) {
        return _json({
          'error':
              'Already clocked in at 10:03 — a recorded clock-in cannot be '
                  'changed'
        }, 409);
      }
      return _json({'error': 'unexpected route'}, 500);
    }));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Clock in'), findsOneWidget);
    await tester.tap(find.text('Clock in'));
    await tester.pumpAndSettle();

    // The server's explanation is surfaced (em-dash and all)...
    expect(find.textContaining('cannot be changed'), findsWidgets);
    // ...and the state resyncs to the record that already exists: Clock out
    // is offered instead of a retry.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Clock out'), findsOneWidget);
  });

  testWidgets('clocked-out day is read-only: times shown, no action buttons',
      (tester) async {
    final api = ApiClient(
        client: MockClient((request) async =>
            _json(_record(status: 'out', clockOutLocal: '17:30'), 200)));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Shift complete'), findsOneWidget);
    expect(find.textContaining('In 10:03'), findsOneWidget);
    expect(find.text('Clock in'), findsNothing);
    expect(find.text('Clock out'), findsNothing);
  });

  testWidgets('clocking out asks for confirmation first', (tester) async {
    var clockedOut = false;
    final api = ApiClient(client: MockClient((request) async {
      if (request.method == 'GET') {
        return _json(
            clockedOut
                ? _record(status: 'out', clockOutLocal: '17:30')
                : _record(status: 'in'),
            200);
      }
      if (request.url.path.endsWith('/attendance/clock-out')) {
        clockedOut = true;
        return _json(_record(status: 'out', clockOutLocal: '17:30'), 200);
      }
      return _json({'error': 'unexpected route'}, 500);
    }));

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clock out'));
    await tester.pumpAndSettle();
    // Nothing sent yet — the confirm dialog is up.
    expect(find.text('Clock out now?'), findsOneWidget);
    expect(clockedOut, isFalse);

    await tester.tap(find.text('Clock out').last);
    await tester.pumpAndSettle();

    expect(clockedOut, isTrue);
    expect(find.text('Shift complete'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
