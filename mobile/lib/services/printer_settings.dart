/// Printer connection preferences, persisted across app launches.
///
/// One [PrinterSettings.instance] holds the selected transport
/// ([PrinterMode] network / USB / Bluetooth) together with its endpoint —
/// raw-TCP host:port, USB ids, or the paired Bluetooth address — and mirrors
/// it to SharedPreferences so the next launch can print without
/// reconfiguring. Call [load] once at startup and [save] after every edit.
library;

import 'package:shared_preferences/shared_preferences.dart';

enum PrinterMode { network, usb, bluetooth }

class PrinterSettings {
  PrinterSettings._();
  static final PrinterSettings instance = PrinterSettings._();

  static const _keyMode = 'printer_mode';
  static const _keyHost = 'printer_host';
  static const _keyPort = 'printer_port';
  static const _keyUsbLabel = 'printer_usb_label';
  static const _keyUsbVendorId = 'printer_usb_vendor_id';
  static const _keyUsbProductId = 'printer_usb_product_id';
  static const _keyUsbDeviceId = 'printer_usb_device_id';
  static const _keyBtAddress = 'printer_bt_address';
  static const _keyBtName = 'printer_bt_name';

  PrinterMode mode = PrinterMode.network;
  String host = '';
  int port = 9100;
  String usbLabel = '';
  int usbVendorId = 0;
  int usbProductId = 0;
  int usbDeviceId = 0;
  String btAddress = '';
  String btName = '';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString(_keyMode);
    if (modeStr != null) {
      mode = PrinterMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => PrinterMode.network,
      );
    }
    host = prefs.getString(_keyHost) ?? '';
    port = prefs.getInt(_keyPort) ?? 9100;
    usbLabel = prefs.getString(_keyUsbLabel) ?? '';
    usbVendorId = prefs.getInt(_keyUsbVendorId) ?? 0;
    usbProductId = prefs.getInt(_keyUsbProductId) ?? 0;
    usbDeviceId = prefs.getInt(_keyUsbDeviceId) ?? 0;
    btAddress = prefs.getString(_keyBtAddress) ?? '';
    btName = prefs.getString(_keyBtName) ?? '';
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMode, mode.name);
    await prefs.setString(_keyHost, host);
    await prefs.setInt(_keyPort, port);
    await prefs.setString(_keyUsbLabel, usbLabel);
    await prefs.setInt(_keyUsbVendorId, usbVendorId);
    await prefs.setInt(_keyUsbProductId, usbProductId);
    await prefs.setInt(_keyUsbDeviceId, usbDeviceId);
    await prefs.setString(_keyBtAddress, btAddress);
    await prefs.setString(_keyBtName, btName);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyMode);
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyUsbLabel);
    await prefs.remove(_keyUsbVendorId);
    await prefs.remove(_keyUsbProductId);
    await prefs.remove(_keyUsbDeviceId);
    await prefs.remove(_keyBtAddress);
    await prefs.remove(_keyBtName);
    mode = PrinterMode.network;
    host = '';
    port = 9100;
    usbLabel = '';
    usbVendorId = 0;
    usbProductId = 0;
    usbDeviceId = 0;
    btAddress = '';
    btName = '';
  }

  bool get isConfigured {
    switch (mode) {
      case PrinterMode.network:
        return host.isNotEmpty;
      case PrinterMode.usb:
        return usbDeviceId != 0;
      case PrinterMode.bluetooth:
        return btAddress.isNotEmpty;
    }
  }
}
