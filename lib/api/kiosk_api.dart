import 'package:dio/dio.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dio_client.dart';
import 'web_api_config.dart';

class KioskApi {
  // =========================================================
  // RESTAURANT + KIOSK SETTINGS
  // =========================================================
  Future<Response> getRestaurantData() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosks/getRestaurantData");
    await KioskRestaurantMeta.storeFromResponse(res.data);
    return res;
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
  Future<Response> getProducts() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosks/getProducts");
    return res;
  }

  // =========================================================
  // CREATE ORDER
  // =========================================================
  Future<Response> createOrder({
    required String orderType,
    required List<Map<String, dynamic>> orderItems,
  }) async {
    final dio = await DioClient.getAuthedDio();
    return dio.post(
      "kiosks/createOrder",
      data: {"orderType": orderType, "orderItemList": orderItems},
    );
  }

  // =========================================================
  // GENERATE QR
  // =========================================================
  Future<Response> generateQr({required int orderId}) async {
    final dio = await DioClient.getAuthedDio();
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString("device_id");

    return dio.get(
      "kiosks/orders/$orderId/generateQr",
      options: Options(
        headers: {
          if (deviceId != null && deviceId.isNotEmpty) "X-DEVICE-ID": deviceId,
        },
      ),
    );
  }

  // =========================================================
  // CHECK PAYMENT
  // =========================================================
  Future<Response> checkPayment(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    return dio.get("kiosks/orders/$orderId/checkPayment");
  }

  // =========================================================
  // GET ORDER DETAILS
  // =========================================================
  Future<Response> getOrderDetails(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    return dio.get("kiosks/orders/$orderId");
  }

  // =========================================================
  // PRINTER (BACKEND + CAPACITOR)
  // =========================================================

  /// 🖨️ Get available printers (Angular + Capacitor side)
  /// Same as EpsonUSBPrinter.getPrinterList()
  Future<List<Map<String, dynamic>>> getPrinterList() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosks/printers");

    final List list = res.data["printers"] ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// 🖨️ Save selected printer for this kiosk
  /// Same as getSelectedPrinter() logic
  Future<void> saveSelectedPrinter(String productId) async {
    final dio = await DioClient.getAuthedDio();
    await dio.post("kiosks/printers/select", data: {"product_id": productId});
  }

  /// 🖨️ Get already selected printer (optional)
  Future<Map<String, dynamic>?> getSelectedPrinter() async {
    final dio = await DioClient.getAuthedDio();
    final res = await dio.get("kiosks/printers/selected");
    return res.data["printer"];
  }

  // =========================================================
  // DEVICE MONITORING
  // =========================================================

  /// Ping device (used for printer/device status)
  /// GET kiosks/ping/{deviceId}/default
  Future<Response> pingDevice() async {
    final dio = await DioClient.getAuthedDio();
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString("device_id") ?? "default_device";

    return dio.get("kiosks/ping/$deviceId/default");
  }

  // =========================================================
  // PRINT RECEIPT (BACKEND HANDLES PRINTER)
  // =========================================================

  /// 🔥 Print receipt
  /// Angular + Capacitor + Epson handles actual printing
  Future<Response> printReceipt(int orderId) async {
    final dio = await DioClient.getAuthedDio();
    return dio.get("kiosks/orders/printReceipt/$orderId");
  }

  // =========================================================
  // ORDER SUMMARY (CATEGORY SUMMARY)
  // =========================================================

  Future<Response> getOrderSummary({
    required String date,
    int? branchId,
    int? restaurantId,
  }) async {
    final dio = await DioClient.getAuthedDio();
    final params = <String, dynamic>{
      "date": date,
      "from_date": date,
      "to_date": date,
      if (branchId != null) "branch_id": branchId,
      if (restaurantId != null) "restaurant_id": restaurantId,
    };

    try {
      return await dio.post("kiosk/order-summary", data: params);
    } catch (_) {
      return dio.get("kiosk/order-summary", queryParameters: params);
    }
  }
}
