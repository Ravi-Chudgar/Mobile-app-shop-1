/// Receipt / KOT printing orchestrator.
///
/// Fetches pre-rendered ESC/POS bytes from the backend, then delivers them
/// through the transport selected in [PrinterSettings]: direct from the
/// device (TCP, USB, Bluetooth) when possible, otherwise proxied through the
/// server (`api.sendPrinterBytes`) — with the legacy server-side print as
/// the last fallback. Returns a short human-readable status string for the
/// caller's SnackBar; all failures surface as [PrinterException].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'api_client.dart';
import 'printer_models.dart';
import 'printer_settings.dart';
import 'printer_transports.dart' as transports;

class PrintingService {
  PrintingService._();
  static final PrintingService instance = PrintingService._();

  Future<String> printReceipt(String orderId, ApiClient api) async {
    final settings = PrinterSettings.instance;
    await settings.load();
    final data = await api.fetchReceiptBytes(orderId);
    final bytes = _decodeBytes(data);
    return _send(bytes, api, legacyFallback: () => api.printReceipt(orderId));
  }

  Future<String> printKot(String orderId, ApiClient api) async {
    final settings = PrinterSettings.instance;
    await settings.load();
    final data = await api.fetchKotBytes(orderId);
    final bytes = _decodeBytes(data);
    return _send(bytes, api, legacyFallback: () => api.printKot(orderId));
  }

  Future<String> printTest(ApiClient api) async {
    final settings = PrinterSettings.instance;
    await settings.load();
    final data = await api.fetchTestBytes();
    final bytes = _decodeBytes(data);
    return _send(bytes, api, legacyFallback: null);
  }

  Future<List<UsbPrinterDevice>> scanUsb() async {
    return transports.listUsbDevices();
  }

  Future<List<BtPrinterDevice>> scanBluetooth() async {
    return transports.listBluetoothPrinters();
  }

  Uint8List _decodeBytes(Map<String, dynamic> data) {
    final b64 = data['bytes_b64'] as String?;
    if (b64 == null || b64.isEmpty) {
      throw PrinterException('No bytes returned from server');
    }
    return base64Decode(b64);
  }

  Future<String> _send(
    Uint8List bytes,
    ApiClient api, {
    required Future<Map<String, dynamic>> Function()? legacyFallback,
  }) async {
    try {
      return await _sendInner(bytes, api, legacyFallback: legacyFallback);
    } on PrinterException {
      rethrow;
    } catch (e) {
      throw PrinterException('$e');
    }
  }

  Future<String> _sendInner(
    Uint8List bytes,
    ApiClient api, {
    required Future<Map<String, dynamic>> Function()? legacyFallback,
  }) async {
    final settings = PrinterSettings.instance;
    final kb = (bytes.length / 1024).toStringAsFixed(1);

    switch (settings.mode) {
      case PrinterMode.network:
        if (settings.host.isEmpty) {
          if (legacyFallback != null) {
            final res = await legacyFallback();
            final dryRun = res['dry_run'] == true;
            return dryRun
                ? 'Dry run — no printer configured on server'
                : 'Sent via server';
          }
          throw PrinterException('No printer host configured');
        }
        if (!kIsWeb) {
          try {
            await transports.sendNetwork(settings.host, settings.port, bytes);
            return 'Sent to ${settings.host}:${settings.port} \u00b7 $kb KB';
          } on PrinterException {
            final res = await api.sendPrinterBytes(
              bytesB64: base64Encode(bytes),
              host: settings.host,
              port: settings.port,
            );
            return 'Sent via server to ${res['host']}:${res['port']} \u00b7 $kb KB';
          }
        } else {
          final res = await api.sendPrinterBytes(
            bytesB64: base64Encode(bytes),
            host: settings.host,
            port: settings.port,
          );
          return 'Sent via server to ${res['host']}:${res['port']} \u00b7 $kb KB';
        }

      case PrinterMode.usb:
        if (settings.usbDeviceId == 0) {
          throw PrinterException('No USB printer selected');
        }
        await transports.sendUsb(settings.usbDeviceId, bytes);
        return 'Sent to USB printer: ${settings.usbLabel} \u00b7 $kb KB';

      case PrinterMode.bluetooth:
        if (settings.btAddress.isEmpty) {
          throw PrinterException('No Bluetooth printer selected');
        }
        await transports.sendBluetooth(settings.btAddress, bytes);
        return 'Sent to ${settings.btName.isNotEmpty ? settings.btName : settings.btAddress} \u00b7 $kb KB';
    }
  }
}
