import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/order.dart';
import '../services/api_client.dart';
import '../util/money.dart';

const paymentMethods = [
  (value: 'gpay', label: 'GPay', icon: Icons.account_balance_wallet_outlined),
  (value: 'cash', label: 'Cash', icon: Icons.payments_outlined),
  (value: 'card', label: 'Card', icon: Icons.credit_card),
  (value: 'upi', label: 'UPI', icon: Icons.qr_code),
];

/// Every method the backend accepts on a split payment.
const allPaymentMethods = [
  (value: 'cash', label: 'Cash', icon: Icons.payments_outlined),
  (value: 'upi', label: 'UPI', icon: Icons.qr_code),
  (value: 'card', label: 'Card', icon: Icons.credit_card),
  (value: 'gpay', label: 'GPay', icon: Icons.account_balance_wallet_outlined),
  (value: 'credit', label: 'Credit', icon: Icons.account_balance),
  (value: 'other', label: 'Other', icon: Icons.more_horiz),
];

/// What staff confirm in the collect dialog: the ordered split-payment rows
/// plus the loyalty points to redeem (0 when not redeeming).
class SplitPaymentResult {
  final List<Map<String, dynamic>> payments;
  final int redeemPoints;
  const SplitPaymentResult(this.payments, {this.redeemPoints = 0});

  String get primaryMethod => payments.first['method'] as String;
  int get totalAmount =>
      payments.fold(0, (sum, p) => sum + ((p['amount'] as int?) ?? 0));
}

/// Asks staff to confirm payment before completing (collecting) an order.
/// Supports splitting the due amount across methods and redeeming the
/// customer's loyalty points (when the order carries a phone number).
/// Returns the payment rows, or null if the staff cancelled.
Future<SplitPaymentResult?> showCollectPaymentDialog(
    BuildContext context, CafeOrder order) {
  return showDialog<SplitPaymentResult>(
    context: context,
    builder: (_) => _CollectPaymentDialog(order: order),
  );
}

class _Row {
  String method;
  final TextEditingController controller;
  _Row(this.method, this.controller);
  void dispose() => controller.dispose();
}

class _CollectPaymentDialog extends StatefulWidget {
  final CafeOrder order;
  const _CollectPaymentDialog({required this.order});

  @override
  State<_CollectPaymentDialog> createState() => _CollectPaymentDialogState();
}

class _CollectPaymentDialogState extends State<_CollectPaymentDialog> {
  late final List<_Row> _rows;
  String? _error;

  // --- loyalty (Phase 3): only when the order has a customer phone ---
  int? _loyaltyPoints; // balance; null until loaded (or unavailable)
  int _pointValue = 100; // paise per point, read from the backend
  bool _loyaltyLoading = false;
  bool _redeeming = false;
  String? _loyaltyError;

  String? get _phone {
    final phone = widget.order.customerPhone;
    return (phone == null || phone.trim().isEmpty) ? null : phone.trim();
  }

  int get _due => widget.order.total - widget.order.paidAmount;

  int get _entered =>
      _rows.fold(0, (sum, r) => sum + _paise(r.controller.text));

  bool _isLoyalty(_Row row) => row.method == 'loyalty';

  /// Whole points that can actually be spent on this due amount.
  int get _redeemablePoints {
    final points = _loyaltyPoints ?? 0;
    if (points <= 0 || _pointValue <= 0) return 0;
    return math.min(points, _due ~/ _pointValue);
  }

  int _paise(String text) {
    final rupees = double.tryParse(text.trim().replaceAll(',', ''));
    if (rupees == null || rupees <= 0) return 0;
    return (rupees * 100).round();
  }

  @override
  void initState() {
    super.initState();
    final first = widget.order.paymentMethod;
    final method = allPaymentMethods.any((m) => m.value == first)
        ? (first == 'gpay' ? 'cash' : first)
        : 'cash';
    _rows = [
      _Row(
          method, TextEditingController(text: (_due / 100).toStringAsFixed(2))),
    ];
    if (_phone != null) _loadLoyalty();
  }

