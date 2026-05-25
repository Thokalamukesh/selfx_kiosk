import 'dart:async';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/printer/printer_s.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  static const Duration _indiaOffset = Duration(hours: 5, minutes: 30);

  // Logic variables (Untouched)
  bool loading = true;
  Map<String, dynamic> stats = {};
  Map<String, dynamic> info = {};
  List<Map<String, dynamic>> orders = [];
  List<Map<String, dynamic>> _allOrders = [];
  int totalOrdersCount = 0;
  int paidOrdersCount = 0;
  int unpaidOrdersCount = 0;
  String? _lastFilterKey;
  String filter = "today";
  DateTimeRange? customRange;
  Timer? timer;
  final TextEditingController _searchController = TextEditingController();
  String _currentSearch = "";
  bool _isBulkPrinting = false;
  bool _loadingInFlight = false;
  bool _pendingInfoRefresh = false;
  final PrinterService _printerService = PrinterService();
  late final VoidCallback _infoListener;

  int _getOrderPk(Map<String, dynamic> order) {
    final raw = order["order_pk"] ?? order["order_id"] ?? order["id"] ?? "";
    return int.tryParse(raw.toString()) ?? 0;
  }

  String _getOrderNumber(Map<String, dynamic> order) {
    final raw = order["order_id"] ??
        order["order_number"] ??
        order["order_pk"] ??
        "N/A";
    return raw.toString();
  }

  @override
  void initState() {
    super.initState();
    _infoListener = () {
      if (_loadingInFlight) {
        _pendingInfoRefresh = true;
        return;
      }
      _load(force: true);
    };
    OrderUtils.infoRevision.addListener(_infoListener);
    _load();
  }

  // logic (Untouched)
  Future<void> _load({bool force = false}) async {
    if (_loadingInFlight) return;
    _loadingInFlight = true;
    try {
      final filterKey =
          "$filter|${customRange?.start.toIso8601String() ?? ''}|${customRange?.end.toIso8601String() ?? ''}";
      if (!force && _lastFilterKey == filterKey && _allOrders.isNotEmpty) {
        _applySearchFilter();
        _loadingInFlight = false;
        return;
      }
      final results = await Future.wait([
        OrderUtils.getRevenueStats(filter, dateRange: customRange),
        OrderUtils.getRestaurantInfo(),
        OrderUtils.getRecentOrders(filter, dateRange: customRange),
      ]);
      if (!mounted) return;
      setState(() {
        stats = results[0] as Map<String, dynamic>;
        info = results[1] as Map<String, dynamic>;
        final all = results[2] as List<Map<String, dynamic>>;
        _allOrders = all;
        totalOrdersCount = all.length;
        paidOrdersCount = all.where(_isPaidOrder).length;
        unpaidOrdersCount = totalOrdersCount - paidOrdersCount;
        orders = all.take(10).toList();
        loading = false;
      });
      _lastFilterKey = filterKey;
      _applySearchFilter();
    } catch (_) {
      if (mounted) setState(() => loading = false);
    } finally {
      _loadingInFlight = false;
      if (_pendingInfoRefresh) {
        _pendingInfoRefresh = false;
        _load(force: true);
      }
    }
  }

  @override
  void dispose() {
    OrderUtils.infoRevision.removeListener(_infoListener);
    _searchController.dispose();
    super.dispose();
  }

  bool _isPaidStatus(String status) {
    final s = status.toLowerCase();
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

  String _extractOrderStatus(Map<String, dynamic> order) {
    return (order["status"] ??
            order["order_status"] ??
            order["payment_status"] ??
            order["paymentStatus"] ??
            "")
        .toString();
  }

  bool _isPaidOrder(Map<String, dynamic> order) {
    return _isPaidStatus(_extractOrderStatus(order));
  }

  num _extractOrderTotal(Map<String, dynamic> order) {
    final direct = order["total"] ??
        order["grand_total"] ??
        order["amount"] ??
        order["total_amount"] ??
        order["totalPrice"];
    final parsed = _asNum(direct);
    if (parsed != null) return parsed;
    final parsedOrder = _parseOrderDetails(order);
    num fallback = 0;
    for (final item in parsedOrder.items) {
      final qty = (item["qty"] as num?) ?? 0;
      final price = (item["price"] as num?) ?? 0;
      fallback += qty * price;
    }
    return fallback;
  }

  num _extractItemsTotal(Map<String, dynamic> order) {
    final parsed = _parseOrderDetails(order);
    if (parsed.items.isEmpty) {
      return _extractOrderTotal(order);
    }
    num total = 0;
    for (final item in parsed.items) {
      final qty = (item["qty"] as num?) ?? 0;
      final price = (item["price"] as num?) ?? 0;
      total += qty * price;
    }
    return total;
  }

  num _sumItemsTotal(List<Map<String, dynamic>> items) {
    num total = 0;
    for (final item in items) {
      final qty = (item["qty"] as num?) ?? 0;
      final price = (item["price"] as num?) ?? 0;
      total += qty * price;
    }
    return total;
  }

  Future<List<Map<String, dynamic>>> _loadOrderItems(
    Map<String, dynamic> order,
  ) async {
    var parsed = _parseOrderDetails(order);
    if (parsed.items.isNotEmpty) return parsed.items;

    final orderId = _getOrderPk(order);
    if (orderId <= 0) return const [];

    dynamic res;
    try {
      res = await AdminApi().getOrder(orderId.toString());
    } catch (_) {
      try {
        res = await KioskApi().getOrderDetails(orderId);
      } catch (_) {
        return const [];
      }
    }

    parsed = _parseOrderDetails(res.data);
    if (parsed.items.isNotEmpty) {
      order["order_items"] = parsed.items;
    }
    return parsed.items;
  }

  String _filterLabel(String value) {
    switch (value) {
      case "today":
        return "Today";
      case "yesterday":
        return "Yesterday";
      case "thisWeek":
        return "This Week";
      case "lastWeek":
        return "Last Week";
      case "last7Days":
        return "Last 7 Days";
      case "month":
      case "currentMonth":
        return "This Month";
      case "lastMonth":
        return "Last Month";
      case "custom":
        return "Custom Range";
      default:
        return value.toUpperCase();
    }
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _startOfWeek(DateTime d) {
    final local = _dateOnly(d);
    final weekday = local.weekday; // Mon=1..Sun=7
    return local.subtract(Duration(days: weekday - 1));
  }

  DateTimeRange _resolveFilterRange() {
    final now = DateTime.now();
    DateTime start;
    DateTime end;
    switch (filter) {
      case "today":
        start = _dateOnly(now);
        end = start;
        break;
      case "yesterday":
        final y = _dateOnly(now.subtract(const Duration(days: 1)));
        start = y;
        end = y;
        break;
      case "thisWeek":
        start = _startOfWeek(now);
        end = start.add(const Duration(days: 6));
        break;
      case "lastWeek":
        start = _startOfWeek(now).subtract(const Duration(days: 7));
        end = start.add(const Duration(days: 6));
        break;
      case "last7Days":
        start = _dateOnly(now.subtract(const Duration(days: 6)));
        end = _dateOnly(now);
        break;
      case "currentMonth":
      case "month":
        start = DateTime(now.year, now.month, 1);
        end = _dateOnly(now);
        break;
      case "lastMonth":
        start = DateTime(now.year, now.month - 1, 1);
        end = DateTime(now.year, now.month, 0);
        break;
      case "custom":
        start = _dateOnly(customRange?.start ?? now);
        end = _dateOnly(customRange?.end ?? now);
        break;
      default:
        start = _dateOnly(now);
        end = start;
    }
    return DateTimeRange(start: start, end: end);
  }

  String _currentDateRangeKey() {
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
      case "lastMonth":
        return "lastMonth";
      case "currentMonth":
      case "month":
        return "currentMonth";
      case "custom":
        return "custom";
      default:
        return "today";
    }
  }

  String _formatDateKey(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  Future<String> _resolveRestaurantName() async {
    final direct = info["restaurant_name"]?.toString().trim() ??
        info["name"]?.toString().trim() ??
        "";
    if (direct.isNotEmpty) return direct;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString("restaurant_name")?.trim() ?? "";
      if (stored.isNotEmpty) return stored;
    } catch (_) {}
    return "Restaurant";
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  num? _asNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    return num.tryParse(value.toString());
  }

  String _firstNonEmpty(List<dynamic> values, {String fallback = ""}) {
    for (final v in values) {
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return fallback;
  }

  String? _findRestaurantName(dynamic data) {
    if (data is Map) {
      final direct = _firstNonEmpty([
        data["restaurant_name"],
        data["restaurantName"],
      ]);
      if (direct.isNotEmpty) return direct;

      final restaurant = data["restaurant"];
      if (restaurant is Map) {
        final nested = _firstNonEmpty([
          restaurant["name"],
          restaurant["restaurant_name"],
          restaurant["restaurantName"],
        ]);
        if (nested.isNotEmpty) return nested;
      }

      for (final key in const ["data", "result", "summary"]) {
        final nested = data[key];
        final found = _findRestaurantName(nested);
        if (found != null && found.isNotEmpty) return found;
      }
    }
    return null;
  }

  Map? _findMap(dynamic value, List<String> keys) {
    if (value is Map) {
      for (final key in keys) {
        final v = value[key];
        if (v is Map) return v;
      }
      for (final key in const ["data", "result", "summary"]) {
        final nested = value[key];
        final found = _findMap(nested, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  List? _findList(dynamic value, List<String> keys) {
    if (value is Map) {
      for (final key in keys) {
        final v = value[key];
        if (v is List) return v;
      }
      for (final key in const ["data", "result", "summary"]) {
        final nested = value[key];
        final found = _findList(nested, keys);
        if (found != null) return found;
      }
    }
    if (value is List) return value;
    return null;
  }

  List<Map<String, dynamic>> _normalizeItems(
    List items, {
    String? categoryOverride,
  }) {
    final List<Map<String, dynamic>> results = [];
    for (final raw in items) {
      if (raw is! Map) continue;
      final nested = raw["item"] is Map ? raw["item"] as Map : const {};
      final name = _firstNonEmpty([
        raw["name"],
        raw["item_name"],
        raw["title"],
        nested["name"],
      ], fallback: "Item");
      final category = categoryOverride ??
          _firstNonEmpty([
            raw["category"],
            raw["category_name"],
            raw["categoryTitle"],
            nested["category"],
            nested["category_name"],
          ], fallback: "Uncategorized");
      final qtyRaw = raw["qty"] ??
          raw["quantity"] ??
          raw["pivot"]?["quantity"] ??
          raw["count"] ??
          1;
      final priceRaw = raw["price"] ??
          raw["unit_price"] ??
          raw["unitPrice"] ??
          raw["pivot"]?["price"] ??
          nested["price"] ??
          raw["item_price"] ??
          0;
      final totalRaw = raw["total"] ??
          raw["amount"] ??
          raw["total_amount"] ??
          raw["total_price"] ??
          raw["totalAmount"] ??
          raw["price_total"];

      final int qty = (_asNum(qtyRaw) ?? 1).toInt();
      num price = _asNum(priceRaw) ?? 0;
      num total = _asNum(totalRaw) ?? 0;

      if (total == 0 && price != 0) {
        total = price * qty;
      }
      if (price == 0 && qty > 0) {
        price = total / qty;
      }

      results.add({
        "name": name,
        "category": category,
        "qty": qty,
        "price": price,
        "total": total,
      });
    }
    return results;
  }

  _CategorySummaryPayload? _parseCategorySummaryResponse(dynamic data) {
    final Map<String, Map<String, Map<String, dynamic>>> bucket = {};
    final restaurantName = _findRestaurantName(data);
    final List<Map<String, dynamic>> categoryTotalsFromApi = [];
    final Map<String, Map<String, dynamic>> categoryTotalsFromApiMap = {};
    final List<String> categoryOrder = [];
    final Set<String> categorySeen = {};
    bool hasCategoryList = false;

    void trackCategoryOrder(String name) {
      if (name.isEmpty || categorySeen.contains(name)) return;
      categorySeen.add(name);
      categoryOrder.add(name);
    }

    void addCategoryTotalFromApi(String name, int qty, num total) {
      if (name.isEmpty) return;
      final row = {"category": name, "qty": qty, "total": total};
      if (categoryTotalsFromApiMap.containsKey(name)) {
        categoryTotalsFromApiMap[name] = row;
        final index = categoryTotalsFromApi.indexWhere(
          (entry) => entry["category"]?.toString() == name,
        );
        if (index >= 0) categoryTotalsFromApi[index] = row;
        return;
      }
      categoryTotalsFromApiMap[name] = row;
      categoryTotalsFromApi.add(row);
    }

    void addItem(Map<String, dynamic> item) {
      final category = item["category"]?.toString() ?? "Uncategorized";
      final name = item["name"]?.toString() ?? "Item";
      final int qty = (item["qty"] as num?)?.toInt() ?? 0;
      final num total = item["total"] is num ? item["total"] as num : 0;
      if (qty == 0 && total == 0) return;
      bucket.putIfAbsent(category, () => {});
      bucket[category]!.putIfAbsent(name, () {
        return {"name": name, "qty": 0, "total": 0};
      });
      bucket[category]![name]!["qty"] =
          (bucket[category]![name]!["qty"] as int) + qty;
      bucket[category]![name]!["total"] =
          (bucket[category]![name]!["total"] as num) + total;
    }

    final categories = _findList(data, const [
      "categories",
      "category_summary",
      "categorySummary",
      "categoryTotals",
      "category_totals",
    ]);

    if (categories != null) {
      hasCategoryList = true;
      for (final entry in categories) {
        if (entry is! Map) continue;
        final categoryName = _firstNonEmpty([
          entry["category"],
          entry["name"],
          entry["category_name"],
          entry["title"],
        ]);
        trackCategoryOrder(categoryName);
        final qtyRaw = entry["total_qty"] ??
            entry["total_quantity"] ??
            entry["total_items_sold"] ??
            entry["items_sold"] ??
            entry["qty"] ??
            entry["total_items"] ??
            entry["count"];
        final totalRaw = entry["total_amount"] ??
            entry["total"] ??
            entry["amount"] ??
            entry["total_sales"];
        final int qty = (_asNum(qtyRaw) ?? 0).toInt();
        final num total = _asNum(totalRaw) ?? 0;
        if (categoryName.isNotEmpty && (qty > 0 || total > 0)) {
          addCategoryTotalFromApi(categoryName, qty, total);
        }
        final items = _findList(entry, const [
          "items",
          "products",
          "order_items",
          "orderItems",
          "item_list",
        ]);
        if (items is List) {
          for (final item in _normalizeItems(
            items,
            categoryOverride: categoryName.isNotEmpty ? categoryName : null,
          )) {
            addItem(item);
          }
        }
      }
    }

    if (bucket.isEmpty) {
      final items = _findList(data, const [
        "items",
        "order_items",
        "orderItems",
        "item_list",
        "products",
      ]);
      if (items is List) {
        for (final item in _normalizeItems(items)) {
          addItem(item);
        }
      }
    }

    if (bucket.isEmpty) {
      final orders = _findList(data, const [
        "orders",
        "order_list",
        "orderList",
      ]);
      if (orders is List) {
        for (final order in orders) {
          final parsed = _parseOrderDetails(order);
          for (final item in parsed.items) {
            final category =
                (item["category"]?.toString().trim().isNotEmpty ?? false)
                    ? item["category"].toString()
                    : "Uncategorized";
            final int qty = (item["qty"] as num?)?.toInt() ?? 0;
            final num price = item["price"] is num ? item["price"] as num : 0;
            final num total = price * qty;
            addItem({
              "name": item["name"]?.toString() ?? "Item",
              "category": category,
              "qty": qty,
              "total": total,
            });
          }
        }
      }
    }

    int totalItems = 0;
    num totalAmount = 0;

    final summaryMap = _findMap(data, const ["summary", "overall"]);
    final summaryOrdersRaw = summaryMap?["total_orders"] ??
        summaryMap?["orders"] ??
        summaryMap?["totalOrders"] ??
        summaryMap?["order_count"] ??
        summaryMap?["total_order"] ??
        summaryMap?["totalOrder"];
    final summaryItemsRaw = summaryMap?["total_items_sold"] ??
        summaryMap?["total_items"] ??
        summaryMap?["items_sold"] ??
        summaryMap?["total_qty"] ??
        summaryMap?["total_quantity"] ??
        summaryMap?["totalItems"];
    final summaryAmountRaw = summaryMap?["total_amount"] ??
        summaryMap?["total"] ??
        summaryMap?["total_sales"] ??
        summaryMap?["totalRevenue"] ??
        summaryMap?["grand_total"] ??
        summaryMap?["total_amount"];
    final summaryOrders = _asInt(summaryOrdersRaw);
    final summaryItems = _asInt(summaryItemsRaw);
    final summaryAmount = _asNum(summaryAmountRaw);

    if (bucket.isEmpty && summaryMap != null) {
      return _CategorySummaryPayload(
        categoryTotals: categoryTotalsFromApi,
        itemsByCategory: const {},
        totalOrders: summaryOrders ?? 0,
        totalItems: summaryItems ?? 0,
        totalAmount: summaryAmount ?? 0,
        restaurantName: restaurantName,
      );
    }

    if (bucket.isEmpty && categoryTotalsFromApi.isNotEmpty) {
      int totalItems = 0;
      num totalAmount = 0;
      for (final row in categoryTotalsFromApi) {
        totalItems += (row["qty"] as num?)?.toInt() ?? 0;
        totalAmount += row["total"] is num ? row["total"] as num : 0;
      }
      return _CategorySummaryPayload(
        categoryTotals: categoryTotalsFromApi,
        itemsByCategory: const {},
        totalOrders: summaryOrders ?? 0,
        totalItems: totalItems == 0 ? (summaryItems ?? 0) : totalItems,
        totalAmount: totalAmount == 0 ? (summaryAmount ?? 0) : totalAmount,
        restaurantName: restaurantName,
      );
    }

    if (bucket.isEmpty) return null;

    final Map<String, List<Map<String, dynamic>>> itemsByCategory = {};
    for (final entry in bucket.entries) {
      final items = entry.value.values.toList();
      for (final item in items) {
        final int qty = (item["qty"] as num?)?.toInt() ?? 0;
        final num total = item["total"] is num ? item["total"] as num : 0;
        item["price"] = qty > 0 ? total / qty : 0;
      }
      if (!hasCategoryList) {
        items.sort(
          (a, b) => (a["name"] ?? "").toString().compareTo(
                (b["name"] ?? "").toString(),
              ),
        );
      }
      itemsByCategory[entry.key] = items;
    }

    final List<Map<String, dynamic>> categoryTotals = [];
    final Map<String, Map<String, dynamic>> computedTotalsMap = {};

    for (final entry in itemsByCategory.entries) {
      final category = entry.key;
      final items = entry.value;
      int qty = 0;
      num amount = 0;
      for (final item in items) {
        qty += (item["qty"] as num?)?.toInt() ?? 0;
        amount += item["total"] is num ? item["total"] as num : 0;
      }
      computedTotalsMap[category] = {
        "category": category,
        "qty": qty,
        "total": amount,
      };
      totalItems += qty;
      totalAmount += amount;
    }

    final Set<String> used = {};
    final List<String> orderedCategories = hasCategoryList
        ? categoryOrder
        : (itemsByCategory.keys.toList()..sort());

    for (final category in orderedCategories) {
      final row =
          categoryTotalsFromApiMap[category] ?? computedTotalsMap[category];
      if (row != null) {
        categoryTotals.add(row);
        used.add(category);
      }
    }

    for (final entry in computedTotalsMap.entries) {
      if (!used.contains(entry.key)) {
        categoryTotals.add(entry.value);
      }
    }

    if (totalItems == 0 || totalAmount == 0) {
      int sumItems = 0;
      num sumAmount = 0;
      for (final row in categoryTotals) {
        sumItems += (row["qty"] as num?)?.toInt() ?? 0;
        sumAmount += row["total"] is num ? row["total"] as num : 0;
      }
      if (totalItems == 0) totalItems = sumItems;
      if (totalAmount == 0) totalAmount = sumAmount;
    }

    int computedOrders = summaryOrders ?? 0;
    if (computedOrders == 0) {
      final ordersList = _findList(data, const [
        "orders",
        "order_list",
        "orderList",
      ]);
      if (ordersList is List) {
        computedOrders = ordersList.length;
      }
    }

    return _CategorySummaryPayload(
      categoryTotals: categoryTotals,
      itemsByCategory: itemsByCategory,
      totalOrders: computedOrders,
      totalItems: totalItems == 0 ? (summaryItems ?? 0) : totalItems,
      totalAmount: totalAmount == 0 ? (summaryAmount ?? 0) : totalAmount,
      restaurantName: restaurantName,
    );
  }

  Future<_CategorySummaryPayload?> _fetchCategorySummaryFromApi(
    DateTime date,
  ) async {
    try {
      final dateKey = _formatDateKey(date);
      final branchId = _asInt(info["branch_id"] ?? info["branchId"]);
      final restaurantId = _asInt(
        info["restaurant_id"] ?? info["restaurantId"],
      );
      try {
        final res = await KioskApi().getOrderSummary(
          date: dateKey,
          branchId: branchId,
          restaurantId: restaurantId,
        );
        final parsed = _parseCategorySummaryResponse(res.data);
        if (parsed != null) return parsed;
      } catch (_) {
        // fallback below
      }
      final res = await AdminApi().getOrderSummary(
        date: dateKey,
        branchId: branchId,
        restaurantId: restaurantId,
      );
      return _parseCategorySummaryResponse(res.data);
    } catch (e) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchOrdersForReport() async {
    final orders = await OrderUtils.getOrdersWithItems(
      dateRange: _currentDateRangeKey(),
      status: "",
      range: customRange,
    );
    return orders.where(_isPaidOrder).toList();
  }

  Future<void> _applyFilter(String nextFilter, {DateTimeRange? range}) async {
    setState(() {
      filter = nextFilter;
      customRange = range;
      loading = true;
    });
    await _load();
  }

  Future<void> _printOrdersForFilter(
    String nextFilter, {
    DateTimeRange? range,
  }) async {
    await _applyFilter(nextFilter, range: range);
    await _printSelectedDay();
  }

  Future<void> _printSummaryForFilter(
    String nextFilter, {
    DateTimeRange? range,
  }) async {
    await _applyFilter(nextFilter, range: range);
    await _printSummary();
  }

  Future<void> _printItemSalesForFilter(
    String nextFilter, {
    DateTimeRange? range,
  }) async {
    await _applyFilter(nextFilter, range: range);
    await _printItemSalesReport();
  }

  Future<void> _printCategorySummaryForFilter(
    String nextFilter, {
    DateTimeRange? range,
  }) async {
    await _applyFilter(nextFilter, range: range);
    await _printCategorySummaryReport();
  }

  Future<void> _printCategorySummaryForDate() async {
    if (_isBulkPrinting) return;
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF9F342C)),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    _isBulkPrinting = true;

    bool dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text("Preparing Category Summary..."),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              const CircularProgressIndicator(color: Color(0xFF9F342C)),
              const SizedBox(height: 16),
              Text(
                DateFormat('dd MMM yyyy').format(picked),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      },
    ).then((_) => dialogOpen = false);

    try {
      final apiSummary = await _fetchCategorySummaryFromApi(picked);
      if (apiSummary != null &&
          (apiSummary.categoryTotals.isNotEmpty ||
              apiSummary.itemsByCategory.isNotEmpty)) {
        final dateKey = _formatDateKey(picked);
        final title = DateFormat('dd MMM yyyy').format(picked);
        final restaurantName = await _resolveRestaurantName();
        final address =
            info["address"] != null ? info["address"].toString() : null;
        final taxId = info["tax_id"]?.toString();

        await _printerService.printCategoryTotalsReport(
          title: title,
          fromDate: dateKey,
          toDate: dateKey,
          categoryTotals: apiSummary.categoryTotals,
          itemsByCategory: apiSummary.itemsByCategory,
          totalItems: apiSummary.totalItems,
          totalAmount: apiSummary.totalAmount,
          restaurantName:
              restaurantName.isNotEmpty ? restaurantName : "Restaurant",
          address: address,
          taxId: taxId,
        );
        _showSnackBar("Category summary printed", Colors.green);
        return;
      }

      final ordersForDate = await OrderUtils.getOrdersForDate(picked);
      final paidOrders = ordersForDate.where(_isPaidOrder).toList();
      if (paidOrders.isEmpty) {
        _showSnackBar("No paid orders for selected date", Colors.orange);
        return;
      }

      final Map<String, Map<String, dynamic>> categoryTotals = {};
      final Map<String, Map<String, Map<String, dynamic>>> categoryItemMap = {};
      num totalAmount = 0;
      int totalItems = 0;

      for (final o in paidOrders) {
        final items = await _loadOrderItems(o);
        if (items.isEmpty) continue;
        for (final item in items) {
          final String category =
              (item["category"]?.toString().trim().isNotEmpty ?? false)
                  ? item["category"].toString()
                  : "Uncategorized";
          final String name = item["name"]?.toString() ?? "Item";
          final int qty = (item["qty"] as num?)?.toInt() ?? 0;
          final num price = item["price"] is num ? item["price"] as num : 0;
          final num total = price * qty;

          categoryTotals.putIfAbsent(
            category,
            () => {"category": category, "qty": 0, "total": 0},
          );
          categoryTotals[category]!["qty"] =
              (categoryTotals[category]!["qty"] as int) + qty;
          categoryTotals[category]!["total"] =
              (categoryTotals[category]!["total"] as num) + total;

          categoryItemMap.putIfAbsent(category, () => {});
          categoryItemMap[category]!.putIfAbsent(
            name,
            () => {"name": name, "qty": 0, "total": 0},
          );
          categoryItemMap[category]![name]!["qty"] =
              (categoryItemMap[category]![name]!["qty"] as int) + qty;
          categoryItemMap[category]![name]!["total"] =
              (categoryItemMap[category]![name]!["total"] as num) + total;

          totalItems += qty;
          totalAmount += total;
        }
      }

      if (categoryTotals.isEmpty) {
        _showSnackBar("No item data to print", Colors.red);
        return;
      }

      final Map<String, List<Map<String, dynamic>>> itemsByCategory = {};
      for (final entry in categoryItemMap.entries) {
        itemsByCategory[entry.key] = entry.value.values.toList();
      }

      final dateKey = _formatDateKey(picked);
      final title = DateFormat('dd MMM yyyy').format(picked);
      final restaurantName = await _resolveRestaurantName();
      final address =
          info["address"] != null ? info["address"].toString() : null;
      final taxId = info["tax_id"]?.toString();

      await _printerService.printCategoryTotalsReport(
        title: title,
        fromDate: dateKey,
        toDate: dateKey,
        categoryTotals: categoryTotals.values.toList(),
        itemsByCategory: itemsByCategory,
        totalItems: totalItems,
        totalAmount: totalAmount,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
        taxId: taxId,
      );
      _showSnackBar("Category summary printed", Colors.green);
    } catch (e) {
      _showSnackBar("Print failed: $e", Colors.red);
    } finally {
      if (dialogOpen && mounted) Navigator.pop(context);
      _isBulkPrinting = false;
    }
  }

  Future<void> _printCategoryTotalsForFilter(
    String nextFilter, {
    DateTimeRange? range,
  }) async {
    await _applyFilter(nextFilter, range: range);
    await _printCategoryTotalsReport();
  }

  Future<void> _runTestPrint() async {
    final restaurantName = await _resolveRestaurantName();
    final address = info["address"]?.toString();
    try {
      await _printerService.testPrint(
        restaurantName: restaurantName,
        address: address,
      );
      _showSnackBar("Test print started", Colors.blue);
    } on PlatformException catch (e) {
      _showSnackBar(e.message ?? e.toString(), Colors.red);
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
    }
  }

  void _goToWelcome() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  Future<void> _openPrintMenu() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      elevation: 10,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Print Reports",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildPrintCard(
                icon: Icons.list_alt_rounded,
                color: Colors.purple,
                title: "Category Summary",
                subtitle: "Categories with items, price & total for a day",
                onTap: () {
                  Navigator.pop(context);
                  _printCategorySummaryForDate();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _loadTodayOrders() async {
    final list = await OrderUtils.getRecentOrders("today");
    return list;
  }

  Future<void> _openTodayOrdersSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Today's Orders",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: _loadTodayOrders(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF9F342C),
                          ),
                        );
                      }
                      final data = snapshot.data ?? [];
                      if (data.isEmpty) {
                        return const Center(child: Text("No orders for today"));
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: data.length,
                        itemBuilder: (context, i) {
                          final o = data[i];
                          final orderPk = _getOrderPk(o);
                          final orderNo = _getOrderNumber(o);
                          final time = o["time"]?.toString() ?? "";
                          final total =
                              o["total"] != null ? o["total"].toString() : "";

                          return ListTile(
                            leading: const Icon(Icons.receipt_long_outlined),
                            title: Text("Order #$orderNo"),
                            subtitle: time.isNotEmpty ? Text(time) : null,
                            trailing: Text(
                              total.isNotEmpty ? "₹$total" : "",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onTap: () async {
                              Navigator.pop(context);
                              await _printOrderById(orderPk);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPrintTile({
    required IconData icon,
    required Color color,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Icon(icon, color: color),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle != null ? Text(subtitle) : null,
      onTap: onTap,
    );
  }

  Widget _buildPrintCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _printOneDaySummaryForDate() async {
    if (_isBulkPrinting) return;
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF9F342C)),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    final start = DateTime(picked.year, picked.month, picked.day);
    final end = start;

    try {
      final apiSummary = await _fetchCategorySummaryFromApi(start);
      int totalOrders = apiSummary?.totalOrders ?? 0;
      num totalRevenue = apiSummary?.totalAmount ?? 0;

      if (totalOrders == 0 && totalRevenue == 0) {
        final ordersForDate = await OrderUtils.getOrdersForDate(start);
        final paidOrders = ordersForDate.where(_isPaidOrder).toList();
        if (paidOrders.isEmpty) {
          _showSnackBar("No paid orders for selected date", Colors.orange);
          return;
        }
        for (final o in paidOrders) {
          final items = await _loadOrderItems(o);
          if (items.isEmpty) continue;
          totalOrders++;
          totalRevenue += _sumItemsTotal(items);
        }
      }

      if (totalOrders == 0) {
        _showSnackBar("No paid orders for selected date", Colors.orange);
        return;
      }

      final restaurantName = await _resolveRestaurantName();
      final address =
          info["address"] != null ? info["address"].toString() : null;

      final dateLabel = DateFormat('yyyy-MM-dd').format(start);
      await _printerService.printDailySummary(
        title: DateFormat('dd MMM yyyy').format(start),
        fromDate: dateLabel,
        toDate: dateLabel,
        totalOrders: totalOrders,
        totalRevenue: totalRevenue,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
      );
      _showSnackBar("Summary printed", Colors.green);
    } catch (e) {
      _showSnackBar("Summary print failed: $e", Colors.red);
    }
  }

  Future<void> _printSelectedDay() async {
    if (_isBulkPrinting) return;
    final paidOrders = _allOrders.where(_isPaidOrder).toList();
    if (paidOrders.isEmpty) {
      _showSnackBar("No paid orders to print", Colors.orange);
      return;
    }
    final confirmed = await _confirmBulkPrint(paidOrders.length);
    if (!confirmed) return;
    _isBulkPrinting = true;
    int printed = 0;
    int failed = 0;
    bool cancelled = false;
    String current = "";
    void Function(void Function())? updateDialog;
    bool dialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            updateDialog = setState;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text("Bulk Printing..."),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value:
                          paidOrders.isEmpty ? 0 : printed / paidOrders.length,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      color: const Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "Success: $printed | Failed: $failed",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Now Processing: #$current",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text("Stop Process"),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => dialogOpen = false);

    final sorted = [...paidOrders];
    sorted.sort((a, b) => _getOrderPk(a).compareTo(_getOrderPk(b)));

    for (final o in sorted) {
      if (!mounted || cancelled) break;
      final orderId = _getOrderPk(o);
      final orderNumber = _getOrderNumber(o);
      if (orderId <= 0) {
        failed++;
        continue;
      }
      current = orderNumber;
      updateDialog?.call(() {});
      try {
        await _printOrderById(orderId);
        printed++;
      } catch (_) {
        failed++;
      }
      updateDialog?.call(() {});
      await Future.delayed(const Duration(milliseconds: 250));
    }

    _isBulkPrinting = false;
    if (dialogOpen && mounted) Navigator.pop(context);
    if (!mounted) return;
    if (cancelled) {
      _showSnackBar("Bulk print cancelled", Colors.orange);
    } else if (failed > 0) {
      _showSnackBar("Printed $printed. Failed $failed.", Colors.red);
    } else {
      _showSnackBar("All orders printed successfully", Colors.green);
    }
  }

  Future<void> _printSummary() async {
    if (_isBulkPrinting) return;
    if (!mounted) return;

    final range = _resolveFilterRange();
    final start = range.start;
    final end = range.end;

    final paidOrders = await _fetchOrdersForReport();
    if (paidOrders.isEmpty) {
      _showSnackBar("No paid orders to print", Colors.orange);
      return;
    }
    int totalOrders = 0;
    num totalRevenue = 0;
    for (final o in paidOrders) {
      final items = await _loadOrderItems(o);
      if (items.isEmpty) continue;
      totalOrders++;
      totalRevenue += _sumItemsTotal(items);
    }
    if (totalOrders == 0) {
      try {
        final stats = await OrderUtils.getRevenueStats(
          filter,
          dateRange: customRange,
        );
        totalOrders = int.tryParse(
              (stats["total_orders"] ?? stats["orders"] ?? 0).toString(),
            ) ??
            0;
        totalRevenue = num.tryParse(
              (stats["total_revenue"] ?? stats["revenue"] ?? 0).toString(),
            ) ??
            0;
      } catch (_) {}
      if (totalOrders == 0) {
        _showSnackBar("No paid orders to print", Colors.orange);
        return;
      }
    }

    final restaurantName = await _resolveRestaurantName();
    final address = info["address"] != null ? info["address"].toString() : null;

    final fromLabel = DateFormat('yyyy-MM-dd').format(start);
    final toLabel = DateFormat('yyyy-MM-dd').format(end);

    try {
      await _printerService.printDailySummary(
        title: _filterLabel(filter),
        fromDate: fromLabel,
        toDate: toLabel,
        totalOrders: totalOrders,
        totalRevenue: totalRevenue,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
      );
      _showSnackBar("Summary printed", Colors.green);
    } catch (e) {
      _showSnackBar("Summary print failed: $e", Colors.red);
    }
  }

  Future<bool> _confirmItemSalesReport(int count) async {
    return (await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Item Sales Report"),
            content: Text("Print item-wise report for $count orders?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9F342C),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Print"),
              ),
            ],
          ),
        )) ??
        false;
  }

  Future<void> _printItemSalesReport() async {
    if (_isBulkPrinting) return;
    final ordersForReport = await _fetchOrdersForReport();
    if (ordersForReport.isEmpty) {
      _showSnackBar("No orders to print", Colors.orange);
      return;
    }
    final confirmed = await _confirmItemSalesReport(ordersForReport.length);
    if (!confirmed) return;
    _isBulkPrinting = true;

    int processed = 0;
    int failed = 0;
    bool cancelled = false;
    void Function(void Function())? updateDialog;
    bool dialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            updateDialog = setState;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text("Preparing Item Report..."),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: ordersForReport.isEmpty
                          ? 0
                          : processed / ordersForReport.length,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      color: const Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text("Processed: $processed | Failed: $failed"),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text("Stop"),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => dialogOpen = false);

    final List<Map<String, dynamic>> lines = [];
    num totalAmount = 0;
    int totalItems = 0;
    final int ordersCount = ordersForReport.length;

    for (final o in ordersForReport) {
      if (!mounted || cancelled) break;
      try {
        final items = await _loadOrderItems(o);
        if (items.isEmpty) {
          failed++;
          updateDialog?.call(() {});
          continue;
        }
        for (final item in items) {
          final int qty = (item["qty"] as num?)?.toInt() ?? 0;
          final num price = item["price"] is num ? item["price"] as num : 0;
          final String name = item["name"]?.toString() ?? "Item";
          for (int i = 0; i < qty; i++) {
            lines.add({"name": name, "price": price});
          }
          totalItems += qty;
          totalAmount += (price * qty);
        }
        processed++;
      } catch (_) {
        failed++;
      }
      updateDialog?.call(() {});
    }

    if (dialogOpen && mounted) Navigator.pop(context);

    if (cancelled) {
      _isBulkPrinting = false;
      _showSnackBar("Item report cancelled", Colors.orange);
      return;
    }

    if (lines.isEmpty) {
      _isBulkPrinting = false;
      _showSnackBar("No item data to print", Colors.red);
      return;
    }

    final range = _resolveFilterRange();
    final start = range.start;
    final end = range.end;

    final fromLabel = DateFormat('yyyy-MM-dd').format(start);
    final toLabel = DateFormat('yyyy-MM-dd').format(end);
    final restaurantName = await _resolveRestaurantName();
    final address = info["address"] != null ? info["address"].toString() : null;
    final showTaxInReceipt = info["show_tax_in_receipt"] == true;
    final taxId = showTaxInReceipt ? info["tax_id"]?.toString() : null;

    try {
      await _printerService.printItemSalesReport(
        title: _filterLabel(filter),
        fromDate: fromLabel,
        toDate: toLabel,
        items: lines,
        totalItems: totalItems,
        totalAmount: totalAmount,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
        taxId: taxId,
      );
      _showSnackBar("Item report printed", Colors.green);
    } catch (e) {
      _showSnackBar("Print failed: $e", Colors.red);
    } finally {
      _isBulkPrinting = false;
    }
  }

  Future<void> _printCategorySummaryReport() async {
    if (_isBulkPrinting) return;
    final ordersForReport = await _fetchOrdersForReport();
    if (ordersForReport.isEmpty) {
      _showSnackBar("No orders to print", Colors.orange);
      return;
    }
    _isBulkPrinting = true;

    int processed = 0;
    int failed = 0;
    bool cancelled = false;
    void Function(void Function())? updateDialog;
    bool dialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            updateDialog = setState;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text("Preparing Category Summary..."),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: ordersForReport.isEmpty
                          ? 0
                          : processed / ordersForReport.length,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      color: const Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text("Processed: $processed | Failed: $failed"),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text("Stop"),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => dialogOpen = false);

    final Map<String, Map<String, Map<String, dynamic>>> categoryItemMap = {};
    num totalAmount = 0;
    int totalItems = 0;
    final int ordersCount = ordersForReport.length;

    for (final o in ordersForReport) {
      if (!mounted || cancelled) break;
      try {
        final items = await _loadOrderItems(o);
        if (items.isEmpty) {
          failed++;
          updateDialog?.call(() {});
          continue;
        }
        for (final item in items) {
          final String name = item["name"]?.toString() ?? "Item";
          final String category =
              (item["category"]?.toString().trim().isNotEmpty ?? false)
                  ? item["category"].toString()
                  : "Uncategorized";
          final int qty = (item["qty"] as num?)?.toInt() ?? 0;
          final num price = item["price"] is num ? item["price"] as num : 0;
          final num total = price * qty;

          categoryItemMap.putIfAbsent(category, () => {});
          categoryItemMap[category]!.putIfAbsent(name, () {
            return {"name": name, "qty": 0, "total": 0};
          });
          categoryItemMap[category]![name]!["qty"] =
              (categoryItemMap[category]![name]!["qty"] as int) + qty;
          categoryItemMap[category]![name]!["total"] =
              (categoryItemMap[category]![name]!["total"] as num) + total;

          totalItems += qty;
          totalAmount += total;
        }
        processed++;
      } catch (_) {
        failed++;
      }
      updateDialog?.call(() {});
    }

    if (dialogOpen && mounted) Navigator.pop(context);

    if (cancelled) {
      _isBulkPrinting = false;
      _showSnackBar("Category summary cancelled", Colors.orange);
      return;
    }

    if (categoryItemMap.isEmpty) {
      _isBulkPrinting = false;
      _showSnackBar("No item data to print", Colors.red);
      return;
    }

    final Map<String, List<Map<String, dynamic>>> itemsByCategory = {};
    for (final entry in categoryItemMap.entries) {
      final list = entry.value.values.toList();
      itemsByCategory[entry.key] = list;
    }

    final range = _resolveFilterRange();
    final start = range.start;
    final end = range.end;

    final fromLabel = DateFormat('yyyy-MM-dd').format(start);
    final toLabel = DateFormat('yyyy-MM-dd').format(end);
    final restaurantName = await _resolveRestaurantName();
    final address = info["address"] != null ? info["address"].toString() : null;
    final taxId = info["tax_id"]?.toString();

    try {
      await _printerService.printCategorySalesReport(
        title: _filterLabel(filter),
        fromDate: fromLabel,
        toDate: toLabel,
        itemsByCategory: itemsByCategory,
        totalItems: ordersCount,
        totalAmount: totalAmount,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
        taxId: taxId,
      );
      _showSnackBar("Category summary printed", Colors.green);
    } catch (e) {
      _showSnackBar("Print failed: $e", Colors.red);
    } finally {
      _isBulkPrinting = false;
    }
  }

  Future<void> _printCategoryTotalsReport() async {
    if (_isBulkPrinting) return;
    final ordersForReport = await _fetchOrdersForReport();
    if (ordersForReport.isEmpty) {
      _showSnackBar("No orders to print", Colors.orange);
      return;
    }
    _isBulkPrinting = true;

    int processed = 0;
    int failed = 0;
    bool cancelled = false;
    void Function(void Function())? updateDialog;
    bool dialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            updateDialog = setState;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text("Preparing Category Totals..."),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: ordersForReport.isEmpty
                          ? 0
                          : processed / ordersForReport.length,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      color: const Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text("Processed: $processed | Failed: $failed"),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text("Stop"),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => dialogOpen = false);

    final Map<String, Map<String, dynamic>> categoryTotals = {};
    final Map<String, Map<String, Map<String, dynamic>>> categoryItemMap = {};
    num totalAmount = 0;
    int totalItems = 0;

    for (final o in ordersForReport) {
      if (!mounted || cancelled) break;
      try {
        final items = await _loadOrderItems(o);
        if (items.isEmpty) {
          failed++;
          updateDialog?.call(() {});
          continue;
        }
        for (final item in items) {
          final String category =
              (item["category"]?.toString().trim().isNotEmpty ?? false)
                  ? item["category"].toString()
                  : "Uncategorized";
          final String name = item["name"]?.toString() ?? "Item";
          final int qty = (item["qty"] as num?)?.toInt() ?? 0;
          final num price = item["price"] is num ? item["price"] as num : 0;
          final num total = price * qty;

          categoryTotals.putIfAbsent(
            category,
            () => {"category": category, "qty": 0, "total": 0},
          );
          categoryTotals[category]!["qty"] =
              (categoryTotals[category]!["qty"] as int) + qty;
          categoryTotals[category]!["total"] =
              (categoryTotals[category]!["total"] as num) + total;

          categoryItemMap.putIfAbsent(category, () => {});
          categoryItemMap[category]!.putIfAbsent(
            name,
            () => {"name": name, "qty": 0},
          );
          categoryItemMap[category]![name]!["qty"] =
              (categoryItemMap[category]![name]!["qty"] as int) + qty;

          totalItems += qty;
          totalAmount += total;
        }
        processed++;
      } catch (_) {
        failed++;
      }
      updateDialog?.call(() {});
    }

    if (dialogOpen && mounted) Navigator.pop(context);

    if (cancelled) {
      _isBulkPrinting = false;
      _showSnackBar("Category totals cancelled", Colors.orange);
      return;
    }

    if (categoryTotals.isEmpty) {
      _isBulkPrinting = false;
      _showSnackBar("No item data to print", Colors.red);
      return;
    }

    final range = _resolveFilterRange();
    final start = range.start;
    final end = range.end;

    final fromLabel = DateFormat('yyyy-MM-dd').format(start);
    final toLabel = DateFormat('yyyy-MM-dd').format(end);
    final restaurantName = await _resolveRestaurantName();
    final address = info["address"] != null ? info["address"].toString() : null;
    final taxId = info["tax_id"]?.toString();

    final Map<String, List<Map<String, dynamic>>> itemsByCategory = {};
    for (final entry in categoryItemMap.entries) {
      itemsByCategory[entry.key] = entry.value.values.toList();
    }

    try {
      await _printerService.printCategoryTotalsReport(
        title: _filterLabel(filter),
        fromDate: fromLabel,
        toDate: toLabel,
        categoryTotals: categoryTotals.values.toList(),
        itemsByCategory: itemsByCategory,
        totalItems: totalItems,
        totalAmount: totalAmount,
        restaurantName:
            restaurantName.isNotEmpty ? restaurantName : "Restaurant",
        address: address,
        taxId: taxId,
      );
      _showSnackBar("Category totals printed", Colors.green);
    } catch (e) {
      _showSnackBar("Print failed: $e", Colors.red);
    } finally {
      _isBulkPrinting = false;
    }
  }

  Future<bool> _confirmBulkPrint(int count) async {
    return (await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Confirmation"),
            content: Text(
              "Do you want to print receipts for $count orders?",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9F342C),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Print All"),
              ),
            ],
          ),
        )) ??
        false;
  }

  Future<void> _printSingleOrder(int orderId, {String? orderNumber}) async {
    if (orderId <= 0) {
      _showSnackBar("Invalid order ID", Colors.red);
      return;
    }
    try {
      await _printOrderById(orderId);
      final label = orderNumber ?? orderId.toString();
      _showSnackBar("Receipt printed (Order #$label)", Colors.green);
    } catch (e) {
      _showSnackBar("Print failed: $e", Colors.red);
    }
  }

  Future<void> _printOrderById(int orderId) async {
    dynamic res;
    try {
      res = await AdminApi().getOrder(orderId.toString());
    } catch (_) {
      res = await KioskApi().getOrderDetails(orderId);
    }
    final parsed = _parseOrderDetails(res.data);
    final txnId = _extractTxnId(res.data);
    final orderDate = _extractOrderDate(res.data);
    final items = parsed.items;
    if (items.isEmpty) throw Exception("Order items not found");
    final parcelTotal = _extractParcelTotal(res.data, items);
    final restaurantName = await _resolveRestaurantName();
    final address = info["address"] != null ? info["address"].toString() : null;
    final showTaxInReceipt = info["show_tax_in_receipt"] == true;
    final taxId = showTaxInReceipt ? info["tax_id"]?.toString() : null;
    await _printerService.printOrder(
      orderId: orderId,
      cartItems: items,
      restaurantName: restaurantName.isNotEmpty ? restaurantName : "Restaurant",
      address: address,
      taxId: taxId,
      transactionId: txnId,
      orderDate: orderDate,
      paymentMode: parsed.paymentMode,
      taxAmount: parsed.taxAmount,
      discountAmount: parsed.discountAmount,
      removeTaxLines: !showTaxInReceipt,
      parcelTotalOverride: parcelTotal,
    );
  }

  num _extractParcelTotal(
    dynamic data,
    List<Map<String, dynamic>> items,
  ) {
    num total = 0;
    bool found = false;
    for (final item in items) {
      final qty = item["qty"] is num ? item["qty"] as num : 1;
      final charge = item["take_away_charge"] ??
          item["takeaway_charge"] ??
          item["parcel_charge"] ??
          item["parcelCharge"] ??
          item["parcel_amount"] ??
          item["parcelAmount"];
      final num c = charge is num ? charge : num.tryParse("$charge") ?? 0;
      if (c > 0) {
        total += c * qty;
        found = true;
      }
    }
    if (found) return total;

    Map? order;
    if (data is Map) {
      final dynamic raw =
          data["order"] ?? data["data"]?["order"] ?? data["data"] ?? data;
      if (raw is Map) order = raw;
    }
    if (order == null) return 0;
    const keys = [
      "take_away_charge",
      "takeaway_charge",
      "parcel_charge",
      "parcel_charges",
      "parcel_amount",
      "parcel_total",
      "parcelTotal",
      "take_away_charge_total",
    ];
    for (final key in keys) {
      final v = order?[key];
      final num value = v is num ? v : num.tryParse("$v") ?? 0;
      if (value > 0) return value;
    }
    return 0;
  }

  String? _extractTxnId(dynamic value) {
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
          if (v.toString().trim().isNotEmpty) return v.toString().trim();
        }
      }
      for (final entry in value.entries) {
        final found = _extractTxnId(entry.value);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _extractTxnId(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  DateTime? _extractOrderDate(dynamic value) {
    final keys = [
      "date_time_formatted",
      "dateTimeFormatted",
      "formatted_date_time",
      "formattedDateTime",
      "date_time",
      "dateTime",
      "created_at",
      "order_date",
      "date",
      "createdAt",
      "placed_at",
      "order_time",
    ];
    if (value is Map) {
      for (final k in keys) {
        final parsed = _parseDateValue(value[k]);
        if (parsed != null) return parsed;
      }
      for (final entry in value.entries) {
        final parsed = _extractOrderDate(entry.value);
        if (parsed != null) return parsed;
      }
    } else if (value is List) {
      for (final item in value) {
        final parsed = _extractOrderDate(item);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  DateTime? _parseDateValue(dynamic v) {
    if (v == null) return null;
    try {
      if (v is int) {
        final instant = v > 1000000000000
            ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
            : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
        return _toIndiaWallTime(instant);
      }
      if (v is String) {
        final trimmed = v.trim();
        final formatted = _parseRestaurantFormattedDate(trimmed);
        if (formatted != null) return formatted;
        final parsed = DateTime.tryParse(trimmed);
        if (parsed == null) return null;
        if (_hasExplicitTimezone(trimmed)) {
          return _toIndiaWallTime(parsed);
        }
        return _toIndiaWallTime(DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        ));
      }
      if (v is DateTime) return _toIndiaWallTime(v);
    } catch (_) {}
    return null;
  }

  DateTime _toIndiaWallTime(DateTime value) {
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

  bool _hasExplicitTimezone(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith("Z") ||
        RegExp(r"[+-]\d{2}:?\d{2}$").hasMatch(trimmed);
  }

  DateTime? _parseRestaurantFormattedDate(dynamic value) {
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

  void _showSnackBar(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading && stats.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF9F342C)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FB),
      body: RefreshIndicator(
        onRefresh: _load,
        color: const Color(0xFF9F342C),
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            _buildSliverAppBar(),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoCards(),
                    const SizedBox(height: 12),
                    _buildOrderSummaryCards(),
                    const SizedBox(height: 16),
                    _buildUnifiedFilterSection(),
                    const SizedBox(height: 16),
                    const SizedBox(height: 20),
                    _buildSearchAndTitle(),
                  ],
                ),
              ),
            ),
            _buildOrdersList(),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildSliverAppBar() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;

    return SliverAppBar(
      expandedHeight: 90,
      pinned: true,
      elevation: 0,
      stretch: true,
      backgroundColor: const Color(0xFF9F342C),

      // 👈 LEADING LOGO
      leadingWidth: isTablet ? 120 : 100,
      leading: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Image.asset(
            "assets/self.png",
            height: isTablet ? 46 : 36,
            fit: BoxFit.contain,
          ),
        ),
      ),

      // 👈 TITLE + BACKGROUND DESIGN
      flexibleSpace: FlexibleSpaceBar(
        centerTitle: false,
        titlePadding: EdgeInsets.only(
          left: isTablet ? 140 : 120, // prevents overlap with logo
          bottom: 16,
        ),
        background: Stack(
          children: [
            Positioned(
              right: -50,
              top: -20,
              child: CircleAvatar(
                radius: 100,
                backgroundColor: Colors.white.withOpacity(0.05),
              ),
            ),
          ],
        ),
      ),

      // 👉 RIGHT EXIT BUTTON
      actions: [
        IconButton(
          onPressed: _goToWelcome,
          icon: const Icon(Icons.logout_rounded),
          color: Colors.white,
          tooltip: "Exit",
        ),
      ],
    );
  }

  Widget _buildUnifiedFilterSection() {
    const brandRed = Color(0xFF9F342C);

    // 1. Refined Button Design with state-aware styling
    Widget printButton = OutlinedButton.icon(
      onPressed: _openPrintMenu,
      icon: const Icon(Icons.print_outlined, size: 18),
      label: const Text("Print Summary"),
      style: OutlinedButton.styleFrom(
        foregroundColor: brandRed,
        side: const BorderSide(color: brandRed, width: 1.2),
        backgroundColor: brandRed.withOpacity(0.04),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        elevation: 0,
      ).copyWith(
        // Adds a subtle fill change when the user hovers (Web/Desktop)
        overlayColor: MaterialStateProperty.resolveWith<Color?>(
          (states) => states.contains(MaterialState.hovered)
              ? brandRed.withOpacity(0.08)
              : null,
        ),
      ),
    );

    // 2. Optimized Responsive Container
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 700;

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
          // Ensures the layout transitions smoothly between Desktop and Mobile
          child: Flex(
            direction: isNarrow ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment:
                isNarrow ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Order Summary",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight:
                          FontWeight.w900, // Heavier weight for clear hierarchy
                      color: Color(0xFF1A1A1A),
                      letterSpacing: -0.4,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "View and manage order details",
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
              if (isNarrow) const SizedBox(height: 20),
              printButton,
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoCards() {
    final restaurantName =
        (info["restaurant_name"] ?? info["name"] ?? "Restaurant").toString();
    final address = (info["address"] ?? "Address not available").toString();
    final taxId = info["tax_id"]?.toString();

    final kioskName = (info["kiosk_name"] ?? "Kiosk").toString().trim().isEmpty
        ? "Kiosk"
        : (info["kiosk_name"] ?? "Kiosk").toString();
    final deviceId = info["device_id"]?.toString();
    final printerId = info["printer_id"]?.toString();
    final branchName = info["branch_name"]?.toString();
    final branchId = info["branch_id"]?.toString();

    Widget buildCard({
      required String title,
      required IconData icon,
      required List<Widget> lines,
      Widget? footer,
    }) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9F342C).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: const Color(0xFF9F342C), size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF2D3243),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...lines,
            if (footer != null) ...[const SizedBox(height: 10), footer],
          ],
        ),
      );
    }

    Widget infoLine(String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(
                label,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          buildCard(
            title: "Restaurant",
            icon: Icons.restaurant,
            lines: [
              Text(
                restaurantName,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                address,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
              if (taxId != null && taxId.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                infoLine("GST", taxId.trim()),
              ],
            ],
          ),
          buildCard(
            title: "Kiosk Details",
            icon: Icons.devices,
            lines: [
              infoLine("Name", kioskName),
              if (deviceId != null && deviceId.trim().isNotEmpty)
                infoLine("Device", deviceId.trim()),
              if (printerId != null && printerId.trim().isNotEmpty)
                infoLine("Printer", printerId.trim()),
              if (branchName != null && branchName.trim().isNotEmpty)
                infoLine("Branch", branchName.trim()),
              if ((branchId ?? "").trim().isNotEmpty)
                infoLine("Branch ID", branchId!.trim()),
            ],
            footer: SizedBox(
              width: double.infinity,
              height: 32,
              child: ElevatedButton.icon(
                onPressed: _runTestPrint,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9F342C),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.receipt_long, size: 14),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "Test Print",
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
        ];

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
          ],
        );
      },
    );
  }

  Widget _buildOrderSummaryCards() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;

        // Use a Row for larger screens and a Column for narrow layouts.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: isWide
              ? Row(
                  children: [
                    Expanded(
                      child: _summaryCardDashboard(
                        title: "Total Orders",
                        value: totalOrdersCount.toString(),
                        color: const Color(0xFF9F342C),
                        icon: Icons.receipt_long,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _summaryCardDashboard(
                        title: "Paid",
                        value: paidOrdersCount.toString(),
                        color: const Color(0xFF1B8E3E),
                        icon: Icons.check_circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _summaryCardDashboard(
                        title: "Unpaid",
                        value: unpaidOrdersCount.toString(),
                        color: Colors.orange,
                        icon: Icons.hourglass_top_rounded,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _summaryCardDashboard(
                      title: "Total Orders",
                      value: totalOrdersCount.toString(),
                      color: const Color(0xFF9F342C),
                      icon: Icons.receipt_long,
                    ),
                    const SizedBox(height: 12),
                    _summaryCardDashboard(
                      title: "Paid",
                      value: paidOrdersCount.toString(),
                      color: const Color(0xFF1B8E3E),
                      icon: Icons.check_circle,
                    ),
                    const SizedBox(height: 12),
                    _summaryCardDashboard(
                      title: "Unpaid",
                      value: unpaidOrdersCount.toString(),
                      color: Colors.orange,
                      icon: Icons.hourglass_top_rounded,
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _summaryCardDashboard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 80),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.15), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Icon Container
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          // Text Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.5,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Color(
                        0xFF2D2D2D,
                      ), // Darker text for better contrast
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndTitle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Live Orders",
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF2D3243),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (val) {
              setState(() => _currentSearch = val);
              _applySearchFilter();
            },
            decoration: InputDecoration(
              hintText: "Search by ID or Transaction...",
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: Color(0xFF9F342C)),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList() {
    if (orders.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              "No orders to display",
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildOrderListItem(orders[index]),
          childCount: orders.length,
        ),
      ),
    );
  }

  Widget _buildOrderListItem(Map<String, dynamic> order) {
    final int orderId = _getOrderPk(order);
    final String orderNumber = _getOrderNumber(order);
    final String txnId = (order['transaction_id'] ?? 'N/A').toString();
    final String statusRaw = (order['status'] ?? 'pending').toString();
    final String status = statusRaw.toLowerCase();
    final bool isPaid = status == "paid" ||
        status == "success" ||
        status == "completed" ||
        status == "delivered";
    final String? imageUrl = order['image_url']?.toString();
    final String? itemsLabel = order['items_label']?.toString();
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int thumbCache = (28 * dpr).round().clamp(1, 256);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF9F342C).withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: imageUrl != null && imageUrl.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    imageUrl,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                    cacheWidth: thumbCache,
                    cacheHeight: thumbCache,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.shopping_bag_outlined,
                      color: Color(0xFF9F342C),
                    ),
                  ),
                )
              : const Icon(
                  Icons.shopping_bag_outlined,
                  color: Color(0xFF9F342C),
                ),
        ),
        title: Text(
          "Order #$orderNumber",
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "TXN: $txnId",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    "₹${order['total']}  •  ${order['time']}",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isPaid
                          ? const Color(0xFF1B8E3E).withOpacity(0.12)
                          : Colors.red.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isPaid ? const Color(0xFF1B8E3E) : Colors.red,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      isPaid ? "PAID" : "UNPAID",
                      style: TextStyle(
                        color: isPaid ? const Color(0xFF1B8E3E) : Colors.red,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
              if (itemsLabel != null && itemsLabel.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  "Items: $itemsLabel",
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        trailing: Material(
          color: Colors.transparent,
          child: Tooltip(
            message: "Print receipt",
            child: InkWell(
              customBorder: const CircleBorder(),
              hoverColor: const Color(0xFF9F342C).withOpacity(0.12),
              splashColor: const Color(0xFF9F342C).withOpacity(0.18),
              highlightColor: const Color(0xFF9F342C).withOpacity(0.08),
              onTap: () => _printSingleOrder(orderId, orderNumber: orderNumber),
              child: Ink(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.print_outlined,
                  size: 40,
                  color: Color(0xFF9F342C),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _applySearchFilter() {
    if (!mounted) return;
    final q = _currentSearch.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        orders = _allOrders.take(10).toList();
      });
      return;
    }
    final filtered = _allOrders.where((o) {
      final orderId = (o["order_id"] ?? o["order_number"] ?? "").toString();
      final txnId = (o["transaction_id"] ?? "").toString();
      return orderId.toLowerCase().contains(q) ||
          txnId.toLowerCase().contains(q);
    }).toList();
    setState(() {
      orders = filtered.take(10).toList();
    });
  }

  // --- Date Range Helper (Logic untouched) ---
  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF9F342C)),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        filter = "custom";
        customRange = picked;
        loading = true;
      });
      _load();
    }
  }

  Widget _buildDateLabel() {
    return Text(
      "${DateFormat('dd MMM').format(customRange!.start)} - ${DateFormat('dd MMM').format(customRange!.end)}",
      style: const TextStyle(
        color: Colors.orange,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    );
  }
}

