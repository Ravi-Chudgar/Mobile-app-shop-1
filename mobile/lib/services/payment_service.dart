import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pay/pay.dart';

import '../config.dart';

/// Thin wrapper around the Google `pay` plugin for Google Pay.
///
/// Everything is guarded: if the platform has no Google Pay support (Linux
/// desktop, web without the JS setup) or the Android device has no Google Play
/// services, the calls report "unavailable" instead of throwing — the POS
/// keeps working and staff just record Cash/Card/UPI as before.
class PaymentService {
  PaymentService._();

  static Pay? _pay;

  static Future<Pay?> _instance() async {
    if (_pay != null) return _pay;
    try {
      final configuration = PaymentConfiguration.fromJsonString(jsonEncode({
        'provider': 'google_pay',
        'data': _googlePayConfig(),
      }));
      _pay = Pay({PayProvider.google_pay: configuration});
    } catch (_) {
      _pay = null;
    }
    return _pay;
  }

  static Map<String, dynamic> _googlePayConfig() {
    const prod = AppConfig.googlePayEnvironment == 'PRODUCTION';
    return {
      'environment': AppConfig.googlePayEnvironment,
      'apiVersion': 2,
      'apiVersionMinor': 0,
      'allowedPaymentMethods': [
        {
          'type': 'CARD',
          'parameters': {
            'allowedAuthMethods': ['PAN_ONLY', 'CRYPTOGRAM_3DS'],
            'allowedCardNetworks': ['VISA', 'MASTERCARD', 'AMEX'],
          },
          'tokenizationSpecification': {
            'type': 'PAYMENT_GATEWAY',
            'parameters': {
              'gateway': AppConfig.googlePayGateway,
              // TEST mode accepts a dummy gateway; production needs yours.
              'gatewayMerchantId': prod
                  ? AppConfig.googlePayGatewayMerchantId
                  : 'exampleGatewayMerchant',
            },
          },
        },
      ],
      'merchantInfo': {
        'merchantName': AppConfig.googlePayMerchantName,
        if (prod && AppConfig.googlePayMerchantId.isNotEmpty)
          'merchantId': AppConfig.googlePayMerchantId,
      },
      'transactionInfo': {
        'currencyCode': AppConfig.currencyCode,
        'countryCode': AppConfig.countryCode,
      },
    };
  }

  /// Whether the current device can actually show a Google Pay sheet.
  static Future<bool> isGooglePayAvailable() async {
    final pay = await _instance();
    if (pay == null) return false;
    try {
      return await pay.userCanPay(PayProvider.google_pay);
    } catch (_) {
      return false;
    }
  }

  /// Runs a Google Pay transaction for [amountMinorUnits] (paise) against the
  /// customer's card. Returns the payment token on success; null if the user
  /// cancelled the sheet. Throws [PlatformException] (or a formatted string)
  /// on a genuine failure.
  static Future<String?> collect({
    required String orderLabel,
    required int amountMinorUnits,
  }) async {
    final pay = await _instance();
    if (pay == null) {
      throw PlatformException(
        code: 'gpay_unavailable',
        message: 'Google Pay is not available on this device.',
      );
    }
    final result = await pay.showPaymentSelector(
      PayProvider.google_pay,
      [
        PaymentItem(
          amount: (amountMinorUnits / 100).toStringAsFixed(2),
          label: orderLabel,
          status: PaymentItemStatus.final_price,
          type: PaymentItemType.total,
        ),
      ],
    );
    // The encrypted card token lives under paymentMethodData.tokenizationData.
    final methodData =
        (result['paymentMethodData'] ?? const {}) as Map<String, dynamic>;
    final tokenization =
        (methodData['tokenizationData'] ?? const {}) as Map<String, dynamic>;
    return tokenization['token'] as String?;
  }
}
