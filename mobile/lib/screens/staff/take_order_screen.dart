import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/menu_item.dart';
import '../../services/api_client.dart';
import '../../services/offline/offline.dart';
import '../../state/cart_state.dart';
import '../../util/money.dart';
import '../../widgets/menu_image.dart';
import '../customer/item_detail_screen.dart';
import 'order_cart_screen.dart';

/// Staff take-order screen for a specific table. Starts a fresh cart.
/// When [existingOrderId] is set, it becomes "add items to order" mode for a
/// reopened order instead of placing a brand-new one.
class TakeOrderScreen extends StatefulWidget {
  final String tableNumber;
  final String? existingOrderId;
  const TakeOrderScreen({
    super.key,
    required this.tableNumber,
    this.existingOrderId,
  });

  @override
  State<TakeOrderScreen> createState() => _TakeOrderScreenState();
}

class _TakeOrderScreenState extends State<TakeOrderScreen> {
  late Future<List<MenuItem>> _future;

  bool get _isAddMode => widget.existingOrderId != null;

  @override
  void initState() {
    super.initState();
    // Fresh cart for this table / reopened order.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CartState>().clear();
    });
    _future = _loadMenu();
  }

  /// Fetch the menu, falling back to the last-good snapshot when offline so
  /// staff can keep building carts (submitting them goes through the queue).
  Future<List<MenuItem>> _loadMenu() async {
    try {
      final items = await context.read<ApiClient>().fetchMenu();
      unawaited(MenuCache.save(items));
      return items;
    } catch (e) {
      final cached = await MenuCache.load();
      if (cached != null) return cached;
      rethrow;
    }
  }

  String _pretty(String c) => c
      .replaceAll('_', ' ')
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAddMode
            ? 'Order #${widget.existingOrderId} • Add items'
            : 'Table ${widget.tableNumber} • New order'),
      ),
      body: FutureBuilder<List<MenuItem>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          final items = snap.data ?? [];
          final categories = <String>[];
          for (final i in items) {
            if (!categories.contains(i.category)) categories.add(i.category);
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              for (final cat in categories) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                  child: Text(_pretty(cat),
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                ...items
                    .where((i) => i.category == cat)
                    .map((i) => _Tile(item: i)),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: cart.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => OrderCartScreen(
                              tableNumber: widget.tableNumber,
                              existingOrderId: widget.existingOrderId,
                            )),
                  ),
                  child: Text(
                      'Review • ${cart.count} item(s) • ${formatMoney(cart.total)}'),
                ),
              ),
            ),
    );
  }
}

class _Tile extends StatelessWidget {
  final MenuItem item;
  const _Tile({required this.item});

  @override
  Widget build(BuildContext context) {
    final disabled = !item.available;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: MenuImage(url: item.imageUrl, width: 56, height: 56),
          ),
          title: Text(item.name),
          subtitle: Text(disabled ? 'Sold out' : item.description,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(formatMoney(item.basePrice),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          onTap: disabled
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ItemDetailScreen(item: item)),
                  ),
        ),
      ),
    );
  }
}
