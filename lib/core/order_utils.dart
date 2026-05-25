import 'package:flutter/material.dart';
import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
// Adding Sunmi Imports
import 'package:sunmi_printer_plus/enums.dart';
import 'package:sunmi_printer_plus/sunmi_printer_plus.dart';
import 'package:sunmi_printer_plus/sunmi_style.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';

class OrderUtils {
  static final ValueNotifier<int> infoRevision = ValueNotifier<int>(0);
  static const Duration _indiaOffset = Duration(hours: 5, minutes: 30);

  static void notifyInfoUpdated() {
    infoRevision.value++;
  }

  // ===============================
  // 1. Internal helper to fetch raw orders
  // ===============================
  static Future<List> _getOrders({
    String dateRange = "today",
    String status = "",
    DateTimeRange? range,
  }) async {
    try {
      final dio = await DioClient.getAdminDio();

      final body = <String, dynamic>{
        "dateRange": dateRange,
        "status": status,
      };
      if (range != null) {
        final start = _dateOnly(range.start);
        final end = _dateOnly(range.end);
        body["from_date"] = DateFormat('yyyy-MM-dd').format(start);
        body["to_date"] = DateFormat('yyyy-MM-dd').format(end);
      }

      final res = await dio.post("admin/orders", data: body);

      return res.data["orders"] ?? res.data["data"]?["orders"] ?? [];
    } catch (e) {
      return [];
    }
  }

  // ===============================
  // 2. Pending Orders Count
  // ===============================
  static Future<int> getPendingOrderCount() async {
    final orders = await _getOrders(dateRange: "today", status: "");
    return orders.where((o) {
      final s = o["status"].toString().toLowerCase();
      return s != "completed" && s != "cancelled" && s != "delivered";
    }).length;
  }

  // ===============================
  // 3. Revenue Stats
  // ===============================
  static Future<Map<String, dynamic>> getRevenueStats(
    String filter, {
    DateTimeRange? dateRange,
  }) async {
    final normalized = _normalizeDateRange(filter, range: dateRange);
    final orders = await _getOrders(
      dateRange: normalized,
      status: "",
      range: dateRange,
    );
    final now = _restaurantNow();
    double total = 0;
    int count = 0;

    for (final o in orders) {
      final localDate = _parseOrderDate(o);
      if (localDate != null &&
          _checkMatch(localDate, filter, now, dateRange) &&
          _isPaidStatus(o["status"])) {
        total += double.tryParse(o["total"].toString()) ?? 0;
        count++;
      }
    }

    // Updated keys to match DashboardTab requirements
    return {
      "revenue": total,
      "total_revenue": total,
      "orders": count,
      "total_orders": count,
      "paid_orders": count,
    };
  }

  static bool _isPaidStatus(dynamic status) {
    final s = status?.toString().toLowerCase() ?? "";
    if (s.isEmpty) return false;
    if (s.contains("cancel") ||
        s.contains("refund") ||
        s.contains("failed") ||
        s.contains("void")) {
      return false;
    }
    return s.contains("paid") ||
        s.contains("completed") ||
        s.contains("success") ||
        s.contains("successful") ||
        s.contains("delivered");
  }

