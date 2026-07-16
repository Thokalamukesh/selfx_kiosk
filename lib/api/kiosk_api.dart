import 'package:dio/dio.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dio_client.dart';
import 'web_api_config.dart';

class KioskApi {
  static final Map<int, String> _orderNumbersById = {};
  static int _syntheticOrderId = -1;
  static const String _fallbackPaymentMethod = "phonepe";
  static const Duration _menuCacheDuration = Duration(seconds: 20);
  static Map<String, dynamic>? _cachedMenuData;
  static DateTime? _cachedMenuAt;
  static const String kioskDisabledMessage =
      "Kiosk ordering is not enabled for this restaurant.";

  static bool isBootstrapForbiddenError(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode ?? 0;
    final path = error.requestOptions.path;
    if (status != 403 || !path.contains("kiosk/bootstrap")) return false;

    final message = errorMessageFrom(error).toLowerCase();
    return message.contains("kiosk ordering") ||
        message.contains("not enabled") ||
        message.contains("forbidden") ||
        message.isEmpty;
  }

  static bool isKioskAuthError(Object error) {
    final message = errorMessageFrom(error).toLowerCase();
    if (message.contains("kiosk token missing") ||
        message.contains("unauthenticated") ||
        message.contains("unauthorized") ||
        message.contains("invalid token") ||
        message.contains("token expired") ||
        message.contains("pair this kiosk")) {
      return true;
    }

    if (error is! DioException) return false;
    final status = error.response?.statusCode ?? 0;
    if (status == 401) return true;
    if (status == 403 && !isBootstrapForbiddenError(error)) return true;
    return false;
  }

