import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models/inventory_item.dart';
import '../../services/api_client.dart';

/// Vendor screen: order stock via WhatsApp and mark delivery received.
///
/// Flow:
///  1. Select items that need restocking
///  2. Tap "Send Order" → opens WhatsApp with message
///  3. When delivery arrives → tap "Mark Received" → restocks inventory
class VendorMessageScreen extends StatefulWidget {
  const VendorMessageScreen({super.key});

  @override
  State<VendorMessageScreen> createState() => _VendorMessageScreenState();
}

class _VendorMessageScreenState extends State<VendorMessageScreen> {
  List<InventoryItem> _items = [];
  bool _loading = true;
  String? _error;
  final Map<String, int> _selected = {};
  String _searchQuery = '';

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
      final items = await context.read<ApiClient>().fetchInventory();
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

  void _toggleItem(InventoryItem item) {
    setState(() {
      if (_selected.containsKey(item.id)) {
        _selected.remove(item.id);
      } else {
        final restockQty = item.quantity < 10 ? 20 - item.quantity : 10;
        _selected[item.id] = restockQty.clamp(1, 999);
      }
    });
  }

  void _updateQty(String itemId, int qty) {
    setState(() {
      if (qty <= 0) {
        _selected.remove(itemId);
      } else {
        _selected[itemId] = qty;
      }
    });
  }

  String _buildWhatsAppMessage() {
    final buffer = StringBuffer()
      ..writeln('📦 Stock Restock Request')
      ..writeln();

    for (final entry in _selected.entries) {
      final item = _items.firstWhere((i) => i.id == entry.key);
      buffer.writeln('  ${item.name}  →  ${entry.value} ${item.unit}');
    }

    buffer
      ..writeln()
      ..writeln('Please deliver as soon as possible.')
      ..writeln('Thanks!');

    return buffer.toString();
  }

