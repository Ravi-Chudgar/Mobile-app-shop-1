/// Real printer transports for the io (VM) targets the mobile app runs on:
/// raw TCP to a network ESC/POS printer, USB serial via `usb_serial`, and
/// Bluetooth thermal via `print_bluetooth_thermal`.
///
/// Every failure is reported as a [PrinterException] with a message that is
/// safe to surface verbatim in the UI. Selected by the conditional export in
/// `printer_transports.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'printer_models.dart';

export 'printer_models.dart';

/// The plugin does not request Android 12+ runtime permissions itself and its
/// method calls never complete when [android.permission.BLUETOOTH_CONNECT] is
/// missing, so guard every Bluetooth call with an explicit check.
Future<void> _ensureBluetoothPermission() async {
  try {
    final granted = await PrintBluetoothThermal.isPermissionBluetoothGranted
        .timeout(const Duration(seconds: 5));
    if (!granted) {
      throw PrinterException(
          'Bluetooth permission not granted — allow "Nearby devices" for '
          'this app in Android Settings, then try again.');
    }
  } on PrinterException {
    rethrow;
  } catch (e) {
    throw PrinterException('Bluetooth permission check failed: $e');
  }
}

Future<void> sendNetwork(String host, int port, Uint8List bytes) async {
  Socket? socket;
  try {
    socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 4));
    socket.add(bytes);
    await socket.flush();
  } on SocketException catch (e) {
    throw PrinterException('Network printer unreachable: ${e.message}');
  } finally {
    await socket?.close();
  }
}

Future<List<UsbPrinterDevice>> listUsbDevices() async {
  try {
    final devices = await UsbSerial.listDevices();
    return devices
        .map((d) => UsbPrinterDevice(
              label: d.productName ?? 'USB Device',
              vendorId: d.vid ?? 0,
              productId: d.pid ?? 0,
              deviceId: d.deviceId ?? 0,
            ))
        .toList();
  } catch (e) {
    throw PrinterException('USB scan failed: $e');
  }
}

Future<void> sendUsb(int deviceId, Uint8List bytes) async {
  UsbPort? port;
  try {
    final devices = await UsbSerial.listDevices();
    final device = devices.firstWhere(
      (d) => d.deviceId == deviceId,
      orElse: () => throw PrinterException('USB device not found'),
    );
    port = await device.create();
    final opened = await port!.open();
    if (!opened) throw PrinterException('Could not open USB port');
    port.setDTR(true);
    port.setRTS(true);
    await port.setPortParameters(
        9600, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    await port.write(Uint8List.fromList(bytes));
  } on PrinterException {
    rethrow;
  } catch (e) {
    throw PrinterException('USB print failed: $e');
  } finally {
    await port?.close();
  }
}

Future<List<BtPrinterDevice>> listBluetoothPrinters() async {
  await _ensureBluetoothPermission();
  try {
    final connected = await PrintBluetoothThermal.pairedBluetooths
        .timeout(const Duration(seconds: 15));
    return connected
        .map((b) => BtPrinterDevice(
              name: b.name,
              address: b.macAdress,
            ))
        .toList();
  } on PrinterException {
    rethrow;
  } catch (e) {
    throw PrinterException('Bluetooth scan failed: $e');
  }
}

Future<void> sendBluetooth(String address, Uint8List bytes) async {
  await _ensureBluetoothPermission();
  try {
    final connected =
        await PrintBluetoothThermal.connect(macPrinterAddress: address)
            .timeout(const Duration(seconds: 10));
    if (!connected) {
      throw PrinterException(
          'Could not connect to Bluetooth printer at $address');
    }
    final ok = await PrintBluetoothThermal.writeBytes(bytes)
        .timeout(const Duration(seconds: 10));
    if (!ok) throw PrinterException('Bluetooth write failed');
    await PrintBluetoothThermal.disconnect;
  } on PrinterException {
    rethrow;
  } catch (e) {
    throw PrinterException('Bluetooth print failed: $e');
  }
}