  Future<void> _loadLoyalty() async {
    final phone = _phone;
    if (phone == null) return;
    setState(() => _loyaltyLoading = true);
    try {
      final data = await context.read<ApiClient>().fetchLoyalty(phone);
      if (!mounted) return;
      setState(() {
        _loyaltyPoints = (data['points'] as num?)?.toInt() ?? 0;
        _pointValue = (data['point_value_paise'] as num?)?.toInt() ?? 100;
        _loyaltyLoading = false;
        _loyaltyError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loyaltyLoading = false;
        _loyaltyError = 'Could not load points';
      });
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  String get _primaryMethod {
    for (final r in _rows) {
      if (!_isLoyalty(r)) return r.method;
    }
    return 'cash';
  }

  void _addRow({String? method, String? amountText}) {
    final remainder = _due - _entered;
    final prefill = remainder > 0 ? remainder : 0;
    setState(() {
      _rows.add(_Row(
          method ?? 'cash',
          TextEditingController(
              text: amountText ?? (prefill / 100).toStringAsFixed(2))));
      _error = null;
    });
  }

  void _fillRemainder() {
    if (_rows.isEmpty) return;
    setState(() {
      // Give the last non-loyalty row whatever is still uncovered (the
      // loyalty row is derived from the points balance and stays read-only).
      var targetRow = -1;
      for (var i = _rows.length - 1; i >= 0; i--) {
        if (!_isLoyalty(_rows[i])) {
          targetRow = i;
          break;
        }
      }
      if (targetRow < 0) {
        // Nothing to top up: add a cash row for the uncovered part.
        final others = _entered;
        final target = _due - others;
        if (target > 0) {
          _rows.insert(
              0,
              _Row(
                  'cash',
                  TextEditingController(
                      text: (target / 100).toStringAsFixed(2))));
        }
        _error = null;
        return;
      }
      final others = _entered - _paise(_rows[targetRow].controller.text);
      final target = _due - others;
      if (target >= 0) {
        _rows[targetRow].controller.text = (target / 100).toStringAsFixed(2);
      }
      _error = null;
    });
  }

  void _removeRow(int i) {
    if (_rows.length <= 1 || _isLoyalty(_rows[i])) return;
    setState(() {
      _rows[i].dispose();
      _rows.removeAt(i);
      _error = null;
    });
  }

  /// Turning redemption on rebuilds the split as "cash remainder + loyalty"
  /// (the loyalty row always sorts last, matching what the backend stores).
  void _setRedeeming(bool value) {
    setState(() {
      _error = null;
      _loyaltyError = null;
      // Strip any existing loyalty row; remember the primary method.
      final primary = _primaryMethod;
      _rows.where(_isLoyalty).forEach((r) => r.dispose());
      _rows.removeWhere(_isLoyalty);

      if (value) {
        final used = _redeemablePoints;
        final loyaltyValue = used * _pointValue;
        if (used <= 0) {
          _redeeming = false;
          _loyaltyError = _loyaltyPoints == null
              ? 'Points are still loading'
              : 'No points available for this phone';
          return;
        }
        final remainder = _due - loyaltyValue;
        for (final r in _rows) {
          r.dispose();
        }
        _rows.clear();
        if (remainder > 0) {
          _rows.add(_Row(
              primary,
              TextEditingController(
                  text: (remainder / 100).toStringAsFixed(2))));
        }
        _rows.add(_Row(
            'loyalty',
            TextEditingController(
                text: (loyaltyValue / 100).toStringAsFixed(2))));
        _redeeming = true;
      } else {
        for (final r in _rows) {
          r.dispose();
        }
        _rows.clear();
        _rows.add(_Row(primary,
            TextEditingController(text: (_due / 100).toStringAsFixed(2))));
        _redeeming = false;
      }
    });
  }

  void _confirm() {
    if (_entered != _due) {
      setState(() => _error = _entered < _due
          ? 'Amounts are ${formatMoney(_due - _entered)} short'
          : 'Amounts exceed the due amount — adjust the rows');
      return;
    }
    if (_rows.any((r) => _paise(r.controller.text) <= 0)) {
      setState(() => _error = 'Every row needs a positive amount');
      return;
    }
    final redeemPoints = _redeeming ? _redeemablePoints : 0;
    Navigator.pop(
      context,
      SplitPaymentResult(
        [
          for (final r in _rows)
            {
              'method': r.method,
              'amount': _paise(r.controller.text),
            },
        ],
        redeemPoints: redeemPoints,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entered = _entered;
    final diff = _due - entered;
    final exact = diff == 0 && entered > 0;
    final overpaid = diff < 0;

    return AlertDialog(
      title: const Text('Collect order'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Order #${widget.order.id}'),
            const SizedBox(height: 8),
            Text('Amount to collect: ${formatMoney(_due)}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (widget.order.paidAmount > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Order total ${formatMoney(widget.order.total)} '
                '• ${formatMoney(widget.order.paidAmount)} already paid',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
            if (_phone != null) ...[
              const SizedBox(height: 12),
              _loyaltySection(),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Payment method',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _fillRemainder,
                  icon: const Icon(Icons.format_align_left, size: 16),
                  label: const Text('Auto-fill'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 118,
                      child: _isLoyalty(_rows[i])
                          ? const InputDecorator(
                              decoration: InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 10),
                              ),
                              child: Text('Loyalty',
                                  style: TextStyle(fontSize: 14)),
                            )
                          : DropdownButtonFormField<String>(
                              value: _rows[i].method,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 10),
                              ),
                              items: allPaymentMethods
                                  .map((m) => DropdownMenuItem(
                                      value: m.value, child: Text(m.label)))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _rows[i].method = v ?? 'cash'),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _rows[i].controller,
                        readOnly: _isLoyalty(_rows[i]),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixText: '₹ ',
                          border: OutlineInputBorder(),
                          hintText: '0.00',
                        ),
                        onChanged: (_) => setState(() => _error = null),
                      ),
                    ),
                    if (_rows.length > 1 && !_isLoyalty(_rows[i]))
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => _removeRow(i),
                      ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add split'),
                style:
                    TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: exact
                    ? Colors.green.shade50
                    : overpaid
                        ? Colors.orange.shade50
                        : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Entered ${formatMoney(entered)} of ${formatMoney(_due)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  if (exact)
                    Text('Exact — ready to collect',
                        style: TextStyle(
                            color: Colors.green.shade700, fontSize: 12)),
                  if (diff > 0)
                    Text('${formatMoney(diff)} short',
                        style: TextStyle(
                            color: Colors.red.shade700, fontSize: 12)),
                  if (overpaid)
                    Text(
                        'Overpaid ${formatMoney(-diff)} — change to return '
                        '${formatMoney(-diff)}',
                        style: TextStyle(
                            color: Colors.orange.shade800, fontSize: 12)),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: exact ? _confirm : null,
          child: const Text('Confirm & collect'),
        ),
      ],
    );
  }

  /// Balance + "redeem" switch. Shown only for orders with a phone number.
  Widget _loyaltySection() {
    final points = _loyaltyPoints;
    final usable = _redeemablePoints;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _redeeming ? Colors.green.shade50 : Colors.amber.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: _redeeming ? Colors.green.shade200 : Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stars, size: 18),
              const SizedBox(width: 6),
              const Text('Loyalty points',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              if (_loyaltyLoading)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (points != null)
                Text('$points pts',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
            ],
          ),
          if (_loyaltyError != null)
            Text(_loyaltyError!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
          if (!_loyaltyLoading && points != null && points > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Redeem up to ${formatMoney(usable * _pointValue)} '
                    '($usable pts)',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                Switch(
                  value: _redeeming,
                  onChanged:
                      usable > 0 || _redeeming ? (v) => _setRedeeming(v) : null,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
