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

import 'package:permission_handler/permission_handler.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'printer_models.dart';

export 'printer_models.dart';

/// The `print_bluetooth_thermal` plugin does not request Android 12+ runtime
/// permissions itself and its method calls never complete when
/// [android.permission.BLUETOOTH_CONNECT] is missing, so guard every Bluetooth
/// call with an explicit check using `permission_handler`.
///
/// This function checks and requests all required Bluetooth and location
/// permissions. Returns normally if all permissions are granted, or throws
/// a [PrinterException] if the user denies the permissions.
Future<void> _ensureBluetoothPermission() async {
  // Check and request BLUETOOTH_SCAN permission (Android 12+ / API 31)
  var bluetoothScanStatus = await Permission.bluetoothScan.status;
  if (!bluetoothScanStatus.isGranted) {
    bluetoothScanStatus = await Permission.bluetoothScan.request();
  }

  // Check and request BLUETOOTH_CONNECT permission (Android 12+ / API 31)
  var bluetoothConnectStatus = await Permission.bluetoothConnect.status;
  if (!bluetoothConnectStatus.isGranted) {
    bluetoothConnectStatus = await Permission.bluetoothConnect.request();
  }

  // Location permission is often required for Bluetooth on Android
  var locationStatus = await Permission.location.status;
  if (!locationStatus.isGranted) {
    locationStatus = await Permission.location.request();
  }

  // Also check coarse location
  var locationCoarseStatus = await Permission.locationAlways.status;
  if (!locationCoarseStatus.isGranted) {
    locationCoarseStatus = await Permission.locationAlways.request();
  }

  // Verify all required permissions are granted
  if (bluetoothScanStatus.isGranted &&
      bluetoothConnectStatus.isGranted &&
      locationStatus.isGranted) {
    // All permissions granted - proceed with Bluetooth operations
    return;
  } else {
    // Permission denied - throw a clear exception for the UI
    throw PrinterException(
        'Bluetooth permission not granted — allow "Nearby devices" and '
        '"Location" permissions for this app in Android Settings, then try again.');
  }
}

/// List previously paired Bluetooth thermal printers.
/// Returns an empty list instead of crashing if permissions are not granted.
Future<List<BtPrinterDevice>> listBluetoothPrinters() async {
  try {
    await _ensureBluetoothPermission();
    final connected =
        await PrintBluetoothThermal.pairedBluetooths
            .timeout(const Duration(seconds: 15));
    return connected
        .map((b) => BtPrinterDevice(
              name: b.name,
              address: b.macAdress,
            ))
        .toList();
  } on PrinterException {
    // Re-throw so the caller can decide what to show the user
    rethrow;
  } catch (e) {
    // Return empty list rather than crashing the app
    // This handles permission denied, plugin errors, and other failures gracefully
    return [];
  }
}

/// Send data to a network ESC/POS printer.
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

/// List USB connected printers.
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

/// Send data to a USB printer.
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

/// Send data to a Bluetooth thermal printer.
/// Returns empty list on failure instead of crashing.
Future<void> sendBluetooth(String address, Uint8List bytes) async {
  try {
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
  } catch (e) {
    throw PrinterException('Bluetooth operation failed: $e');
  }
}