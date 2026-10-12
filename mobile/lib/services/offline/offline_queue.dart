/// Durable queue for mutations captured while the device is offline.
///
/// Each [PendingOp] is written to SharedPreferences as JSON before it is
/// attempted, replayed in insertion order by [OfflineQueue.flush] once
/// connectivity returns, and only then discarded — an app kill mid-flight
/// leaves the operation pending for the next launch. [isConnectivityError]
/// separates "retry later" (no network / 5xx) from a genuine API rejection.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';

/// Thrown by screens when the connectivity monitor already says the device
/// is offline — skips waiting for an HTTP timeout before queueing.
class DeviceOfflineException implements Exception {
  const DeviceOfflineException();
  @override
  String toString() => 'You are offline';
}

/// True when [error] means "the network/backend is unreachable" — the signal
/// to queue an operation instead of failing the UX. A real API rejection
/// (4xx with a message) is NOT a connectivity problem.
bool isConnectivityError(Object error) {
  if (error is DeviceOfflineException) return true;
  if (error is ApiException) {
    final code = error.statusCode;
    return code == null || code >= 500;
  }
  return error is SocketException || error is TimeoutException;
}

/// One mutation captured while offline, waiting to be replayed on the server.
class PendingOp {
  PendingOp({
    required this.opId,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.retries = 0,
    this.nextAttemptAt = 0,
    String? localId,
  }) : localId = localId ?? localIdFor(opId);

  /// Client-generated uuid. The server dedupes replays on this id, so a
  /// retried batch can never create the order twice.
  final String opId;

  /// Sync op type ("order_create" is the MVP).
  final String type;

  /// Exactly what the online endpoint would have received (payments are
  /// never queued — collect stays online-only).
  final Map<String, dynamic> payload;

  final String createdAt;
  int retries;
  int nextAttemptAt;

  /// Why the server last refused this op (e.g. "Table already occupied") —
  /// shown on the pending card until a later replay succeeds.
  String? lastError;

  /// Device-local display id ("OFF-3F2A1C") shown until the server order id
  /// replaces it after a successful flush.
  final String localId;

  static String localIdFor(String opId) {
    final hex = opId.replaceAll('-', '').toUpperCase();
    final end = hex.length < 6 ? hex.length : 6;
    return 'OFF-${hex.substring(0, end)}';
  }

  String? get tableNumber {
    final table = payload['table_number'];
    return table == null ? null : '$table';
  }

  int get itemCount {
    final items = payload['items'];
    if (items is! List) return 0;
    var total = 0;
    for (final line in items) {
      if (line is Map && line['qty'] is num) {
        total += (line['qty'] as num).toInt();
      }
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
        'op_id': opId,
        'type': type,
        'payload': payload,
        'created_at': createdAt,
        'retries': retries,
        'next_attempt_at': nextAttemptAt,
        'local_id': localId,
        'last_error': lastError,
      };

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
        opId: json['op_id'] as String,
        type: json['type'] as String,
        payload: Map<String, dynamic>.from((json['payload'] as Map?) ?? {}),
        createdAt: json['created_at'] as String? ?? '',
        retries: (json['retries'] as num?)?.toInt() ?? 0,
        nextAttemptAt: (json['next_attempt_at'] as num?)?.toInt() ?? 0,
        localId: json['local_id'] as String?,
      )..lastError = json['last_error'] as String?;
}

/// Outcome of one [OfflineQueue.flush] pass.
class FlushResult {
  const FlushResult({
    this.applied = 0,
    this.deduped = 0,
    this.failed = 0,
    this.remaining = 0,
    this.attempted = false,
  });

  /// Ops the server created (or recognised as a replay).
  final int applied;
  final int deduped;

  /// Ops the server rejected — kept in the queue with backoff.
  final int failed;

  /// Ops still waiting after this pass.
  final int remaining;

  /// Whether a batch was actually sent (false: no session / already running).
  final bool attempted;
}

/// Durable FIFO mutation queue (offline-first sync).
///
/// Ops are persisted in [SharedPreferences] so they survive an app restart,
/// replayed against `POST /sync/batch` in order, and removed only once the
/// server reports them `applied`/`deduped`. Per-op errors are kept and
/// retried with capped exponential backoff (2s .. 5min).
class OfflineQueue {
  OfflineQueue._();

  static final OfflineQueue instance = OfflineQueue._();

  static const String storageKey = 'offline_queue_v1';

  /// Keep in sync with backend `SYNC_MAX_BATCH` (default 50).
  static const int maxBatch = 50;

  static const int _maxChunksPerFlush = 10;
  static const Duration _maxBackoff = Duration(minutes: 5);

  /// Live count for the app-bar badge (0 = everything synced).
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// local temp id -> server order id, filled while flushing so screens can
  /// reconcile an "Order OFF-1A2B3C" with the real order.
  final Map<String, String> localToServerOrderId = <String, String>{};

  final List<PendingOp> _ops = <PendingOp>[];
  ApiClient? _api;
  Future<void>? _loading;
  bool _flushing = false;
  Timer? _retryTimer;
  static final Random _rng = Random();

  /// All queued ops (FIFO).
  List<PendingOp> get ops => List<PendingOp>.unmodifiable(_ops);

  /// Queued offline orders — the staff order queue renders these with a
  /// "pending sync" chip.
  List<PendingOp> get pendingOrderOps =>
      List<PendingOp>.unmodifiable(_ops.where((o) => o.type == 'order_create'));

  int get pending => _ops.length;

  /// Server order for a local id, once that op has synced this session.
  String? serverOrderIdFor(String localId) => localToServerOrderId[localId];

