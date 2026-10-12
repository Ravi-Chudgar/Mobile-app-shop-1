import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import 'customer_ui.dart';

/// Customer tracking screen for a QR order: polls the public status
/// endpoint every few seconds and shows where the order is in the kitchen.
/// [tenant] keeps the polling on the cafe the order belongs to (null =
/// default cafe, legacy endpoint).
class CustomerOrderStatusScreen extends StatefulWidget {
  final String orderId;
  final String? tableNumber;
  final String? tenant;
  final VoidCallback? onOrderMore;

  const CustomerOrderStatusScreen({
    super.key,
    required this.orderId,
    this.tableNumber,
    this.tenant,
    this.onOrderMore,
  });

  @override
  State<CustomerOrderStatusScreen> createState() =>
      _CustomerOrderStatusScreenState();
}

class _CustomerOrderStatusScreenState extends State<CustomerOrderStatusScreen> {
  Timer? _timer;
  Map<String, dynamic>? _order;
  String? _error;
  bool _loading = true;

  static const _steps = [
    ('received', 'Order received', Icons.receipt_long_outlined),
    ('preparing', 'Being prepared', Icons.coffee_maker_outlined),
    (
      'ready',
      'Ready — watch for your name',
      Icons.notifications_active_outlined
    ),
    ('collected', 'Enjoy!', Icons.check_circle_outline),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final data = await context
          .read<ApiClient>()
          .fetchPublicOrder(widget.orderId, tenant: widget.tenant);
      if (!mounted) return;
      setState(() {
        _order = data;
        _error = null;
        _loading = false;
      });
      final status = data['status'];
      if (status == 'collected' || status == 'cancelled') {
        _timer?.cancel();
      }
    } catch (e) {
      if (!mounted) return;
      // Keep the last good snapshot on a transient failure.
      setState(() {
        _error = _order == null ? '$e' : null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Order #${widget.orderId}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? EmptyStateArt(
                  title: 'Could not load your order',
                  message: '$_error',
                  icon: Icons.wifi_off_rounded,
                  action: FilledButton.tonal(
                      onPressed: _refresh, child: const Text('Retry')),
                )
              : _buildStatus(),
    );
  }

  Widget _buildStatus() {
    final order = _order!;
    final status = (order['status'] ?? 'received') as String;
    final items = (order['items'] as List?) ?? [];
    final total = (order['total'] as num?)?.toInt() ?? 0;
    final table = order['table_number'] ?? widget.tableNumber;
    final activeIndex = _steps.indexWhere((s) => s.$1 == status);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _hero(status, table),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(height: 14),
                  for (var i = 0; i < _steps.length; i++)
                    _stepTile(i, _steps[i], activeIndex, status),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _itemsCard(items, total, table),
          if (widget.onOrderMore != null) ...[
            const SizedBox(height: 20),
            GradientPillButton(
              onPressed: widget.onOrderMore,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_shopping_cart_rounded, size: 20),
                  SizedBox(width: 8),
                  Text('Order more'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hero(String status, Object? table) {
    final (title, emoji, gradient) = switch (status) {
      'preparing' => ('Being prepared with love', '☕', CafeGradients.sunrise),
      'ready' => ('Ready — listen for your name!', '🔔', CafeGradients.mint),
      'collected' => ('Enjoy your order!', '💚', CafeGradients.mint),
      'cancelled' => ('Order cancelled', '😔', CafeGradients.berry),
      _ => (
          'Order received',
          '🧾',
          CafeGradients.coffee,
        ),
    };
    return HeroBanner(
      gradient: gradient,
      illustration: Align(
        alignment: const Alignment(1.0, 0.15),
        child: Opacity(
          opacity: 0.28,
          child: SizedBox(
            width: 150,
            height: 150,
            child: CustomPaint(painter: LatteArtPainter(withBeans: false)),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroChip(
                icon: Icons.table_restaurant_rounded,
                label: table == null ? 'Table —' : 'Table $table',
              ),
              _HeroChip(
                icon: Icons.tag_rounded,
                label: '#${widget.orderId}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemsCard(List items, int total, Object? table) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Items',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 14),
            for (final raw in items)
              Builder(builder: (context) {
                final line = Map<String, dynamic>.from(raw as Map);
                final opts = ((line['selected_options'] ?? []) as List)
                    .map((o) => '${(o as Map)['label']}')
                    .join(' · ');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 26,
                        height: 24,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        decoration: BoxDecoration(
                          color: CafePalette.latte,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${line['qty']}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: CafePalette.espresso,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${line['name']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (opts.isNotEmpty)
                              Text(opts,
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black54)),
                          ],
                        ),
                      ),
                      Text(
                        formatMoney(
                            ((line['line_total'] as num?)?.toInt() ?? 0)),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                );
              }),
            const Divider(),
            Row(
              children: [
                const Expanded(
                    child: Text('Total (GST incl.)',
                        style: TextStyle(fontWeight: FontWeight.w600))),
                Text(formatMoney(total),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepTile(int index, (String, String, IconData) step, int activeIndex,
      String status) {
    final done = activeIndex > index ||
        (activeIndex >= 0 && index == activeIndex && status == 'collected');
    final current = index == activeIndex && status != 'collected';
    final isLast = index == _steps.length - 1;
    final circleColor = done
        ? CafePalette.mint
        : current
            ? CafePalette.coffee
            : CafePalette.latte;
    final iconColor = done || current
        ? Colors.white
        : CafePalette.caramel.withValues(alpha: 0.8);

    return Opacity(
      opacity: activeIndex < 0 || index <= activeIndex ? 1 : 0.55,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: done
                        ? null
                        : current
                            ? CafeGradients.coffee
                            : null,
                    color: done
                        ? CafePalette.mint
                        : (current ? null : circleColor),
                    shape: BoxShape.circle,
                    boxShadow: done || current
                        ? [
                            BoxShadow(
                              color:
                                  (done ? CafePalette.mint : CafePalette.coffee)
                                      .withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    done ? Icons.check_rounded : step.$3,
                    size: 17,
                    color: iconColor,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: done
                          ? CafePalette.mint.withValues(alpha: 0.7)
                          : CafePalette.latte,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 18, top: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.$2,
                      style: TextStyle(
                        fontWeight:
                            current || done ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 14.5,
                        color: current || done ? null : Colors.black54,
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(height: 2),
                      const Text(
                        'Hang tight — we are on it',
                        style:
                            TextStyle(fontSize: 12, color: CafePalette.coffee),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (current)
              const Padding(
                padding: EdgeInsets.only(top: 9),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small translucent chip used inside the tracking hero.
class _HeroChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HeroChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
