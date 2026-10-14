/// Data types shared by every printer transport.
///
/// [PrinterException] carries the human-readable reason a print failed;
/// [UsbPrinterDevice] and [BtPrinterDevice] describe a discovered printer
/// well enough to show it in the picker and reconnect to it later.
library;

class PrinterException implements Exception {
  final String message;
  PrinterException(this.message);
  @override
  String toString() => message;
}

class UsbPrinterDevice {
  final String label;
  final int vendorId;
  final int productId;
  final int deviceId;

  const UsbPrinterDevice({
    required this.label,
    required this.vendorId,
    required this.productId,
    required this.deviceId,
  });

  @override
  String toString() => label;
}

class BtPrinterDevice {
  final String name;
  final String address;

  const BtPrinterDevice({required this.name, required this.address});

  @override
  String toString() => name;
}

/// A raw ESC/POS printer discovered on the local (Wi-Fi) network.
///
/// [host] is the printer's IP and [port] its raw-print port (9100/9101),
/// which is exactly what [PrinterSettings.host]/[PrinterSettings.port]
/// need for direct network printing.
class NetPrinterDevice {
  final String host;
  final int port;

  const NetPrinterDevice({required this.host, required this.port});

  @override
  String toString() => '$host:$port';
}