  /// Clear all in-memory state (tests only).
  @visibleForTesting
  void debugReset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _ops.clear();
    localToServerOrderId.clear();
    _flushing = false;
    _api = null;
    _loading = null;
  }

  /// Remember the API client (bearer token included) so reconnect flushes
  /// can run without a BuildContext. Call from the shared app bar.
  void bind(ApiClient api) => _api = api;

  /// Load the persisted queue (idempotent; safe before the first use).
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              try {
                _ops.add(PendingOp.fromJson(Map<String, dynamic>.from(entry)));
              } catch (_) {
                // Corrupt entry — drop it rather than poison the queue.
              }
            }
          }
        }
      }
    } catch (_) {
      // Storage unavailable (e.g. widget tests): run from memory only.
    }
    _sort();
    _notify();
  }

  /// Queue an operation for later replay. Returns the op (with its local id)
  /// so the UI can confirm "saved offline" straight away.
  Future<PendingOp> enqueue({
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    await init();
    final now = DateTime.now().toUtc();
    final op = PendingOp(
      opId: _newUuid(),
      type: type,
      payload: payload,
      createdAt: now.toIso8601String(),
      nextAttemptAt: now.millisecondsSinceEpoch,
    );
    _ops.add(op);
    _sort();
    _notify();
    await _persist();
    // A short-while flush covers "the backend blipped while the network
    // still looked fine"; reconnects are flushed by ConnectivityMonitor.
    _scheduleRetry(const Duration(seconds: 1));
    return op;
  }

  /// Replay everything that is due. [api] defaults to the bound client.
  Future<FlushResult> flush([ApiClient? api]) async {
    await init();
    final client = api ?? _api;
    if (client != null) bind(client);
    if (client == null || client.token == null) {
      // No session to replay under (e.g. a customer QR device): keep queued.
      return const FlushResult();
    }
    if (_flushing) return const FlushResult();
    _flushing = true;
    var applied = 0, deduped = 0, failed = 0;
    var attempted = false;
    try {
      for (var chunk = 0; chunk < _maxChunksPerFlush; chunk++) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final due =
            _ops.where((o) => o.nextAttemptAt <= now).take(maxBatch).toList();
        if (due.isEmpty) break;
        attempted = true;

        List<dynamic> results;
        try {
          final body = await client.syncBatch([
            for (final op in due)
              {'op_id': op.opId, 'type': op.type, 'payload': op.payload},
          ]);
          results = (body['results'] as List?) ?? const <dynamic>[];
        } on ApiException catch (e) {
          // Whole request failed (offline / 5xx / auth): keep everything
          // queued with backoff and retry later.
          for (final op in due) {
            op.lastError = e.message;
          }
          _backoffAll(due);
          break;
        }

        final byId = <String, Map<String, dynamic>>{};
        for (final raw in results) {
          if (raw is Map) {
            byId['${raw['op_id']}'] = Map<String, dynamic>.from(raw);
          }
        }

        var progressed = false;
        for (final op in List<PendingOp>.of(due)) {
          final result = byId[op.opId];
          final status = result == null ? null : '${result['status']}';
          if (status == 'applied' || status == 'deduped') {
            final orderId = result?['order_id'];
            if (orderId is String) {
              localToServerOrderId[op.localId] = orderId;
            }
            if (status == 'applied') applied++;
            // A deduped result is also a success: the server already has it.
            if (status == 'deduped') deduped++;
            _ops.remove(op);
            progressed = true;
          } else {
            // Per-op error (occupied table, bad payload ...): keep + backoff.
            failed++;
            final error = result == null ? null : result['error'];
            op.lastError = error is String ? error : 'Could not sync';
            _backoffOp(op);
          }
        }
        if (progressed) await _persist();
        if (due.length < maxBatch) break; // nothing else due right now
      }
    } catch (_) {
      // Unexpected failure — never lose the queue.
      _backoffAll(List<PendingOp>.of(_ops));
    } finally {
      _flushing = false;
      _notify();
      _scheduleRetry();
    }
    return FlushResult(
      applied: applied,
      deduped: deduped,
      failed: failed,
      remaining: _ops.length,
      attempted: attempted,
    );
  }

  // --------------------------------------------------------------------- //

  void _sort() {
    _ops.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  void _notify() {
    if (pendingCount.value != _ops.length) {
      pendingCount.value = _ops.length;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          storageKey, jsonEncode([for (final op in _ops) op.toJson()]));
    } catch (_) {
      // Best effort: this session's in-memory queue still flushes.
    }
  }

  void _backoffOp(PendingOp op) {
    op.retries++;
    final shift = op.retries > 8 ? 8 : op.retries;
    var ms = 2000 * (1 << shift);
    if (ms > _maxBackoff.inMilliseconds) ms = _maxBackoff.inMilliseconds;
    op.nextAttemptAt = DateTime.now().millisecondsSinceEpoch + ms;
  }

  void _backoffAll(List<PendingOp> ops) {
    for (final op in ops) {
      _backoffOp(op);
    }
  }

  /// Arm a single timer for the next retry (capped exponential backoff).
  void _scheduleRetry([Duration? force]) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (force != null) {
      if (_ops.isNotEmpty) {
        _retryTimer = Timer(force, _retryFlush);
      }
      return;
    }
    if (_ops.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var next = now + _maxBackoff.inMilliseconds;
    for (final op in _ops) {
      if (op.nextAttemptAt < next) next = op.nextAttemptAt;
    }
    var delay = next - now;
    if (delay < 500) delay = 500;
    if (delay > _maxBackoff.inMilliseconds) delay = _maxBackoff.inMilliseconds;
    _retryTimer = Timer(Duration(milliseconds: delay), _retryFlush);
  }

  void _retryFlush() {
    _retryTimer = null;
    unawaited(flush());
  }

  /// RFC-4122 v4 uuid, generated locally (no extra dependency).
  String _newUuid() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
