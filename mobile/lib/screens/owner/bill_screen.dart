import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../services/printer_models.dart';
import '../../services/printing_service.dart';

class BillScreen extends StatefulWidget {
  final CafeOrder order;
  const BillScreen({super.key, required this.order});

  @override
  State<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends State<BillScreen> {
  late CafeOrder _order;
  bool _processing = false;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _order = widget.order;
  }

  String _formatMoney(int amount) => '₹$amount';

  int get _cgstTotal => _order.items.fold(0, (s, l) => s + l.cgst);
  int get _sgstTotal => _order.items.fold(0, (s, l) => s + l.sgst);
  int get _taxableTotal => _order.items.fold(0, (s, l) => s + l.taxableValue);

  /// Per-rate GST summary rows: [{"rate": 5, "taxable": ..., "cgst": ...}].
  List<Map<String, int>> get _taxByRate {
    final buckets = <int, Map<String, int>>{};
    for (final line in _order.items) {
      final rate = line.gstRate ?? 0;
      final b = buckets.putIfAbsent(
          rate, () => {'rate': rate, 'taxable': 0, 'cgst': 0, 'sgst': 0});
      b['taxable'] = b['taxable']! + line.taxableValue;
      b['cgst'] = b['cgst']! + line.cgst;
      b['sgst'] = b['sgst']! + line.sgst;
    }
    final rates = buckets.keys.toList()..sort();
    return [for (final r in rates) buckets[r]!];
  }

  /// Server-rendered GST bill text (identical to what WhatsApp receives).
  /// Falls back to local formatting when the backend is unreachable.
  Future<String> _billText() async {
    try {
      final data = await context.read<ApiClient>().fetchBillText(_order.id);
      final text = data['text'] as String?;
      if (text != null && text.isNotEmpty) return text;
    } catch (_) {
      // fall through to local formatting
    }
    return _buildBillText();
  }

