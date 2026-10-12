import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../util/money.dart';
import '../owner/bill_screen.dart';

/// Full order detail view: shows who took the order, when, items, status,
/// and provides a "Serve to Customer" action when the order is ready.
class OrderDetailScreen extends StatelessWidget {
  final CafeOrder order;
  const OrderDetailScreen({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = order;

    return Scaffold(
      appBar: AppBar(
        title: Text('Order #${o.id}'),
        actions: [
          // View Bill button
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'View Bill',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => BillScreen(order: o)),
              );
            },
          ),
          if (o.status == 'ready')
            TextButton.icon(
              onPressed: () => _serveToCustomer(context, o),
              icon: const Icon(Icons.check_circle, color: Colors.green),
              label: const Text('Serve',
                  style: TextStyle(
                      color: Colors.green, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status Badge ──
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: _statusColor(o.status).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_statusIcon(o.status),
                      size: 18, color: _statusColor(o.status)),
                  const SizedBox(width: 8),
                  Text(
                    o.status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: _statusColor(o.status),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Order Info Card ──
          _InfoCard(
            children: [
              _InfoRow(
                icon: Icons.person_outline,
                label: 'Customer',
                value: o.customerName,
              ),
              if (o.customerPhone != null && o.customerPhone!.isNotEmpty)
                _InfoRow(
                  icon: Icons.phone_outlined,
                  label: 'Phone',
                  value: o.customerPhone!,
                ),
              if (o.tableNumber != null)
                _InfoRow(
                  icon: Icons.table_restaurant_outlined,
                  label: 'Table',
                  value: 'Table ${o.tableNumber}',
                ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Staff & Time Card ──
          _InfoCard(
            children: [
              _InfoRow(
                icon: Icons.storefront_outlined,
                label: 'Taken by',
                value: o.takenBy ?? 'Unknown',
                valueStyle: const TextStyle(fontWeight: FontWeight.bold),
              ),
              _InfoRow(
                icon: Icons.access_time,
                label: 'Order time',
                value: _formatTime(o.createdAt),
              ),
              _InfoRow(
                icon: Icons.payment_outlined,
                label: 'Payment',
                value:
                    '${_prettyPayment(o.paymentMethod)} • ${o.paymentStatus}',
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Items ──
          _InfoCard(
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('ITEMS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
              ),
              for (final line in o.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${line.qty}×',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(line.name,
                                style: const TextStyle(fontSize: 14)),
                            if (line.options.isNotEmpty)
                              Text(line.options.join(' • '),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Text(formatMoney(line.lineTotal),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(formatMoney(o.total),
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary)),
                ],
              ),
            ],
          ),

          // ── Notes ──
          if (o.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            _InfoCard(
              children: [
                Row(
                  children: [
                    Icon(Icons.notes, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    const Text('Notes',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(o.notes,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ],
            ),
          ],

          // ── Serve Button (big, prominent) ──
          if (o.status == 'ready') ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _serveToCustomer(context, o),
              icon: const Icon(Icons.check_circle, size: 20),
              label: const Text(
                'Serve to Customer',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],

          // ── Send Bill to WhatsApp ──
          if (o.status == 'ready' &&
              o.customerPhone != null &&
              o.customerPhone!.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => BillScreen(order: o)),
                ),
                icon: const Icon(Icons.receipt_long, color: Colors.green),
                label: const Text(
                  'View & Send Bill via WhatsApp',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.green),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _serveToCustomer(BuildContext context, CafeOrder order) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Serve Order?'),
        content: Text(
          'Mark Order #${order.id} as collected?\n\n'
          '${order.customerName}${order.tableNumber != null ? ' at Table ${order.tableNumber}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    try {
      await context.read<ApiClient>().updateOrderStatus(order.id, 'collected',
          paid: true, paymentMethod: order.paymentMethod);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order #${order.id} served successfully'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // return true to trigger refresh
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'received':
        return Colors.blueGrey;
      case 'preparing':
        return Colors.orange;
      case 'ready':
        return Colors.green;
      case 'collected':
        return Colors.grey;
      default:
        return Colors.red;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'received':
        return Icons.receipt_long;
      case 'preparing':
        return Icons.pending;
      case 'ready':
        return Icons.check_circle;
      case 'collected':
        return Icons.done_all;
      default:
        return Icons.help_outline;
    }
  }

  String _formatTime(String iso) {
    if (iso.isEmpty) return '—';
    try {
      final dt = DateTime.parse(iso);
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      final month = dt.month.toString().padLeft(2, '0');
      return '$day/$month/${dt.year} at $hour:$min';
    } catch (_) {
      return iso;
    }
  }

  String _prettyPayment(String method) {
    switch (method) {
      case 'cash':
        return 'Cash';
      case 'card':
        return 'Card';
      case 'upi':
        return 'UPI';
      case 'gpay':
        return 'Google Pay';
      default:
        return method.toUpperCase();
    }
  }
}

// ─── Helper widgets ───

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final TextStyle? valueStyle;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle ??
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