  // ===============================
  // 4. Orders for Dashboard List
  // ===============================
  static Future<List<Map<String, dynamic>>> getRecentOrders(
    String filter, {
    DateTimeRange? dateRange,
    String? searchQuery,
  }) async {
    final normalized = _normalizeDateRange(filter, range: dateRange);
    final orders = await _getOrders(
      dateRange: normalized,
      status: "",
      range: dateRange,
    );
    final now = _restaurantNow();
    List<Map<String, dynamic>> history = [];

    for (final o in orders) {
      final localDate = _parseOrderDate(o);
      if (localDate == null ||
          !_checkMatch(localDate, filter, now, dateRange)) {
        continue;
      }

      String txn = _getTxnId(o);
      final rawPk = o["id"] ?? o["order_id"] ?? o["orderId"];
      final orderNumber =
          (o["order_number"] ?? o["order_no"] ?? rawPk ?? "N/A").toString();

      if (searchQuery != null && searchQuery.isNotEmpty) {
        final q = searchQuery.toLowerCase();
        if (!orderNumber.toLowerCase().contains(q) &&
            !txn.toLowerCase().contains(q)) {
          continue;
        }
      }

      history.add({
        "order_id": orderNumber,
        "order_pk": rawPk,
        "transaction_id": txn,
        "total": (o["total"] ?? 0).toString(),
        "items_count": (o["order_items"] as List?)?.length ?? 0,
        "time": DateFormat('hh:mm a').format(localDate),
        "status": o["status"] ?? "pending",
        "image_url": _getFirstItemImage(o),
        "items_label": _getItemsLabel(o),
      });
    }

    history.sort(
      (a, b) => b["order_id"].toString().compareTo(a["order_id"].toString()),
    );

    return history;
  }

  // ===============================
  // 5. Restaurant Info
  // ===============================
  static Future<Map<String, dynamic>> getRestaurantInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dio = await DioClient.getAuthedDio();
      final res = await dio.get("kiosks/getRestaurantData");

      final restaurant = res.data["restaurant"];
      final kiosk = res.data["kiosk_settings"];
      final branch = res.data["branch"];
      final savedKioskName = prefs.getString("kiosk_name");
      final savedDisplayName = prefs.getString(
        KioskRestaurantMeta.kioskDisplayNameKey,
      );
      await KioskRestaurantMeta.storeFromResponse(res.data);
      final bundle = KioskRestaurantMeta.extractBundle(res.data);
      String? taxId;
      if (restaurant is Map) {
        taxId = restaurant["gst_number"] ??
            restaurant["gstin"] ??
            restaurant["tax_id"] ??
            restaurant["taxId"] ??
            restaurant["gst_no"] ??
            restaurant["gst"];
      }