  Future<void> _copyBill() async {
    final text = await _billText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Bill copied')));
  }

  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiClient>();
    try {
      final result =
          await PrintingService.instance.printReceipt(_order.id, api);
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green,
        content: Text('✓ $result'),
      ));
    } on PrinterException catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Print failed: ${e.message}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('Print failed: $e'),
      ));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  String _buildBillText() {
    final items = _order.items.map((item) {
      final opts =
          item.options.isNotEmpty ? '\n   ${item.options.join(" | ")}' : '';
      return '  ${item.name} x${item.qty}  ₹${item.lineTotal}$opts';
    }).join('\n');

    final upiLink =
        'upi://pay?pa=${AppConfig.upiId}&pn=${Uri.encodeComponent(AppConfig.merchantName)}&am=${_order.total}&cu=INR';

    final buffer = StringBuffer()
      ..writeln('╭─────────────────────────╮')
      ..writeln('│     ${AppConfig.merchantName}     │')
      ..writeln('╰─────────────────────────╯')
      ..writeln()
      ..writeln('📋 Bill #${_order.id}')
      ..writeln(
          '📅 ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.tryParse(_order.createdAt) ?? DateTime.now())}')
      ..writeln('👤 ${_order.customerName}')
      ..writeln('🪑 Table ${_order.tableNumber ?? "N/A"}')
      ..writeln('👨‍🍳 Served by: ${_order.takenBy ?? 'N/A'}')
      ..writeln()
      ..writeln('─────────────────────────')
      ..writeln('  ITEM              QTY   AMT')
      ..writeln('─────────────────────────')
      ..writeln(items)
      ..writeln('─────────────────────────')
      ..writeln()
      ..writeln('💰 TOTAL: ₹${_order.total}')
      ..writeln('💳 Payment: ${_order.paymentMethod.toUpperCase()}')
      ..writeln('✅ Status: ${_order.paymentStatus.toUpperCase()}')
      ..writeln();

    if (_order.paymentStatus != 'paid') {
      buffer
        ..writeln(' pay using upi')
        ..writeln(upiLink)
        ..writeln();
    }

    buffer
      ..writeln('─────────────────────────')
      ..writeln('  Thank you for visiting!')
      ..writeln('  Visit us again 🙏')
      ..writeln('─────────────────────────');
    return buffer.toString();
  }

  String get _customerPhone {
    final phone = _order.customerPhone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    if (phone.isEmpty) return '';
    if (phone.startsWith('91') && phone.length >= 12) return phone;
    if (phone.length == 10) return '91$phone';
    return phone;
  }

  Future<void> _sendWhatsApp(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String? url;
    try {
      // Server-rendered bill: GST breakdown + normalized wa.me link.
      final data = await context.read<ApiClient>().fetchBillText(_order.id);
      final link = data['wa_link'] as String?;
      if (link != null && link.isNotEmpty) {
        url = link;
      } else {
        messenger.showSnackBar(const SnackBar(
            content: Text('No customer phone number on this order')));
        return;
      }
    } catch (_) {
      // Backend unreachable — fall back to the locally-built bill.
      final phone = _customerPhone;
      if (phone.isEmpty) {
        messenger.showSnackBar(const SnackBar(
            content: Text('No customer phone number on this order')));
        return;
      }
      url =
          'https://wa.me/$phone?text=${Uri.encodeComponent(_buildBillText())}';
    }
    final parsed = Uri.parse(url);
    if (await canLaunchUrl(parsed)) {
      await launchUrl(parsed, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp')));
    }
  }

  Future<void> _collectPayment(String method) async {
    final due = _order.total - _order.paidAmount;
    if (due <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order already paid')),
        );
      }
      return;
    }

    setState(() => _processing = true);
    final api = context.read<ApiClient>();
    try {
      await api.updateOrderStatus(
        _order.id,
        'collected',
        paid: true,
        paymentMethod: method,
      );
      // Reload order
      final updated = await api.fetchOrder(_order.id);
      setState(() {
        _order = updated;
        _processing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment of ₹$due recorded via $method'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final due = _order.total - _order.paidAmount;
    final isPaid = due <= 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Bill #${_order.id}'),
        actions: [
          IconButton(
            tooltip: 'Print receipt',
            icon: _printing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print),
            onPressed: _printing ? null : _print,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyBill,
          ),
          IconButton(
            icon: const Icon(Icons.chat, color: Colors.green),
            onPressed: () => _sendWhatsApp(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Center(
                      child: Column(
                        children: [
                          Text(
                            'CAFE POS',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Bill Receipt',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const Divider(thickness: 2),
                    const SizedBox(height: 8),

                    // Order info
                    _InfoRow(label: 'Bill #', value: _order.id),
                    _InfoRow(
                      label: 'Date',
                      value: DateFormat('dd MMM yyyy, hh:mm a').format(
                          DateTime.tryParse(_order.createdAt) ??
                              DateTime.now()),
                    ),
                    if (_order.customerName.isNotEmpty)
                      _InfoRow(label: 'Customer', value: _order.customerName),
                    if (_order.tableNumber != null)
                      _InfoRow(label: 'Table', value: _order.tableNumber!),
                    if (_order.takenBy != null)
                      _InfoRow(label: 'Served by', value: _order.takenBy!),

                    const Divider(thickness: 2),
                    const SizedBox(height: 8),

                    // Items header
                    const Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text('ITEM',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text('QTY',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text('AMOUNT',
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Items
                    ..._order.items.map((item) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                Expanded(
                                  flex: 1,
                                  child: Text(
                                    '${item.qty}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    _formatMoney(item.lineTotal),
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                            ...item.options.map((opt) => Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: Text(
                                    '  $opt',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                )),
                            if (item.hsnCode != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Text(
                                  '  HSN ${item.hsnCode} • GST ${item.gstRate ?? 0}%',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 6),
                          ],
                        )),

                    const Divider(thickness: 2),
                    const SizedBox(height: 8),

                    // Total
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('TOTAL',
                            style: TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 18)),
                        Text(
                          _formatMoney(_order.total),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 22,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),

                    // GST breakdown (tax-inclusive pricing)
                    if (_cgstTotal + _sgstTotal > 0) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('GST BREAKDOWN',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5)),
                            const SizedBox(height: 6),
                            _TaxRow(
                                label: 'Taxable value',
                                value: _formatMoney(_taxableTotal)),
                            _TaxRow(
                                label: 'CGST', value: _formatMoney(_cgstTotal)),
                            _TaxRow(
                                label: 'SGST', value: _formatMoney(_sgstTotal)),
                            for (final b in _taxByRate)
                              _TaxRow(
                                label: '@ ${b['rate']}%  taxable '
                                    '${_formatMoney(b['taxable']!)}',
                                value: 'CGST ${_formatMoney(b['cgst']!)} '
                                    '+ SGST ${_formatMoney(b['sgst']!)}',
                                small: true,
                              ),
                          ],
                        ),
                      ),
                    ],

                    if (_order.paidAmount > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('PAID',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.green.shade700)),
                          Text(
                            _formatMoney(_order.paidAmount),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('DUE',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.red.shade700)),
                          Text(
                            _formatMoney(due),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.red.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 12),

                    // Payment info
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isPaid
                            ? Colors.green.shade50
                            : Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isPaid ? Icons.check_circle : Icons.pending,
                            color: isPaid ? Colors.green : Colors.orange,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Payment: ${_order.paymentMethod.toUpperCase()}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  'Status: ${isPaid ? "PAID" : "UNPAID"}',
                                  style: TextStyle(
                                    color: isPaid
                                        ? Colors.green.shade700
                                        : Colors.orange.shade700,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Copy & WhatsApp buttons
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _copyBill,
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _sendWhatsApp(context),
                            icon: const Icon(Icons.chat),
                            label: const Text('WhatsApp'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                          ),
                        ),
                      ],
                    ),

                    Center(
                      child: Text(
                        'Thank you for your visit!',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Payment Collection Buttons (if unpaid) ──
            if (!isPaid) ...[
              const SizedBox(height: 20),
              Text(
                'Collect Payment',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _PaymentButton(
                      icon: Icons.money,
                      label: 'Cash',
                      color: Colors.green,
                      onTap: _processing ? null : () => _collectPayment('cash'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PaymentButton(
                      icon: Icons.credit_card,
                      label: 'Card',
                      color: Colors.blue,
                      onTap: _processing ? null : () => _collectPayment('card'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PaymentButton(
                      icon: Icons.qr_code,
                      label: 'UPI',
                      color: Colors.purple,
                      onTap: _processing ? null : () => _collectPayment('upi'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PaymentButton(
                      icon: Icons.account_balance_wallet,
                      label: 'GPay',
                      color: Colors.teal,
                      onTap: _processing ? null : () => _collectPayment('gpay'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaymentButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _PaymentButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _TaxRow extends StatelessWidget {
  final String label;
  final String value;
  final bool small;
  const _TaxRow({required this.label, required this.value, this.small = false});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontSize: small ? 11 : 13,
        color: small ? Colors.black54 : null,
        fontWeight: small ? FontWeight.w400 : FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: style)),
          Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: style.copyWith(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
