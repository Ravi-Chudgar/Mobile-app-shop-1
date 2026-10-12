import 'dart:convert';

import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/state/tenant_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Records every request and answers with a canned JSON body.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.body);

  final String body;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

const _orderJson = '{"id":"A1","items":[],"total":0,"table_number":"3",'
    '"customer":{"name":"Ravi","phone":"9999999999"},'
    '"status":"received","created_at":"2026-01-01T00:00:00"}';

void main() {
  group('tenant-scoped public endpoints', () {
    test('fall back to the legacy paths when no cafe code is set', () async {
      final client = _RecordingClient('[]');
      final api = ApiClient(client: client);

      await api.fetchPublicMenu();
      await api.fetchPublicMenu(tenant: 'bean');
      await api.fetchPublicMenu(tenant: '  ');

      expect(
        [for (final r in client.requests) r.url.path],
        ['/public/menu', '/public/bean/menu', '/public/menu'],
      );
    });

    test('orders and tracking carry the cafe code', () async {
      final client = _RecordingClient(_orderJson);
      final api = ApiClient(client: client);

      await api.placePublicOrder(
        tableNumber: '3',
        items: [
          {'item_id': 'espresso', 'qty': 1}
        ],
        name: 'Ravi',
        phone: '9999999999',
      );
      await api.placePublicOrder(
        tableNumber: '3',
        items: [
          {'item_id': 'espresso', 'qty': 1}
        ],
        name: 'Ravi',
        phone: '9999999999',
        tenant: 'bean',
      );
      await api.fetchPublicOrder('A1');
      await api.fetchPublicOrder('A1', tenant: 'bean');

      expect(
        [for (final r in client.requests) r.url.path],
        [
          '/public/orders',
          '/public/bean/orders',
          '/public/orders/A1',
          '/public/bean/orders/A1',
        ],
      );
    });

    test('QR cards and tenant config are scoped too', () async {
      final client = _RecordingClient(
          '{"table_number":"3","url":"https://x/t/bean/table/3"}');
      final api = ApiClient(client: client);

      await api.publicTableQr('3');
      await api.publicTableQr('3', tenant: 'bean');
      await api.fetchTableQrUrl('3', tenant: 'bean');
      await api.fetchTenantConfig('bean');

      expect(
        [for (final r in client.requests) r.url.path],
        [
          '/public/qr/3',
          '/public/bean/qr/3',
          '/public/bean/qr/3',
          '/public/bean/config',
        ],
      );
      expect(
        client.requests.map((r) => r.url.queryParameters['format']).toList(),
        ['json', 'json', 'json', null],
      );
    });

    test('login only sends a tenant field when one was typed', () async {
      final client = _RecordingClient(
          '{"token":"t","role":"owner","username":"owner","name":"Owner",'
          '"tenant":"bean"}');
      final api = ApiClient(client: client);

      final result = await api.login('owner', 'cafe123', tenant: 'bean');
      final withTenant =
          jsonDecode((client.requests.single as http.Request).body)
              as Map<String, dynamic>;
      expect(withTenant['tenant'], 'bean');
      expect(result['tenant'], 'bean');

      client.requests.clear();
      await api.login('owner', 'cafe123');
      final withoutTenant =
          jsonDecode((client.requests.single as http.Request).body)
              as Map<String, dynamic>;
      expect(withoutTenant.containsKey('tenant'), isFalse);
    });
  });

  group('TenantState', () {
    test('loadFor fills the public branding subset', () async {
      final client = _RecordingClient('{"display_name":"Bean House Cafe",'
          '"kind":"cafe","bill_footer":"Thank you, come again"}');
      final state = TenantState(ApiClient(client: client));

      await state.loadFor('bean');

      expect(state.slug, 'bean');
      expect(state.displayName, 'Bean House Cafe');
      expect(state.kind, 'cafe');
      expect(state.billFooter, 'Thank you, come again');
      expect(state.hasBranding, isTrue);
      expect(client.requests.single.url.path, '/public/bean/config');
    });

    test('a failed lookup stays silent and leaves branding empty', () async {
      final failing = _FailingClient();
      final state = TenantState(ApiClient(client: failing));

      await state.loadFor('nope');

      expect(state.hasBranding, isFalse);
      expect(state.displayName, isEmpty);
    });

    test('a blank code resolves to the default cafe', () async {
      final client = _RecordingClient('{"display_name":"Main Cafe"}');
      final state = TenantState(ApiClient(client: client));

      await state.loadFor(null);

      expect(state.slug, TenantState.defaultSlug);
      expect(client.requests.single.url.path, '/public/main/config');
    });
  });
}

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":"Unknown tenant"}')),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}
