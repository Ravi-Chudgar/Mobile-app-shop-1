import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models/billing.dart';
import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../util/money.dart';
import 'bill_screen.dart';

/// Owner billing: collected orders grouped by date, with paid/unpaid totals
/// and the ability to confirm payment.

String _short(String s) => s.length > 26 ? '${s.substring(0, 26)}…' : s;

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  final _fmt = DateFormat('yyyy-MM-dd');
  DateTime? _selected; // null = all dates
  BillingSummary? _summary;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await context.read<ApiClient>().fetchBilling(
            date: _selected == null ? null : _fmt.format(_selected!),
          );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _selected = picked);
      _load();
    }
  }

  Future<void> _markPaid(CafeOrder order) async {
    try {
      await context.read<ApiClient>().markOrderPaid(order.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final summary = _summary!;
    final selected = _selected;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  selected == null
                      ? 'All dates'
                      : DateFormat('EEE, d MMM yyyy').format(selected),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(selected == null ? 'Pick date' : 'Change date'),
              ),
              if (selected != null)
                IconButton(
                  tooltip: 'Show all dates',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    setState(() => _selected = null);
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          _SummaryRow(summary: summary),
          const SizedBox(height: 16),
          if (summary.days.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(
                child: Text('No collected orders yet.',
                    style: TextStyle(color: Colors.black54)),
              ),
            )
          else
            ...summary.days.map((day) => _DaySection(
                  day: day,
                  onMarkPaid: _markPaid,
                )),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final BillingSummary summary;
  const _SummaryRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Tile(
            label: 'Total due',
            value: formatMoney(summary.total),
            color: Colors.blueGrey,
            icon: Icons.receipt_long,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Tile(
            label: 'Paid',
            value: formatMoney(summary.paid),
            color: Colors.green,
            icon: Icons.check_circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Tile(
            label: 'Unpaid',
            value: formatMoney(summary.unpaid),
            color: Colors.orange,
            icon: Icons.pending_actions,
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  const _Tile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DaySection extends StatelessWidget {
  final BillingDay day;
  final Future<void> Function(CafeOrder order) onMarkPaid;
  const _DaySection({required this.day, required this.onMarkPaid});

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(day.date);
    final title =
        date == null ? day.date : DateFormat('EEE, d MMM yyyy').format(date);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                  '${day.orderCount} orders • ${formatMoney(day.total)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...day.orders.map((o) => _OrderCard(order: o, onMarkPaid: onMarkPaid)),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  final CafeOrder order;
  final Future<void> Function(CafeOrder order) onMarkPaid;
  const _OrderCard({required this.order, required this.onMarkPaid});

  @override
  Widget build(BuildContext context) {
    final isPaid = order.paymentStatus == 'paid';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BillScreen(order: order)),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text('#${order.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    label: Text(isPaid ? 'PAID' : 'UNPAID',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11)),
                    backgroundColor: isPaid ? Colors.green : Colors.orange,
                    visualDensity: VisualDensity.compact,
                  ),
                  const Spacer(),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(formatMoney(order.total),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.person_outline,
                      size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(order.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 12),
                  if (order.tableNumber != null) ...[
                    Icon(Icons.table_restaurant_outlined,
                        size: 14, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('Table ${order.tableNumber}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.payments_outlined,
                      size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(_prettyPayment(order.paymentMethod),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 12),
                  if (order.takenBy != null) ...[
                    Icon(Icons.badge_outlined,
                        size: 14, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('Served by ${order.takenBy}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ],
              ),
              if (order.paymentToken?.isNotEmpty ?? false) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.verified_outlined,
                        size: 14, color: Colors.green.shade600),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'GPay ref ${_short(order.paymentToken!)}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              if (!isPaid) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: () => onMarkPaid(order),
                    child: const Text('Mark as paid'),
                  ),
                ),
              ],
              if (isPaid) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () => _sendWhatsApp(context),
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('Send Bill'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _prettyPayment(String m) => m
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  String get _customerPhone {
    final phone = order.customerPhone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    if (phone.isEmpty) return '';
    if (phone.startsWith('91') && phone.length >= 12) return phone;
    if (phone.length == 10) return '91$phone';
    return phone;
  }

  void _sendWhatsApp(BuildContext context) {
    final phone = _customerPhone;
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No customer phone number on this order')),
      );
      return;
    }

    final items = order.items.map((item) {
      final opts = item.options.map((o) => '  $o').join('\n');
      return '${item.name} x${item.qty}  ₹${item.lineTotal}'
          '${opts.isNotEmpty ? '\n$opts' : ''}';
    }).join('\n');

    final upiLink =
        'upi://pay?pa=${AppConfig.upiId}&pn=${Uri.encodeComponent(AppConfig.merchantName)}&am=${order.total}&cu=INR';

    final buffer = StringBuffer()
      ..writeln('═══════════════════════════')
      ..writeln('       ${AppConfig.merchantName}')
      ..writeln('═══════════════════════════')
      ..writeln()
      ..writeln('Bill #: ${order.id}')
      ..writeln(
          'Date: ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.tryParse(order.createdAt) ?? DateTime.now())}')
      ..writeln('Customer: ${order.customerName}')
      ..writeln('Table: ${order.tableNumber ?? "N/A"}')
      ..writeln('Staff: ${order.takenBy ?? 'N/A'}')
      ..writeln()
      ..writeln('─── ITEMS ───────────────')
      ..writeln(items)
      ..writeln()
      ..writeln('─────────────────────────')
      ..writeln('TOTAL: ₹${order.total}')
      ..writeln()
      ..writeln('Payment: ${order.paymentMethod.toUpperCase()}')
      ..writeln('Status: ${order.paymentStatus.toUpperCase()}')
      ..writeln()
      ..writeln('UPI Payment Link:')
      ..writeln(upiLink)
      ..writeln()
      ..writeln('═══════════════════════════')
      ..writeln('  Thank you for your visit!')
      ..writeln('═══════════════════════════');
    final billText = buffer.toString();

    final url =
        Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(billText)}');
    final messenger = ScaffoldMessenger.of(context);
    canLaunchUrl(url).then((ok) {
      if (ok) {
        launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp')),
        );
      }
    });
  }
}
