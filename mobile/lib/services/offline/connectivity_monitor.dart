/// Connectivity watcher behind the offline banner and the queue flush.
///
/// Wraps `connectivity_plus` in a singleton with an optimistic online
/// default, a [ValueNotifier] the UI can listen to, and an `onOnline`
/// callback fired the moment the network comes back so the offline queue can
/// drain.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Watches device connectivity.
///
/// * [isOnline] — ValueNotifier the UI listens to (offline banner).
/// * The callback given to [start] fires the moment the network comes back,
///   which is when the offline queue flushes.
class ConnectivityMonitor {
  ConnectivityMonitor._();

  static final ConnectivityMonitor instance = ConnectivityMonitor._();

  /// Optimistic default: assume online until the platform says otherwise
  /// (also the right default where the plugin is unavailable, e.g. tests).
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  bool _started = false;
  void Function()? _onOnline;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// Start listening. Safe to call from every screen: only the first call
  /// subscribes; later calls just update the reconnect callback.
  Future<void> start({void Function()? onOnline}) async {
    if (onOnline != null) _onOnline = onOnline;
    if (_started) return;
    _started = true;
    try {
      final connectivity = Connectivity();
      final initial = await connectivity.checkConnectivity();
      _apply(initial);
      _subscription = connectivity.onConnectivityChanged.listen(
        _apply,
        // Platform stream unavailable (widget tests, odd platforms):
        // ignore and keep the optimistic default.
        onError: (Object _) {},
      );
    } catch (_) {
      // No connectivity plugin here — stay optimistic (online).
    }
  }

  /// Stop listening (tests / hot restart).
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
  }

  void _apply(List<ConnectivityResult> results) {
    try {
      final wasOnline = isOnline.value;
      final online = results.isNotEmpty &&
          results.any((r) => r != ConnectivityResult.none);
      if (online != isOnline.value) {
        isOnline.value = online;
      }
      if (online && !wasOnline) {
        // Back online: let the queue replay everything it held.
        _onOnline?.call();
      }
    } catch (_) {
      // A listener/callback must never crash the app.
    }
  }

  /// For tests / manual overrides.
  void debugSetOnline(bool value) {
    final wasOnline = isOnline.value;
    isOnline.value = value;
    if (value && !wasOnline) _onOnline?.call();
  }
}
