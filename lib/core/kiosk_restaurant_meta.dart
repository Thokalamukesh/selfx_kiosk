import 'package:shared_preferences/shared_preferences.dart';

class KioskRestaurantMeta {
  static const String kioskDisplayNameKey = "kiosk_display_name";
  static const String restaurantNameKey = "restaurant_name";
  static const String showTaxInReceiptKey = "show_tax_in_receipt";
  static const String showItemImagesKey = "show_item_images";
  static const String showCategoryImagesKey = "show_category_images";
  static const String taxBreakdownDisplayKey = "tax_breakdown_display";
  static const String variantPriceDisplayKey = "variant_price_display";
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
        _toStringKeyedMap(data?["kiosk_settings"]) ??
        _toStringKeyedMap(root?["kiosk"]) ??
        _toStringKeyedMap(data?["kiosk"]) ??
        (data != null && _looksLikeKioskSettings(data) ? data : null) ??
        (root != null && _looksLikeKioskSettings(root) ? root : null);

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
    final showItemImages = resolveBoolSetting(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
      keys: const ["show_item_images", "showItemImages"],
    );
    if (showItemImages != null) {
      await prefs.setBool(showItemImagesKey, showItemImages);
    }
    final showCategoryImages = resolveBoolSetting(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
      keys: const ["show_category_images", "showCategoryImages"],
    );
    if (showCategoryImages != null) {
      await prefs.setBool(showCategoryImagesKey, showCategoryImages);
    }
    final taxBreakdown = resolveStringSetting(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
      keys: const ["tax_breakdown_display", "taxBreakdownDisplay"],
    );
    if (taxBreakdown != null) {
      await prefs.setString(taxBreakdownDisplayKey, taxBreakdown);
    }
    final variantPrice = resolveStringSetting(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
      keys: const ["variant_price_display", "variantPriceDisplay"],
    );
    if (variantPrice != null) {
      await prefs.setString(variantPriceDisplayKey, variantPrice);
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
      restaurant?["name"],
      restaurant?["restaurant_name"],
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

  static bool? resolveBoolSetting({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    required List<String> keys,
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      final value = _readBool(source, keys);
      if (value != null) return value;
    }
    return null;
  }

  static String? resolveStringSetting({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    required List<String> keys,
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      if (source == null) continue;
      final values = keys.map((key) => source[key]);
      final value = _firstNonEmpty(values);
      if (value != null) return value;
    }
    return null;
  }

  static Map<String, bool> resolveOrderTypeAvailability({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    bool defaultDineIn = true,
    bool defaultPickup = true,
  }) {
    bool? dineIn;
    bool? pickup;

    for (final source in [kioskSettings, restaurant, data, root]) {
      if (source == null) continue;

      final configured = _readOrderTypeConfig(source);
      if (configured.configured) {
        if (configured.dineIn != null) dineIn = configured.dineIn;
        if (configured.pickup != null) pickup = configured.pickup;
      }

      final explicitDineIn = _readBool(source, const [
        "dine_in",
        "dinein",
        "eat_here",
        "eatHere",
        "is_dine_in",
        "enable_dine_in",
        "enableDineIn",
        "dine_in_enabled",
        "dineInEnabled",
        "eat_here_enabled",
        "eatHereEnabled",
        "allow_dine_in_orders",
        "allowDineInOrders",
      ]);
      if (explicitDineIn != null) dineIn = explicitDineIn;

      final explicitPickup = _readBool(source, const [
        "pickup",
        "pick_up",
        "pickUp",
        "takeaway",
        "take_away",
        "takeAway",
        "is_pickup",
        "enable_pickup",
        "enablePickup",
        "enable_takeaway",
        "enableTakeaway",
        "enable_take_away",
        "enableTakeAway",
        "pickup_enabled",
        "pickupEnabled",
        "takeaway_enabled",
        "takeawayEnabled",
        "take_away_enabled",
        "takeAwayEnabled",
        "allow_customer_pickup_orders",
        "allowCustomerPickupOrders",
      ]);
      if (explicitPickup != null) pickup = explicitPickup;

      final allowCustomerOrders = _readBool(source, const [
        "allow_customer_orders",
        "allowCustomerOrders",
        "customer_orders_enabled",
        "customerOrdersEnabled",
        "allow_orders",
        "allowOrders",
      ]);
      if (allowCustomerOrders == false) {
        dineIn = false;
        pickup = false;
      }
    }

    return {
      "dine_in": dineIn ?? defaultDineIn,
      "pickup": pickup ?? defaultPickup,
    };
  }

  static Map<String, bool> resolveWelcomeOrderTypes({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    bool defaultDineIn = true,
    bool defaultPickup = true,
  }) {
    final availability = resolveOrderTypeAvailability(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
      defaultDineIn: defaultDineIn,
      defaultPickup: defaultPickup,
    );

    final allowChoice = resolveAllowOrderTypeChoice(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    if (allowChoice) return availability;

    final defaultType = resolveDefaultOrderType(
      root: root,
      data: data,
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    if (defaultType == "pickup" && availability["pickup"] == true) {
      return {"dine_in": false, "pickup": true};
    }
    if (defaultType == "dine_in" && availability["dine_in"] == true) {
      return {"dine_in": true, "pickup": false};
    }
    if (availability["dine_in"] == true) {
      return {"dine_in": true, "pickup": false};
    }
    if (availability["pickup"] == true) {
      return {"dine_in": false, "pickup": true};
    }
    return {"dine_in": false, "pickup": false};
  }

  static bool resolveAllowOrderTypeChoice({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    bool defaultValue = true,
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      final value = _readBool(source, const [
        "allow_order_type_choice",
        "allowOrderTypeChoice",
        "show_order_type_choice",
        "showOrderTypeChoice",
      ]);
      if (value != null) return value;
    }
    return defaultValue;
  }

  static String resolveDefaultOrderType({
    Map? root,
    Map? data,
    Map? restaurant,
    Map? kioskSettings,
    String defaultValue = "dine_in",
  }) {
    for (final source in [kioskSettings, restaurant, data, root]) {
      final value = _firstNonEmpty([
        source?["order_type"],
        source?["orderType"],
        source?["default_order_type"],
        source?["defaultOrderType"],
      ]);
      final normalized = _normalizeOrderType(value);
      if (normalized == "dine_in") {
        return "dine_in";
      }
      if (normalized == "pickup") return "pickup";
    }
    return defaultValue;
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

  static _OrderTypeFlags _readOrderTypeConfig(Map source) {
    for (final key in const [
      "order_types",
      "orderTypes",
      "available_order_types",
      "availableOrderTypes",
      "allowed_order_types",
      "allowedOrderTypes",
      "order_type_list",
      "orderTypeList",
      "pos_order_types",
      "posOrderTypes",
    ]) {
      if (!source.containsKey(key)) continue;
      return _parseOrderTypeConfig(source[key]);
    }
    return _OrderTypeFlags();
  }

  static _OrderTypeFlags _parseOrderTypeConfig(dynamic value) {
    final flags = _OrderTypeFlags(configured: true);
    if (value == null) return flags;

    if (value is List) {
      if (value.isEmpty) {
        flags.dineIn = false;
        flags.pickup = false;
        return flags;
      }
      var sawKnownType = false;
      for (final item in value) {
        final applied = _applyOrderTypeValue(flags, item);
        sawKnownType = sawKnownType || applied;
      }
      if (sawKnownType) {
        flags.dineIn ??= false;
        flags.pickup ??= false;
      }
      return flags;
    }

    if (value is Map) {
      if (value.isEmpty) {
        flags.dineIn = false;
        flags.pickup = false;
        return flags;
      }
      var sawKnownType = false;
      final directType = _firstNonEmpty([
        value["type"],
        value["slug"],
        value["key"],
        value["value"],
        value["name"],
        value["order_type"],
        value["orderType"],
      ]);
      if (directType != null) {
        sawKnownType = _setOrderType(
          flags,
          directType,
          _readEnabled(value, defaultValue: true),
        );
      } else {
        for (final entry in value.entries) {
          final applied = _setOrderType(
            flags,
            entry.key.toString(),
            _enabledFromValue(entry.value, defaultValue: true),
          );
          sawKnownType = sawKnownType || applied;
        }
      }
      if (sawKnownType) {
        flags.dineIn ??= false;
        flags.pickup ??= false;
      }
      return flags;
    }

    final text = value.toString().trim();
    if (text.isEmpty) return flags;
    var sawKnownType = false;
    for (final part in text
        .split(",")
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)) {
      final applied = _setOrderType(flags, part, true);
      sawKnownType = sawKnownType || applied;
    }
    if (sawKnownType) {
      flags.dineIn ??= false;
      flags.pickup ??= false;
    }
    return flags;
  }

  static bool _applyOrderTypeValue(_OrderTypeFlags flags, dynamic value) {
    if (value is Map) {
      final type = _firstNonEmpty([
        value["type"],
        value["slug"],
        value["key"],
        value["value"],
        value["name"],
        value["order_type"],
        value["orderType"],
      ]);
      if (type == null) return false;
      return _setOrderType(
        flags,
        type,
        _readEnabled(value, defaultValue: true),
      );
    }
    return _setOrderType(flags, value?.toString(), true);
  }

  static bool _setOrderType(
    _OrderTypeFlags flags,
    String? rawType,
    bool enabled,
  ) {
    final type = _normalizeOrderType(rawType);
    if (type == null) return false;
    if (type == "dine_in") {
      flags.dineIn = enabled;
      return true;
    }
    if (type == "pickup") {
      flags.pickup = enabled;
      return true;
    }
    return false;
  }

  static String? _normalizeOrderType(String? value) {
    if (value == null) return null;
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll("-", "_")
        .replaceAll(RegExp(r"\s+"), "_");
    if (normalized.isEmpty) return null;
    if (normalized == "dinein" || normalized == "dine_in") return "dine_in";
    if (normalized == "pickup" ||
        normalized == "pick_up" ||
        normalized == "takeaway" ||
        normalized == "take_away" ||
        normalized == "takeout" ||
        normalized == "take_out") {
      return "pickup";
    }
    return normalized;
  }

  static bool _readEnabled(Map value, {required bool defaultValue}) {
    return _readBool(value, const [
          "enabled",
          "is_enabled",
          "isEnabled",
          "available",
          "is_available",
          "isAvailable",
          "active",
          "is_active",
          "isActive",
          "visible",
          "show",
          "status",
          "allow",
        ]) ??
        defaultValue;
  }

  static bool _enabledFromValue(dynamic value, {required bool defaultValue}) {
    if (value is Map) return _readEnabled(value, defaultValue: defaultValue);
    return _boolFromValue(value) ?? defaultValue;
  }

  static Map<String, dynamic>? _toStringKeyedMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry("$key", value));
  }

  static bool _looksLikeKioskSettings(Map<String, dynamic> value) {
    return const {
      "order_type",
      "orderType",
      "allow_order_type_choice",
      "allowOrderTypeChoice",
      "require_customer_name",
      "requireCustomerName",
      "payment_at_counter",
      "paymentAtCounter",
      "show_item_images",
      "showItemImages",
      "show_category_images",
      "showCategoryImages",
      "print_receipt_on_complete",
      "printReceiptOnComplete",
      "tax_breakdown_display",
      "taxBreakdownDisplay",
      "variant_price_display",
      "variantPriceDisplay",
      "idle_timeout_seconds",
      "idleTimeoutSeconds",
      "payment_qr_timeout_seconds",
      "paymentQrTimeoutSeconds",
      "screensaver_interval_seconds",
      "screensaverIntervalSeconds",
    }.any(value.containsKey);
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
      final value = _boolFromValue(data[key]);
      if (value != null) return value;
    }
    return null;
  }

  static bool? _boolFromValue(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final value = raw.trim().toLowerCase();
      if (value.isEmpty) return null;
      if (const {
        "1",
        "true",
        "yes",
        "y",
        "on",
        "active",
        "enabled",
        "available",
        "visible",
        "show",
      }.contains(value)) {
        return true;
      }
      if (const {
        "0",
        "false",
        "no",
        "n",
        "off",
        "inactive",
        "disabled",
        "unavailable",
        "hidden",
        "hide",
      }.contains(value)) {
        return false;
      }
    }
    return null;
  }
}

class _OrderTypeFlags {
  _OrderTypeFlags({
    this.configured = false,
  });

  final bool configured;
  bool? dineIn;
  bool? pickup;
}
