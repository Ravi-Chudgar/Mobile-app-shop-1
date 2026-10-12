import 'package:flutter/material.dart';

import '../../models/menu_item.dart';
import '../../models/option_group.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import 'customer_cart.dart';
import 'customer_ui.dart';

/// Option/quantity picker for one menu item in the QR self-order flow.
/// Shows the sheet, adds to [cart] on confirm; returns true when added.
Future<bool> showCustomerItemSheet(
    BuildContext context, MenuItem item, CustomerCart cart) async {
  final added = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CustomerItemSheet(item: item, cart: cart),
  );
  return added ?? false;
}

class _CustomerItemSheet extends StatefulWidget {
  final MenuItem item;
  final CustomerCart cart;
  const _CustomerItemSheet({required this.item, required this.cart});

  @override
  State<_CustomerItemSheet> createState() => _CustomerItemSheetState();
}

class _CustomerItemSheetState extends State<_CustomerItemSheet> {
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

  void _add() {
    final options = <SelectedOption>[];
    _selected.forEach((group, labels) {
      for (final label in labels) {
        options.add(SelectedOption(group: group, label: label));
      }
    });
    widget.cart.add(widget.item, options, _qty);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final text = Theme.of(context).textTheme;
    return Padding(
      // Lift the sheet above the keyboard for the quantity stepper.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(text),
                      if (item.description.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          item.description,
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: Colors.black54,
                            height: 1.4,
                          ),
                        ),
                      ],
                      for (final g in item.options) _buildGroup(g),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          const Text(
                            'Quantity',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          QtyStepper(
                            qty: _qty,
                            onDecrement:
                                _qty > 1 ? () => setState(() => _qty--) : null,
                            onIncrement: () => setState(() => _qty++),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              _stickyFooter(text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(TextTheme text) {
    final item = widget.item;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ItemArt(item: item, size: 76, fontSize: 32),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatMoney(item.basePrice),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: CafePalette.coffee,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GstChip(rate: item.gstRate),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stickyFooter(TextTheme text) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.05))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_valid)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Choose a required option to continue',
                style: text.bodySmall?.copyWith(
                  color: CafePalette.berry,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: CafePalette.latte,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$_qty ${_qty == 1 ? 'item' : 'items'}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: CafePalette.espresso,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GradientPillButton(
                  onPressed: _valid ? _add : null,
                  gradient: CafeGradients.espresso,
                  child: Text(
                    'Add  •  ${formatMoney(_unitPrice * _qty)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(OptionGroup g) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  g.group,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: g.required
                      ? CafePalette.berry.withValues(alpha: 0.12)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  g.required ? 'Required' : (g.multi ? 'Pick any' : 'Optional'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: g.required
                        ? CafePalette.berry
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final c in g.choices) _choiceChip(g, c)],
          ),
        ],
      ),
    );
  }

  Widget _choiceChip(OptionGroup g, OptionChoice c) {
    final chosen = _selected[g.group]?.contains(c.label) ?? false;
    final delta = c.priceDelta == 0 ? null : '+${formatMoney(c.priceDelta)}';
    const radius = BorderRadius.all(Radius.circular(999));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _toggle(g, c.label),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: chosen ? CafeGradients.coffee : null,
            color: chosen ? null : Colors.white,
            borderRadius: radius,
            border: chosen
                ? null
                : Border.all(color: Colors.black.withValues(alpha: 0.09)),
            boxShadow: chosen
                ? [
                    BoxShadow(
                      color: CafePalette.coffee.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chosen)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child:
                      Icon(Icons.check_rounded, size: 15, color: Colors.white),
                ),
              Text(
                c.label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: chosen ? Colors.white : CafePalette.espresso,
                ),
              ),
              if (delta != null) ...[
                const SizedBox(width: 6),
                Text(
                  delta,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: chosen
                        ? Colors.white.withValues(alpha: 0.85)
                        : CafePalette.mint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
