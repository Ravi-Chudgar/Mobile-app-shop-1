import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models/cafe_table.dart';
import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../state/cart_state.dart';
import '../../util/money.dart';
import '../../widgets/collect_order_flow.dart';
import '../../widgets/ui_kit.dart';
import 'customer_info_screen.dart';

/// Staff picks a table. Empty -> take an order. Occupied -> view/advance/free.
class TablesGridScreen extends StatefulWidget {
  const TablesGridScreen({super.key});

  @override
  State<TablesGridScreen> createState() => _TablesGridScreenState();
}

class _TablesGridScreenState extends State<TablesGridScreen> {
  /// In-memory view preference (no persistence dependency in the app).
  /// Static so the choice survives rebuilds for the app session.
  static bool _floorView = false;

  List<CafeTable> _tables = [];
  final Map<String, CafeOrder?> _orderCache = {};
  bool _loading = true;
  String? _error;
  int _lastTablesTick = 0;
  CartState? _cart;

  @override
  void initState() {
    super.initState();
    _lastTablesTick = context.read<CartState>().tablesTick;
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cart = context.read<CartState>();
    if (_cart != cart) {
      _cart?.removeListener(_onCartChanged);
      _cart = cart;
      cart.addListener(_onCartChanged);
    }
  }

  @override
  void dispose() {
    _cart?.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() {
    final tick = context.read<CartState>().tablesTick;
    if (tick != _lastTablesTick) {
      _lastTablesTick = tick;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    try {
      final tables = await api.fetchTables();
      _orderCache.clear();
      final orders = await api.fetchOrders();
      for (final order in orders) {
        if (order.id.isNotEmpty) {
          _orderCache[order.id] = order;
        }
      }
      if (!mounted) return;
      setState(() {
        _tables = tables;
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

  /// The staff member currently serving [t] (from the live order when known).
  String? _serverOf(CafeTable t) {
    final order = t.orderId != null ? _orderCache[t.orderId] : null;
    return order?.takenBy ?? t.takenBy;
  }

  /// A table is locked for this user when another server is on it.
  bool _isLocked(CafeTable t) {
    final auth = context.read<AuthState>();
    if (auth.isOwner) return false;
    final server = _serverOf(t);
    return server != null && server.isNotEmpty && server != auth.username;
  }

  Future<void> _openTable(CafeTable t) async {
    if (t.isOccupied) {
      final order = t.orderId != null ? _orderCache[t.orderId] : null;
      final server = _serverOf(t);
      await _showOccupied(t, order, locked: _isLocked(t), server: server);
    } else {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => CustomerInfoScreen(tableNumber: t.number)));
    }
    _load();
  }

  Future<void> _showOccupied(
    CafeTable t,
    CafeOrder? order, {
    required bool locked,
    String? server,
  }) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // ── Header ──
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: CafeGradients.peach,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.table_restaurant_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Table ${t.number}',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        if (order != null)
                          Text(
                            'Order #${order.id} • ${order.status} • ${formatMoney(order.total)}',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey.shade600),
                          ),
                      ],
                    ),
                  ),
                  if (server != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: CafePalette.latte,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'by $server',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: CafePalette.coffee),
                      ),
                    ),
                ],
              ),
            ),

            const Divider(height: 1),

            // ── Items ──
            if (order != null)
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    const SizedBox(height: 8),
                    for (final l in order.items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: CafePalette.latte,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('${l.qty}×',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: CafePalette.coffee)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l.name,
                                      style: const TextStyle(fontSize: 14)),
                                  if (l.options.isNotEmpty)
                                    Text(l.options.join(' • '),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade500)),
                                ],
                              ),
                            ),
                            Text(formatMoney(l.lineTotal),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

            // ── Actions ──
            const Divider(height: 1),
            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: locked
                    ? Row(
                        children: [
                          const Icon(Icons.lock_outline,
                              color: CafePalette.coffee, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Locked by $server',
                              style: const TextStyle(color: CafePalette.coffee),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (order != null &&
                              (order.customerPhone?.isNotEmpty ?? false))
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _sendWhatsApp(order);
                                },
                                icon: const Icon(Icons.chat, size: 18),
                                label: const Text('Send Bill'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: CafePalette.mint,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                          if (order != null &&
                              (order.customerPhone?.isNotEmpty ?? false))
                            const SizedBox(width: 10),
                          if (order != null && order.status == 'ready')
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _advance(order);
                                },
                                icon: const Icon(Icons.shopping_bag, size: 18),
                                label: const Text('Serve to Customer'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: CafePalette.mint,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                          if (order != null && order.status != 'collected') ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await context
                                      .read<ApiClient>()
                                      .freeTable(t.number);
                                  _load();
                                },
                                icon: const Icon(Icons.check_circle_outline,
                                    size: 18),
                                label: const Text('Free table'),
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                          ],
                          if (order == null || order.status == 'collected')
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await context
                                      .read<ApiClient>()
                                      .freeTable(t.number);
                                  _load();
                                },
                                icon: const Icon(Icons.check_circle_outline,
                                    size: 18),
                                label: const Text('Free table'),
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _customerPhone(CafeOrder order) {
    final phone = order.customerPhone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    if (phone.isEmpty) return '';
    if (phone.startsWith('91') && phone.length >= 12) return phone;
    if (phone.length == 10) return '91$phone';
    return phone;
  }

  String _buildBillText(CafeOrder order) {
    final items = order.items.map((item) {
      final opts =
          item.options.isNotEmpty ? '\n   ${item.options.join(" | ")}' : '';
      return '  ${item.name} x${item.qty}  ₹${item.lineTotal}$opts';
    }).join('\n');

    final upiLink =
        'upi://pay?pa=${AppConfig.upiId}&pn=${Uri.encodeComponent(AppConfig.merchantName)}&am=${order.total}&cu=INR';

    final buffer = StringBuffer()
      ..writeln('╭─────────────────────────╮')
      ..writeln('│     ${AppConfig.merchantName}     │')
      ..writeln('╰─────────────────────────╯')
      ..writeln()
      ..writeln('📋 Bill #${order.id}')
      ..writeln(
          '📅 ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.tryParse(order.createdAt) ?? DateTime.now())}')
      ..writeln('👤 ${order.customerName}')
      ..writeln('🪑 Table ${order.tableNumber ?? "N/A"}')
      ..writeln('👨‍🍳 Served by: ${order.takenBy ?? 'N/A'}')
      ..writeln()
      ..writeln('─────────────────────────')
      ..writeln('  ITEM              QTY   AMT')
      ..writeln('─────────────────────────')
      ..writeln(items)
      ..writeln('─────────────────────────')
      ..writeln()
      ..writeln('💰 TOTAL: ₹${order.total}')
      ..writeln('💳 Payment: ${order.paymentMethod.toUpperCase()}')
      ..writeln('✅ Status: ${order.paymentStatus.toUpperCase()}')
      ..writeln();

    if (order.paymentStatus != 'paid') {
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

  Future<void> _sendWhatsApp(CafeOrder order) async {
    final phone = _customerPhone(order);
    if (phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No customer phone number on this order')),
        );
      }
      return;
    }
    final billText = _buildBillText(order);
    final url =
        Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(billText)}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp')),
        );
      }
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
        _load();
        final hasPhone =
            updated.customerPhone != null && updated.customerPhone!.isNotEmpty;
        final sendBill = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.check_circle, color: Colors.green, size: 40),
            title: const Text('Payment collected'),
            content: Text(
              hasPhone
                  ? 'Send bill to ${updated.customerName} via WhatsApp?'
                  : 'No phone number on this order. Bill not sent.',
            ),
            actions: [
              if (hasPhone)
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Skip'),
                ),
              if (hasPhone)
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.chat, size: 18),
                  label: const Text('Send Bill'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                ),
              if (!hasPhone)
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
            ],
          ),
        );
        if (sendBill == true && mounted) {
          await _sendWhatsApp(updated);
        }
      } else {
        await context.read<ApiClient>().updateOrderStatus(order.id, next);
        _load();
      }
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.grey),
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }

    final occupied = _tables.where((t) => t.isOccupied).length;
    final empty = _tables.length - occupied;

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          // ── Compact hero: greeting + free/occupied pills ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: HeroBanner(
              gradient: CafeGradients.coffee,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              illustration: Align(
                alignment: const Alignment(0.9, 0.4),
                child: Opacity(
                  opacity: 0.16,
                  child: SizedBox(
                    width: 120,
                    height: 120,
                    child: CustomPaint(painter: LatteArtPainter()),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting(),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_tables.length} tables on the floor',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.78),
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  _CountPill(
                      label: 'Free', value: '$empty', color: CafePalette.mint),
                  const SizedBox(width: 8),
                  _CountPill(
                      label: 'Seated',
                      value: '$occupied',
                      color: CafePalette.peach),
                ],
              ),
            ),
          ),

          // ── View toggle: grid (list) vs floor map ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Text(
                  'Tables',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        label: Text('Grid'),
                        icon: Icon(Icons.grid_view, size: 15)),
                    ButtonSegment(
                        value: true,
                        label: Text('Floor'),
                        icon: Icon(Icons.map_outlined, size: 15)),
                  ],
                  selected: {_floorView},
                  onSelectionChanged: (v) =>
                      setState(() => _floorView = v.first),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.white,
                    foregroundColor:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                    selectedBackgroundColor: CafePalette.coffee,
                    selectedForegroundColor: Colors.white,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),

          // ── Grid / Floor map ──
          Expanded(
            child: _tables.isEmpty
                ? const EmptyStateArt(
                    title: 'No tables configured',
                    message:
                        'Ask the owner to add tables from the floor editor.',
                    icon: Icons.table_restaurant_outlined,
                  )
                : _floorView
                    ? _buildFloorMap()
                    : _buildGridView(),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final auth = context.read<AuthState>();
    final who = auth.name ?? auth.username;
    if (who == null || who.isEmpty) return 'Floor';
    return 'Hi ${who.split(' ').first}';
  }

  Widget _buildGridView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 600 ? 4 : 3;
        return GridView.count(
          crossAxisCount: crossAxisCount,
          padding: const EdgeInsets.all(12),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.84,
          children: _tables
              .map((t) => _TableCard(
                    table: t,
                    order: _orderCache[t.orderId],
                    locked: _isLocked(t),
                    onTap: () => _openTable(t),
                  ))
              .toList(),
        );
      },
    );
  }

  /// Visual floor map: tables positioned by their saved x/y/w/h (percent of
  /// the canvas), falling back to a grid when a table has no layout yet.
  Widget _buildFloorMap() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cw = constraints.maxWidth;
        final ch = constraints.maxHeight;
        return Stack(
          children: [
            for (var i = 0; i < _tables.length; i++)
              _floorTile(_tables[i], i, cw, ch),
          ],
        );
      },
    );
  }

  Positioned _floorTile(CafeTable t, int index, double cw, double ch) {
    final rect = t.hasLayout
        ? TableRect(t.x!, t.y!, t.w!, t.h!)
        : fallbackRect(index, total: _tables.length);
    return Positioned(
      left: rect.x / 100 * cw,
      top: rect.y / 100 * ch,
      width: rect.w / 100 * cw,
      height: rect.h / 100 * ch,
      child: _FloorTile(
        table: t,
        order: t.orderId != null ? _orderCache[t.orderId] : null,
        locked: _isLocked(t),
        onTap: () => _openTable(t),
      ),
    );
  }
}