  Future<void> _sendWhatsApp() async {
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one item to order')),
      );
      return;
    }

    final message = _buildWhatsAppMessage();
    final url = Uri.parse(
        'https://wa.me/${AppConfig.vendorPhone}?text=${Uri.encodeComponent(message)}');

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

  Future<void> _markReceived() async {
    if (_selected.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Delivery'),
        content: Text(
          'Restock ${_selected.length} item(s)? This will add the ordered quantities to your inventory.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (!mounted) return;

    final api = context.read<ApiClient>();
    int success = 0;
    int failed = 0;

    for (final entry in _selected.entries) {
      try {
        await api.restockItem(entry.key, entry.value);
        success++;
      } catch (e) {
        failed++;
      }
    }

    if (!mounted) return;
    setState(() => _selected.clear());

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '✅ $success item(s) restocked successfully'
              : '⚠️ $success restocked, $failed failed',
        ),
        backgroundColor: failed == 0 ? Colors.green : Colors.orange,
      ),
    );

    _load();
  }

  List<InventoryItem> get _filteredItems {
    if (_searchQuery.isEmpty) return _items;
    return _items
        .where((i) => i.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
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
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final allItems = _filteredItems;
    final lowStock = allItems.where((i) => i.quantity <= 10).toList();
    final normalStock = allItems
        .where((i) => i.quantity > 10 && !_selected.containsKey(i.id))
        .toList();
    final selectedItems = _selected.entries
        .map((e) => _items.firstWhere((i) => i.id == e.key))
        .toList();

    return Column(
      children: [
        // ── Header with search ──
        _VendorHeader(
          lowStockCount: lowStock.length,
          onSearch: (q) => setState(() => _searchQuery = q),
        ),

        // ── Selected items bar ──
        if (_selected.isNotEmpty)
          _SelectedBar(
            count: _selected.length,
            totalQty: _selected.values.fold(0, (a, b) => a + b),
            onSendWhatsApp: _sendWhatsApp,
            onMarkReceived: _markReceived,
            onClear: () => setState(() => _selected.clear()),
          ),

        // ── Items list ──
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                if (selectedItems.isNotEmpty) ...[
                  _SectionHeader(
                    title: 'SELECTED',
                    count: selectedItems.length,
                    color: Colors.green,
                  ),
                  ...selectedItems.map((item) => _ItemTile(
                        item: item,
                        selected: true,
                        quantity: _selected[item.id]!,
                        onTap: () => _toggleItem(item),
                        onQtyChanged: (q) => _updateQty(item.id, q),
                      )),
                  const SizedBox(height: 20),
                ],
                if (lowStock.isNotEmpty) ...[
                  _SectionHeader(
                    title: 'LOW STOCK',
                    count: lowStock.length,
                    color: Colors.orange,
                  ),
                  ...lowStock
                      .where((i) => !_selected.containsKey(i.id))
                      .map((item) => _ItemTile(
                            item: item,
                            selected: false,
                            quantity: null,
                            onTap: () => _toggleItem(item),
                            onQtyChanged: null,
                          )),
                  const SizedBox(height: 20),
                ],
                if (normalStock.isNotEmpty) ...[
                  _SectionHeader(
                    title: 'ALL ITEMS',
                    count: normalStock.length,
                    color: Colors.blueGrey,
                  ),
                  ...normalStock.map((item) => _ItemTile(
                        item: item,
                        selected: false,
                        quantity: null,
                        onTap: () => _toggleItem(item),
                        onQtyChanged: null,
                      )),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────── Widget Parts ────────────────────────────

class _VendorHeader extends StatelessWidget {
  final int lowStockCount;
  final ValueChanged<String> onSearch;

  const _VendorHeader({
    required this.lowStockCount,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.storefront_rounded,
                    color: scheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stock Vendor',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimaryContainer,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      AppConfig.vendorPhone,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              if (lowStockCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$lowStockCount low',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: onSearch,
            decoration: InputDecoration(
              hintText: 'Search items...',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedBar extends StatelessWidget {
  final int count;
  final int totalQty;
  final VoidCallback onSendWhatsApp;
  final VoidCallback onMarkReceived;
  final VoidCallback onClear;

  const _SelectedBar({
    required this.count,
    required this.totalQty,
    required this.onSendWhatsApp,
    required this.onMarkReceived,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.shopping_cart_rounded,
                  color: Colors.green.shade700, size: 20),
              const SizedBox(width: 8),
              Text(
                '$count items · $totalQty units',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade800,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size.zero,
                ),
                child: Text('Clear',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onSendWhatsApp,
                  icon: const Icon(Icons.chat_rounded, size: 18),
                  label: const Text('Send via WhatsApp'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onMarkReceived,
                  icon: const Icon(Icons.inventory_rounded, size: 18),
                  label: const Text('Mark Received'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: color,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final InventoryItem item;
  final bool selected;
  final int? quantity;
  final VoidCallback onTap;
  final ValueChanged<int>? onQtyChanged;

  const _ItemTile({
    required this.item,
    required this.selected,
    required this.quantity,
    required this.onTap,
    this.onQtyChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isLow = item.quantity <= 10;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: selected ? 2 : 0,
      color: selected ? Colors.green.shade50 : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? Colors.green.shade400 : Colors.grey.shade200,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: selected ? Colors.green : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      selected ? Icons.check : Icons.add,
                      color: selected ? Colors.white : Colors.grey.shade500,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isLow
                                    ? Colors.orange.shade100
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${item.quantity} ${item.unit}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isLow
                                      ? Colors.orange.shade800
                                      : Colors.grey.shade700,
                                  fontWeight: isLow
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (isLow) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade100,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'LOW',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '₹${item.costPrice}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
              if (selected && quantity != null && onQtyChanged != null) ...[
                const SizedBox(height: 10),
                _QtyControl(
                  qty: quantity!,
                  onChanged: onQtyChanged!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  final int qty;
  final ValueChanged<int> onChanged;

  const _QtyControl({required this.qty, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.shade100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _QtyButton(
            icon: Icons.remove,
            enabled: qty > 1,
            onTap: () => onChanged(qty - 1),
          ),
          Container(
            width: 50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$qty',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          _QtyButton(
            icon: Icons.add,
            enabled: true,
            onTap: () => onChanged(qty + 1),
          ),
        ],
      ),
    );
  }
}

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _QtyButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: enabled ? Colors.green : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? Colors.white : Colors.grey.shade400,
        ),
      ),
    );
  }
}
