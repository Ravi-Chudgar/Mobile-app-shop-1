class OrderLine {
  final String name;
  final String category;
  final int qty;
  final int unitPrice;
  final int lineTotal;
  final List<String> options;

  /// GST breakdown (tax-inclusive). Legacy orders without these fields -> 0.
  final int taxableValue;
  final int cgst;
  final int sgst;
  final int? gstRate;
  final String? hsnCode;

  const OrderLine({
    required this.name,
    required this.category,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    required this.options,
    this.taxableValue = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.gstRate,
    this.hsnCode,
  });

  int get taxTotal => cgst + sgst;

  factory OrderLine.fromJson(Map<String, dynamic> json) => OrderLine(
        name: json['name'] as String,
        category: (json['category'] ?? 'other') as String,
        qty: (json['qty'] ?? 1) as int,
        unitPrice: (json['unit_price'] ?? 0) as int,
        lineTotal: (json['line_total'] ?? 0) as int,
        options: ((json['selected_options'] ?? []) as List)
            .map((o) => (o as Map<String, dynamic>)['label'] as String)
            .toList(),
        taxableValue: (json['taxable_value'] ?? 0) as int,
        cgst: (json['cgst'] ?? 0) as int,
        sgst: (json['sgst'] ?? 0) as int,
        gstRate: json['gst_rate'] as int?,
        hsnCode: json['hsn_code'] as String?,
      );
}

class CafeOrder {
  final String id;
  final List<OrderLine> items;
  final int total;

  /// Tax-inclusive grand total split out: sub_total == total here,
  /// tax_total is the GST contained in it. Legacy orders default sanely.
  final int subTotal;
  final int taxTotal;

  final String customerName;
  final String? customerPhone;
  final String pickupType;
  final String? tableNumber;
  final String status;
  final String createdAt;
  final String notes;
  final String? takenBy;
  final String paymentMethod;
  final String paymentStatus;
  final int paidAmount;
  final String? paymentToken;

  /// Split/multi payments collected for this order (may be empty).
  final List<Map<String, dynamic>> payments;

  /// What's still owed after a reopen (total minus amount already paid).
  int get remaining => total - paidAmount;

  const CafeOrder({
    required this.id,
    required this.items,
    required this.total,
    required this.customerName,
    required this.customerPhone,
    required this.pickupType,
    this.tableNumber,
    required this.status,
    required this.createdAt,
    required this.notes,
    required this.takenBy,
    required this.paymentMethod,
    required this.paymentStatus,
    this.paidAmount = 0,
    this.paymentToken,
    this.subTotal = 0,
    this.taxTotal = 0,
    this.payments = const [],
  });

  factory CafeOrder.fromJson(Map<String, dynamic> json) {
    final customer = (json['customer'] ?? {}) as Map<String, dynamic>;
    final total = (json['total'] ?? 0) as int;
    return CafeOrder(
      id: json['id'] as String,
      items: ((json['items'] ?? []) as List)
          .map((i) => OrderLine.fromJson(i as Map<String, dynamic>))
          .toList(),
      total: total,
      customerName: (customer['name'] ?? 'Guest') as String,
      customerPhone: customer['phone'] as String?,
      pickupType: (json['pickup_type'] ?? 'counter') as String,
      tableNumber: json['table_number'] as String?,
      status: (json['status'] ?? 'received') as String,
      createdAt: (json['created_at'] ?? '') as String,
      notes: (json['notes'] ?? '') as String,
      takenBy: json['taken_by'] as String?,
      paymentMethod: (json['payment_method'] ?? 'cash') as String,
      paymentStatus: (json['payment_status'] ?? 'unpaid') as String,
      paidAmount: (json['paid_amount'] ?? 0) as int,
      paymentToken: json['payment_token'] as String?,
      subTotal: (json['sub_total'] ?? total) as int,
      taxTotal: (json['tax_total'] ?? 0) as int,
      payments: ((json['payments'] ?? []) as List)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList(),
    );
  }

  static const List<String> flow = [
    'received',
    'preparing',
    'ready',
    'collected'
  ];
}
