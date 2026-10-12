import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/menu_item.dart';
import '../../services/api_client.dart';
import '../../state/tenant_state.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import 'cart_screen.dart';
import 'customer_cart.dart';
import 'customer_item_sheet.dart';
import 'customer_ui.dart';
import 'order_lookup_screen.dart';

/// Customer self-order menu — the screen the table QR code opens.
///
/// [tableNumber] comes from the QR deep link ("/table/<n>"); when the app is
/// opened without one the customer picks/enters a table before checkout.
/// [tenant] is the cafe code carried by a tenant-scoped card
/// ("/t/<slug>/table/<n>") — every public call then targets that cafe,
/// while null keeps the legacy (default-tenant) endpoints.
class CustomerMenuScreen extends StatefulWidget {
  final String? tableNumber;
  final String? tenant;
  const CustomerMenuScreen({super.key, this.tableNumber, this.tenant});

  @override
  State<CustomerMenuScreen> createState() => _CustomerMenuScreenState();
}

class _CustomerMenuScreenState extends State<CustomerMenuScreen> {
  late final CustomerCart _cart;
  List<MenuItem> _items = [];
  String? _category;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cart = CustomerCart(tableNumber: widget.tableNumber);
    // Best effort: brand the screen with the scanned cafe's name. Missing
    // provider (tests) or a failed lookup just keeps the generic copy.
    if (widget.tenant != null) {
      try {
        context.read<TenantState>().loadFor(widget.tenant);
      } catch (_) {
        // No TenantState above us — the menu itself does not need it.
      }
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await context
          .read<ApiClient>()
          .fetchPublicMenu(tenant: widget.tenant);
      if (!mounted) return;
      setState(() {
        _items = items;
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

  List<String> get _categories {
    final seen = <String>{};
    for (final i in _items) {
      if (i.category.isNotEmpty) seen.add(i.category);
    }
    final list = seen.toList()..sort();
    return list;
  }

  List<MenuItem> get _visible => _category == null
      ? _items
      : _items.where((i) => i.category == _category).toList();

  Future<void> _pickTable() async {
    final controller = TextEditingController(text: _cart.tableNumber ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Which table?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Table number'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (picked != null) _cart.setTable(picked);
  }

  Future<void> _openItem(MenuItem item) async {
    if (!item.available) return;
    final added = await showCustomerItemSheet(context, item, _cart);
    if (!added || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: CafePalette.espresso,
      duration: const Duration(milliseconds: 1400),
      content: Text('${item.name} added to your order'),
    ));
  }

  void _openCart() {
    if (_cart.isEmpty) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                CustomerCartScreen(cart: _cart, tenant: widget.tenant)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _cart,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(_cart.tableNumber == null
                ? 'Self order'
                : 'Table ${_cart.tableNumber} • Self order'),
            actions: [
              IconButton(
                tooltip: 'Track an order',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            CustomerOrderLookupScreen(tenant: widget.tenant))),
              ),
            ],
          ),
          body: _buildBody(),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.5),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _cart.isEmpty
                    ? const SizedBox.shrink(key: ValueKey('cart-empty'))
                    : FloatingCartBar(
                        key: const ValueKey('cart-bar'),
                        count: _cart.count,
                        total: _cart.total,
                        onTap: _openCart,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Warming up the menu…',
                style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }
    if (_error != null) {
      return EmptyStateArt(
        title: 'The menu is taking a break',
        message: '$_error',
        icon: Icons.wifi_off_rounded,
        action:
            FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
      );
    }
    if (_items.isEmpty) {
      return const EmptyStateArt(
        title: 'Nothing on the menu yet',
        message: 'Please check back in a moment',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _hero(),
          if (_categories.length > 1) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CategoryPill(
                      emoji: '☕',
                      label: 'All',
                      selected: _category == null,
                      onTap: () => setState(() => _category = null),
                    ),
                  ),
                  for (final cat in _categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CategoryPill(
                        emoji: categoryEmoji(cat),
                        label: cat.replaceAll('_', ' '),
                        selected: _category == cat,
                        onTap: () => setState(() => _category = cat),
                      ),
                    ),
                ],
              ),
            ),
          ],
          SectionHeader(
            title: _category == null
                ? 'Full menu'
                : _category!.replaceAll('_', ' '),
            subtitle: '${_visible.length} '
                '${_visible.length == 1 ? 'item' : 'items'} • GST included',
          ),
          if (_visible.isEmpty)
            const EmptyStateArt(
              title: 'Nothing here yet',
              message: 'Try another category — more goodies are waiting',
            )
          else
            for (final item in _visible) _itemCard(item),
        ],
      ),
    );
  }

  Widget _hero() {
    // Branded with the scanned cafe's name when the config is loaded.
    final brand = tenantStateOf(context)?.displayName;
    final welcome = (brand == null || brand.isEmpty)
        ? 'Welcome to Café POS'
        : 'Welcome to $brand';
    return HeroBanner(
      gradient: CafeGradients.sunrise,
      illustration: Align(
        alignment: const Alignment(1.05, 0.1),
        child: Opacity(
          opacity: 0.35,
          child: SizedBox(
            width: 170,
            height: 170,
            child: CustomPaint(painter: LatteArtPainter(withBeans: true)),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            welcome,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 23,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _cart.tableNumber == null
                ? 'Grab a seat — pick your table and order in a tap'
                : 'Sip, snack, repeat — order right from your table',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 16),
          TablePill(
            tableNumber: _cart.tableNumber,
            onTap: _pickTable,
          ),
        ],
      ),
    );
  }

  Widget _itemCard(MenuItem item) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openItem(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Opacity(
            opacity: item.available ? 1 : 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ItemArt(item: item, size: 84, fontSize: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (item.description.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              item.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    GstChip(rate: item.gstRate),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatMoney(item.basePrice),
                          style: const TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ItemAddButton(
                      label: item.options.isEmpty ? 'Add' : 'Choose',
                      onTap: item.available ? () => _openItem(item) : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
