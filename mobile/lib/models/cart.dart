import 'menu_item.dart';
import 'option_group.dart';

/// One configured line in the cart. Price is previewed client-side; the server
/// is authoritative at checkout.
class CartLine {
  final MenuItem item;
  final List<SelectedOption> selectedOptions;
  int qty;

  CartLine({
    required this.item,
    required this.selectedOptions,
    this.qty = 1,
  });

  int get unitPrice {
    var price = item.basePrice;
    for (final sel in selectedOptions) {
      final group = item.options.firstWhere(
        (g) => g.group == sel.group,
        orElse: () => const OptionGroup(
            group: '', required: false, multi: false, choices: []),
      );
      for (final choice in group.choices) {
        if (choice.label == sel.label) price += choice.priceDelta;
      }
    }
    return price;
  }

  int get lineTotal => unitPrice * qty;

  /// A short human summary of the chosen options, e.g. "Large · Oat".
  String get optionsSummary => selectedOptions.map((o) => o.label).join(' · ');

  Map<String, dynamic> toOrderItemJson() => {
        'item_id': item.id,
        'qty': qty,
        'selected_options': selectedOptions.map((o) => o.toJson()).toList(),
      };
}
