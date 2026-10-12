import 'package:flutter/foundation.dart';

import '../../models/cart.dart';
import '../../models/menu_item.dart';
import '../../models/option_group.dart';

/// Cart for the QR self-order flow.
///
/// Deliberately separate from the staff `CartState`: a customer browsing the
/// QR menu must never touch the cart the staff is building at the counter.
/// Owned by `CustomerMenuScreen` and handed to the cart/checkout screens.
class CustomerCart extends ChangeNotifier {
  final List<CartLine> _lines = [];

  /// Table picked from the QR link (or typed in when there is none).
  String? tableNumber;

  CustomerCart({this.tableNumber});

  List<CartLine> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;
  int get count => _lines.fold(0, (sum, l) => sum + l.qty);
  int get total => _lines.fold(0, (sum, l) => sum + l.lineTotal);

  List<Map<String, dynamic>> get itemsJson =>
      _lines.map((l) => l.toOrderItemJson()).toList();

  void add(MenuItem item, List<SelectedOption> options, int qty) {
    // Identical configuration (same item + same options) merges into the
    // existing line instead of showing twice.
    final existing = _lines.indexWhere((l) =>
        l.item.id == item.id &&
        l.selectedOptions.length == options.length &&
        l.selectedOptions.every(options.contains));
    if (existing >= 0) {
      _lines[existing].qty += qty;
    } else {
      _lines.add(CartLine(item: item, selectedOptions: options, qty: qty));
    }
    notifyListeners();
  }

  void setQty(int index, int qty) {
    if (index < 0 || index >= _lines.length) return;
    if (qty <= 0) {
      _lines.removeAt(index);
    } else {
      _lines[index].qty = qty;
    }
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _lines.length) return;
    _lines.removeAt(index);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  void setTable(String? number) {
    tableNumber = (number ?? '').trim().isEmpty ? null : number!.trim();
    notifyListeners();
  }
}