// ─── Status copy shared by grid + floor tiles ───

String _tableStatusLabel(String status) {
  switch (status) {
    case 'received':
      return 'Order placed';
    case 'preparing':
      return 'Preparing';
    case 'ready':
      return 'Ready to serve';
    case 'collected':
      return 'Bill pending';
    default:
      return status;
  }
}

// ─── Table Card ───

class _TableCard extends StatelessWidget {
  final CafeTable table;
  final CafeOrder? order;
  final bool locked;
  final VoidCallback onTap;

  const _TableCard({
    required this.table,
    this.order,
    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final occupied = table.isOccupied;
    final accent = occupied ? CafePalette.peach : CafePalette.mint;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'TABLE',
                        style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade500),
                      ),
                    ),
                    Text(occupied ? '🧾' : '🍽️',
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '#${table.number}',
                  style: TextStyle(
                      fontSize: 26,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      color:
                          occupied ? CafePalette.espresso : CafePalette.coffee),
                ),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    order != null && occupied
                        ? _tableStatusLabel(order!.status)
                        : occupied
                            ? 'Occupied'
                            : 'Free',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: occupied
                          ? const Color(0xFF9A4A2B)
                          : const Color(0xFF2F6B51),
                    ),
                  ),
                ),
                const Spacer(),
                if (occupied && order != null)
                  Text(
                    formatMoney(order!.total),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: CafePalette.espresso),
                  ),
                if (occupied && table.takenBy != null)
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          size: 11, color: CafePalette.caramel),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          table.takenBy!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10, color: CafePalette.caramel),
                        ),
                      ),
                    ],
                  ),
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline,
                            size: 11, color: CafePalette.berry),
                        const SizedBox(width: 3),
                        Text(
                          'Locked',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Colors.brown.shade400),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Count Pill (hero) ───