// Data Classes & Helper Methods (Logic Untouched)
class _ParsedOrder {
  final List<Map<String, dynamic>> items;
  final String? paymentMode;
  final num? taxAmount;
  final num? discountAmount;
  const _ParsedOrder({
    required this.items,
    this.paymentMode,
    this.taxAmount,
    this.discountAmount,
  });
}

class _CategorySummaryPayload {
  final List<Map<String, dynamic>> categoryTotals;
  final Map<String, List<Map<String, dynamic>>> itemsByCategory;
  final int totalOrders;
  final int totalItems;
  final num totalAmount;
  final String? restaurantName;
  const _CategorySummaryPayload({
    required this.categoryTotals,
    required this.itemsByCategory,
    required this.totalOrders,
    required this.totalItems,
    required this.totalAmount,
    this.restaurantName,
  });
}

_ParsedOrder _parseOrderDetails(dynamic data) {
  Map order = {};
  Map? dataMap;
  if (data is Map) {
    dataMap = data;
    final dynamic raw =
        data["order"] ?? data["data"]?["order"] ?? data["data"] ?? data;
    if (raw is Map) order = raw;
  }
  final List rawItems = (order["order_items"] ??
      order["items"] ??
      order["orderItems"] ??
      dataMap?["order_items"] ??
      []) as List;
  final items = rawItems.map<Map<String, dynamic>>((item) {
    final map = item is Map ? item : {};
    final nested = map["item"] is Map ? map["item"] as Map : const {};
    final qty = map["qty"] ?? map["quantity"] ?? map["pivot"]?["quantity"] ?? 1;
    final price = map["price"] ??
        map["unit_price"] ??
        map["pivot"]?["price"] ??
        nested["price"] ??
        0;
    final name = map["name"] ?? nested["name"] ?? map["title"] ?? "Item";
    final image = map["item_photo_url"] ??
        map["image_url"] ??
        map["image"] ??
        nested["item_photo_url"] ??
        nested["image_url"] ??
        nested["image"];
    final category = map["category_name"] ??
        map["category"] ??
        nested["category_name"] ??
        nested["category"] ??
        "";
    return {
      "qty": num.tryParse(qty.toString()) ?? 1,
      "price": num.tryParse(price.toString()) ?? 0,
      "name": name.toString(),
      "category": category.toString(),
      "image": image?.toString(),
    };
  }).toList();
  final paymentMode = order["payment_mode"] ??
      order["paymentMethod"] ??
      order["payment_method"] ??
      order["payment_status"] ??
      "PAID";
  final taxAmount =
      order["tax"] ?? order["tax_amount"] ?? order["gst"] ?? order["total_tax"];
  final discountAmount = order["discount"] ?? order["discount_amount"] ?? 0;
  return _ParsedOrder(
    items: items,
    paymentMode: paymentMode?.toString(),
    taxAmount: taxAmount is num ? taxAmount : num.tryParse("$taxAmount"),
    discountAmount: discountAmount is num
        ? discountAmount
        : num.tryParse("$discountAmount"),
  );
}
