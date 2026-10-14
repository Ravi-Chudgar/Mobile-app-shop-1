import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../services/printer_models.dart';
import '../../services/printer_settings.dart';
import '../../services/printing_service.dart';
import '../../widgets/ui_kit.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final _settings = PrinterSettings.instance;

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _macCtrl = TextEditingController();

  bool _loading = true;
  bool _testPrinting = false;
  String? _lastResult;
  bool _lastWasError = false;

  List<UsbPrinterDevice> _usbDevices = [];
  bool _usbScanning = false;

  List<BtPrinterDevice> _btDevices = [];
  bool _btScanning = false;

  List<NetPrinterDevice> _netDevices = [];
  bool _netScanning = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _settings.load();
    _hostCtrl.text = _settings.host;
    _portCtrl.text = _settings.port.toString();
    _macCtrl.text = _settings.btAddress;
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _macCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveMode(PrinterMode mode) async {
    _settings.mode = mode;
    await _settings.save();
    if (mounted) setState(() {});
  }

  Future<void> _saveNetwork({bool silent = false}) async {
    _settings.host = _hostCtrl.text.trim();
    _settings.port = int.tryParse(_portCtrl.text.trim()) ?? 9100;
    await _settings.save();
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network printer saved')),
      );
    }
  }

  Future<void> _scanUsb() async {
    setState(() {
      _usbScanning = true;
      _usbDevices = [];
    });
    try {
      final devices = await PrintingService.instance.scanUsb();
      if (mounted) setState(() => _usbDevices = devices);
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() => _usbDevices = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _usbScanning = false);
    }
  }

  Future<void> _selectUsb(UsbPrinterDevice dev) async {
    _settings.usbLabel = dev.label;
    _settings.usbVendorId = dev.vendorId;
    _settings.usbProductId = dev.productId;
    _settings.usbDeviceId = dev.deviceId;
    await _settings.save();
    if (mounted) setState(() {});
  }

  Future<void> _scanBluetooth() async {
    setState(() {
      _btScanning = true;
      _btDevices = [];
    });
    try {
      final devices = await PrintingService.instance.scanBluetooth();
      if (mounted) setState(() => _btDevices = devices);
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() => _btDevices = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _btScanning = false);
    }
  }

  Future<void> _selectBluetooth(BtPrinterDevice dev) async {
    _settings.btAddress = dev.address;
    _settings.btName = dev.name;
    _macCtrl.text = dev.address;
    await _settings.save();
    if (mounted) setState(() {});
  }

  Future<void> _scanNetwork() async {
    setState(() {
      _netScanning = true;
      _netDevices = [];
    });
    try {
      final devices = await PrintingService.instance.scanNetwork();
      if (mounted) setState(() => _netDevices = devices);
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() => _netDevices = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) setState(() => _netDevices = []);
    } finally {
      if (mounted) setState(() => _netScanning = false);
    }
  }

  Future<void> _selectNetwork(NetPrinterDevice dev) async {
    setState(() {
      _hostCtrl.text = dev.host;
      _portCtrl.text = dev.port.toString();
    });
    await _saveNetwork();
    if (mounted) setState(() {});
  }

  Future<void> _saveManualMac() async {
    _settings.btAddress = _macCtrl.text.trim();
    _settings.btName = '';
    await _settings.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth address saved')),
      );
    }
  }

  Future<void> _testPrint() async {
    if (_testPrinting) return;
    final api = context.read<ApiClient>();
    setState(() {
      _testPrinting = true;
      _lastResult = null;
    });
    // Persist whatever is typed right now so the test uses the visible values.
    if (_settings.mode == PrinterMode.network) {
      await _saveNetwork(silent: true);
    }
    try {
      final result = await PrintingService.instance.printTest(api);
      if (mounted) {
        setState(() {
          _lastResult = result;
          _lastWasError = false;
          _testPrinting = false;
        });
      }
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() {
          _lastResult = e.message;
          _lastWasError = true;
          _testPrinting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastResult = '$e';
          _lastWasError = true;
          _testPrinting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Printer Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                const SizedBox(height: 12),
                HeroBanner(
                  gradient: CafeGradients.coffee,
                  height: 110,
                  illustration: Opacity(
                    opacity: 0.18,
                    child: CustomPaint(
                      painter: LatteArtPainter(withBeans: true),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Thermal Printer',
                        style: text.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ESC/POS compatible · 58mm & 80mm rolls',
                        style: text.bodySmall?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const SectionHeader(
                  title: 'Connection Mode',
                  subtitle: 'Choose how the app reaches your printer',
                ),
                const SizedBox(height: 8),
                _ModeCard(
                  icon: Icons.wifi,
                  label: 'Network (WiFi / LAN)',
                  description: 'Connect over your local network',
                  selected: _settings.mode == PrinterMode.network,
                  gradient: CafeGradients.sky,
                  onTap: () => _saveMode(PrinterMode.network),
                ),
                const SizedBox(height: 8),
                _ModeCard(
                  icon: Icons.usb,
                  label: 'USB (OTG Cable)',
                  description: 'Direct connection via USB-OTG',
                  selected: _settings.mode == PrinterMode.usb,
                  gradient: CafeGradients.sunrise,
                  onTap: () => _saveMode(PrinterMode.usb),
                ),
                const SizedBox(height: 8),
                _ModeCard(
                  icon: Icons.bluetooth,
                  label: 'Bluetooth',
                  description: 'Wireless connection up to ~10m',
                  selected: _settings.mode == PrinterMode.bluetooth,
                  gradient: CafeGradients.berry,
                  onTap: () => _saveMode(PrinterMode.bluetooth),
                ),
                const SizedBox(height: 8),
                if (_settings.mode == PrinterMode.network) ...[
                  const SectionHeader(
                    title: 'Network Printer',
                    subtitle: 'Search the Wi-Fi network or enter the IP manually',
                  ),
                  _networkContent(scheme),
                ],
                if (_settings.mode == PrinterMode.usb) ...[
                  const SectionHeader(
                    title: 'USB Printer',
                    subtitle: 'Scan and select your USB-OTG printer',
                  ),
                  _usbContent(scheme),
                ],
                if (_settings.mode == PrinterMode.bluetooth) ...[
                  const SectionHeader(
                    title: 'Bluetooth Printer',
                    subtitle: 'Scan paired devices or enter MAC manually',
                  ),
                  _bluetoothContent(scheme),
                ],
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _testPrinting ? null : _testPrint,
                    icon: _testPrinting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.print_outlined),
                    label: Text(_testPrinting ? 'Printing…' : 'Test Print'),
                    style: FilledButton.styleFrom(
                      backgroundColor: CafePalette.coffee,
                    ),
                  ),
                ),
                if (_lastResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _lastWasError
                          ? Colors.red.shade50
                          : Colors.green.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _lastWasError
                            ? Colors.red.shade200
                            : Colors.green.shade200,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _lastWasError
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 18,
                          color: _lastWasError
                              ? Colors.red.shade700
                              : Colors.green.shade700,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _lastResult!,
                            style: text.bodySmall?.copyWith(
                              color: _lastWasError
                                  ? Colors.red.shade700
                                  : Colors.green.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _usbContent(ColorScheme scheme) {
    final isWeb = _isWeb();
    if (isWeb) {
      return const EmptyStateArt(
        title: 'USB not available on web',
        message: 'Connect via the Android app to use USB-OTG printing.',
        icon: Icons.usb_off_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_settings.usbLabel.isNotEmpty)
          _SelectedBadge(
            label: _settings.usbLabel,
            sub:
                'VID:${_settings.usbVendorId.toRadixString(16).padLeft(4, '0').toUpperCase()} '
                'PID:${_settings.usbProductId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
            gradient: CafeGradients.sunrise,
            icon: Icons.usb,
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _usbScanning ? null : _scanUsb,
          icon: _usbScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search, size: 18),
          label: Text(_usbScanning ? 'Scanning…' : 'Scan USB Devices'),
        ),
        if (_usbDevices.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final dev in _usbDevices)
            _DeviceTile(
              title: dev.label,
              subtitle:
                  'VID:${dev.vendorId.toRadixString(16).padLeft(4, '0').toUpperCase()} '
                  'PID:${dev.productId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
              icon: Icons.usb,
              selected: _settings.usbDeviceId == dev.deviceId,
              onTap: () => _selectUsb(dev),
            ),
        ] else if (!_usbScanning) ...[
          const SizedBox(height: 8),
          Text(
            'No USB devices found. Tap Scan to search.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _bluetoothContent(ColorScheme scheme) {
    final isWeb = _isWeb();
    if (isWeb) {
      return const EmptyStateArt(
        title: 'Bluetooth not available on web',
        message: 'Connect via the Android app to use Bluetooth printing.',
        icon: Icons.bluetooth_disabled_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_settings.btAddress.isNotEmpty)
          _SelectedBadge(
            label: _settings.btName.isNotEmpty
                ? _settings.btName
                : _settings.btAddress,
            sub: _settings.btAddress,
            gradient: CafeGradients.berry,
            icon: Icons.bluetooth,
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _btScanning ? null : _scanBluetooth,
          icon: _btScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.bluetooth_searching, size: 18),
          label: Text(_btScanning ? 'Scanning…' : 'Scan Paired Devices'),
        ),
        if (_btDevices.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final dev in _btDevices)
            _DeviceTile(
              title: dev.name,
              subtitle: dev.address,
              icon: Icons.bluetooth,
              selected: _settings.btAddress == dev.address,
              onTap: () => _selectBluetooth(dev),
            ),
        ] else if (!_btScanning) ...[
          const SizedBox(height: 8),
          Text(
            'No paired devices. Pair your printer in Android Settings first.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Manual MAC address entry',
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _macCtrl,
                decoration: const InputDecoration(
                  labelText: 'MAC Address',
                  hintText: 'AA:BB:CC:DD:EE:FF',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.bluetooth_outlined),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _saveManualMac,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _networkContent(ColorScheme scheme) {
    final isWeb = _isWeb();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_settings.host.isNotEmpty)
          _SelectedBadge(
            label: '${_settings.host}:${_settings.port}',
            sub: 'Network printer · raw ESC/POS',
            gradient: CafeGradients.sky,
            icon: Icons.router_outlined,
          ),
        const SizedBox(height: 8),

        // LAN discovery needs dart:io sockets — not possible in a browser.
        if (!isWeb) ...[
          OutlinedButton.icon(
            onPressed: _netScanning ? null : _scanNetwork,
            icon: _netScanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search, size: 18),
            label: Text(
                _netScanning ? 'Searching network…' : 'Search Network Printers'),
          ),
          if (_netDevices.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final dev in _netDevices)
              _DeviceTile(
                title: dev.host,
                subtitle: 'Port ${dev.port} · raw ESC/POS',
                icon: Icons.router_outlined,
                selected: _settings.host == dev.host &&
                    _settings.port == dev.port,
                onTap: () => _selectNetwork(dev),
              ),
          ] else if (!_netScanning) ...[
            const SizedBox(height: 8),
            Text(
              'Tap Search to find printers on this Wi-Fi network.\n'
              'Printer broadcasts its own Wi-Fi? Join the printer\'s network '
              'in Settings → Wi-Fi first, then tap Search.\n'
              'On iPhone, allow Local Network access when asked — if the '
              'list stays empty, tap Search once more after allowing.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
        ],

        // Manual entry stays available everywhere (the web app prints
        // through the server).
        TextField(
          controller: _hostCtrl,
          decoration: const InputDecoration(
            labelText: 'IP Address',
            hintText: '192.168.1.100',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.router_outlined),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _portCtrl,
          decoration: const InputDecoration(
            labelText: 'Port',
            hintText: '9100',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.settings_ethernet),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _saveNetwork,
          child: const Text('Save Network Settings'),
        ),
      ],
    );
  }

  bool _isWeb() => kIsWeb;
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final Gradient gradient;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? gradient.colors.first : Colors.transparent,
          width: 2,
        ),
        color: selected
            ? gradient.colors.first.withValues(alpha: 0.07)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              IconChip(
                icon: icon,
                gradient: selected ? gradient : null,
                color: selected ? null : CafePalette.latte,
                size: 44,
                iconSize: 22,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? gradient.colors.first : null,
                      ),
                    ),
                    Text(
                      description,
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle,
                    color: gradient.colors.first, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  final String label;
  final String sub;
  final Gradient gradient;
  final IconData icon;

  const _SelectedBadge({
    required this.label,
    required this.sub,
    required this.gradient,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors:
              gradient.colors.map((c) => c.withValues(alpha: 0.12)).toList(),
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: gradient.colors.first.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: gradient.colors.first),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        text.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(sub,
                    style: text.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: gradient.colors.first.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Selected',
              style: text.labelSmall?.copyWith(
                color: gradient.colors.first,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: scheme.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
