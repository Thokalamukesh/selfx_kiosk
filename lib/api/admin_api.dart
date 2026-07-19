import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';

import 'dio_client.dart';

class AdminApi {
  static final Map<int, String> _orderNumbersById = {};
  static int _syntheticOrderId = -1;

  // =========================================================
  // ADMIN UNLOCK
  // =========================================================
  Future<Response> login({
    required String deviceId,
    required String pin,
  }) async {
    final dio = await DioClient.getAuthedDio();

    final res = await dio.post(
      "kiosk/admin/unlock",
      data: {"password": pin},
    );
    kioskLog(
      "unlock status=${res.statusCode} body=${_compactLog(res.data)}",
      tag: "ADMIN_PIN",
    );
    _ensureSuccess(res);

    final data = _map(res.data);
    final nestedData = _map(data["data"]);
    final token = data["admin_token"] ??
        data["token"] ??
        nestedData["admin_token"] ??
        nestedData["token"];
    if (token == null || token.toString().trim().isEmpty) {
      throw Exception("Admin token missing");
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("admin_token", token.toString());
    final expiresAt =
        (data["expires_at"] ?? nestedData["expires_at"])?.toString();
    if (expiresAt != null && expiresAt.isNotEmpty) {
      await prefs.setString("admin_token_expires_at", expiresAt);
    } else {
      await prefs.remove("admin_token_expires_at");
    }

    return _copyResponse(res, {
      ...data,
      "token": token,
    });
  }

  Future<Response> lock() async {
    try {
      final dio = await DioClient.getAdminDio();
      final res = await dio.post("kiosk/admin/lock");
      _ensureSuccess(res);
      return res;
    } finally {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("admin_token");
      await prefs.remove("admin_token_expires_at");
    }
  }

  // =========================================================
  // ADMIN AUTH APIs
  // =========================================================

  Future<Response> getItems() async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.get("kiosk/admin/menu");
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeAdminMenu(res.data));
  }

  Future<Response> getCategories() async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.get("kiosk/admin/menu");
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeAdminMenu(res.data));
  }

  Future<Response> getOrders(Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.get(
      "kiosk/admin/orders",
      queryParameters: {
        if ((body["page"]?.toString() ?? "").isNotEmpty) "page": body["page"],
        if ((body["status"]?.toString() ?? "").isNotEmpty)
          "status": body["status"],
        if ((body["per_page"]?.toString() ?? "").isNotEmpty)
          "per_page": body["per_page"],
        if ((body["terminal_id"]?.toString() ?? "").isNotEmpty)
          "terminal_id": body["terminal_id"],
        if ((body["device_uuid"]?.toString() ?? "").isNotEmpty)
          "device_uuid": body["device_uuid"],
        if ((body["device_id"]?.toString() ?? "").isNotEmpty)
          "device_id": body["device_id"],
      },
    );
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeOrders(res.data));
  }

  Future<Response> getOrder(String id) async {
    final dio = await DioClient.getAdminDio();
    final orderNumber = _resolveOrderNumber(id);
    final res = await dio.get("kiosk/admin/orders/$orderNumber");
    _ensureSuccess(res);
    return res;
  }

  Future<Response> getSettings() async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.get("kiosk/admin/settings");
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeSettings(res.data));
  }

  Future<Response> updateSettings(Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.patch("kiosk/admin/settings", data: body);
    _ensureSuccess(res);
    return res;
  }

  Future<Response> updateCategory(String id, Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final payload = _categoryPayload(body);
    final res = await dio.patch(
      "kiosk/admin/menu-categories/$id",
      data: payload,
    );
    _ensureSuccess(res);
    return res;
  }

  Future<Response> toggleCategory(String id) async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.post("kiosk/admin/menu-categories/$id/toggle-active");
    _ensureSuccess(res);
    return res;
  }

  Future<Response> createCategory(Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final payload = _categoryPayload(body);
    final res = await dio.post("kiosk/admin/menu-categories", data: payload);
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeCategoryUpdate(res.data));
  }

  Future<Response> updateItem(String id, Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final payload = _itemPayload(body);
    final res = await dio.patch("kiosk/admin/menu-items/$id", data: payload);
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeItemUpdate(res.data));
  }

  Future<Response> toggleItem(String id) async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.post("kiosk/admin/menu-items/$id/toggle-available");
    _ensureSuccess(res);
    return res;
  }

  Future<Response> cancelOrder(String id) async {
    final dio = await DioClient.getAdminDio();
    final orderNumber = _resolveOrderNumber(id);
    try {
      final res = await dio.post("kiosk/admin/orders/$orderNumber/cancel");
      _ensureSuccess(res);
      return res;
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (status != 404 && status != 405) rethrow;
    }

    final res = await dio.patch(
      "kiosk/admin/orders/$orderNumber/status",
      data: {"status": "cancelled"},
    );
    _ensureSuccess(res);
    return res;
  }

  Future<Response> createItem(Map<String, dynamic> body) async {
    final dio = await DioClient.getAdminDio();
    final payload = _itemPayload(body);
    final res = await dio.post("kiosk/admin/menu-items", data: payload);
    _ensureSuccess(res);
    return _copyResponse(res, _normalizeItemUpdate(res.data));
  }

  Future<Response> getOrderSummary({
    required String date,
    int? branchId,
    int? restaurantId,
  }) async {
    final dio = await DioClient.getAdminDio();
    final res = await dio.get("kiosk/admin/dashboard");
    _ensureSuccess(res);
    final root = _map(res.data);
    final data = _firstNonEmptyMap([
      root["data"],
      root["dashboard"],
      root["result"],
      root,
    ]);
    final summary = _firstNonEmptyMap([
      data["summary"],
      data["stats"],
      data["totals"],
      root["summary"],
      root["stats"],
      root["totals"],
    ]);
    final recentOrders = _firstList([
      data["recent_orders"],
      data["recentOrders"],
      data["orders"],
      root["recent_orders"],
      root["recentOrders"],
      root["orders"],
    ]);
    return _copyResponse(res, {
      ...root,
      ...data,
      "date": date,
      "total_orders": summary["total_orders"] ??
          summary["totalOrders"] ??
          summary["today_orders"] ??
          summary["todayOrders"] ??
          0,
      "pending_orders": summary["pending_orders"] ??
          summary["pendingOrders"] ??
          summary["today_pending"] ??
          summary["todayPending"] ??
          0,
      "total_pending": summary["total_pending"] ??
          summary["totalPending"] ??
          summary["today_pending"] ??
          summary["todayPending"] ??
          0,
      "total_amount": summary["total_amount"] ??
          summary["totalAmount"] ??
          summary["today_revenue"] ??
          summary["todayRevenue"] ??
          summary["revenue"] ??
          0,
      "total_revenue": summary["total_revenue"] ??
          summary["totalRevenue"] ??
          summary["today_revenue"] ??
          summary["todayRevenue"] ??
          summary["revenue"] ??
          0,
      "orders": recentOrders,
      "data": {
        "orders": recentOrders,
        "summary": summary,
      },
      "category_totals": <Map<String, dynamic>>[],
      "items_by_category": <String, dynamic>{},
    });
  }

  Map<String, dynamic> _normalizeAdminMenu(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final source = data.isNotEmpty ? data : root;
    final rawCategories =
        source["categories"] is List ? source["categories"] as List : const [];

    final categories = <Map<String, dynamic>>[];
    final items = <Map<String, dynamic>>[];

    for (final rawCategory in rawCategories.whereType<Map>()) {
      final category = _map(rawCategory);
      final categoryName = category["category_name"] ?? category["name"];
      final categoryImage = firstImageValueFromMap(
        category,
        keys: const [
          "category_image",
          "category_image_url",
          "image_url",
          "imageUrl",
          "image",
          "photo_url",
          "photoUrl",
          "photo",
          "thumbnail",
          "thumb",
          "img",
        ],
      );
      final rawItems =
          category["items"] is List ? category["items"] as List : const [];
      final normalizedItems = rawItems.whereType<Map>().map((rawItem) {
        final item = _map(rawItem);
        final itemImage = firstImageValueFromMap(item);
        final rawAvailability = item["is_available"] ??
            item["isAvailable"] ??
            item["available"] ??
            item["enabled"] ??
            item["status"] ??
            item["item_status"] ??
            item["itemStatus"];
        final isAvailable =
            rawAvailability == null ? true : _boolValue(rawAvailability);
        return {
          ...item,
          "category_id": category["id"],
          "category_name": categoryName,
          "item_id": item["id"],
          "item_name": item["item_name"] ?? item["name"],
          "item_photo_url": itemImage ?? categoryImage,
          "item_price": item["item_price"] ?? item["price"],
          "price": item["price"] ?? item["item_price"],
          "is_available": isAvailable ? 1 : 0,
          "isAvailable": isAvailable ? 1 : 0,
          "available": isAvailable ? 1 : 0,
        };
      }).toList();

      items.addAll(normalizedItems);
      categories.add({
        ...category,
        "id": category["id"] ?? category["category_id"],
        "category_id": category["id"] ?? category["category_id"],
        "category_name": categoryName,
        "category_image": categoryImage,
        "items": normalizedItems,
      });
    }

    return {
      ...source,
      "categories": categories,
      "categoryList": categories,
      "menus": source["menus"] is List ? source["menus"] : const [],
      "time_slots":
          source["time_slots"] is List ? source["time_slots"] : const [],
      "modifiers": source["modifiers"] is List ? source["modifiers"] : const [],
      "items": items,
      "data": items,
    };
  }

  Map<String, dynamic> _normalizeOrders(dynamic raw) {
    final root = _map(raw);
    final nested = _firstNonEmptyMap([
      root["data"],
      root["result"],
      root["payload"],
    ]);
    final data = _firstList([
      root["orders"],
      root["recent_orders"],
      root["recentOrders"],
      root["data"],
      nested["orders"],
      nested["recent_orders"],
      nested["recentOrders"],
      nested["data"],
      nested["items"],
    ]);
    final orders = data.whereType<Map>().map((order) {
      final map = _map(order);
      final orderNumber = map["order_number"]?.toString() ??
          map["number"]?.toString() ??
          map["id"]?.toString();
      final rawId = _asInt(map["id"]);
      final id = rawId == 0 && orderNumber != null && orderNumber.isNotEmpty
          ? _syntheticOrderId--
          : rawId;
      if (id != 0 && orderNumber != null && orderNumber.isNotEmpty) {
        _orderNumbersById[id] = orderNumber;
      }
      return {
        ...map,
        "id": id,
        "order_id": id,
        "order_number": orderNumber,
      };
    }).toList();
    return {
      ...root,
      "orders": orders,
      "data": {
        "orders": orders,
        "meta": root["meta"] ?? nested["meta"],
      },
    };
  }

  Map<String, dynamic> _normalizeSettings(dynamic raw) {
    final root = _map(raw);
    final data = _firstNonEmptyMap([root["data"], root["result"], root]);
    final kiosk = _firstNonEmptyMap([
      data["kiosk"],
      data["settings"],
      data["kiosk_settings"],
      root["kiosk"],
      root["settings"],
      root["kiosk_settings"],
      if (_looksLikeKioskSettings(data)) data,
      if (_looksLikeKioskSettings(root)) root,
    ]);
    final restaurant = _firstNonEmptyMap([
      data["restaurant"],
      root["restaurant"],
    ]);
    return {
      ...root,
      ...data,
      "restaurant": restaurant,
      "settings": kiosk,
      "kiosk_settings": kiosk,
    };
  }

  bool _looksLikeKioskSettings(Map<String, dynamic> value) {
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

  Map<String, dynamic> _normalizeItemUpdate(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final item = _firstNonEmptyMap([
      root["item"],
      data["item"],
      data,
      root,
    ]);
    return {
      ...root,
      "ok": root["ok"] ?? true,
      "item": {
        ...item,
        "item_name": item["item_name"] ?? item["name"],
        "item_price": item["item_price"] ?? item["price"],
      },
    };
  }

  Map<String, dynamic> _normalizeCategoryUpdate(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final category = _firstNonEmptyMap([
      root["category"],
      data["category"],
      data,
      root,
    ]);
    return {
      ...root,
      "ok": root["ok"] ?? true,
      "category": {
        ...category,
        "category_id": category["category_id"] ?? category["id"],
        "category_name": category["category_name"] ?? category["name"],
      },
    };
  }

  Map<String, dynamic> _itemPayload(Map<String, dynamic> body) {
    final payload = <String, dynamic>{};
    final name = body["name"] ?? body["item_name"];
    final price = body["price"] ?? body["item_price"];
    final isAvailable =
        body["is_available"] ?? body["isAvailable"] ?? body["available"];
    final categoryId = body["menu_category_id"] ??
        body["item_category_id"] ??
        body["category_id"];

    if (name != null && name.toString().trim().isNotEmpty) {
      payload["name"] = name.toString().trim();
    }
    if (price != null) payload["price"] = _numOrOriginal(price);
    if (isAvailable != null) {
      payload["is_available"] = _boolValue(isAvailable);
    }
    if (categoryId != null) {
      payload["menu_category_id"] = _numOrOriginal(categoryId);
    }
    _copyPayloadKeys(body, payload, const [
      "menu_id",
      "branch_id",
      "restaurant_id",
      "description",
      "type",
      "take_away_charge",
      "parcel_charge",
      "has_variations",
      "has_variation",
      "variations",
      "modifier_ids",
      "time_slot_ids",
    ]);

    for (final imageKey in const [
      "image",
      "image_url",
      "imageUrl",
      "photo",
      "photo_url",
      "photoUrl",
      "item_photo",
      "item_photo_url",
      "itemPhotoUrl",
    ]) {
      if (body.containsKey(imageKey) && body[imageKey] != null) {
        payload[imageKey] = body[imageKey];
      }
    }

    return payload.isEmpty ? body : payload;
  }

  Map<String, dynamic> _categoryPayload(Map<String, dynamic> body) {
    final payload = <String, dynamic>{};
    final name = body["name"] ?? body["category_name"];
    final description = body["description"];
    final isActive = body["is_active"] ??
        body["isActive"] ??
        body["active"] ??
        body["enabled"] ??
        body["status"] ??
        body["category_status"] ??
        body["categoryStatus"] ??
        body["is_available"] ??
        body["isAvailable"] ??
        body["available"];

    if (name != null && name.toString().trim().isNotEmpty) {
      payload["name"] = name.toString().trim();
    }
    if (description != null) payload["description"] = description;
    if (isActive != null) payload["is_active"] = _boolValue(isActive);
    _copyPayloadKeys(body, payload, const [
      "menu_id",
      "branch_id",
      "restaurant_id",
      "type",
      "time_slot_ids",
      "sort_order",
      "display_order",
    ]);

    for (final imageKey in const [
      "image",
      "image_url",
      "imageUrl",
      "photo",
      "photo_url",
      "photoUrl",
      "category_image",
      "category_image_url",
      "categoryImageUrl",
    ]) {
      if (body.containsKey(imageKey) && body[imageKey] != null) {
        payload[imageKey] = body[imageKey];
      }
    }

    return payload.isEmpty ? body : payload;
  }

  void _copyPayloadKeys(
    Map<String, dynamic> source,
    Map<String, dynamic> target,
    List<String> keys,
  ) {
    for (final key in keys) {
      if (!source.containsKey(key)) continue;
      final value = source[key];
      if (value == null) continue;
      target[key] = value;
    }
  }

  dynamic _numOrOriginal(dynamic value) {
    if (value is num) return value;
    return num.tryParse(value.toString()) ?? value;
  }

  bool _boolValue(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    if (text == "0" ||
        text == "false" ||
        text == "no" ||
        text == "n" ||
        text == "off" ||
        text == "inactive" ||
        text == "disabled" ||
        text == "hidden" ||
        text == "unavailable" ||
        text == "not_available" ||
        text == "not available" ||
        text == "out_of_stock" ||
        text == "out of stock") {
      return false;
    }
    return text == "1" ||
        text == "true" ||
        text == "yes" ||
        text == "y" ||
        text == "on" ||
        text == "active" ||
        text == "enabled" ||
        text == "available" ||
        text == "in_stock" ||
        text == "in stock";
  }

  Response _copyResponse(Response source, dynamic data) {
    return Response(
      requestOptions: source.requestOptions,
      statusCode: source.statusCode,
      statusMessage: source.statusMessage,
      headers: source.headers,
      redirects: source.redirects,
      extra: source.extra,
      data: data,
    );
  }

  static String errorMessage(Object error) {
    final message = _errorMessage(error);
    if (message != null && message.trim().isNotEmpty) {
      final normalized = message.trim().toLowerCase();
      if (normalized.contains("kiosk token missing")) {
        return "Pair this kiosk first, then enter the admin PIN.";
      }
      if (normalized.contains("admin token missing")) {
        return "PIN accepted, but the backend did not return an admin token.";
      }
      return message;
    }
    return "Something went wrong";
  }

  void _ensureSuccess(Response response) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;

    final message = _errorMessage(response.data) ??
        response.statusMessage ??
        "Request failed with status $status";
    throw Exception(message);
  }

  static String? _errorMessage(dynamic value) {
    if (value is DioException) {
      return _errorMessage(value.response?.data) ?? value.message;
    }
    if (value is Map) {
      final map = value.map((key, value) => MapEntry("$key", value));
      final direct = map["message"] ?? map["error"];
      if (direct != null && direct.toString().trim().isNotEmpty) {
        return direct.toString();
      }
      final errors = map["errors"];
      if (errors is Map && errors.isNotEmpty) {
        final first = errors.values.first;
        if (first is List && first.isNotEmpty) return first.first.toString();
        return first.toString();
      }
    }
    final text = value.toString();
    if (text.startsWith("Exception: ")) {
      return text.substring("Exception: ".length);
    }
    return text.isEmpty ? null : text;
  }

  static String _compactLog(dynamic value) {
    final text = value?.toString() ?? "null";
    if (text.length <= 500) return text;
    return "${text.substring(0, 500)}...";
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry("$key", value));
  }

  Map<String, dynamic> _firstNonEmptyMap(Iterable<dynamic> values) {
    for (final value in values) {
      final map = _map(value);
      if (map.isNotEmpty) return map;
    }
    return <String, dynamic>{};
  }

  List _firstList(Iterable<dynamic> values) {
    for (final value in values) {
      if (value is List) return value;
      if (value is Map) {
        final map = _map(value);
        for (final key in const ["data", "orders", "items", "results"]) {
          final nested = map[key];
          if (nested is List) return nested;
        }
      }
    }
    return const [];
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? "") ?? 0;
  }

  String _resolveOrderNumber(String id) {
    final parsed = int.tryParse(id);
    if (parsed != null && _orderNumbersById.containsKey(parsed)) {
      return _orderNumbersById[parsed]!;
    }
    return id;
  }
}
