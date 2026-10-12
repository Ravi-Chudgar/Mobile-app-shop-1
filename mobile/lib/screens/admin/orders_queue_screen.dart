import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cart.dart';
import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../state/cart_state.dart';
import '../../util/money.dart';
import '../../util/permissions.dart';
import '../../widgets/collect_order_flow.dart';
import '../../widgets/menu_picker_sheet.dart';
import '../staff/order_detail_screen.dart';
import '../staff/take_order_screen.dart';

/// Owner's view of all orders with full management capabilities.
class OrdersQueueScreen extends StatefulWidget {
  const OrdersQueueScreen({super.key});

  @override
  State<OrdersQueueScreen> createState() => _OrdersQueueScreenState();
}

class _OrdersQueueScreenState extends State<OrdersQueueScreen> {
  List<CafeOrder> _orders = [];
  bool _loading = true;
  String? _error;
  bool _activeOnly = true;

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
      final orders = await context.read<ApiClient>().fetchOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
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

  Future<void> _advance(CafeOrder order) async {
    final idx = CafeOrder.flow.indexOf(order.status);
    if (idx < 0 || idx >= CafeOrder.flow.length - 1) return;
    final next = CafeOrder.flow[idx + 1];
    try {
      if (next == 'collected') {
        final updated = await collectOrderAndPay(context, order);
        if (updated == null || !mounted) return;
      } else {
        await context.read<ApiClient>().updateOrderStatus(order.id, next);
      }

      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  static const _nextLabel = {
    'received': 'Start preparing',
    'preparing': 'Mark ready',
    'ready': 'Serve to Customer',
  };

  Future<void> _reopenAndAdd(CafeOrder order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reopen order'),
        content: Text(
            'Order #${order.id} will be reopened and ${order.tableNumber != null ? 'table ${order.tableNumber} ' : ''}'
            'locked again. ${formatMoney(order.paidAmount)} already paid stays '
            'as credit — only the new items will be charged.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<ApiClient>().reopenOrder(order.id);
      if (!mounted) return;
      context.read<CartState>().tablesChanged();
      await _load();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TakeOrderScreen(
            tableNumber: order.tableNumber ?? '',
            existingOrderId: order.id,
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addItemsToOrder(CafeOrder order) async {
    final cart = context.read<CartState>();
    final api = context.read<ApiClient>();
    final messenger = ScaffoldMessenger.of(context);
    final snapshot = List<CartLine>.from(cart.lines);
    await showMenuPickerSheet(context);
    if (!mounted) return;
    final added = cart.lines.where((l) => !snapshot.contains(l)).toList();
    if (added.isEmpty) return;
    try {
      if (order.status == 'collected') {
        await api.reopenOrder(order.id);
        cart.tablesChanged();
      }
      final updated = await api.addOrderItems(
          order.id, added.map((l) => l.toOrderItemJson()).toList());
      for (final l in added) {
        cart.removeLine(l);
      }
      await _load();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('Added ${added.length} item(s) to Order #${order.id} • '
              'new total ${formatMoney(updated.total)}')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.grey),
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final visible = _activeOnly
        ? _orders.where((o) => o.status != 'collected').toList()
        : _orders;

    final received = _orders.where((o) => o.status == 'received').length;
    final preparing = _orders.where((o) => o.status == 'preparing').length;
    final ready = _orders.where((o) => o.status == 'ready').length;
    final collected = _orders.where((o) => o.status == 'collected').length;

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          // ── Summary bar ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.45),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SummaryTile('New', received, Colors.blueGrey),
                _SummaryTile('Prep', preparing, Colors.orange),
                _SummaryTile('Ready', ready, Colors.green),
                _SummaryTile('Done', collected, Colors.grey),
              ],
            ),
          ),

          // ── Toggle ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: Colors.green.shade400),
                const SizedBox(width: 6),
                Text(
                  'Active orders only',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const Spacer(),
                Switch(
                  value: _activeOnly,
                  onChanged: (v) => setState(() => _activeOnly = v),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),

          // ── Orders list ──
          Expanded(
            child: visible.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 120),
                    Center(child: Text('No orders yet.')),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final o = visible[i];
                      final canAdvance = _nextLabel.containsKey(o.status);
                      final canEdit = canEditOrder(auth, o);
                      return _OrderCard(
                        order: o,
                        statusColor: _statusColor(o.status),
                        canAdvance: canAdvance,
                        canEdit: canEdit,
                        nextLabel: _nextLabel[o.status],
                        onAdvance: () => _advance(o),
                        onAddItem: () => _addItemsToOrder(o),
                        onReopen: () => _reopenAndAdd(o),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Reusable Order Card ───

class _OrderCard extends StatelessWidget {
  final CafeOrder order;
  final Color statusColor;
  final bool canAdvance;
  final bool canEdit;
  final String? nextLabel;
  final VoidCallback onAdvance;
  final VoidCallback onAddItem;
  final VoidCallback onReopen;

  const _OrderCard({
    required this.order,
    required this.statusColor,
    required this.canAdvance,
    required this.canEdit,
    this.nextLabel,
    required this.onAdvance,
    required this.onAddItem,
    required this.onReopen,
  });

  @override
  Widget build(BuildContext context) {
    final o = order;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OrderDetailScreen(order: o),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: statusColor.withValues(alpha: 0.08),
              child: Row(
                children: [
                  Text('#${o.id}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(o.status,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                  if (o.tableNumber != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('T${o.tableNumber}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange.shade800)),
                    ),
                  ],
                  const Spacer(),
                  Text(formatMoney(o.total),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ],
              ),
            ),

            // ── Customer + phone + staff ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(
                children: [
                  Icon(Icons.person_outline,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(o.customerName,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                  if (o.customerPhone != null &&
                      o.customerPhone!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.phone_outlined,
                        size: 12, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text(o.customerPhone!,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                  if (o.takenBy != null && o.takenBy!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.storefront_outlined,
                        size: 12, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text(o.takenBy!,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),

            // ── Items ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in o.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        children: [
                          Text('${line.qty}×',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${line.name}'
                              '${line.options.isEmpty ? '' : ' (${line.options.join(', ')})'}',
                              style: TextStyle(
                                  fontSize: 13, color: scheme.onSurfaceVariant),
                            ),
                          ),
                          Text(formatMoney(line.lineTotal),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // ── Notes ──
            if (o.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    o.notes,
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: Colors.amber.shade900,
                    ),
                  ),
                ),
              ),

            // ── Actions ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (canEdit)
                    OutlinedButton.icon(
                      onPressed: onAddItem,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  if (canEdit && canAdvance) const SizedBox(width: 8),
                  if (canAdvance)
                    o.status == 'ready'
                        ? FilledButton.icon(
                            onPressed: onAdvance,
                            icon: const Icon(Icons.shopping_bag, size: 16),
                            label: Text(nextLabel!),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.green,
                              visualDensity: VisualDensity.compact,
                            ),
                          )
                        : FilledButton.tonal(
                            onPressed: onAdvance,
                            child: Text(nextLabel!),
                          )
                  else if (canEdit && o.status == 'collected')
                    FilledButton.tonal(
                      onPressed: onReopen,
                      child: const Text('Reopen'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _SummaryTile(this.label, this.count, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$count',
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