class _CountPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _CountPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('$value $label',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ─── Floor Map Tile ───

class _FloorTile extends StatelessWidget {
  final CafeTable table;
  final CafeOrder? order;
  final bool locked;
  final VoidCallback onTap;

  const _FloorTile({
    required this.table,
    this.order,
    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final occupied = table.isOccupied;
    final accent = occupied ? CafePalette.peach : CafePalette.mint;
    final borderRadius = BorderRadius.circular(14);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: table.isRound ? null : borderRadius,
        shape: table.isRound ? BoxShape.circle : BoxShape.rectangle,
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: table.isRound ? null : borderRadius,
          customBorder: table.isRound ? const CircleBorder() : null,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(occupied ? '🧾' : '🍽️',
                      style: const TextStyle(fontSize: 14)),
                  Text(
                    'T${table.number}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  if (table.zone != 'main')
                    Text(
                      table.zone,
                      style:
                          TextStyle(fontSize: 8, color: Colors.grey.shade700),
                    ),
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      occupied
                          ? (order != null
                              ? _tableStatusLabel(order!.status)
                              : 'Occupied')
                          : 'Free',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: occupied
                            ? const Color(0xFF9A4A2B)
                            : const Color(0xFF2F6B51),
                      ),
                    ),
                  ),
                  if (locked)
                    const Icon(Icons.lock_outline,
                        size: 10, color: CafePalette.berry),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
