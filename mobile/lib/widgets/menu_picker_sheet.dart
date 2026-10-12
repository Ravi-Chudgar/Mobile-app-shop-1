import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/menu_item.dart';
import '../models/option_group.dart';
import '../services/api_client.dart';
import '../state/cart_state.dart';
import '../util/money.dart';
import '../widgets/menu_image.dart';

/// Opens a bottom-sheet menu picker so staff can add more items to the cart
/// straight from the order review / order-queue screen, without leaving it.
///
/// Tapping an item shows that item's options + quantity inline *within the same
/// sheet* (not by pushing a route over it) — pushing a route over a modal
/// bottom sheet corrupts its dismiss state and leaves the sheet stuck open.
/// The live cart count/total in the sheet footer updates as items are added.
Future<void> showMenuPickerSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _MenuPickerSheet(),
  );
}

/// Fixed-height sheet so the inner [Column] always gets bounded width/height.
class _MenuPickerSheet extends StatelessWidget {
  const _MenuPickerSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: MediaQuery.of(context).size.width,
      height: MediaQuery.of(context).size.height * 0.92,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Add items',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Expanded(child: _MenuPickerContents()),
            const _CartFooter(),
          ],
        ),
      ),
    );
  }
}

class _MenuPickerContents extends StatefulWidget {
  const _MenuPickerContents();

  @override
  State<_MenuPickerContents> createState() => _MenuPickerContentsState();
}

class _MenuPickerContentsState extends State<_MenuPickerContents> {
  late final Future<List<MenuItem>> _future;
  String _q = '';
  MenuItem? _selected;

  @override
  void initState() {
    super.initState();
    _future = context.read<ApiClient>().fetchMenu();
  }

  String _pretty(String c) => c
      .replaceAll('_', ' ')
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    if (_selected != null) {
      return _ItemDetailPane(
        item: _selected!,
        onBack: () => setState(() => _selected = null),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search menu…',
              prefixIcon: const Icon(Icons.search),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            ),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<MenuItem>>(
            future: _future,
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('${snap.error}'));
              }
              final all = snap.data ?? [];
              final filtered = _q.isEmpty
                  ? all
                  : all
                      .where((i) =>
                          i.name.toLowerCase().contains(_q) ||
                          i.category.toLowerCase().contains(_q))
                      .toList();
              if (filtered.isEmpty) {
                return const Center(child: Text('No matching items.'));
              }
              final categories = <String>[];
              for (final i in filtered) {
                if (!categories.contains(i.category)) {
                  categories.add(i.category);
                }
              }
              return ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final cat in categories) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text(_pretty(cat),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    for (final i in filtered.where((x) => x.category == cat))
                      _ItemRow(
                        item: i,
                        onTap: () => setState(() => _selected = i),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Item options + quantity editor shown inline inside the sheet (no route
/// push), so the sheet never loses its dismissible state.
class _ItemDetailPane extends StatefulWidget {
  final MenuItem item;
  final VoidCallback onBack;
  const _ItemDetailPane({required this.item, required this.onBack});

  @override
  State<_ItemDetailPane> createState() => _ItemDetailPaneState();
}

class _ItemDetailPaneState extends State<_ItemDetailPane> {
  final Map<String, Set<String>> _selected = {};
  int _qty = 1;

  @override
  void initState() {
    super.initState();
    for (final g in widget.item.options) {
      if (g.required && !g.multi && g.choices.isNotEmpty) {
        _selected[g.group] = {g.choices.first.label};
      }
    }
  }

  int get _unitPrice {
    var price = widget.item.basePrice;
    for (final g in widget.item.options) {
      for (final c in g.choices) {
        if (_selected[g.group]?.contains(c.label) ?? false) {
          price += c.priceDelta;
        }
      }
    }
    return price;
  }

  bool get _valid {
    for (final g in widget.item.options) {
      if (g.required && (_selected[g.group]?.isEmpty ?? true)) return false;
    }
    return true;
  }

  void _toggle(OptionGroup g, String label) {
    setState(() {
      final current = _selected.putIfAbsent(g.group, () => <String>{});
      if (g.multi) {
        current.contains(label) ? current.remove(label) : current.add(label);
      } else {
        _selected[g.group] = {label};
      }
    });
  }

  void _add() {
    final options = <SelectedOption>[];
    _selected.forEach((group, labels) {
      for (final label in labels) {
        options.add(SelectedOption(group: group, label: label));
      }
    });
    context.read<CartState>().add(widget.item, options, _qty);
    // Close the whole sheet so the caller can commit the picked items.
    // (The back arrow still uses onBack to return to the list without adding.)
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to menu',
                onPressed: widget.onBack,
              ),
              Expanded(
                child: Text(item.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MenuImage(url: item.imageUrl, height: 160),
              const SizedBox(height: 12),
              Text(item.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(formatMoney(item.basePrice),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: scheme.primary)),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(item.description,
                    style: const TextStyle(color: Colors.black54)),
              ],
              for (final g in item.options) _buildGroup(g),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Quantity',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _QtyStepper(
                    qty: _qty,
                    onChanged: (v) => setState(() => _qty = v),
                  ),
                ],
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              onPressed: _valid ? _add : null,
              child: Text('Add to cart  •  ${formatMoney(_unitPrice * _qty)}'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGroup(OptionGroup g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Row(
          children: [
            Text(g.group, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text(g.required ? 'Required' : 'Optional',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        ...g.choices.map((c) {
          final chosen = _selected[g.group]?.contains(c.label) ?? false;
          return CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: chosen,
            title: Text(c.label),
            secondary:
                Text(c.priceDelta == 0 ? '—' : '+${formatMoney(c.priceDelta)}'),
            onChanged: (_) => _toggle(g, c.label),
          );
        }),
      ],
    );
  }
}

/// Live "items in cart / total" footer with a Done button. Lives outside the
/// scrolling contents so it stays pinned at the bottom of the sheet.
class _CartFooter extends StatelessWidget {
  const _CartFooter();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cart = context.watch<CartState>();
    if (cart.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${cart.count} item(s) in cart',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                Text(formatMoney(cart.total),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onTap;
  const _ItemRow({required this.item, required this.onTap});

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
          onTap: disabled ? null : onTap,
        ),
      ),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  final int qty;
  final ValueChanged<int> onChanged;
  const _QtyStepper({required this.qty, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: qty > 1 ? () => onChanged(qty - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('$qty', style: const TextStyle(fontSize: 16)),
        IconButton(
          onPressed: () => onChanged(qty + 1),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}
