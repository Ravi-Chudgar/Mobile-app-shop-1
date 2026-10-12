import 'dart:convert';
import 'dart:io';

import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/services/offline/offline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OfflineQueue queue;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    queue = OfflineQueue.instance;
    queue.debugReset();
    await queue.init();
  });

  ApiClient clientReturning(Map<String, dynamic> body) => ApiClient(
        client: MockClient((request) async => http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            )),
      )..token = 'test-token';

  test('enqueue keeps FIFO order and bumps pendingCount', () async {
    final a = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '1'});
    final b = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '2'});

    expect(queue.pending, 2);
    expect(queue.ops.first.opId, a.opId);
    expect(queue.ops.last.opId, b.opId);
    expect(a.localId, startsWith('OFF-'));
    expect(queue.pendingOrderOps.length, 2);
  });

  test('queue is persisted to SharedPreferences on enqueue', () async {
    final op = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '7'});
    final raw = SharedPreferences.getInstance()
        .then((p) => p.getString(OfflineQueue.storageKey));
    expect(await raw, contains(op.opId));
  });

  test('queue survives a restart (reloaded from storage)', () async {
    final op = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '9'});
    queue.debugReset();
    expect(queue.pending, 0);
    await queue.init();
    expect(queue.pending, 1);
    expect(queue.ops.first.opId, op.opId);
  });

  test('flush applies queued ops and clears them', () async {
    final op = await queue.enqueue(type: 'order_create', payload: {
      'table_number': '3',
      'items': [
        {'item_id': 'espresso', 'qty': 2}
      ],
    });
    final api = clientReturning({
      'server_time': '2026-01-01T00:00:00+00:00',
      'results': [
        {
          'op_id': op.opId,
          'status': 'applied',
          'order_id': 'abc123',
        },
      ],
    });

    final result = await queue.flush(api);

    expect(result.applied, 1);
    expect(result.attempted, isTrue);
    expect(queue.pending, 0);
    expect(queue.serverOrderIdFor(op.localId), 'abc123');
  });

  test('flush treats a replay (deduped) as success', () async {
    final op = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '4'});
    final api = clientReturning({
      'results': [
        {
          'op_id': op.opId,
          'status': 'deduped',
          'order_id': 'original-1',
          'deduped': true,
        },
      ],
    });

    final result = await queue.flush(api);

    expect(result.deduped, 1);
    expect(result.applied, 0);
    expect(queue.pending, 0);
    expect(queue.serverOrderIdFor(op.localId), 'original-1');
  });

  test('per-op server error keeps the op queued with its message', () async {
    final op = await queue
        .enqueue(type: 'order_create', payload: {'table_number': '5'});
    final api = clientReturning({
      'results': [
        {
          'op_id': op.opId,
          'status': 'error',
          'error': 'Table already occupied',
        },
      ],
    });

    final result = await queue.flush(api);

    expect(result.failed, 1);
    expect(queue.pending, 1);
    expect(queue.ops.first.lastError, 'Table already occupied');
    // Backoff: not due again immediately.
    expect(queue.ops.first.nextAttemptAt,
        greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('connectivity failure keeps the whole batch queued', () async {
    await queue.enqueue(type: 'order_create', payload: {'table_number': '6'});
    final api = ApiClient(
      client: MockClient((_) async => throw const SocketException('down')),
    )..token = 'test-token';

    final result = await queue.flush(api);

    expect(result.attempted, isTrue);
    expect(result.applied, 0);
    expect(queue.pending, 1);
  });

  test('flush without a session keeps ops queued (no token)', () async {
    await queue.enqueue(type: 'order_create', payload: {'table_number': '8'});
    final api =
        ApiClient(client: MockClient((_) async => http.Response('', 200)));
    // No token set: nothing may be sent, nothing may be lost.
    final result = await queue.flush(api);
    expect(result.attempted, isFalse);
    expect(queue.pending, 1);
  });

  test('isConnectivityError distinguishes outages from rejections', () {
    expect(isConnectivityError(const DeviceOfflineException()), isTrue);
    expect(
        isConnectivityError(ApiException('Cannot reach the server.')), isTrue);
    expect(isConnectivityError(ApiException('boom', statusCode: 500)), isTrue);
    expect(isConnectivityError(ApiException('occupied', statusCode: 409)),
        isFalse);
    expect(isConnectivityError(ApiException('nope', statusCode: 401)), isFalse);
  });

  test('ConnectivityMonitor notifies the reconnect callback once online',
      () async {
    var flushed = 0;
    ConnectivityMonitor.instance.debugSetOnline(false);
    ConnectivityMonitor.instance.start(onOnline: () => flushed++);
    // Simulate the network coming back (plugin unavailable in tests, so the
    // monitor stays on its optimistic default; drive it directly).
    ConnectivityMonitor.instance.debugSetOnline(true);
    ConnectivityMonitor.instance.debugSetOnline(true); // no second flip
    expect(flushed, 1);
    ConnectivityMonitor.instance.debugSetOnline(false);
    ConnectivityMonitor.instance.debugSetOnline(true);
    expect(flushed, 2);
  });
}
