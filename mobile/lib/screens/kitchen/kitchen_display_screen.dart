import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../services/notification_service.dart';
import '../../services/printer_models.dart';
import '../../services/printing_service.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';

/// Kitchen display: incoming orders grouped by stage, colour-coded by age
/// (fresh = mint, aging = sunshine, late = berry) so the pass can triage.
class KitchenDisplayScreen extends StatefulWidget {
  final bool showCompleted;
  const KitchenDisplayScreen({super.key, this.showCompleted = false});

  @override
  State<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends State<KitchenDisplayScreen> {
  List<CafeOrder> _orders = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    try {
      final all = await api.fetchOrders();
      if (!mounted) return;
      setState(() {
        _orders = all;
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

  List<CafeOrder> get _visible {
    if (widget.showCompleted) {
      return _orders.where((o) => o.status == 'ready').toList();
    }
    return _orders
        .where((o) => o.status == 'received' || o.status == 'preparing')
        .toList();
  }

  /// Fresh -> aging -> late, measured from the order timestamp.
  static Color ageColor(CafeOrder order) {
    final age = _ageMinutes(order.createdAt);
    if (age == null) return CafePalette.mint;
    if (age <= 5) return CafePalette.mint;
    if (age <= 15) return CafePalette.sunshine;
    return CafePalette.berry;
  }

  static int? _ageMinutes(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return null;
    final dt = DateTime.tryParse(createdAt);
    if (dt == null) return null;
    return DateTime.now().difference(dt.toLocal()).inMinutes;
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'received':
        return 'NEW';
      case 'preparing':
        return 'PREPARING';
      case 'ready':
        return 'READY';
      default:
        return status.toUpperCase();
    }
  }

  String _sectionTitle(String status) {
    switch (status) {
      case 'received':
        return 'Received';
      case 'preparing':
        return 'Preparing';
      case 'ready':
        return 'Ready to serve';
      default:
        return status;
    }
  }

  String _sectionSubtitle(String status) {
    switch (status) {
      case 'received':
        return 'Fresh tickets waiting to start';
      case 'preparing':
        return 'On the pass — keep them moving';
      case 'ready':
        return 'Waiting for a server to pick up';
      default:
        return '';
    }
  }

  Future<void> _advance(CafeOrder order) async {
    final idx = CafeOrder.flow.indexOf(order.status);
    if (idx < 0 || idx >= CafeOrder.flow.length - 1) return;
    final next = CafeOrder.flow[idx + 1];
    try {
      await context.read<ApiClient>().updateOrderStatus(order.id, next);

      // Notify staff when order is ready
      if (next == 'ready') {
        await NotificationService.showOrderReady(
          orderId: order.id,
          customerName: order.customerName,
          tableNumber: order.tableNumber,
          takenBy: order.takenBy,
        );
      }

      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Manual KOT reprint from the kitchen display.
  Future<void> _printKot(CafeOrder order) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiClient>();
    try {
      final result = await PrintingService.instance.printKot(order.id, api);
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.green,
        content: Text('✓ $result'),
      ));
    } on PrinterException catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('KOT print failed: ${e.message}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Text('KOT print failed: $e'),
      ));
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
            const Icon(Icons.error_outline, size: 40, color: Colors.grey),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final visible = _visible;

    if (visible.isEmpty) {
      return EmptyStateArt(
        title: widget.showCompleted ? 'No ready orders' : 'No pending orders',
        message: widget.showCompleted
            ? 'Orders ready for pickup will appear here'
            : 'New orders will appear here automatically',
        icon: widget.showCompleted
            ? Icons.check_circle_outline
            : Icons.kitchen_outlined,
      );
    }

    // Group the visible tickets by stage so the pass reads top to bottom.
    const stageOrder = ['received', 'preparing', 'ready'];
    final groups = <String, List<CafeOrder>>{};
    for (final o in visible) {
      groups.putIfAbsent(o.status, () => <CafeOrder>[]).add(o);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final status in stageOrder)
            if (groups[status] != null && groups[status]!.isNotEmpty) ...[
              SectionHeader(
                title: _sectionTitle(status),
                subtitle:
                    '${groups[status]!.length} ${groups[status]!.length == 1 ? 'ticket' : 'tickets'} · ${_sectionSubtitle(status)}',
                trailing: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: CafePalette.latte,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${groups[status]!.length}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: CafePalette.coffee)),
                ),
              ),
              for (final order in groups[status]!) ...[
                _KitchenOrderCard(
                  order: order,
                  ageColor: ageColor(order),
                  statusLabel: _statusLabel(order.status),
                  onAdvance: () => _advance(order),
                  onPrintKot: () => _printKot(order),
                ),
                const SizedBox(height: 12),
              ],
            ],
        ],
      ),
    );
  }
}

class _KitchenOrderCard extends StatelessWidget {
  final CafeOrder order;
  final Color ageColor;
  final String statusLabel;
  final VoidCallback onAdvance;
  final VoidCallback onPrintKot;

  const _KitchenOrderCard({
    required this.order,
    required this.ageColor,
    required this.statusLabel,
    required this.onAdvance,
    required this.onPrintKot,
  });

  String _nextAction(String status) {
    switch (status) {
      case 'received':
        return 'Start Preparing';
      case 'preparing':
        return 'Mark Ready';
      default:
        return '';
    }
  }

  IconData _nextIcon(String status) {
    switch (status) {
      case 'received':
        return Icons.restaurant;
      case 'preparing':
        return Icons.check_circle;
      default:
        return Icons.check;
    }
  }

  /// Sunshine is too light for white text — use espresso on it.
  Color get _onAge =>
      ageColor == CafePalette.sunshine ? CafePalette.espresso : Colors.white;

  String _timeAgo(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nextLabel = _nextAction(order.status);
    final elapsed = _timeAgo(order.createdAt);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: ageColor.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: status, order id, age ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: ageColor.withValues(alpha: 0.12),
              border: Border(
                left: BorderSide(color: ageColor, width: 5),
                bottom: BorderSide(
                    color: ageColor.withValues(alpha: 0.25), width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ageColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: _onAge,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '#${order.id}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                if (elapsed.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: ageColor.withValues(alpha: 0.6)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined, size: 12, color: ageColor),
                        const SizedBox(width: 4),
                        Text(
                          elapsed,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: ageColor,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // ── Table / customer / total ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                if (order.tableNumber != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: CafePalette.latte,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.table_restaurant,
                            size: 14, color: CafePalette.coffee),
                        const SizedBox(width: 4),
                        Text(
                          'Table ${order.tableNumber}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: CafePalette.coffee,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (order.customerName.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      order.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  formatMoney(order.total),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: CafePalette.espresso,
                  ),
                ),
              ],
            ),
          ),

          // ── Items list ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ITEMS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade500,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                ...order.items.map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              gradient: CafeGradients.forSeed(item.name),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              dishEmoji(item.name, category: item.category),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: CafePalette.latte,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${item.qty}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: CafePalette.coffee,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (item.options.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                item.options.join(', '),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    )),
              ],
            ),
          ),

          // ── Notes ──
          if (order.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
              child: Row(
                children: [
                  Icon(Icons.note, size: 14, color: Colors.amber.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      order.notes,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.amber.shade900,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Action buttons ──
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (nextLabel.isNotEmpty)
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: onAdvance,
                        icon: Icon(_nextIcon(order.status), size: 20),
                        label: Text(
                          nextLabel,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _onAge,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: ageColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (nextLabel.isNotEmpty) const SizedBox(width: 10),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: onPrintKot,
                    icon: const Icon(Icons.print, size: 18),
                    label: const Text('Print KOT'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
