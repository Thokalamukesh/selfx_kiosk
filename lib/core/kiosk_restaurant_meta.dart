import 'package:shared_preferences/shared_preferences.dart';

class KioskRestaurantMeta {
  static const String kioskDisplayNameKey = "kiosk_display_name";
  static const String restaurantNameKey = "restaurant_name";
  static const String showTaxInReceiptKey = "show_tax_in_receipt";
  static const String gstNumberKey = "gst_number";
  static const String taxIdKey = "tax_id";

  static ({
    Map<String, dynamic>? root,
    Map<String, dynamic>? data,
    Map<String, dynamic>? restaurant,
    Map<String, dynamic>? kioskSettings,
  }) extractBundle(dynamic raw) {
    final root = _toStringKeyedMap(raw);
    final data = _toStringKeyedMap(root?["data"]);
    final restaurant = _toStringKeyedMap(root?["restaurant"]) ??
        _toStringKeyedMap(data?["restaurant"]);
    final kioskSettings = _toStringKeyedMap(root?["kiosk_settings"]) ??
        _toStringKeyedMap(data?["kiosk_settings"]);

    return (
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
  }

  static Future<void> storeFromResponse(dynamic raw) async {
    final bundle = extractBundle(raw);
    await storeFromMaps(
      root: bundle.root,
      data: bundle.data,
      restaurant: bundle.restaurant,
      kioskSettings: bundle.kioskSettings,
    );
  }

  static Future<void> storeFromMaps({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final displayName = resolveDisplayName(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    if (displayName != null) {
      await prefs.setString(kioskDisplayNameKey, displayName);
      await prefs.setString(restaurantNameKey, displayName);
    }

    final showTax = resolveShowTaxInReceipt(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    if (showTax != null) {
      await prefs.setBool(showTaxInReceiptKey, showTax);
    }

    final taxId = resolveTaxId(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    if (taxId != null) {
      await prefs.setString(gstNumberKey, taxId);
      await prefs.setString(taxIdKey, taxId);
    }
  }

  static String? resolveDisplayName({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    String? fallback,
  }) {
    return _firstNonEmpty([
      kioskSettings?["kiosk_display_name"],
      data?["kiosk_display_name"],
      root?["kiosk_display_name"],
      restaurant?["kiosk_display_name"],
      kioskSettings?["kioskDisplayName"],
      restaurant?["kioskDisplayName"],
      kioskSettings?["display_name"],
      restaurant?["display_name"],
      fallback,
    ]);
  }

  static String resolveRestaurantName({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    String fallback = "Restaurant",
  }) {
    return resolveDisplayName(
          root: root,
          data: data,
          restaurant: restaurant,
          kioskSettings: kioskSettings,
        ) ??
        _firstNonEmpty([
          restaurant?["name"],
          restaurant?["restaurant_name"],
          data?["restaurant_name"],
          root?["restaurant_name"],
          fallback,
        ]) ??
        fallback;
  }

  static bool? resolveShowTaxInReceipt({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      final value = _readBool(source, const [
        "show_tax_in_receipt",
        "showTaxInReceipt",
        "show_gst_in_receipt",
        "showGstInReceipt",
        "show_tax",
        "showTax",
        "show_gst",
        "showGst",
      ]);
      if (value != null) return value;
    }
    return null;
  }

  static String? resolveTaxId({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      final value = _firstNonEmpty([
        source?["gst_number"],
        source?["gstin"],
        source?["tax_id"],
        source?["taxId"],
        source?["gst_no"],
        source?["gst"],
      ]);
      if (value != null) return value;
    }
    return null;
  }

  static Future<bool> getStoredShowTaxInReceipt({
    bool defaultValue = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(showTaxInReceiptKey) ?? defaultValue;
  }

  static Map<String, dynamic>? _toStringKeyedMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry("$key", value));
  }

  static String? _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
        return text;
      }
    }
    return null;
  }

  static bool? _readBool(Map? data, List<String> keys) {
    if (data == null) return null;
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final raw = data[key];
      if (raw is bool) return raw;
      if (raw is num) return raw != 0;
      if (raw is String) {
        final value = raw.trim().toLowerCase();
        if (value.isEmpty) return null;
        if (value == "1" ||
            value == "true" ||
            value == "yes" ||
            value == "y" ||
            value == "on") {
          return true;
        }
        if (value == "0" ||
            value == "false" ||
            value == "no" ||
            value == "n" ||
            value == "off") {
          return false;
        }
      }
    }
    return null;
  }
}
