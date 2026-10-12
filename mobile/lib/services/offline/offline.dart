/// Offline-first sync surface: durable mutation queue, last-good menu cache,
/// and the connectivity monitor that flushes one when the network returns.
///
/// Screens import this barrel rather than reaching into the individual
/// files.
library;

export 'connectivity_monitor.dart';
export 'menu_cache.dart';
export 'offline_queue.dart';
