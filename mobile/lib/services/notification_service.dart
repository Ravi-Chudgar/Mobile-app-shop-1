import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Simple local notification service for order-ready alerts.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Call once at app startup (main.dart).
  static Future<void> init() async {
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: android);
      await _plugin.initialize(settings);
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  /// Show a notification when an order is ready to serve.
  static Future<void> showOrderReady({
    required String orderId,
    required String customerName,
    required String? tableNumber,
    String? takenBy,
  }) async {
    if (!_initialized) return;

    try {
      final title = tableNumber != null
          ? 'Table $tableNumber - Order Ready!'
          : 'Order #$orderId Ready!';

      final staffPart = takenBy != null ? ' for $takenBy' : '';
      final body = customerName.isNotEmpty
          ? '$customerName\'s order is ready$staffPart.'
          : 'Order #$orderId is ready$staffPart.';

      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'order_ready',
          'Order Ready',
          channelDescription: 'Notifies when an order is ready to serve',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );

      await _plugin.show(
        orderId.hashCode,
        title,
        body,
        details,
      );
    } catch (_) {
      // Notification failed — silently ignore.
    }
  }
}
