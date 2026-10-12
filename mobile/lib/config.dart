import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Base URL of the Flask backend.
///
/// - Android emulator reaches the host machine at 10.0.2.2
/// - Everything else (web, iOS sim, desktop) uses localhost
/// Override at build/run time with:
///   --dart-define=API_BASE_URL=http://192.168.1.5:9999
///
/// Production (Cloudflare tunnel):
///   https://mobileapp.unonomercysound.online
class AppConfig {
  static const String _override =
      String.fromEnvironment('API_BASE_URL', defaultValue: '');

  static String get baseUrl {
    if (_override.isNotEmpty) return _override;
    // Android emulator maps the host loopback to 10.0.2.2.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:9999';
    }
    // Web, iOS, macOS, Windows, Linux — use production tunnel URL.
    return productionBaseUrl;
  }

  /// Production API base URL (Cloudflare tunnel).
  static const String productionBaseUrl =
      'https://mobileapp.unonomercysound.online';

  /// Currency symbol used across the UI. Amounts are integers in minor units.
  static const String currencySymbol = '₹'; // ₹

  /// ISO-4217 code + country for payment integrations (Google Pay).
  static const String currencyCode = 'INR';
  static const String countryCode = 'IN';

  // ---- UPI Payments -------------------------------------------------------
  static const String upiId = 'ravi.chudgar-1@okicici';
  static const String merchantName = 'Cafe POS';

  // ---- WhatsApp -----------------------------------------------------------
  // Vendor phone for stock orders (with country code, no + or spaces).
  static const String vendorPhone = '919998814647';

  // ---- Google Pay ---------------------------------------------------------
  // Defaults run in Google's TEST environment (no real money). For production,
  // pass your merchant details at build/run time:
  //   --dart-define=GOOGLE_PAY_ENV=PRODUCTION
  //   --dart-define=GOOGLE_PAY_MERCHANT_ID=<merchant id>
  //   --dart-define=GOOGLE_PAY_GATEWAY=<e.g. stripe/>
  //   --dart-define=GOOGLE_PAY_GATEWAY_MERCHANT_ID=<gateway account>
  //   --dart-define=GOOGLE_PAY_MERCHANT_NAME=<your business name>
  static const String googlePayEnvironment =
      String.fromEnvironment('GOOGLE_PAY_ENV', defaultValue: 'TEST');
  static const String googlePayMerchantId =
      String.fromEnvironment('GOOGLE_PAY_MERCHANT_ID', defaultValue: '');
  static const String googlePayGateway =
      String.fromEnvironment('GOOGLE_PAY_GATEWAY', defaultValue: 'example');
  static const String googlePayGatewayMerchantId = String.fromEnvironment(
      'GOOGLE_PAY_GATEWAY_MERCHANT_ID',
      defaultValue: 'exampleGatewayMerchant');
  static const String googlePayMerchantName = String.fromEnvironment(
      'GOOGLE_PAY_MERCHANT_NAME',
      defaultValue: 'Cafe POS');
}
