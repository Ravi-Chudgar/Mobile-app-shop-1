/// Web fallback for `printer_transports.dart`.
///
/// `dart:io` sockets and the USB/Bluetooth plugins do not exist in the
/// browser, so every transport fails fast with a [PrinterException] telling
/// the user to print from the Android app instead.
library;

import 'dart:typed_data';

import 'printer_models.dart';

export 'printer_models.dart';

Future<void> sendNetwork(String host, int port, Uint8List bytes) async {
  throw PrinterException('Available in the Android app.');
}

Future<List<UsbPrinterDevice>> listUsbDevices() async {
  throw PrinterException('Available in the Android app.');
}

Future<void> sendUsb(int deviceId, Uint8List bytes) async {
  throw PrinterException('Available in the Android app.');
}

Future<List<BtPrinterDevice>> listBluetoothPrinters() async {
  throw PrinterException('Available in the Android app.');
}

Future<void> sendBluetooth(String address, Uint8List bytes) async {
  throw PrinterException('Available in the Android app.');
}

Future<List<NetPrinterDevice>> scanNetwork() async {
  throw PrinterException('Available in the Android app.');
}