  static String errorMessageFrom(Object error) {
    if (error is DioException) {
      final message =
          _extractErrorMessage(error.response?.data) ?? error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return message;
      }
    }
    return error.toString().replaceFirst("Exception: ", "").trim();
  }

  static String kioskLoadMessageFrom(Object error) {
    if (isBootstrapForbiddenError(error)) {
      return bootstrapDisabledHelpMessage(error);
    }

    final message = errorMessageFrom(error).toLowerCase();
    if (error is DioException) {
      final status = error.response?.statusCode ?? 0;
      if (status == 429 ||
          message.contains("too many attempts") ||
          message.contains("rate limit")) {
        return "Server is busy. Please wait a moment, then retry.";
      }
      if (status == 404 ||
          message.contains("could not be found") ||
          message.contains("not found")) {
        return "This kiosk is not paired yet. Pair this kiosk again from the admin panel.";
      }
      if (status == 401 || status == 403) {
        return "Kiosk session expired. Pair this kiosk again from the admin panel.";
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return "Kiosk could not connect to the server. Check the internet connection, then retry.";
      }
    }

    if (message.contains("dioexception") ||
        message.contains("bad response") ||
        message.contains("api request failed")) {
      return "Kiosk could not load. Retry loading, or pair this kiosk again from the admin panel.";
    }

    final clean = errorMessageFrom(error);
    return clean.isEmpty
        ? "Kiosk could not load. Retry loading, or pair this kiosk again from the admin panel."
        : clean;
  }

  static String bootstrapDisabledHelpMessage(Object error) {
    final message = errorMessageFrom(error);
    final base = message.isEmpty ? kioskDisabledMessage : message;
    return "$base Enable kiosk ordering for this restaurant in the admin panel, then retry.";
  }

  // =========================================================
  // RESTAURANT + KIOSK SETTINGS
  // =========================================================
  Future<Response> getRestaurantData() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosk/bootstrap");
    _throwForBadStatus(res);
    final normalized = _normalizeBootstrap(res.data);
    await KioskRestaurantMeta.storeFromResponse(normalized);
    await _storeBootstrapPrefs(normalized);
    return _copyResponse(res, normalized);
  }

  Future<List<Map<String, dynamic>>> getAllRestaurantsWeb() async {
    if (!kIsWeb) return const [];

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 18),
        sendTimeout: null,
        headers: const {
          "Accept": "application/json",
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final configuredUrl = WebApiConfig.allRestaurantsUrl.trim();
    if (configuredUrl.isEmpty) {
      kioskLog(
        'No web restaurants URL configured',
        tag: 'WEB_RESTAURANTS',
      );
      return const [];
    }

    kioskLog(
      'Loading web restaurants from $configuredUrl',
      tag: 'WEB_RESTAURANTS',
    );
    final initial = await dio.get(configuredUrl);

    final direct = _extractRestaurantList(initial.data);
    if (direct.isNotEmpty) {
      kioskLog(
        'Loaded ${direct.length} restaurants directly from JSON',
        tag: 'WEB_RESTAURANTS',
      );
      return direct;
    }

    final fallbackUrl = _deriveRestaurantApiUrl(
      configuredUrl: configuredUrl,
      responseData: initial.data,
    );
    if (fallbackUrl == null || fallbackUrl == configuredUrl) return const [];

    kioskLog(
      'Falling back to restaurant API $fallbackUrl',
      tag: 'WEB_RESTAURANTS',
    );
    final fallback = await dio.get(fallbackUrl);
    final list = _extractRestaurantList(fallback.data);
    kioskLog(
      'Loaded ${list.length} restaurants from fallback JSON',
      tag: 'WEB_RESTAURANTS',
    );
    return list;
  }

  List<Map<String, dynamic>> _extractRestaurantList(dynamic raw) {
    final rawList = raw is List
        ? raw
        : raw is Map
            ? (raw["data"] ?? raw["restaurants"] ?? raw["items"])
            : null;
    if (rawList is! List) return const [];

    return rawList
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry("$key", value)))
        .toList();
  }

  String? _deriveRestaurantApiUrl({
    required String configuredUrl,
    required dynamic responseData,
  }) {
    final configuredUri = Uri.tryParse(configuredUrl);
    if (configuredUri == null || responseData is! String) return null;

    final html = responseData;
    final match = RegExp(
      r"""fetch\(\s*['"]([^'"]+)['"]\s*\)""",
      caseSensitive: false,
    ).firstMatch(html);
    final path = match?.group(1)?.trim();
    if (path == null || path.isEmpty) return null;

    return configuredUri.resolve(path).toString();
  }

  // =========================================================
  // PRODUCTS
  // =========================================================
  Future<Response> getProducts({bool forceRefresh = false}) async {
    final cached = forceRefresh ? null : _freshCachedMenuData();
    if (cached != null) {
      return Response(
        requestOptions: RequestOptions(path: "kiosk/menu"),
        statusCode: 200,
        data: cached,
      );
    }

    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosk/menu");
    _throwForBadStatus(res);
    final normalized = _normalizeMenu(res.data);
    _cachedMenuData = normalized;
    _cachedMenuAt = DateTime.now();
    return _copyResponse(res, normalized);
  }

  // =========================================================
  // CREATE ORDER
  // =========================================================
  Future<Response> createOrder({
    required String orderType,
    required List<Map<String, dynamic>> orderItems,
  }) async {
    final dio = await DioClient.getAuthedDio();
    final paymentMethod = await _resolvePaymentMethod();
    final payload = {
      "items": orderItems.map(_normalizeCheckoutItem).toList(),
      "order_type": _normalizeOrderType(orderType),
      "payment_method": paymentMethod,
      "customer_name": "Guest",
    };
    kioskLog("CREATE_ORDER payload=${_compactLog(payload)}", tag: "ORDER");
    final res = await dio.post(
      "kiosk/orders",
      data: payload,
    );
    kioskLog(
      "CREATE_ORDER response status=${res.statusCode} body=${_compactLog(res.data)}",
      tag: "ORDER",
    );
    _throwForBadStatus(res);
    final normalized = _normalizeCreatedOrder(res.data);
    final id = _asInt(normalized["order"]?["id"]);
    final number = normalized["order"]?["order_number"]?.toString();
    if (id != 0 && number != null && number.isNotEmpty) {
      _orderNumbersById[id] = number;
    }
    return _copyResponse(res, normalized);
  }

  // =========================================================
  // GENERATE QR
  // =========================================================
  Future<Response> generateQr({required int orderId}) async {
    final dio = await DioClient.getAuthedDio();
    final orderNumber = _resolveOrderNumber(orderId);
    final paymentMethod = await _resolvePaymentMethod();
    final orderRefs = _uniqueStrings([
      orderNumber,
      orderId.toString(),
    ]);
    final queryAttempts = <Map<String, dynamic>>[
      if (paymentMethod.isNotEmpty) {"gateway": paymentMethod},
      const <String, dynamic>{},
    ];

    Response? lastResponse;
    DioException? lastException;

    for (final orderRef in orderRefs) {
      for (final query in queryAttempts) {
        final hasGateway = query.containsKey("gateway");
        try {
          final res = await dio.get(
            "kiosk/orders/$orderRef/payment/qr",
            queryParameters: query.isEmpty ? null : query,
          );
          kioskLog(
            "QR response status=${res.statusCode} order=$orderRef gateway=${hasGateway ? paymentMethod : '-'} body=${_compactLog(res.data)}",
            tag: "PAYMENT",
          );
          if ((res.statusCode ?? 0) < 400) {
            return _copyResponse(res, _normalizeQr(res.data));
          }
          if (res.statusCode == 429) {
            _throwForBadStatus(res);
          }
          lastResponse = res;
        } on DioException catch (e) {
          lastException = e;
          lastResponse = e.response;
          kioskLogError(
            "QR request failed order=$orderRef gateway=${hasGateway ? paymentMethod : '-'} status=${e.response?.statusCode ?? 'NO_STATUS'} body=${_compactLog(e.response?.data)}",
            tag: "PAYMENT",
            error: e,
            stackTrace: e.stackTrace,
          );
          if (e.response?.statusCode == 429) {
            rethrow;
          }
        }
      }
    }

    if (lastResponse != null) {
      _throwForBadStatus(lastResponse);
    }
    if (lastException != null) {
      throw lastException;
    }
    throw Exception("QR generation failed");
  }

  // =========================================================
  // CHECK PAYMENT
  // =========================================================
  Future<Response> checkPayment(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    final orderNumber = _resolveOrderNumber(orderId);
    final paymentMethod = await _resolvePaymentMethod();
    final res = await dio.get(
      "kiosk/orders/$orderNumber/payment/status",
      queryParameters: {"gateway": paymentMethod},
      options: Options(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 4),
        extra: const {"no_retry": true},
      ),
    );
    _throwForBadStatus(res);
    return _copyResponse(res, _normalizePaymentStatus(res.data));
  }

  // =========================================================
  // GET ORDER DETAILS
  // =========================================================
  Future<Response> getOrderDetails(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    final orderNumber = _resolveOrderNumber(orderId);
    final res = await dio.get("kiosk/orders/$orderNumber");
    _throwForBadStatus(res);
    return _copyResponse(res, _normalizeOrderDetails(res.data, orderId));
  }

  // =========================================================
  // PRINTER (BACKEND + CAPACITOR)
  // =========================================================

  Future<List<Map<String, dynamic>>> getPrinterList() async {
    return const [];
  }

  Future<void> saveSelectedPrinter(String productId) async {}

  Future<Map<String, dynamic>?> getSelectedPrinter() async {
    return null;
  }

  // =========================================================
  // DEVICE MONITORING
  // =========================================================

  Future<Response> pingDevice() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.post(
      "kiosk/heartbeat",
      data: {
        "app_version": "1.0.0",
        "platform": kIsWeb ? "web" : "android",
      },
    );
    _throwForBadStatus(res);
    return res;
  }

  // =========================================================
  // PRINT RECEIPT (BACKEND HANDLES PRINTER)
  // =========================================================

  Future<Response> printReceipt(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    final orderNumber = _resolveOrderNumber(orderId);
    final res = await dio.get(
      "kiosk/orders/$orderNumber/print",
      options: Options(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 4),
        extra: const {"no_retry": true},
      ),
    );
    _throwForBadStatus(res);
    return res;
  }

  Future<Response> printReceiptByOrderNumber(String orderNumber) async {
    final normalized = orderNumber.trim();
    if (normalized.isEmpty) {
      throw Exception("Order number missing");
    }
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get(
      "kiosk/orders/$normalized/print",
      options: Options(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 4),
        extra: const {"no_retry": true},
      ),
    );
    _throwForBadStatus(res);
    return res;
  }

  // =========================================================
  // ORDER SUMMARY (CATEGORY SUMMARY)
  // =========================================================

  Future<Response> getOrderSummary({
    required String date,
    int? branchId,
    int? restaurantId,
  }) async {
    final data = {
      "date": date,
      "from_date": date,
      "to_date": date,
      "category_totals": <Map<String, dynamic>>[],
      "items_by_category": <String, dynamic>{},
      "total_items": 0,
      "total_amount": 0,
      "total_orders": 0,
    };
    return Response(
      requestOptions: RequestOptions(path: "kiosk/order-summary"),
      statusCode: 200,
      data: data,
    );
  }

  Map<String, dynamic> _normalizeBootstrap(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final source = data.isNotEmpty ? data : root;
    final restaurant = _map(source["restaurant"]);
    final branch = _map(source["branch"]);
    final terminal = _map(source["terminal"] ?? source["kiosk_settings"]);
    final settings = _map(source["settings"] ?? source["kiosk"]);
    final receiptSettings = _map(
      source["receipt_settings"] ??
          source["receipt"] ??
          source["receipt_template"],
    );
    final taxSettings = _map(source["tax_settings"] ?? source["tax"]);
    final ordering = _map(source["ordering"]);
    final orderTypeCharges = _map(source["order_type_charges"]);
    final serviceCharge = _map(source["service_charge"]);
    final currency = _map(source["currency"]);
    final sync = _map(source["sync"]);
    final paymentAtCounter = _readBool(
          settings,
          const ["payment_at_counter", "paymentAtCounter", "pay_at_counter"],
        ) ??
        _readBool(
          source,
          const ["payment_at_counter", "paymentAtCounter", "pay_at_counter"],
        );
    final defaultPaymentMethod = _firstNonEmpty([
      settings["default_payment_method"],
      settings["payment_method"],
      source["default_payment_method"],
      source["payment_method"],
      _firstPaymentSlug(settings["payment_options"] ?? settings["payments"]),
      _firstPaymentSlug(source["payment_options"] ?? source["payments"]),
      _fallbackPaymentMethod,
    ]);
    final orderTypes = _resolveBootstrapOrderTypes(
      settings: settings,
      ordering: ordering,
      orderTypeCharges: orderTypeCharges,
    );
    final homeBackgroundUrl = _firstNonEmpty([
      settings["home_background_url"],
      settings["homeBackgroundUrl"],
      settings["background_image_url"],
      settings["backgroundImageUrl"],
      source["home_background_url"],
      source["homeBackgroundUrl"],
      source["background_image_url"],
      source["backgroundImageUrl"],
      restaurant["home_background_url"],
      restaurant["homeBackgroundUrl"],
      restaurant["background_image_url"],
      restaurant["backgroundImageUrl"],
    ]);
    final homeBannerUrl = _firstNonEmpty([
      homeBackgroundUrl,
      settings["home_banner_url"],
      settings["homeBannerUrl"],
      settings["banner_url"],
      settings["bannerUrl"],
      source["home_banner_url"],
      source["homeBannerUrl"],
      source["banner_url"],
      source["bannerUrl"],
      restaurant["home_banner_url"],
      restaurant["homeBannerUrl"],
      restaurant["banner_url"],
      restaurant["bannerUrl"],
      restaurant["cover_url"],
      restaurant["coverUrl"],
    ]);
    final screensaverImages = settings["screensaver_images"] ??
        settings["screensaverImages"] ??
        settings["screen_saver_images"] ??
        settings["screenSaverImages"] ??
        source["screensaver_images"] ??
        source["screensaverImages"] ??
        source["screen_saver_images"] ??
        source["screenSaverImages"] ??
        restaurant["screensaver_images"] ??
        restaurant["screensaverImages"];

    final kioskSettings = <String, dynamic>{
      ...terminal,
      ...settings,
      ...ordering,
      "id": terminal["id"] ?? settings["id"],
      "name": terminal["name"] ?? settings["name"],
      "terminal_id": terminal["id"],
      "terminal_name": terminal["name"],
      "device_password_required": terminal["device_password_required"],
      "kiosk_display_name": settings["kiosk_display_name"] ??
          settings["kioskDisplayName"] ??
          settings["display_name"] ??
          settings["displayName"] ??
          restaurant["name"] ??
          settings["name"] ??
          terminal["name"] ??
          "Restaurant",
      "device_id": terminal["device_uuid"] ?? terminal["device_id"],
      "restaurant_id": restaurant["id"],
      "branch_id": branch["id"],
      "branch_name": branch["name"],
      "branch_timezone": branch["timezone"],
      "logo_url": restaurant["logo_url"] ??
          restaurant["logoUrl"] ??
          settings["logo_url"] ??
          settings["logoUrl"] ??
          source["logo_url"] ??
          source["logoUrl"],
      "primary_color": restaurant["primary_color"] ??
          restaurant["primaryColor"] ??
          settings["primary_color"] ??
          settings["primaryColor"] ??
          source["primary_color"] ??
          source["primaryColor"],
      "home_background_url": homeBackgroundUrl,
      "home_banner_url": homeBannerUrl,
      "screensaver_images": screensaverImages,
      "default_payment_method": defaultPaymentMethod,
      "payment_at_counter": paymentAtCounter,
      "payment_options": settings["payment_options"] ??
          settings["payments"] ??
          source["payment_options"] ??
          source["payments"],
      "ordering": ordering,
      "order_types": orderTypes,
      "available_order_types": orderTypes,
      "receipt_settings": receiptSettings,
      "receipt_footer_line": receiptSettings["footer_line"],
      "footer_line": receiptSettings["footer_line"],
      "receipt_width": receiptSettings["receipt_width"],
      "tax_settings": taxSettings,
      "prices_include_tax": _readBool(
            taxSettings,
            const ["prices_include_tax", "pricesIncludeTax"],
          ) ??
          false,
      "taxes": taxSettings["taxes"] is List ? taxSettings["taxes"] : const [],
      "order_type_charges": orderTypeCharges,
      "service_charge": serviceCharge,
      "currency": currency,
      "currency_code": currency["code"],
      "bootstrap_revision": sync["bootstrap_revision"],
      "show_tax_in_receipt": _readBool(
            settings,
            const ["show_tax_in_receipt", "show_tax", "show_gst"],
          ) ??
          _readBool(
            taxSettings,
            const ["show_tax_in_receipt", "showTaxInReceipt"],
          ) ??
          false,
    };

    return {
      ...source,
      "restaurant": restaurant,
      "branch": branch,
      "terminal": terminal,
      "kiosk": settings,
      "ordering": ordering,
      "receipt_settings": receiptSettings,
      "tax_settings": taxSettings,
      "order_type_charges": orderTypeCharges,
      "service_charge": serviceCharge,
      "currency": currency,
      "sync": sync,
      "kiosk_settings": kioskSettings,
      "restaurant_name": restaurant["name"],
    };
  }

  Future<void> _storeBootstrapPrefs(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final restaurant = _map(data["restaurant"]);
    final branch = _map(data["branch"]);
    final terminal = _map(data["terminal"]);
    final kiosk = _map(data["kiosk_settings"]);
    final receiptSettings = _map(data["receipt_settings"]);
    final taxSettings = _map(data["tax_settings"]);
    final currency = _map(data["currency"]);
    final sync = _map(data["sync"]);

    final restaurantId = restaurant["id"]?.toString();
    final restaurantName = restaurant["name"]?.toString();
    final branchId = _asInt(branch["id"]);
    final terminalUuid =
        terminal["device_uuid"]?.toString() ?? kiosk["device_id"]?.toString();
    final terminalId =
        terminal["id"]?.toString() ?? kiosk["terminal_id"]?.toString();
    final terminalName =
        terminal["name"]?.toString() ?? kiosk["terminal_name"]?.toString();
    final displayName =
        kiosk["kiosk_display_name"]?.toString() ?? restaurantName;
    final defaultPaymentMethod = kiosk["default_payment_method"]?.toString();
    final logoUrl = kiosk["logo_url"]?.toString();
    final primaryColor = kiosk["primary_color"]?.toString();
    final homeBackgroundUrl = kiosk["home_background_url"]?.toString();
    final homeBannerUrl = kiosk["home_banner_url"]?.toString();
    final branchTimezone = branch["timezone"]?.toString();
    final currencyCode =
        currency["code"]?.toString() ?? kiosk["currency_code"]?.toString();
    final bootstrapRevision = sync["bootstrap_revision"]?.toString() ??
        kiosk["bootstrap_revision"]?.toString();
    final receiptFooterLine = receiptSettings["footer_line"]?.toString() ??
        kiosk["footer_line"]?.toString();
    final receiptWidth = receiptSettings["receipt_width"]?.toString() ??
        kiosk["receipt_width"]?.toString();
    final pricesIncludeTax = _readBool(
      taxSettings,
      const ["prices_include_tax", "pricesIncludeTax"],
    );
    final printReceiptOnComplete = _readBool(
      kiosk,
      const ["print_receipt_on_complete", "printReceiptOnComplete"],
    );
    if (restaurantId != null && restaurantId.isNotEmpty) {
      await prefs.setString("restaurant_id", restaurantId);
    }
    if (restaurantName != null && restaurantName.isNotEmpty) {
      await prefs.setString("restaurant_name", restaurantName);
    }
    if (displayName != null && displayName.isNotEmpty) {
      await prefs.setString("kiosk_display_name", displayName);
    }
    if (branchId != 0) {
      await prefs.setInt("branch_id", branchId);
    }
    if (branchTimezone != null && branchTimezone.isNotEmpty) {
      await prefs.setString("branch_timezone", branchTimezone);
    }
    if (terminalUuid != null && terminalUuid.isNotEmpty) {
      await prefs.setString("device_uuid", terminalUuid);
      await prefs.setString("device_id", terminalUuid);
    }
    if (terminalId != null && terminalId.isNotEmpty) {
      await prefs.setString("terminal_id", terminalId);
      await prefs.setString("kiosk_terminal_id", terminalId);
    }
    if (terminalName != null && terminalName.isNotEmpty) {
      await prefs.setString("kiosk_name", terminalName);
    }
    if (logoUrl != null && logoUrl.isNotEmpty) {
      await prefs.setString("restaurant_logo_url", logoUrl);
    }
    if (primaryColor != null && primaryColor.isNotEmpty) {
      await prefs.setString("restaurant_primary_color", primaryColor);
    }
    if (homeBackgroundUrl != null && homeBackgroundUrl.isNotEmpty) {
      await prefs.setString("home_background_url", homeBackgroundUrl);
      await prefs.setString("home_banner_url", homeBackgroundUrl);
    } else if (homeBannerUrl != null && homeBannerUrl.isNotEmpty) {
      await prefs.setString("home_banner_url", homeBannerUrl);
    }
    if (defaultPaymentMethod != null && defaultPaymentMethod.isNotEmpty) {
      await prefs.setString("kiosk_default_payment_method",
          _normalizePaymentMethod(defaultPaymentMethod));
    }
    if (currencyCode != null && currencyCode.isNotEmpty) {
      await prefs.setString("currency_code", currencyCode);
    }
    if (bootstrapRevision != null && bootstrapRevision.isNotEmpty) {
      await prefs.setString("bootstrap_revision", bootstrapRevision);
    }
    if (receiptFooterLine != null && receiptFooterLine.isNotEmpty) {
      await prefs.setString("receipt_footer_line", receiptFooterLine);
    }
    if (receiptWidth != null && receiptWidth.isNotEmpty) {
      await prefs.setString("receipt_width", receiptWidth);
    }
    if (pricesIncludeTax != null) {
      await prefs.setBool("prices_include_tax", pricesIncludeTax);
    }
    if (printReceiptOnComplete != null) {
      await prefs.setBool(
        "print_receipt_on_complete",
        printReceiptOnComplete,
      );
    }
    await prefs.remove("payment_at_counter");
  }

  Map<String, dynamic>? _freshCachedMenuData() {
    final data = _cachedMenuData;
    final cachedAt = _cachedMenuAt;
    if (data == null || cachedAt == null) return null;
    if (DateTime.now().difference(cachedAt) > _menuCacheDuration) return null;
    return data;
  }

  Map<String, dynamic> _normalizeMenu(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final source = data.isNotEmpty ? data : root;
    final rawCategories =
        source["categories"] is List ? source["categories"] as List : const [];

    final categories = rawCategories.whereType<Map>().map((category) {
      final categoryMap = _map(category);
      final categoryImage = categoryMap["category_image"] ??
          categoryMap["category_image_url"] ??
          categoryMap["image_url"] ??
          categoryMap["image"] ??
          categoryMap["photo_url"];
      final rawItems = categoryMap["items"] is List
          ? categoryMap["items"] as List
          : const [];
      final items = rawItems.whereType<Map>().map((item) {
        final itemMap = _map(item);
        final itemImage = itemMap["item_photo_url"] ??
            itemMap["image_url"] ??
            itemMap["image"] ??
            itemMap["photo_url"];
        final rawAvailability = itemMap["is_available"] ??
            itemMap["isAvailable"] ??
            itemMap["available"] ??
            itemMap["enabled"] ??
            itemMap["status"] ??
            itemMap["item_status"] ??
            itemMap["itemStatus"];
        final isAvailable = _availabilityBool(rawAvailability);
        return {
          ...itemMap,
          "id": itemMap["id"],
          "item_id": itemMap["id"],
          "item_name": itemMap["item_name"] ?? itemMap["name"],
          "item_photo_url": itemImage ?? categoryImage,
          "item_type": itemMap["item_type"] ?? itemMap["type"],
          "price": itemMap["price"] ?? itemMap["item_price"] ?? 0,
          "is_available": isAvailable ? 1 : 0,
          "isAvailable": isAvailable ? 1 : 0,
          "available": isAvailable ? 1 : 0,
          "variations": _normalizeVariants(
            itemMap["variants"] ?? itemMap["variations"],
          ),
          "modifiers": {
            "options": _normalizeModifierOptions(itemMap["modifiers"]),
          },
        };
      }).toList();

      return {
        ...categoryMap,
        "category_name": categoryMap["category_name"] ?? categoryMap["name"],
        "category_image": categoryImage,
        "is_active": categoryMap["is_active"] ?? true,
        "items": items,
      };
    }).toList();

    return {
      ...source,
      "products": categories,
      "categories": categories,
    };
  }

  Map<String, dynamic> _normalizeCheckoutItem(Map<String, dynamic> item) {
    final modifiers = item["modifiers"] is List
        ? (item["modifiers"] as List).whereType<Map>().toList()
        : const <Map>[];
    final normalized = <String, dynamic>{
      "menu_item_id": item["menu_item_id"] ?? item["id"],
      "quantity": _asInt(item["quantity"] ?? item["qty"]),
    };
    final takeAwayCharge = _asInt(
      item["take_away_charge"] ??
          item["takeaway_charge"] ??
          item["parcel_charge"] ??
          item["parcelCharge"],
    );
    if (takeAwayCharge > 0) {
      normalized["take_away_charge"] = takeAwayCharge;
    }
    final variantId = item["variant_id"] ?? item["variation_id"];
    final variantText = variantId?.toString().trim();
    if (variantText != null &&
        variantText.isNotEmpty &&
        variantText.toLowerCase() != "null") {
      normalized["variant_id"] = variantId;
    }

    final normalizedModifiers = modifiers
        .map(
          (modifier) => {
            "modifier_option_id": modifier["modifier_option_id"] ??
                modifier["option_id"] ??
                modifier["id"],
            "quantity": _asInt(modifier["quantity"] ?? 1),
          },
        )
        .where((modifier) => modifier["modifier_option_id"] != null)
        .toList();
    if (normalizedModifiers.isNotEmpty) {
      normalized["modifiers"] = normalizedModifiers;
    }
    return normalized;
  }

  Map<String, dynamic> _normalizeCreatedOrder(dynamic raw) {
    final root = _map(raw);
    final nestedOrder = _map(root["order"]);
    final nestedData = _map(root["data"]);
    final order = nestedOrder.isNotEmpty ? nestedOrder : root;
    final source = nestedOrder.isNotEmpty
        ? nestedOrder
        : nestedData.isNotEmpty
            ? nestedData
            : order;
    final rawId = _asInt(source["id"]);
    final orderNumber = source["order_number"]?.toString() ??
        source["number"]?.toString() ??
        source["order_no"]?.toString() ??
        (rawId == 0 ? null : "ORD-$rawId");
    final id = rawId == 0 && orderNumber != null && orderNumber.isNotEmpty
        ? _syntheticOrderId--
        : rawId;
    return {
      ...root,
      "order": {
        ...source,
        "id": id,
        "order_number": orderNumber,
        "payment_status": source["payment_status"] ?? "unpaid",
      },
    };
  }

  Map<String, dynamic> _normalizeQr(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final source = data.isNotEmpty ? data : root;
    final qr = _map(source["qr"]);
    final payment = _map(source["payment"]);
    final order = _map(source["order"]);
    final payload = _firstNonEmpty([
      qr["upi_url"],
      qr["upiUrl"],
      qr["payload"],
      qr["qr_payload"],
      source["payload"],
      source["qr_payload"],
      source["qr_data"],
      source["qrData"],
      source["upi"],
      source["upi_url"],
      payment["upi_url"],
      payment["payload"],
      payment["intent_url"],
      payment["intentUrl"],
      payment["deep_link"],
      payment["deepLink"],
      payment["deeplink"],
      payment["payment_url"],
      payment["paymentUrl"],
      payment["checkout_url"],
      payment["checkoutUrl"],
      source["intent_url"],
      source["deep_link"],
      source["deeplink"],
      source["payment_url"],
      source["checkout_url"],
    ]);
    final imageUrl = _firstNonEmpty([
      qr["qr_url"],
      qr["qrUrl"],
      qr["image_url"],
      qr["imageUrl"],
      source["qr_url"],
      source["image_url"],
      source["imageUrl"],
      payment["qr_url"],
      payment["image_url"],
    ]);
    final qrValue = payload ?? imageUrl;
    final imageBase64 = qr["image_base64"] ?? source["image_base64"];
    final total = _asNum(
      source["amount"] ??
          source["total"] ??
          order["total"] ??
          payment["amount"],
    );
    return {
      ...root,
      ...source,
      "qrCode": qrValue,
      "qrData": qrValue,
      "payload": qrValue,
      "image_base64": imageBase64,
      "amount": total == null ? null : total * 100,
    };
  }

  Map<String, dynamic> _normalizePaymentStatus(dynamic raw) {
    final root = _map(raw);
    final data = _map(root["data"]);
    final source = data.isNotEmpty ? data : root;
    final order = _map(source["order"]);
    final payment = _map(source["payment"] ?? order["payment"]);
    final transaction = _map(source["transaction"] ?? payment["transaction"]);
    final paid = _readBool(source, const ["paid", "success"]) ??
        _readBool(payment, const ["paid", "success"]) ??
        _readBool(transaction, const ["paid", "success"]) ??
        false;
    final status = source["payment_status"] ??
        source["paymentStatus"] ??
        payment["payment_status"] ??
        payment["paymentStatus"] ??
        transaction["payment_status"] ??
        transaction["paymentStatus"] ??
        transaction["status"] ??
        order["payment_status"] ??
        payment["status"] ??
        source["status"] ??
        (paid ? "paid" : "pending");
    return {
      ...root,
      ...source,
      "status": status,
      "payment_status": status,
      "order": {
        ...order,
        "payment_status": status,
      },
      "payment": {
        ...payment,
        "payment_status": status,
      },
    };
  }

  Map<String, dynamic> _normalizeOrderDetails(dynamic raw, int requestedId) {
    final root = _map(raw);
    final order = _map(root["order"]).isNotEmpty ? _map(root["order"]) : root;
    final id = _asInt(order["id"]);
    final normalizedId = id == 0 ? requestedId : id;
    return {
      ...root,
      ...order,
      "id": normalizedId,
      "order": {
        ...order,
        "id": normalizedId,
      },
    };
  }

  List<Map<String, dynamic>> _normalizeVariants(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((variant) {
      final map = _map(variant);
      return {
        ...map,
        "id": map["id"],
        "variation": map["variation"] ?? map["name"] ?? map["label"],
        "name": map["name"] ?? map["variation"] ?? map["label"],
        "price": map["price"] ?? map["amount"] ?? 0,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _normalizeModifierOptions(dynamic raw) {
    final options = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final modifier in raw.whereType<Map>()) {
        final map = _map(modifier);
        final nestedOptions = map["options"];
        if (nestedOptions is List) {
          for (final option in nestedOptions.whereType<Map>()) {
            final optionMap = _map(option);
            options.add({
              ...optionMap,
              "id": optionMap["id"],
              "name": optionMap["name"] ?? optionMap["label"],
              "price": optionMap["price"] ??
                  optionMap["amount"] ??
                  optionMap["price_adjustment"] ??
                  0,
            });
          }
        } else {
          options.add({
            ...map,
            "id": map["id"],
            "name": map["name"] ?? map["label"],
            "price":
                map["price"] ?? map["amount"] ?? map["price_adjustment"] ?? 0,
          });
        }
      }
    } else if (raw is Map && raw["options"] is List) {
      for (final option in (raw["options"] as List).whereType<Map>()) {
        final optionMap = _map(option);
        options.add({
          ...optionMap,
          "id": optionMap["id"],
          "name": optionMap["name"] ?? optionMap["label"],
          "price": optionMap["price"] ??
              optionMap["amount"] ??
              optionMap["price_adjustment"] ??
              0,
        });
      }
    }
    return options;
  }

  String _resolveOrderNumber(int orderId) {
    return _orderNumbersById[orderId] ?? orderId.toString();
  }

  Future<String> _resolvePaymentMethod() async {
    final prefs = await SharedPreferences.getInstance();
    return _normalizePaymentMethod(
      prefs.getString("kiosk_default_payment_method") ?? _fallbackPaymentMethod,
    );
  }

  String? _firstPaymentSlug(dynamic value) {
    if (value is! List) return null;
    for (final item in value.whereType<Map>()) {
      final payment = _map(item);
      final slug = _firstNonEmpty([
        payment["slug"],
        payment["type"],
        payment["method"],
        payment["payment_method"],
      ]);
      if (slug != null) return slug;
    }
    return null;
  }

  List<String> _resolveBootstrapOrderTypes({
    required Map<String, dynamic> settings,
    required Map<String, dynamic> ordering,
    required Map<String, dynamic> orderTypeCharges,
  }) {
    final selected = _normalizeOrderType(
      settings["order_type"]?.toString() ?? "dine_in",
    );
    final allowChoice = _readBool(
          settings,
          const ["allow_order_type_choice", "allowOrderTypeChoice"],
        ) ??
        false;
    if (!allowChoice) return [selected];

    final mergedSettings = <String, dynamic>{
      ...settings,
      ...ordering,
    };
    final configured = settings["order_types"] ??
        settings["orderTypes"] ??
        settings["available_order_types"] ??
        settings["availableOrderTypes"] ??
        ordering["order_types"] ??
        ordering["orderTypes"] ??
        ordering["available_order_types"] ??
        ordering["availableOrderTypes"] ??
        ordering["allowed_order_types"] ??
        ordering["allowedOrderTypes"] ??
        ordering["pos_order_types"] ??
        ordering["posOrderTypes"];
    if (configured != null ||
        ordering.isNotEmpty ||
        _hasOrderTypeAvailabilityFlags(mergedSettings)) {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: mergedSettings,
      );
      final types = <String>[
        if (availability["dine_in"] == true) "dine_in",
        if (availability["pickup"] == true) "takeaway",
      ];
      if (types.isNotEmpty || configured != null || ordering.isNotEmpty) {
        return types;
      }
    }

    final fromCharges = orderTypeCharges.keys
        .map((key) => _normalizeOrderType(key.toString()))
        .where((value) => value.isNotEmpty)
        .toList();
    return fromCharges.isEmpty ? [selected] : _uniqueStrings(fromCharges);
  }

  bool _hasOrderTypeAvailabilityFlags(Map<String, dynamic> settings) {
    return const [
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
      "allow_customer_orders",
      "allowCustomerOrders",
      "customer_orders_enabled",
      "customerOrdersEnabled",
      "allow_orders",
      "allowOrders",
      "allowed_order_types",
      "allowedOrderTypes",
    ].any(settings.containsKey);
  }

  List<String> _uniqueStrings(List<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      if (seen.add(value)) result.add(value);
    }
    return result;
  }

  String _normalizePaymentMethod(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(" ", "_");
    return normalized.isEmpty ? _fallbackPaymentMethod : normalized;
  }

  String _normalizeOrderType(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(" ", "_");
    if (normalized == "pickup" || normalized == "pick_up") {
      return "takeaway";
    }
    if (normalized == "takeaway" || normalized == "take_away") {
      return "takeaway";
    }
    if (normalized == "dinein" || normalized == "dine_in") {
      return "dine_in";
    }
    return normalized.isEmpty ? "dine_in" : normalized;
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

  void _throwForBadStatus(Response response) {
    final status = response.statusCode ?? 0;
    if (status < 400) return;
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      type: DioExceptionType.badResponse,
      message: _extractErrorMessage(response.data) ?? "API request failed",
    );
  }

  static String? _extractErrorMessage(dynamic data) {
    if (data is Map) {
      final errors = data["errors"];
      if (errors is Map && errors.isNotEmpty) {
        return errors.entries
            .map((entry) => "${entry.key}: ${_compactLog(entry.value)}")
            .join("; ");
      }
      for (final key in const ["message", "error", "detail"]) {
        final value = data[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  static String _compactLog(dynamic value) {
    final text = value.toString();
    return text.length <= 1200 ? text : "${text.substring(0, 1200)}...";
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry("$key", value));
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? "") ?? 0;
  }

  num? _asNum(dynamic value) {
    if (value is num) return value;
    return num.tryParse(value?.toString() ?? "");
  }

  String? _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      if (value is Map || value is Iterable) continue;
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
        return text;
      }
    }
    return null;
  }

  bool _availabilityBool(dynamic value, {bool fallback = true}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    if (text.isEmpty) return fallback;
    if (const {
      "0",
      "false",
      "no",
      "n",
      "off",
      "inactive",
      "disabled",
      "hidden",
      "unavailable",
      "not_available",
      "not available",
      "out_of_stock",
      "out of stock",
    }.contains(text)) {
      return false;
    }
    if (const {
      "1",
      "true",
      "yes",
      "y",
      "on",
      "active",
      "enabled",
      "available",
      "in_stock",
      "in stock",
    }.contains(text)) {
      return true;
    }
    final parsed = num.tryParse(text);
    if (parsed != null) return parsed != 0;
    return fallback;
  }

  bool? _readBool(Map data, List<String> keys) {
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      final text = value?.toString().trim().toLowerCase();
      if (text == null || text.isEmpty) continue;
      if (const {"1", "true", "yes", "y", "on", "paid"}.contains(text)) {
        return true;
      }
      if (const {"0", "false", "no", "n", "off", "pending"}.contains(text)) {
        return false;
      }
    }
    return null;
  }
}
