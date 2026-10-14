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

/// Check and request Bluetooth permissions for the current platform.
///
/// This function requests the necessary Bluetooth permissions depending on the
/// platform:
///
/// - **Android 12+ (API 31)** : Requests `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`,
///   and `Location` permissions. All three must be granted for Bluetooth scanning
///   and connections to work.
/// - **iOS 13+** : Checks the current Bluetooth permission status. The first time
///   the app uses Bluetooth, iOS shows a system permission dialog whose message
///   is defined by `NSBluetoothUsageDescription` in Info.plist (already configured).
///   If the user has previously denied, the setting can be changed in:
///   `Settings → Privacy → Bluetooth`.
///
/// Throws a [PrinterException] with a platform-appropriate message if the
/// required permissions are not granted after requesting them.
Future<void> _ensureBluetoothPermission() async {
  // ---- iOS -------------------------------------------------------------
  // Only Permission.bluetooth exists here: it maps to CoreBluetooth and
  // triggers the NSBluetoothAlwaysUsageDescription dialog. The Android-only
  // groups (bluetoothScan/bluetoothConnect) are dispatched to permission_
  // handler's UnknownPermissionStrategy on iOS, which reports DENIED no
  // matter what — requiring them would fail the verification forever.
  // Location isn't needed for CoreBluetooth scanning on iOS either.
  if (Platform.isIOS) {
    var status = await Permission.bluetooth.status;
    if (!status.isGranted) {
      status = await Permission.bluetooth.request();
    }
    if (status.isGranted) return;
    throw PrinterException(
        'Bluetooth permission not granted — enable Bluetooth for this app in '
        'Settings → Privacy & Security → Bluetooth, then try again.');
  }

  // ---- Android ---------------------------------------------------------
  // On Android this maps to BLUETOOTH_CONNECT (API 31+) and is a no-op on
  // older Android versions.
  var bluetoothStatus = await Permission.bluetooth.status;
  if (!bluetoothStatus.isGranted) {
    bluetoothStatus = await Permission.bluetooth.request();
  }

  // ---- Android 12+ (API 31): also request BLUETOOTH_SCAN permission
  var bluetoothScanStatus = await Permission.bluetoothScan.status;
  if (!bluetoothScanStatus.isGranted) {
    bluetoothScanStatus = await Permission.bluetoothScan.request();
  }

  // ---- Android 12+ (API 31): also request BLUETOOTH_CONNECT permission
  var bluetoothConnectStatus = await Permission.bluetoothConnect.status;
  if (!bluetoothConnectStatus.isGranted) {
    bluetoothConnectStatus = await Permission.bluetoothConnect.request();
  }

  // Location permission is often required for Bluetooth on Android
  var locationStatus = await Permission.location.status;
  if (!locationStatus.isGranted) {
    locationStatus = await Permission.location.request();
  }

  // Also check coarse location on Android
  var locationCoarseStatus = await Permission.locationAlways.status;
  if (!locationCoarseStatus.isGranted) {
    locationCoarseStatus = await Permission.locationAlways.request();
  }

  // ---- Verify all required permissions are granted (Android) ----
  if (bluetoothStatus.isGranted &&
      bluetoothScanStatus.isGranted &&
      bluetoothConnectStatus.isGranted &&
      locationStatus.isGranted) {
    // All permissions granted - proceed with Bluetooth operations
    return;
  }

  // Permission denied - provide a clear, platform-appropriate message
  throw PrinterException(
      'Bluetooth permission not granted — allow "Nearby devices" and '
      '"Location" permissions for this app in your device Settings, then try again.');
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

/// Discover raw ESC/POS printers on the local (Wi-Fi) network.
///
/// Sweeps the device's own /24 subnet on the standard raw-print ports
/// (9100 and 9101) with a short TCP-connect timeout, probing up to 40
/// addresses at a time so a full sweep finishes in a few seconds. A host
/// that accepts the connection on a print port is reported as a candidate
/// printer.
///
/// On iOS the first sweep triggers the system **Local Network** permission
/// prompt (`NSLocalNetworkUsageDescription` is in Info.plist). While the
/// prompt is open — or if access was denied — the probes time out and an
/// empty list comes back; re-running after allowing access finds the
/// printers.
Future<List<NetPrinterDevice>> scanNetwork(
    {List<int> ports = const [9100, 9101]}) async {
  // ---- Pick the best private IPv4 interface (Wi-Fi/LAN first) ----
  String base;
  try {
    final interfaces = await NetworkInterface.list(
        includeLoopback: false, includeLinkLocal: false);
    String? candidate;
    for (final prefix in ['192.168.', '10.', '172.']) {
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              addr.address.startsWith(prefix)) {
            candidate = addr.address;
            break;
          }
        }
        if (candidate != null) break;
      }
      if (candidate != null) break;
    }
    if (candidate == null) {
      throw PrinterException(
          'No local network connection — connect this device to the '
          'printer\'s Wi-Fi network first.');
    }
    base = candidate;
  } on PrinterException {
    rethrow;
  } catch (e) {
    throw PrinterException('Network scan failed: $e');
  }

  // ---- Build the target list (own /24, minus self) ----
  final octets = base.split('.');
  final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
  final self = base;
  final targets = <(String, int)>[];
  for (var i = 1; i <= 254; i++) {
    final ip = '$prefix.$i';
    if (ip == self) continue;
    for (final port in ports) {
      targets.add((ip, port));
    }
  }

  // ---- Probe with bounded parallelism ----
  const batchSize = 40;
  const probeTimeout = Duration(milliseconds: 300);
  final found = <NetPrinterDevice>[];
  for (var i = 0; i < targets.length; i += batchSize) {
    final slice =
        targets.skip(i).take(batchSize).toList(growable: false);
    await Future.wait(slice.map((t) async {
      try {
        final socket = await Socket.connect(t.$1, t.$2,
            timeout: probeTimeout);
        await socket.close();
        found.add(NetPrinterDevice(host: t.$1, port: t.$2));
      } catch (_) {
        // Timeout / connection refused: not a printer on this port.
      }
    }));
  }

  found.sort((a, b) {
    final c = a.host.compareTo(b.host);
    return c != 0 ? c : a.port.compareTo(b.port);
  });
  return found;
}