      return {
        "restaurant_name": KioskRestaurantMeta.resolveRestaurantName(
          root: bundle.root,
          data: bundle.data,
          restaurant: bundle.restaurant,
          kioskSettings: bundle.kioskSettings,
          fallback: savedDisplayName ?? "Restaurant",
        ),
        "address": res.data["restaurant"]?["address"],
        "tax_id": taxId,
        "show_tax_in_receipt": KioskRestaurantMeta.resolveShowTaxInReceipt(
              root: bundle.root,
              data: bundle.data,
              restaurant: bundle.restaurant,
              kioskSettings: bundle.kioskSettings,
            ) ??
            prefs.getBool(KioskRestaurantMeta.showTaxInReceiptKey) ??
            false,
        "timezone": restaurant?["timezone"] ?? "Asia/Kolkata",
        "restaurant_timezone": restaurant?["timezone"] ?? "Asia/Kolkata",
        "printer_id": kiosk?["printer_id"],
        "kiosk_id": kiosk?["id"] ?? kiosk?["kiosk_id"],
        "kiosk_name":
            (savedKioskName != null && savedKioskName.trim().isNotEmpty)
                ? savedKioskName
                : (kiosk?["name"] ??
                    kiosk?["kiosk_name"] ??
                    kiosk?["device_name"] ??
                    "SELFX Kiosk"),
        "device_id": kiosk?["device_id"] ?? kiosk?["device_uuid"],
        "branch_id": kiosk?["branch_id"] ?? branch?["id"],
        "branch_name": kiosk?["branch_name"] ?? branch?["name"],
      };
    } catch (e) {
      return {};
    }
  }

  // ===============================
  // 5A. Orders for a Specific Date
  // ===============================
  static Future<List<Map<String, dynamic>>> getOrdersForDate(
    DateTime date,
  ) async {
    final target = DateTime(date.year, date.month, date.day);
    final dateRange = _dateRangeForDate(target);
    final DateTimeRange? range = dateRange == "custom"
        ? DateTimeRange(start: target, end: target)
        : null;
    final orders = await getOrdersWithItems(
      dateRange: dateRange,
      status: "",
      range: range,
    );
    final results = <Map<String, dynamic>>[];
    for (final o in orders) {
      final dt = _parseOrderDate(o);
      if (dt == null) continue;
      final local = DateTime(dt.year, dt.month, dt.day);
      if (_isSameDay(local, target)) {
        results.add(o);
      }
    }
    return results;
  }

  // ===============================
  // 5B. Orders with Items (Single Call)
  // ===============================
  static Future<List<Map<String, dynamic>>> getOrdersWithItems({
    String dateRange = "today",
    String status = "",
    DateTimeRange? range,
  }) async {
    try {
      final normalized = _normalizeDateRange(dateRange, range: range);
      final res = await _getOrders(
        dateRange: normalized,
        status: status,
        range: range,
      );
      return res
          .whereType<Map>()
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ===============================
  // 6. 🖨 BACKEND DAILY REPORT (Original)
  // ===============================
  static Future<void> printDailyReport({
    required String fromDate,
    required String toDate,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dio = await DioClient.getAdminDio();

      await dio.post(
        "admin/kioskLog/daily-report",
        data: {
          "restaurant_id": prefs.getString("restaurant_id"),
          "branch_id": prefs.getInt("branch_id"),
          "from_date": fromDate,
          "to_date": toDate,
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  // ===============================
  // 7. 🚀 SUNMI HARDWARE LOCAL PRINT (New)
  // ===============================
  static Future<void> printLocalSummaryReport({
    required String title,
    required Map<String, dynamic> stats,
    required List<Map<String, dynamic>> orders,
  }) async {
    try {
      bool? isBind = await SunmiPrinter.bindingPrinter();
      if (isBind != true) return;

      await SunmiPrinter.initPrinter();
      await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);

      // Report Header
      await SunmiPrinter.printText(
        title.toUpperCase(),
        style: SunmiStyle(bold: true, fontSize: SunmiFontSize.XL),
      );
      await SunmiPrinter.printText(
        "Date: ${DateFormat('dd-MM-yyyy').format(DateTime.now())}",
      );
      await SunmiPrinter.line();

      // Summary Stats
      await SunmiPrinter.setAlignment(SunmiPrintAlign.LEFT);
      await SunmiPrinter.printText(
        "TOTAL SALES:  ₹${stats['revenue'] ?? stats['total_revenue'] ?? '0'}",
        style: SunmiStyle(bold: true, fontSize: SunmiFontSize.LG),
      );
      await SunmiPrinter.printText(
        "TOTAL ORDERS: ${stats['orders'] ?? stats['total_orders'] ?? '0'}",
      );
      await SunmiPrinter.line();

      // Transaction List (Last 15 for brevity)
      await SunmiPrinter.printText(
        "LAST 15 TRANSACTIONS:",
        style: SunmiStyle(bold: true),
      );
      for (var o in orders.take(15)) {
        await SunmiPrinter.printText(
          "#${o['order_id']} | ₹${o['total']} | ${o['status']}",
        );
      }

      // Feed & Cut
      await SunmiPrinter.lineWrap(3);
    } catch (e) {}
  }

  // ===============================
  // 8. Date Filter Helper
  // ===============================
  static bool _checkMatch(
    DateTime date,
    String filter,
    DateTime now,
    DateTimeRange? range,
  ) {
    if (filter == "today") return _isSameDay(date, now);

    if (filter == "yesterday") {
      final y = now.subtract(const Duration(days: 1));
      return date.year == y.year && date.month == y.month && date.day == y.day;
    }

    if (filter == "month" || filter == "currentMonth") {
      return date.year == now.year && date.month == now.month;
    }

    if (filter == "lastMonth") {
      final prev = DateTime(now.year, now.month - 1, 1);
      return date.year == prev.year && date.month == prev.month;
    }

    if (filter == "thisWeek") {
      final start = _startOfWeek(now);
      final end = start.add(const Duration(days: 6));
      return !date.isBefore(start) && !date.isAfter(end);
    }

    if (filter == "lastWeek") {
      final start = _startOfWeek(now).subtract(const Duration(days: 7));
      final end = start.add(const Duration(days: 6));
      return !date.isBefore(start) && !date.isAfter(end);
    }

    if (filter == "last7Days") {
      final start = now.subtract(const Duration(days: 6));
      return !date.isBefore(_dateOnly(start)) && !date.isAfter(_dateOnly(now));
    }

    if (filter == "custom" && range != null) {
      return date.isAfter(range.start.subtract(const Duration(seconds: 1))) &&
          date.isBefore(range.end.add(const Duration(days: 1)));
    }

    return false;
  }

  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _startOfWeek(DateTime d) {
    final local = _dateOnly(d);
    final weekday = local.weekday; // Mon=1..Sun=7
    return local.subtract(Duration(days: weekday - 1));
  }

  static String _normalizeDateRange(
    String filter, {
    DateTimeRange? range,
  }) {
    switch (filter) {
      case "today":
        return "today";
      case "yesterday":
        return "yesterday";
      case "thisWeek":
        return "thisWeek";
      case "lastWeek":
        return "lastWeek";
      case "last7Days":
        return "last7Days";
      case "currentMonth":
      case "month":
        return "currentMonth";
      case "lastMonth":
        return "lastMonth";
      case "custom":
        if (range != null) {
          final start = _dateOnly(range.start);
          final end = _dateOnly(range.end);
          final now = _dateOnly(_restaurantNow());
          if (_isSameDay(start, now) && _isSameDay(end, now)) {
            return "today";
          }
          final y =
              _dateOnly(_restaurantNow().subtract(const Duration(days: 1)));
          if (_isSameDay(start, y) && _isSameDay(end, y)) {
            return "yesterday";
          }
          final startThisWeek = _startOfWeek(now);
          final endThisWeek = startThisWeek.add(const Duration(days: 6));
          if (!start.isBefore(startThisWeek) && !end.isAfter(endThisWeek)) {
            return "thisWeek";
          }
          final startLastWeek = startThisWeek.subtract(const Duration(days: 7));
          final endLastWeek = startLastWeek.add(const Duration(days: 6));
          if (!start.isBefore(startLastWeek) && !end.isAfter(endLastWeek)) {
            return "lastWeek";
          }
          final last7Start = _dateOnly(
            _restaurantNow().subtract(const Duration(days: 6)),
          );
          if (!start.isBefore(last7Start) && !end.isAfter(now)) {
            return "last7Days";
          }
          final currentMonthStart = DateTime(now.year, now.month, 1);
          if (!start.isBefore(currentMonthStart) && !end.isAfter(now)) {
            return "currentMonth";
          }
          final prev = DateTime(now.year, now.month - 1, 1);
          final prevEnd = DateTime(now.year, now.month, 0);
          if (!start.isBefore(prev) && !end.isAfter(prevEnd)) {
            return "lastMonth";
          }
        }
        return "custom";
      default:
        return "today";
    }
  }

  static String _dateRangeForDate(DateTime target) {
    final now = _dateOnly(_restaurantNow());
    if (_isSameDay(target, now)) return "today";
    final y = _dateOnly(_restaurantNow().subtract(const Duration(days: 1)));
    if (_isSameDay(target, y)) return "yesterday";

    final startThisWeek = _startOfWeek(now);
    final endThisWeek = startThisWeek.add(const Duration(days: 6));
    if (!target.isBefore(startThisWeek) && !target.isAfter(endThisWeek)) {
      return "thisWeek";
    }

    final startLastWeek = startThisWeek.subtract(const Duration(days: 7));
    final endLastWeek = startLastWeek.add(const Duration(days: 6));
    if (!target.isBefore(startLastWeek) && !target.isAfter(endLastWeek)) {
      return "lastWeek";
    }

    final last7Start = _dateOnly(
      _restaurantNow().subtract(const Duration(days: 6)),
    );
    if (!target.isBefore(last7Start) && !target.isAfter(now)) {
      return "last7Days";
    }

    if (target.year == now.year && target.month == now.month) {
      return "currentMonth";
    }

    final prevStart = DateTime(now.year, now.month - 1, 1);
    final prevEnd = DateTime(now.year, now.month, 0);
    if (!target.isBefore(prevStart) && !target.isAfter(prevEnd)) {
      return "lastMonth";
    }

    return "custom";
  }

  static DateTime? _parseOrderDate(dynamic order) {
    if (order is Map) {
      final formatted = order["date_time_formatted"] ??
          order["dateTimeFormatted"] ??
          order["formatted_date_time"] ??
          order["formattedDateTime"];
      final formattedDate = _parseRestaurantFormattedDate(formatted);
      if (formattedDate != null) return formattedDate;

      final raw = order["date_time"] ??
          order["dateTime"] ??
          order["created_at"] ??
          order["createdAt"] ??
          order["created_at_utc"] ??
          order["order_date"] ??
          order["date"];
      return _parseDateValue(raw);
    }
    return _parseDateValue(order);
  }

  static DateTime _restaurantNow() =>
      _toRestaurantWallTime(DateTime.now().toUtc());

  static DateTime _toRestaurantWallTime(DateTime value) {
    final utc = value.isUtc ? value : value.toUtc();
    final shifted = utc.add(_indiaOffset);
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  static bool _hasExplicitTimezone(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith("Z") ||
        RegExp(r"[+-]\d{2}:?\d{2}$").hasMatch(trimmed);
  }

  static DateTime? _parseRestaurantFormattedDate(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final cleaned = raw
        .replaceAll(RegExp(r"\s+"), " ")
        .replaceAll(RegExp(r"\s*-\s*"), " ")
        .trim();
    for (final pattern in const [
      "d MMM y h:mm a",
      "d MMM y hh:mm a",
      "dd MMM y h:mm a",
      "dd MMM y hh:mm a",
      "d MMMM y h:mm a",
      "d MMMM y hh:mm a",
      "dd MMMM y h:mm a",
      "dd MMMM y hh:mm a",
      "d MMM y HH:mm",
      "dd MMM y HH:mm",
    ]) {
      try {
        return DateFormat(pattern).parseStrict(cleaned);
      } catch (_) {}
    }
    return null;
  }

  static DateTime? _parseDateValue(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return _toRestaurantWallTime(value);
    if (value is int) {
      if (value > 1000000000000) {
        return _toRestaurantWallTime(
          DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
        );
      }
      return _toRestaurantWallTime(
        DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true),
      );
    }
    if (value is double) {
      final v = value.toInt();
      if (v > 1000000000000) {
        return _toRestaurantWallTime(
          DateTime.fromMillisecondsSinceEpoch(v, isUtc: true),
        );
      }
      return _toRestaurantWallTime(
        DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true),
      );
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      final formatted = _parseRestaurantFormattedDate(trimmed);
      if (formatted != null) return formatted;

      final direct = DateTime.tryParse(trimmed);
      if (direct != null) {
        if (_hasExplicitTimezone(trimmed)) {
          return _toRestaurantWallTime(direct);
        }
        return _toRestaurantWallTime(DateTime.utc(
          direct.year,
          direct.month,
          direct.day,
          direct.hour,
          direct.minute,
          direct.second,
          direct.millisecond,
          direct.microsecond,
        ));
      }

      try {
        return _toRestaurantWallTime(
          DateFormat('yyyy-MM-dd HH:mm:ss').parse(trimmed, true),
        );
      } catch (_) {}
      try {
        return _toRestaurantWallTime(
          DateFormat('yyyy-MM-dd HH:mm:ss.SSS').parse(trimmed, true),
        );
      } catch (_) {}
      try {
        return _toRestaurantWallTime(
          DateFormat('yyyy-MM-dd').parse(trimmed, true),
        );
      } catch (_) {}

      if (trimmed.contains(' ') && !trimmed.contains('T')) {
        final normalized = trimmed.replaceFirst(' ', 'T');
        final parsed = DateTime.tryParse(normalized);
        if (parsed != null) return _toRestaurantWallTime(parsed);
      }
    }
    return null;
  }

  static String _getTxnId(dynamic o) {
    final id = _findTxnId(o);
    if (id == null) return "N/A";
    final s = id.toString().trim();
    return s.isEmpty ? "N/A" : s;
  }

  static dynamic _findTxnId(dynamic value) {
    const keys = [
      "transaction_id",
      "payment_id",
      "txn_id",
      "transactionId",
      "paymentId",
      "razorpay_payment_id",
      "payment_reference",
      "payment_txn_id",
      "txnid",
      "txnId",
    ];

    if (value is Map) {
      for (final k in keys) {
        if (value.containsKey(k) && value[k] != null) {
          final v = value[k];
          if (v.toString().trim().isNotEmpty) return v;
        }
      }
      for (final entry in value.entries) {
        final found = _findTxnId(entry.value);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findTxnId(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String? _getFirstItemImage(dynamic o) {
    if (o is! Map) return null;
    final items = o["order_items"] ?? o["items"] ?? o["orderItems"];
    if (items is List && items.isNotEmpty) {
      final first = items.first;
      final url = _findImageUrl(first);
      if (url != null) return url;
    }
    return _findImageUrl(o);
  }

  static String? _getItemsLabel(dynamic o, {int maxItems = 2}) {
    if (o is! Map) return null;
    final items = o["order_items"] ?? o["items"] ?? o["orderItems"];
    if (items is! List || items.isEmpty) return null;
    final names = <String>[];
    for (final item in items) {
      final name = _extractItemName(item);
      if (name != null && name.trim().isNotEmpty) {
        names.add(name.trim());
      }
    }
    if (names.isEmpty) return null;
    final display = names.take(maxItems).toList();
    if (names.length > maxItems) {
      display.add("+${names.length - maxItems} more");
    }
    return display.join(", ");
  }

  static String? _extractItemName(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map) {
      const keys = [
        "name",
        "item_name",
        "itemName",
        "title",
        "product_name",
        "menu_item_name",
      ];
      for (final k in keys) {
        if (value.containsKey(k) && value[k] != null) {
          final v = value[k].toString().trim();
          if (v.isNotEmpty) return v;
        }
      }
      final nested = value["menu_item"] ??
          value["item"] ??
          value["menuItem"] ??
          value["product"];
      if (nested != null) {
        final nestedName = _extractItemName(nested);
        if (nestedName != null && nestedName.trim().isNotEmpty) {
          return nestedName.trim();
        }
      }
      for (final entry in value.entries) {
        final found = _extractItemName(entry.value);
        if (found != null && found.trim().isNotEmpty) return found.trim();
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _extractItemName(item);
        if (found != null && found.trim().isNotEmpty) return found.trim();
      }
    }
    return null;
  }

  static String? _findImageUrl(dynamic value) {
    const keys = [
      "item_photo_url",
      "image_url",
      "image",
      "photo_url",
      "item_image",
      "itemImage",
      "thumbnail",
      "thumb",
      "img",
    ];

    if (value is Map) {
      for (final k in keys) {
        if (value.containsKey(k) && value[k] != null) {
          final v = value[k].toString().trim();
          if (v.isNotEmpty) return _normalizeImageUrl(v);
        }
      }
      if (value.containsKey("item")) {
        final nested = _findImageUrl(value["item"]);
        if (nested != null) return nested;
      }
      for (final entry in value.entries) {
        final found = _findImageUrl(entry.value);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findImageUrl(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String _normalizeImageUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
      return trimmed;
    }
    if (trimmed.startsWith("//")) {
      return "https:$trimmed";
    }
    var base = DioClient.baseUrl;
    if (base.contains("/api/")) {
      base = base.replaceFirst("/api/", "/");
    }
    if (trimmed.startsWith("/")) {
      return base.endsWith("/")
          ? "${base.substring(0, base.length - 1)}$trimmed"
          : "$base$trimmed";
    }
    return base.endsWith("/") ? "$base$trimmed" : "$base/$trimmed";
  }
}
