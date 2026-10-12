/// Local snapshot of the last successfully fetched menu.
///
/// Keeps the take-order screen browsable (and carts buildable) while the
/// backend is unreachable; the server's own snapshot from `GET /sync/pull`
/// can refresh it further. Writes are best effort — a stale cache still
/// beats none.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/menu_item.dart';

/// Last-good menu snapshot so the staff take-order screen can still browse
/// and build carts while the network is down (the cart itself is local, and
/// submitting it goes through the offline queue).
///
/// Refreshed after every successful menu fetch. The server's full menu
/// snapshot on `GET /sync/pull` can be used to refresh it further.
class MenuCache {
  MenuCache._();

  static const String _key = 'offline_menu_cache_v1';

  static Future<void> save(List<MenuItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode([for (final item in items) _encode(item)]);
      await prefs.setString(_key, encoded);
    } catch (_) {
      // Best effort — a stale cache still beats none.
    }
  }

  /// Save from raw server JSON (e.g. the `menu` array of `GET /sync/pull`).
  static Future<void> saveJson(List<dynamic> jsonItems) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(jsonItems));
    } catch (_) {
      // Best effort — a stale cache still beats none.
    }
  }

  static Future<List<MenuItem>?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final items = <MenuItem>[
        for (final entry in decoded)
          if (entry is Map) MenuItem.fromJson(Map<String, dynamic>.from(entry)),
      ];
      return items.isEmpty ? null : items;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _encode(MenuItem item) => {
        'id': item.id,
        'name': item.name,
        'description': item.description,
        'category': item.category,
        'base_price': item.basePrice,
        'image_url': item.imageUrl,
        'available': item.available,
        'gst_rate': item.gstRate,
        'hsn_code': item.hsnCode,
        'options': [
          for (final group in item.options)
            {
              'group': group.group,
              'required': group.required,
              'multi': group.multi,
              'choices': [
                for (final choice in group.choices)
                  {'label': choice.label, 'price_delta': choice.priceDelta},
              ],
            },
        ],
      };
}
