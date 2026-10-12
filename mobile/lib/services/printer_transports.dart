/// Platform-conditional printer transports.
///
/// The conditional export picks the real implementations (`dart:io` VM and
/// mobile targets: raw TCP, USB serial, thermal Bluetooth) or the throwing
/// web stub, so callers can `import 'printer_transports.dart'` and use one
/// API everywhere without `kIsWeb` branches at the call site.
library;

export 'printer_transports_stub.dart'
    if (dart.library.io) 'printer_transports_io.dart';
