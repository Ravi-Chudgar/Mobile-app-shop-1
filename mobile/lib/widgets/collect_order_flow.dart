import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/order.dart';
import '../services/api_client.dart';
import '../services/payment_service.dart';
import 'collect_payment_dialog.dart';

/// Runs the full "collect this order" flow:
///   1. pick payment method(s) — the dialog supports splitting the due amount
///      across cash/UPI/card/GPay/credit/other
///   2. if a single GPay payment was chosen, show the Google Pay sheet (falls
///      back cleanly if the device has no Google Pay / Play services)
///   3. mark the order collected + paid in one step, sending the full
///      `payments` list to the backend
/// Returns the updated order, or null if the staff cancelled / payment failed.
Future<CafeOrder?> collectOrderAndPay(
    BuildContext context, CafeOrder order) async {
  final messenger = ScaffoldMessenger.of(context);
  final api = context.read<ApiClient>();
  final result = await showCollectPaymentDialog(context, order);
  if (result == null || !context.mounted) return null;
  final payments = result.payments;

  String? token;
  final singleGpay = payments.length == 1 && payments.first['method'] == 'gpay';
  if (singleGpay) {
    final available = await PaymentService.isGooglePayAvailable();
    if (!available) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Google Pay is not available on this device. '
            'Record the payment as Cash/Card/UPI instead.'),
      ));
      return null;
    }
    try {
      token = await PaymentService.collect(
        orderLabel: 'Order #${order.id}',
        amountMinorUnits: (payments.first['amount'] as int?) ?? 0,
      );
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.code == 'gpay_unavailable'
            ? 'Google Pay is not available on this device.'
            : 'Google Pay was cancelled. No payment was taken.'),
      ));
      return null;
    }
    if (token == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Google Pay was cancelled. No payment was taken.')));
      return null;
    }
  }

  try {
    return await api.updateOrderStatus(
      order.id,
      'collected',
      paid: true,
      paymentMethod: result.primaryMethod,
      paymentToken: token,
      payments: payments,
      redeemPoints: result.redeemPoints,
    );
  } on ApiException catch (e) {
    // Bad split (sum != due), a stale points balance, or anything else the
    // backend rejects: show it.
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
}
