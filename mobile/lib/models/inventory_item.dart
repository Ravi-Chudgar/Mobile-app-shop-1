class InventoryItem {
  final String id;
  final String name;
  final int quantity;
  final int costPrice; // in whole currency units (rupees/dollars)
  final String unit; // kg, litre, piece, etc.
  final String? purchaseDate;
  final String? lastRestocked;

  /// Stock level at which this item should be reordered.
  /// 0 (default) disables low-stock alerts for the item.
  final int reorderLevel;

  const InventoryItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.costPrice,
    this.unit = 'piece',
    this.purchaseDate,
    this.lastRestocked,
    this.reorderLevel = 0,
  });

  /// Alerting enabled for this item.
  bool get hasReorderLevel => reorderLevel > 0;

  /// Matches the backend rule: level > 0 and quantity at/below it.
  bool get isLowStock => reorderLevel > 0 && quantity <= reorderLevel;

  bool get isOutOfStock => quantity <= 0;

  factory InventoryItem.fromJson(Map<String, dynamic> json) => InventoryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        quantity: _toInt(json['quantity'] ?? 0),
        costPrice: _toInt(json['cost_price'] ?? 0),
        unit: (json['unit'] as String?) ?? 'piece',
        purchaseDate: json['purchase_date'] as String?,
        lastRestocked: json['last_restocked'] as String?,
        reorderLevel: _toInt(json['reorder_level'] ?? 0),
      );

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    if (v is double) return v.toInt();
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'quantity': quantity,
        'cost_price': costPrice,
        'unit': unit,
        'purchase_date': purchaseDate,
        'last_restocked': lastRestocked,
        'reorder_level': reorderLevel,
      };

  int get totalValue => quantity * costPrice;
}

/// One entry of `GET /admin/inventory/alerts`.
class LowStockAlert {
  final String? id;
  final String item;
  final int qty;
  final int reorderLevel;
  final String unit;
  final bool outOfStock;

  const LowStockAlert({
    required this.item,
    required this.qty,
    required this.reorderLevel,
    this.id,
    this.unit = 'piece',
    this.outOfStock = false,
  });

  factory LowStockAlert.fromJson(Map<String, dynamic> json) => LowStockAlert(
        id: json['id'] as String?,
        item: (json['item'] ?? '') as String,
        qty: _toInt(json['qty']),
        reorderLevel: _toInt(json['reorder_level']),
        unit: (json['unit'] as String?) ?? 'piece',
        outOfStock: json['out_of_stock'] == true,
      );

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
