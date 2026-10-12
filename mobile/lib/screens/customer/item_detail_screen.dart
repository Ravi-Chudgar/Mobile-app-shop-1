import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/menu_item.dart';
import '../../models/option_group.dart';
import '../../state/cart_state.dart';
import '../../util/money.dart';
import '../../widgets/menu_image.dart';

class ItemDetailScreen extends StatefulWidget {
  final MenuItem item;
  const ItemDetailScreen({super.key, required this.item});

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  // group -> set of chosen labels
  final Map<String, Set<String>> _selected = {};
  int _qty = 1;

  @override
  void initState() {
    super.initState();
    // Pre-select the first choice of each required single-choice group.
    for (final g in widget.item.options) {
      if (g.required && !g.multi && g.choices.isNotEmpty) {
        _selected[g.group] = {g.choices.first.label};
      }
    }
  }

  int get _unitPrice {
    var price = widget.item.basePrice;
    for (final g in widget.item.options) {
      for (final choice in g.choices) {
        if (_selected[g.group]?.contains(choice.label) ?? false) {
          price += choice.priceDelta;
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

  void _addToCart() {
    final options = <SelectedOption>[];
    _selected.forEach((group, labels) {
      for (final label in labels) {
        options.add(SelectedOption(group: group, label: label));
      }
    });
    final messenger = ScaffoldMessenger.of(context);
    context.read<CartState>().add(widget.item, options, _qty);
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(content: Text('${widget.item.name} added to cart')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
      body: ListView(
        children: [
          MenuImage(url: item.imageUrl, height: 200),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(formatMoney(item.basePrice),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary)),
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(item.description,
                      style: const TextStyle(color: Colors.black54)),
                ],
                for (final g in item.options) _buildGroup(g),
                const SizedBox(height: 16),
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
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _valid ? _addToCart : null,
            child: Text('Add to cart  •  ${formatMoney(_unitPrice * _qty)}'),
          ),
        ),
      ),
    );
  }

  Widget _buildGroup(OptionGroup g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            Text(g.group, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text(g.required ? 'Required' : 'Optional',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 6),
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
