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
