import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:api_selfxo_project/printer/printer_s.dart';
import 'package:intl/intl.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/core/india_time.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/order_utils.dart';

class OrdersHistoryTab extends StatefulWidget {
  const OrdersHistoryTab({super.key});

  @override
  State<OrdersHistoryTab> createState() => _OrdersHistoryTabState();
}

class _OrdersHistoryTabState extends State<OrdersHistoryTab>
    with AutomaticKeepAliveClientMixin {
  bool loading = true;
  bool _loadingInFlight = false;
  bool _hasLoaded = false;
  String? _lastRequestKey;
  int _requestSeq = 0;
  int _activeRequestId = 0;
  List allOrders = [];
  List filteredOrders = [];
  _OrderStatusFilter statusFilter = _OrderStatusFilter.all;
  final PrinterService _printerService = PrinterService();

  // Filters
  _DateRangeFilter dateRangeFilter = _DateRangeFilter.today;
  final TextEditingController searchController = TextEditingController();
  String searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadOrders(force: true, component: "init");
    searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  void _goToWelcome() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  // ================= LOAD DATA =================
  Future<void> _loadOrders({bool force = false, String? component}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final branchId = _readPrefString(prefs, "branch_id");
      final restaurantId = _readPrefString(prefs, "restaurant_id");
      final machineScope = _MachineOrderScope.fromPrefs(prefs);

      final rangeKey = _dateRangeValue(dateRangeFilter);
      final statusKey = _statusFilterValue(statusFilter);
      final requestKey =
          "${branchId ?? ''}|${restaurantId ?? ''}|${machineScope.cacheKey}|$rangeKey|$statusKey";
      if (!force && _hasLoaded && _lastRequestKey == requestKey) {
        return;
      }
      if (_loadingInFlight && _lastRequestKey == requestKey) {
        return;
      }
      if (component != null && component.trim().isNotEmpty) {}

      final requestId = ++_requestSeq;
      _activeRequestId = requestId;
      _loadingInFlight = true;
      if (mounted) setState(() => loading = true);

      final Map<String, dynamic> body = {
        "dateRange": _dateRangeValue(dateRangeFilter),
        "status": _statusFilterValue(statusFilter),
        if (machineScope.terminalId != null)
          "terminal_id": machineScope.terminalId,
        if (machineScope.deviceUuid != null)
          "device_uuid": machineScope.deviceUuid,
        if (machineScope.deviceId != null) "device_id": machineScope.deviceId,
      };

      List rawOrders;
      if (statusFilter == _OrderStatusFilter.cancelled) {
        rawOrders = await _fetchCancelledOrders(body);
      } else {
        rawOrders = await _fetchOrdersForHistory(body);
        if (!mounted || requestId != _activeRequestId) return;
      }
      if (statusFilter == _OrderStatusFilter.all) {
        rawOrders = await _withCancelledOrders(body, rawOrders);
        if (!mounted || requestId != _activeRequestId) return;
      }
      final dateFilteredOrders =
          rawOrders.where(_matchesSelectedDateRange).toList();
      final enforceMachineMetadata =
          dateFilteredOrders.any(_hasOrderOriginMetadata);
      var nextOrders = dateFilteredOrders
          .where(
            (order) => _belongsToThisMachine(
              order,
              machineScope,
              enforceMachineMetadata: enforceMachineMetadata,
            ),
          )
          .toList();
      if (dateFilteredOrders.isNotEmpty && nextOrders.isEmpty) {
        kioskLog(
          "Order history machine filter produced 0 visible orders from ${dateFilteredOrders.length}; showing date-filtered orders",
          tag: "ORDER_HISTORY",
        );
        nextOrders = dateFilteredOrders;
      }
      nextOrders.sort(_compareOrdersNewestFirst);
      kioskLog(
        "Order history loaded raw=${rawOrders.length} date=${dateFilteredOrders.length} visible=${nextOrders.length} range=$rangeKey status=$statusKey",
        tag: "ORDER_HISTORY",
      );
      if (mounted) {
        setState(() {
          allOrders = nextOrders;
          _applyLocalFilters();
        });
      } else {
        allOrders = nextOrders;
        _applyLocalFilters();
      }
      _lastRequestKey = requestKey;
      _hasLoaded = true;
    } catch (e) {
      if (mounted && _activeRequestId == _requestSeq) {
        allOrders = [];
        _hasLoaded = false;
      }
    } finally {
      if (_activeRequestId == _requestSeq) {
        _loadingInFlight = false;
        if (mounted) setState(() => loading = false);
      }
    }
  }

  Future<List> _fetchOrdersForHistory(Map<String, dynamic> body) async {
    try {
      final orders = await OrderUtils.getOrdersWithItems(
        dateRange: body["dateRange"]?.toString() ?? "today",
        status: "",
      );
      if (orders.isNotEmpty) return orders;
    } catch (e) {
      kioskLog(
        "Order history shared loader failed, falling back to AdminApi: $e",
        tag: "ORDER_HISTORY",
      );
    }

    final res = await AdminApi().getOrders(body);
    return _extractOrders(res.data);
  }

  // ================= FILTER LOGIC =================
  void _onSearchChanged() {
    setState(() {
      searchQuery = searchController.text.toLowerCase();
      _applyLocalFilters();
    });
  }

  void _applyLocalFilters() {
    Iterable temp = allOrders;
    if (statusFilter == _OrderStatusFilter.paid) {
      temp = temp.where((o) => _isPaidStatus(_getStatus(o)));
    } else if (statusFilter == _OrderStatusFilter.pending) {
      temp = temp.where((o) => _isPendingStatus(_getStatus(o)));
    } else if (statusFilter == _OrderStatusFilter.cancelled) {
      temp = temp.where((o) => _isCancelledStatus(_getStatus(o)));
    }
    if (searchQuery.isNotEmpty) {
      temp = temp.where((o) {
        final orderId = _getOrderLabel(o).toLowerCase();
        final txnId = _getTxnId(o).toLowerCase();
        if (orderId.contains(searchQuery) || txnId.contains(searchQuery)) {
          return true;
        }
        final dt = _parseOrderCreatedAt(o);
        if (dt != null) {
          final dateStr = DateFormat('dd MMM yyyy').format(dt).toLowerCase();
          if (dateStr.contains(searchQuery)) return true;
          if (searchQuery == "today") {
            return _isSameDay(_dateOnly(dt), _dateOnly(IndiaTime.now()));
          }
          if (searchQuery == "yesterday") {
            final y = _dateOnly(
              IndiaTime.now().subtract(const Duration(days: 1)),
            );
            return _isSameDay(_dateOnly(dt), y);
          }
          if (searchQuery.contains("week") || searchQuery.contains("7")) {
            return _isWithinLastDays(_dateOnly(dt), 7);
          }
          if (searchQuery.contains("14")) {
            return _isWithinLastDays(_dateOnly(dt), 14);
          }
        }
        return false;
      });
    }
    filteredOrders = temp.toList();
  }

  void _setStatusFilter(_OrderStatusFilter next) {
    setState(() {
      if (next == _OrderStatusFilter.all || statusFilter == next) {
        statusFilter = _OrderStatusFilter.all;
      } else {
        statusFilter = next;
      }
      _applyLocalFilters();
    });
    _loadOrders(component: "status_filter");
  }

  void _setDateRangeFilter(_DateRangeFilter next) {
    if (next == dateRangeFilter) {
      return;
    }
    setState(() {
      dateRangeFilter = next;
      _applyLocalFilters();
    });
    _loadOrders(component: "dropdown_filter");
  }

  // ================= UI BUILD =================
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
        elevation: 0,
        leadingWidth: 120,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Image.asset(
              "assets/self.png",
              height: 36,
              fit: BoxFit.contain,
            ),
          ),
        ),
        title: const Text(
          "Order History",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            onPressed: _goToWelcome,
            icon: const Icon(Icons.logout_rounded),
            color: Colors.white,
            tooltip: "Exit",
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: "Search by Order ID or Transaction...",
                prefixIcon: const Icon(Icons.search, color: Color(0xFF9F342C)),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: searchController.clear,
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF9F342C)),
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  return false;
                },
                child: RefreshIndicator(
                  onRefresh: () =>
                      _loadOrders(force: true, component: "pull_refresh"),
                  color: const Color(0xFF9F342C),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(child: _buildDateRangeFilters()),
                      SliverToBoxAdapter(child: _buildStatusSummaryFilters()),
                      SliverToBoxAdapter(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 16,
                          ),
                          color: const Color(0xFF9F342C).withOpacity(0.05),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.calendar_month,
                                size: 14,
                                color: Color(0xFF9F342C),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _rangeLabel(dateRangeFilter),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF9F342C),
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                "${filteredOrders.length} results",
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (filteredOrders.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildEmptyState(),
                        )
                      else
                        SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final crossAxisCount =
                                constraints.crossAxisExtent < 700 ? 2 : 3;
                            return SliverGrid(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) =>
                                    _buildOrderCard(filteredOrders[index]),
                                childCount: filteredOrders.length,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio:
                                    constraints.crossAxisExtent < 700
                                        ? 0.85
                                        : 1.2,
                              ),
                            );
                          },
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            "${filteredOrders.length} orders",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 80)),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildOrderCard(dynamic o) {
    final status = _getStatus(o);
    final amount = _getAmount(o);
    final dateStr = _formatOrderDate(o);
    final imageUrl = _getItemImage(o);
    final orderLabel = _getOrderLabel(o);
    final paymentMode = _getPaymentMode(o);

    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int thumbCache = (40 * dpr).round().clamp(1, 512);

    return InkWell(
      onTap: () => _showOrderDetailsDialog(o),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Color(0xFFFAF7F3)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey.shade100),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  if (imageUrl != null && imageUrl.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        imageUrl,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        cacheWidth: thumbCache,
                        cacheHeight: thumbCache,
                        errorBuilder: (_, __, ___) => Container(
                          width: 40,
                          height: 40,
                          color: Colors.grey.shade100,
                          child: const Icon(Icons.image_not_supported),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.image, color: Colors.grey),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Order #${orderLabel.isNotEmpty ? orderLabel : "-"}",
                          maxLines: 2,
                          softWrap: true,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          dateStr,
                          maxLines: 2,
                          softWrap: true,
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _buildStatusBadge(status, maxWidth: 200),
                ],
              ),
              const Divider(height: 18),
              Row(
                children: [
                  const Icon(
                    Icons.receipt_long,
                    size: 12,
                    color: Colors.blueGrey,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Text(
                            "TXN: ${_getTxnId(o)}",
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.blueGrey,
                            ),
                            maxLines: 3,
                            softWrap: true,
                          ),
                        ),
                        if (paymentMode.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Text(
                              "Payment: ${paymentMode.toUpperCase()}",
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                              ),
                              maxLines: 2,
                              softWrap: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  "₹${amount.toStringAsFixed(2)}",
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: Color(0xFF9F342C),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final bg = selected ? color.withOpacity(0.12) : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(selected ? 0.25 : 0.12)),
          gradient: selected
              ? LinearGradient(
                  colors: [color.withOpacity(0.22), color.withOpacity(0.06)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: color.withOpacity(selected ? 0.25 : 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 12),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 7.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSummaryFilters() {
    final successfulCount =
        allOrders.where((order) => _isPaidStatus(_getStatus(order))).length;
    final pendingCount =
        allOrders.where((order) => _isPendingStatus(_getStatus(order))).length;
    final cancelledCount = allOrders
        .where((order) => _isCancelledStatus(_getStatus(order)))
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: _summaryCard(
              title: "All",
              value: allOrders.length.toString(),
              color: const Color(0xFF607D8B),
              icon: Icons.receipt_long_rounded,
              selected: statusFilter == _OrderStatusFilter.all,
              onTap: () => _setStatusFilter(_OrderStatusFilter.all),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryCard(
              title: "Successful",
              value: successfulCount.toString(),
              color: const Color(0xFF1B8E3E),
              icon: Icons.check_circle_rounded,
              selected: statusFilter == _OrderStatusFilter.paid,
              onTap: () => _setStatusFilter(_OrderStatusFilter.paid),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryCard(
              title: "Pending",
              value: pendingCount.toString(),
              color: Colors.orange,
              icon: Icons.hourglass_bottom_rounded,
              selected: statusFilter == _OrderStatusFilter.pending,
              onTap: () => _setStatusFilter(_OrderStatusFilter.pending),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryCard(
              title: "Cancelled",
              value: cancelledCount.toString(),
              color: Colors.red,
              icon: Icons.cancel_rounded,
              selected: statusFilter == _OrderStatusFilter.cancelled,
              onTap: () => _setStatusFilter(_OrderStatusFilter.cancelled),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _printOrderFromHistory(
    dynamic o, {
    List<Map<String, dynamic>>? items,
  }) async {
    final orderId = _resolveOrderId(o, orderPk: _getOrderPk(o));
    final orderNumber = _getOrderLabel(o);
    if (orderId <= 0 && orderNumber.isEmpty) {
      _showSnack("Invalid order ID", Colors.red);
      return;
    }

    List<Map<String, dynamic>> finalItems = items ?? [];
    dynamic res;

    try {
      try {
        res = await AdminApi().getOrder(
          orderNumber.isEmpty ? orderId.toString() : orderNumber,
        );
      } catch (_) {
        if (orderId > 0) {
          res = await KioskApi().getOrderDetails(orderId);
        }
      }
      final data = res?.data ?? {};
      final normalized = data is Map ? Map<String, dynamic>.from(data) : {};
      final fetchedItems = _extractOrderItems(normalized);
      if (fetchedItems.isNotEmpty) {
        finalItems = fetchedItems;
      }
    } catch (_) {
      // ignore
    }

    if (finalItems.isEmpty && orderNumber.isEmpty) {
      _showSnack("Order items not found", Colors.red);
      return;
    }

    final rawData = res?.data ?? o;
    final txnId = _getTxnId(rawData);
    final orderDate = _parseOrderCreatedAt(rawData);
    final paymentMode = _getPaymentMode(rawData);

    final prefs = await SharedPreferences.getInstance();
    final fallbackRestaurant =
        prefs.getString("restaurant_name")?.trim().isNotEmpty == true
            ? prefs.getString("restaurant_name")!.trim()
            : "Restaurant";
    final restaurantName =
        _extractRestaurantName(rawData) ?? fallbackRestaurant;
    final address = _extractRestaurantAddress(rawData);
    final taxId = _extractTaxId(rawData);
    final showTaxInReceipt =
        prefs.getBool(KioskRestaurantMeta.showTaxInReceiptKey) ?? false;
    final taxAmount = _extractTaxAmount(rawData);
    final discountAmount = _extractDiscountAmount(rawData);
    final orderTypeLabel = _getOrderType(rawData);
    final parcelTotal = _extractParcelTotal(rawData, finalItems);

    try {
      await _printerService.printOrder(
        orderId: orderId,
        cartItems: finalItems,
        restaurantName: restaurantName,
        address: address,
        taxId: showTaxInReceipt ? taxId : null,
        transactionId: txnId,
        orderDate: orderDate,
        paymentMode: paymentMode,
        taxAmount: taxAmount,
        discountAmount: discountAmount,
        orderType: orderTypeLabel,
        orderNumber: orderNumber.isEmpty ? null : orderNumber,
        preserveBackendPrintFormat: orderNumber.isNotEmpty,
        removeTaxLines: !showTaxInReceipt,
        parcelTotalOverride: parcelTotal,
      );
      _showSnack("Print started", Colors.green);
    } catch (e, stackTrace) {
      kioskLogError(
        "Admin history print failed order=${orderNumber.isEmpty ? orderId : orderNumber}",
        tag: "ORDER_HISTORY",
        error: e,
        stackTrace: stackTrace,
      );
      _showSnack("Print failed", Colors.red);
    }
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
      final v = order[key];
      final num value = v is num ? v : num.tryParse("$v") ?? 0;
      if (value > 0) return value;
    }
    return 0;
  }

  void _showSnack(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  Widget _buildDateRangeFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 16, color: Color(0xFF9F342C)),
          const SizedBox(width: 8),
          const Text(
            "Date Filter",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<_DateRangeFilter>(
              value: dateRangeFilter,
              isExpanded: true,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
              ),
              items: [
                const DropdownMenuItem(
                  value: _DateRangeFilter.today,
                  child: Text("Today"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.yesterday,
                  child: Text("Yesterday"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.thisWeek,
                  child: Text("This Week"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.lastWeek,
                  child: Text("Last Week"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.last7Days,
                  child: Text("Last 7 Days"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.currentMonth,
                  child: Text("This Month"),
                ),
                const DropdownMenuItem(
                  value: _DateRangeFilter.lastMonth,
                  child: Text("Last Month"),
                ),
              ],
              onChanged: (val) {
                if (val == null) return;
                _setDateRangeFilter(val);
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showOrderDetailsDialog(dynamic o) {
    final orderLabel = _getOrderLabel(o);
    String status = _getStatus(o);
    final amount = _getAmount(o);
    final time = _formatOrderDate(o);
    final txnId = _getTxnId(o);
    final paymentMode = _getPaymentMode(o);
    final orderPk = _getOrderPk(o);
    String orderTypeLabel = _getOrderType(o);
    bool loading = true;
    List<Map<String, dynamic>> items = [];
    bool started = false;
    bool cancelling = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, dialogSetState) {
          final media = MediaQuery.of(context);
          final dialogWidth =
              media.size.width * (media.size.width > 900 ? 0.82 : 0.94);
          final dialogHeight = media.size.height * 0.6;

          Future<void> loadDetails() async {
            if (started) return;
            started = true;
            try {
              dynamic res;
              final resolvedId = _resolveOrderId(o, orderPk: orderPk);

              if (resolvedId > 0) {
                try {
                  res = await AdminApi().getOrder(resolvedId.toString());
                } catch (_) {
                  res = await KioskApi().getOrderDetails(resolvedId);
                }
              }
              final data = res?.data ?? {};
              final normalized =
                  data is Map ? Map<String, dynamic>.from(data) : {};
              items = _extractOrderItems(normalized);
              if (items.isEmpty) {
                items = _extractOrderItems(o);
              }
              final detailedType = _getOrderType(normalized);
              if (detailedType.isNotEmpty && detailedType != "N/A") {
                orderTypeLabel = detailedType;
              }
              final detailedStatus = _getStatus(normalized);
              if (detailedStatus.trim().isNotEmpty) {
                status = detailedStatus;
              }
            } catch (_) {
              items = [];
            } finally {
              if (mounted) {
                dialogSetState(() => loading = false);
              }
            }
          }

          if (loading) {
            loadDetails();
          }

          final subtotal = items.fold<num>(
            0,
            (sum, i) => sum + (i["amount"] as num? ?? 0),
          );
          final total = amount > 0 ? amount : subtotal;
          final bool showDue = _isPendingStatus(status) ||
              status.contains("due") ||
              status.contains("unpaid");

          Future<void> cancelOrder() async {
            if (cancelling) return;
            final resolvedId = _resolveOrderId(o, orderPk: orderPk);
            if (resolvedId <= 0) return;
            dialogSetState(() => cancelling = true);
            try {
              await AdminApi().cancelOrder(resolvedId.toString());
              status = "cancelled";
              if (mounted) {
                setState(() {
                  _updateOrderStatusInList(resolvedId, status);
                  _applyLocalFilters();
                });
              }
              dialogSetState(() {});
            } catch (_) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Failed to cancel order"),
                  backgroundColor: Colors.red,
                ),
              );
            } finally {
              if (mounted) dialogSetState(() => cancelling = false);
            }
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 16,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
            contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    "Order Details of $orderLabel",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.center,
            actionsPadding: const EdgeInsets.only(bottom: 16),
            actions: [
              SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: loading
                      ? null
                      : () => _printOrderFromHistory(o, items: items),
                  icon: const Icon(Icons.print_rounded),
                  label: const Text(
                    "Print",
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9F342C),
                    foregroundColor: Colors.white,
                    elevation: 4,
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
            content: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDue)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.red.withOpacity(0.25),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: Colors.redAccent,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      "Payment Due. Tap to cancel this order.",
                                      style: TextStyle(
                                        color: Colors.red.shade700,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: cancelling ? null : cancelOrder,
                                    child: cancelling
                                        ? const SizedBox(
                                            height: 16,
                                            width: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text("Cancel"),
                                  ),
                                ],
                              ),
                            ),
                          if (showDue) const SizedBox(height: 12),
                          Row(
                            children: [
                              Icon(
                                Icons.access_time,
                                size: 14,
                                color: Colors.grey.shade600,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  time,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF9F342C,
                                  ).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF9F342C,
                                    ).withOpacity(0.2),
                                  ),
                                ),
                                child: Text(
                                  "${items.length} items",
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF9F342C),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _sectionHeader("Order Items"),
                          const SizedBox(height: 8),
                          _tableHeader(const [
                            "#",
                            "Name",
                            "Qty",
                            "Price",
                            "Amount",
                          ]),
                          const SizedBox(height: 6),
                          if (items.isEmpty)
                            const Text(
                              "No items found",
                              style: TextStyle(color: Colors.grey),
                            )
                          else
                            Column(
                              children: [
                                for (int i = 0; i < items.length; i++)
                                  _tableRow([
                                    "${i + 1}",
                                    items[i]["name"]?.toString() ?? "Item",
                                    "${items[i]["qty"] ?? 0}",
                                    _money(items[i]["price"] ?? 0),
                                    _money(items[i]["amount"] ?? 0),
                                  ]),
                              ],
                            ),
                          const SizedBox(height: 20),
                          _sectionHeader("Order Summary"),
                          const SizedBox(height: 8),
                          _summaryRow("Sub Total", _money(subtotal)),
                          const SizedBox(height: 6),
                          _summaryRow("Total", _money(total), bold: true),
                          const SizedBox(height: 20),
                          _sectionHeader("Payment Details"),
                          const SizedBox(height: 8),
                          _tableHeader(const [
                            "#",
                            "Transaction ID",
                            "Amount",
                          ], isPayment: true),
                          const SizedBox(height: 6),
                          _tableRow([
                            "1",
                            txnId,
                            _money(total),
                          ], isPayment: true),
                          const SizedBox(height: 12),
                          _statusDetailRow(status),
                          _detailRow("Date & Time", time, dense: true),
                          _detailRow(
                            "Order Type",
                            orderTypeLabel.isEmpty ? "N/A" : orderTypeLabel,
                            dense: true,
                          ),
                          _detailRow(
                            "Payment",
                            paymentMode.isEmpty
                                ? "N/A"
                                : paymentMode.toUpperCase(),
                            dense: true,
                          ),
                        ],
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool dense = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: dense ? 11 : 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: dense ? 12 : 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
  }

  Widget _tableHeader(List<String> headers, {bool isPayment = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: isPayment
            ? [
                SizedBox(width: 24, child: Text(headers[0])),
                Expanded(flex: 4, child: Text(headers[1])),
                Expanded(child: Text(headers[2], textAlign: TextAlign.end)),
              ]
            : [
                SizedBox(width: 24, child: Text(headers[0])),
                Expanded(flex: 4, child: Text(headers[1])),
                Expanded(
                  flex: 1,
                  child: Text(headers[2], textAlign: TextAlign.center),
                ),
                Expanded(
                  flex: 2,
                  child: Text(headers[3], textAlign: TextAlign.center),
                ),
                Expanded(
                  flex: 2,
                  child: Text(headers[4], textAlign: TextAlign.end),
                ),
              ],
      ),
    );
  }

  Widget _tableRow(List<String> cols, {bool isPayment = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(
        children: isPayment
            ? [
                SizedBox(width: 24, child: Text(cols[0])),
                Expanded(
                  flex: 4,
                  child: Text(cols[1], maxLines: 3, softWrap: true),
                ),
                Expanded(child: Text(cols[2], textAlign: TextAlign.end)),
              ]
            : [
                SizedBox(width: 24, child: Text(cols[0])),
                Expanded(
                  flex: 4,
                  child: Text(cols[1], maxLines: 4, softWrap: true),
                ),
                Expanded(
                  flex: 1,
                  child: Text(cols[2], textAlign: TextAlign.center),
                ),
                Expanded(
                  flex: 2,
                  child: Text(cols[3], textAlign: TextAlign.center),
                ),
                Expanded(
                  flex: 2,
                  child: Text(cols[4], textAlign: TextAlign.end),
                ),
              ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String status, {bool dense = true}) {
    final s = _getStatusLabel(status).toLowerCase();
    Color color = Colors.grey;
    IconData icon = Icons.info_outline_rounded;
    if (s.contains("successful")) {
      color = const Color(0xFF1B8E3E);
      icon = Icons.check_circle_rounded;
    } else if (s.contains("pending") ||
        s.contains("processing") ||
        s.contains("unpaid") ||
        s.contains("due")) {
      color = Colors.orange;
      icon = Icons.hourglass_bottom_rounded;
    } else if (s.contains("failed") || s.contains("cancel")) {
      color = Colors.red;
      icon = Icons.cancel_rounded;
    }
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(dense ? 0.12 : 0.16),
        borderRadius: BorderRadius.circular(dense ? 8 : 10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 12 : 14, color: color),
          SizedBox(width: dense ? 4 : 6),
          Text(
            _getStatusLabel(status).toUpperCase(),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: dense ? 10 : 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusDetailRow(String status) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              "Status",
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _statusChip(status, dense: false),
        ],
      ),
    );
  }

  String _money(num value) => "₹${value.toStringAsFixed(0)}";

  String _getOrderType(dynamic data) {
    if (data == null) return "N/A";
    dynamic raw;
    if (data is Map) {
      raw = data["order_type"] ??
          data["orderType"] ??
          data["order_mode"] ??
          data["orderMode"] ??
          data["type"] ??
          data["order_for"] ??
          data["orderFor"] ??
          data["service_type"] ??
          data["serviceType"];
      if (raw == null && data["order"] is Map) {
        final order = data["order"] as Map;
        raw = order["order_type"] ??
            order["orderType"] ??
            order["order_mode"] ??
            order["orderMode"] ??
            order["type"] ??
            order["order_for"] ??
            order["orderFor"] ??
            order["service_type"] ??
            order["serviceType"];
      }
    }

    if (raw == null) return "N/A";
    if (raw is num) {
      if (raw == 1) return "Dine In";
      if (raw == 2) return "Take Away";
      if (raw == 3) return "Delivery";
    }
    final value = raw.toString().toLowerCase();
    if (value.contains("dine")) return "Dine In";
    if (value.contains("take") || value.contains("pickup")) return "Take Away";
    if (value.contains("deliver")) return "Delivery";
    if (value.contains("counter")) return "Counter";
    if (value.isNotEmpty) {
      return value
          .split(RegExp(r"[ _-]+"))
          .map((w) => w.isEmpty ? w : "${w[0].toUpperCase()}${w.substring(1)}")
          .join(" ");
    }
    return "N/A";
  }

  List<Map<String, dynamic>> _extractOrderItems(dynamic data) {
    List<dynamic> raw = [];
    if (data is Map) {
      final candidates = [
        data["order_items"],
        data["items"],
        data["orderItems"],
        data["order_item_list"],
        data["orderItemList"],
        data["orderDetails"],
        data["order_details"],
      ];
      for (final c in candidates) {
        if (c is List) {
          raw = c;
          break;
        }
        if (c is Map && c["data"] is List) {
          raw = c["data"];
          break;
        }
      }
      if (raw.isEmpty && data["data"] is Map) {
        final nested = data["data"];
        final nestedCandidates = [
          nested["order_items"],
          nested["items"],
          nested["orderDetails"],
          nested["order_details"],
        ];
        for (final c in nestedCandidates) {
          if (c is List) {
            raw = c;
            break;
          }
          if (c is Map && c["data"] is List) {
            raw = c["data"];
            break;
          }
        }
      }
    }

    if (raw.isEmpty) {
      final found = _findItemsList(data);
      if (found != null) raw = found;
    }

    final List<Map<String, dynamic>> items = [];

    void addItem(Map item) {
      final menuItem = item["menu_item"] is Map
          ? item["menu_item"] as Map
          : item["item"] is Map
              ? item["item"] as Map
              : null;
      final pivot = item["pivot"] is Map ? item["pivot"] as Map : null;
      final name = item["item_name"] ??
          item["name"] ??
          item["menu_item_name"] ??
          menuItem?["item_name"] ??
          menuItem?["name"] ??
          "Item";
      final qty = item["quantity"] ??
          item["qty"] ??
          item["count"] ??
          item["qty_ordered"] ??
          pivot?["quantity"] ??
          1;
      final price = item["price"] ??
          item["unit_price"] ??
          item["item_price"] ??
          item["rate"] ??
          pivot?["price"] ??
          menuItem?["price"] ??
          0;
      final amount = item["amount"] ??
          item["total"] ??
          item["total_price"] ??
          (qty is num ? qty * (price is num ? price : 0) : 0);
      final category = item["category_name"] ??
          item["category"] ??
          item["item_category"] ??
          menuItem?["category_name"] ??
          menuItem?["category"] ??
          menuItem?["item_category"] ??
          "";

      items.add({
        "name": name,
        "qty": qty is num ? qty : num.tryParse(qty.toString()) ?? 0,
        "price": price is num ? price : num.tryParse(price.toString()) ?? 0,
        "amount": amount is num ? amount : num.tryParse(amount.toString()) ?? 0,
        "category": category.toString(),
      });
    }

    if (raw.isNotEmpty && raw.first is Map && raw.first["items"] is List) {
      // orderDetails structure
      for (final entry in raw) {
        if (entry is Map && entry["items"] is List) {
          for (final it in entry["items"]) {
            if (it is Map) addItem(it);
          }
        }
      }
    } else {
      for (final it in raw) {
        if (it is Map) addItem(it);
      }
    }

    return items;
  }

  List<dynamic>? _findItemsList(dynamic value) {
    if (value is List) {
      if (_looksLikeItemsList(value)) return value;
      for (final item in value) {
        final found = _findItemsList(item);
        if (found != null) return found;
      }
      return null;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        final found = _findItemsList(entry.value);
        if (found != null) return found;
      }
    }
    return null;
  }

  bool _looksLikeItemsList(List<dynamic> list) {
    if (list.isEmpty) return false;
    final first = list.first;
    if (first is! Map) return false;
    final keys = first.keys.map((k) => k.toString()).toList();
    const hints = [
      "item_name",
      "menu_item_name",
      "menu_item",
      "name",
      "qty",
      "quantity",
      "price",
      "amount",
    ];
    return keys.any((k) => hints.contains(k));
  }

  Widget _buildStatusBadge(String status, {double maxWidth = 90}) {
    final label = _getStatusLabel(status);
    final normalized = label.toLowerCase();
    Color color = Colors.grey;
    if (normalized == "successful") color = Colors.green;
    if (normalized == "pending") color = Colors.orange;
    if (normalized == "cancelled" || normalized == "failed") color = Colors.red;

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 60, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text(
            "No matching orders found",
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  double _toDouble(dynamic v) =>
      v == null ? 0.0 : double.tryParse(v.toString()) ?? 0.0;

  int _toIntSafe(dynamic v) => v == null ? 0 : int.tryParse(v.toString()) ?? 0;

  String? _readPrefString(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _startOfWeek(DateTime d) {
    final local = _dateOnly(d);
    return local.subtract(Duration(days: local.weekday - 1));
  }

  bool _matchesSelectedDateRange(dynamic order) {
    final dt = _parseOrderCreatedAt(order);
    if (dt == null) return true;

    final date = _dateOnly(dt);
    final now = _dateOnly(IndiaTime.now());
    switch (dateRangeFilter) {
      case _DateRangeFilter.today:
        return _isSameDay(date, now);
      case _DateRangeFilter.yesterday:
        return _isSameDay(date, now.subtract(const Duration(days: 1)));
      case _DateRangeFilter.thisWeek:
        final start = _startOfWeek(now);
        final end = start.add(const Duration(days: 6));
        return !date.isBefore(start) && !date.isAfter(end);
      case _DateRangeFilter.lastWeek:
        final start = _startOfWeek(now).subtract(const Duration(days: 7));
        final end = start.add(const Duration(days: 6));
        return !date.isBefore(start) && !date.isAfter(end);
      case _DateRangeFilter.last7Days:
        final start = now.subtract(const Duration(days: 6));
        return !date.isBefore(start) && !date.isAfter(now);
      case _DateRangeFilter.currentMonth:
        return date.year == now.year && date.month == now.month;
      case _DateRangeFilter.lastMonth:
        final previous = DateTime(now.year, now.month - 1, 1);
        return date.year == previous.year && date.month == previous.month;
    }
  }

  int _compareOrdersNewestFirst(dynamic a, dynamic b) {
    final aDate = _parseOrderCreatedAt(a);
    final bDate = _parseOrderCreatedAt(b);
    if (aDate != null && bDate != null) return bDate.compareTo(aDate);
    if (aDate != null) return -1;
    if (bDate != null) return 1;
    return _getOrderLabel(b).compareTo(_getOrderLabel(a));
  }

  bool _isWithinLastDays(DateTime dt, int days) {
    if (days <= 0) return false;
    final now = IndiaTime.now();
    final end = _dateOnly(now);
    final start = _dateOnly(now.subtract(Duration(days: days - 1)));
    return !dt.isBefore(start) && !dt.isAfter(end);
  }

  String _dateRangeValue(_DateRangeFilter range) {
    switch (range) {
      case _DateRangeFilter.today:
        return "today";
      case _DateRangeFilter.yesterday:
        return "yesterday";
      case _DateRangeFilter.thisWeek:
        return "thisWeek";
      case _DateRangeFilter.lastWeek:
        return "lastWeek";
      case _DateRangeFilter.last7Days:
        return "last7Days";
      case _DateRangeFilter.currentMonth:
        return "currentMonth";
      case _DateRangeFilter.lastMonth:
        return "lastMonth";
    }
  }

  String _rangeLabel(_DateRangeFilter range) {
    switch (range) {
      case _DateRangeFilter.today:
        return "Today";
      case _DateRangeFilter.yesterday:
        return "Yesterday";
      case _DateRangeFilter.thisWeek:
        return "This Week";
      case _DateRangeFilter.lastWeek:
        return "Last Week";
      case _DateRangeFilter.last7Days:
        return "Last 7 Days";
      case _DateRangeFilter.currentMonth:
        return "This Month";
      case _DateRangeFilter.lastMonth:
        return "Last Month";
    }
  }

  String _statusFilterValue(_OrderStatusFilter status) {
    switch (status) {
      case _OrderStatusFilter.paid:
        return "paid";
      case _OrderStatusFilter.pending:
        return "unpaid";
      case _OrderStatusFilter.cancelled:
        return "cancelled";
      case _OrderStatusFilter.all:
        return "";
    }
  }

  DateTime? _parseOrderCreatedAt(dynamic o) {
    final raw = o["date_time_formatted"] ??
        o["dateTimeFormatted"] ??
        o["formatted_date_time"] ??
        o["formattedDateTime"] ??
        o["date_time"] ??
        o["dateTime"] ??
        o["created_at"] ??
        o["order_date"] ??
        o["date"] ??
        o["createdAt"] ??
        o["placed_at"] ??
        o["order_time"];
    return IndiaTime.parseDateValue(raw);
  }

  int _getOrderPk(dynamic o) {
    final raw = o["order_pk"] ?? o["order_id"] ?? o["id"] ?? o["orderId"];
    return int.tryParse(raw.toString()) ?? 0;
  }

  int _resolveOrderId(dynamic o, {int orderPk = 0}) {
    if (orderPk > 0) return orderPk;
    if (o is Map) {
      final direct = _toIntSafe(
        o["order_id"] ?? o["id"] ?? o["order_pk"] ?? o["orderId"],
      );
      if (direct > 0) return direct;
      final nested = o["order"];
      if (nested is Map) {
        final nestedId = _toIntSafe(
          nested["order_id"] ??
              nested["id"] ??
              nested["order_pk"] ??
              nested["orderId"],
        );
        if (nestedId > 0) return nestedId;
      }
    }
    final label = _getOrderLabel(o);
    final parsed = int.tryParse(label);
    return parsed ?? 0;
  }

  void _updateOrderStatusInList(int id, String status) {
    if (id <= 0) return;
    for (final o in allOrders) {
      if (o is! Map) continue;
      final oid = _resolveOrderId(o);
      if (oid == id) {
        o["status"] = status;
        o["order_status"] = status;
        o["payment_status"] = status;
      }
    }
  }

  List _extractOrders(dynamic data) {
    if (data is List) return data;
    if (data is! Map) return [];

    final map = data.map((key, value) => MapEntry("$key", value));
    for (final key in const [
      "orders",
      "recent_orders",
      "recentOrders",
      "data",
      "items",
      "results",
      "payload",
      "result",
    ]) {
      final value = map[key];
      if (value is List) return value;
      if (value is Map) {
        final nested = _extractOrders(value);
        if (nested.isNotEmpty) return nested;
      }
    }
    return [];
  }

  Future<List> _withCancelledOrders(
    Map<String, dynamic> body,
    List rawOrders,
  ) async {
    final cancelledOrders = await _fetchCancelledOrders(body);
    return _mergeUniqueOrders(rawOrders, cancelledOrders);
  }

  Future<List> _fetchCancelledOrders(Map<String, dynamic> body) async {
    var merged = <dynamic>[];
    for (final status in const ["cancelled", "canceled"]) {
      try {
        final res = await AdminApi().getOrders({...body, "status": status});
        final cancelledOrders = _extractOrders(res.data);
        if (cancelledOrders.isEmpty) continue;
        merged = _mergeUniqueOrders(merged, cancelledOrders);
        kioskLog(
          "Order history loaded ${cancelledOrders.length} $status orders",
          tag: "ORDER_HISTORY",
        );
      } catch (e) {
        kioskLog(
          "Order history $status fetch skipped: $e",
          tag: "ORDER_HISTORY",
        );
      }
    }
    return merged;
  }

  List _mergeUniqueOrders(List first, List second) {
    final seen = <String>{};
    final merged = <dynamic>[];
    for (final order in [...first, ...second]) {
      final key = _orderMergeKey(order);
      if (seen.add(key)) merged.add(order);
    }
    return merged;
  }

  String _orderMergeKey(dynamic order) {
    if (order is Map) {
      for (final key in const [
        "order_number",
        "order_no",
        "invoice_number",
        "number",
      ]) {
        final value = order[key]?.toString().trim();
        if (value != null &&
            value.isNotEmpty &&
            value.toLowerCase() != "null") {
          return "number:$value";
        }
      }
      for (final key in const ["id", "order_id", "order_pk", "orderId"]) {
        final value = order[key]?.toString().trim();
        if (value != null && value.isNotEmpty && value != "0") {
          return "id:$value";
        }
      }
    }
    return "identity:${identityHashCode(order)}";
  }

  bool _belongsToThisMachine(
    dynamic order,
    _MachineOrderScope scope, {
    required bool enforceMachineMetadata,
  }) {
    if (order is! Map) return true;

    final values = _readNestedValues(order, const [
      "terminal_id",
      "terminalId",
      "kiosk_terminal_id",
      "kioskTerminalId",
      "device_id",
      "deviceId",
      "device_uuid",
      "deviceUuid",
      "terminal_uuid",
      "terminalUuid",
      "kiosk_id",
      "kioskId",
      "terminal_name",
      "terminalName",
      "kiosk_name",
      "kioskName",
    ]).map((value) => value.toString().trim().toLowerCase()).toList();

    final hasMachineMetadata = values.isNotEmpty;
    if (values.any(scope.matches)) return true;

    final sourceValues = _readNestedValues(order, const [
      "source",
      "order_source",
      "orderSource",
      "channel",
      "sales_channel",
      "salesChannel",
      "platform",
      "created_from",
      "createdFrom",
      "origin",
    ]).map((value) => value.toString().trim().toLowerCase()).toList();

    final hasKioskSource = sourceValues.any(_isKioskSource);
    final hasPosSource = sourceValues.any(_isPosSource);

    if (hasMachineMetadata) return false;
    if (hasKioskSource && !hasPosSource) return true;
    if (hasPosSource) return false;

    return !enforceMachineMetadata;
  }

  bool _hasOrderOriginMetadata(dynamic order) {
    if (order is! Map) return false;
    final machineValues = _readNestedValues(order, const [
      "terminal_id",
      "terminalId",
      "kiosk_terminal_id",
      "kioskTerminalId",
      "device_id",
      "deviceId",
      "device_uuid",
      "deviceUuid",
      "terminal_uuid",
      "terminalUuid",
      "kiosk_id",
      "kioskId",
      "terminal_name",
      "terminalName",
      "kiosk_name",
      "kioskName",
    ]);
    if (machineValues.isNotEmpty) return true;
    return _readNestedValues(order, const [
      "source",
      "order_source",
      "orderSource",
      "channel",
      "sales_channel",
      "salesChannel",
      "platform",
      "created_from",
      "createdFrom",
      "origin",
    ]).isNotEmpty;
  }

  bool _isKioskSource(String value) {
    if (value.isEmpty) return false;
    return value == "kiosk" ||
        value == "selfx" ||
        value == "self_order" ||
        value == "self-order" ||
        value.contains("kiosk") ||
        value.contains("self order") ||
        value.contains("self_order");
  }

  bool _isPosSource(String value) {
    if (value.isEmpty) return false;
    return value == "pos" ||
        value == "counter" ||
        value == "cashier" ||
        value == "staff" ||
        value.contains("point of sale") ||
        value.contains("pos") ||
        value.contains("cashier") ||
        value.contains("staff");
  }

  String _getOrderLabel(dynamic o) {
    final label = o["order_number"] ??
        o["order_no"] ??
        o["invoice_number"] ??
        o["id"] ??
        "";
    return label.toString().trim();
  }

  String _getPaymentMode(dynamic o) {
    final mode = _readNestedValue(o, const [
          "payment_mode",
          "paymentMode",
          "payment_method",
          "paymentMethod",
          "gateway",
          "provider",
          "method",
        ]) ??
        "";
    return mode.toString().trim();
  }

  String _getStatus(dynamic o) {
    final paymentStatuses = _readNestedValues(o, const [
      "payment_status",
      "paymentStatus",
      "payment_state",
      "paymentState",
      "transaction_status",
      "transactionStatus",
    ]).map((value) => value.toString().trim()).toList();
    final paymentStatus =
        paymentStatuses.isNotEmpty ? paymentStatuses.first : null;
    final orderStatus = _readNestedValue(o, const [
      "status",
      "order_status",
      "orderStatus",
      "state",
    ])?.toString().trim();
    final paidFlags = _readNestedBools(o, const [
      "paid",
      "is_paid",
      "isPaid",
      "payment_success",
      "paymentSuccess",
      "success",
    ]);

    if (_isCancelledStatus(orderStatus ?? "")) return "cancelled";
    if (paymentStatuses.any(_isCancelledStatus)) return "cancelled";
    if (paidFlags.contains(true) || paymentStatuses.any(_isPaidStatus)) {
      return "successful";
    }
    if (paymentStatuses.any(_isFailedStatus)) return "failed";
    if (_isPaidStatus(orderStatus ?? "")) return "successful";
    if (_isFailedStatus(orderStatus ?? "")) return "failed";
    if (_isPendingStatus(paymentStatus ?? "")) return "pending";
    if (_isPendingStatus(orderStatus ?? "")) return "pending";

    final fallback = (paymentStatus?.isNotEmpty == true
            ? paymentStatus
            : orderStatus?.isNotEmpty == true
                ? orderStatus
                : "pending") ??
        "pending";
    return fallback.toLowerCase().replaceAll(" ", "_");
  }

  String _getStatusLabel(String status) {
    final normalized = status.toLowerCase().replaceAll("_", " ").trim();
    if (_isPaidStatus(normalized)) return "Successful";
    if (_isCancelledStatus(normalized)) return "Cancelled";
    if (_isFailedStatus(normalized)) return "Failed";
    if (_isPendingStatus(normalized)) return "Pending";
    if (normalized.isEmpty) return "Pending";
    return normalized
        .split(RegExp(r"\s+"))
        .where((part) => part.isNotEmpty)
        .map((part) => "${part[0].toUpperCase()}${part.substring(1)}")
        .join(" ");
  }

  dynamic _readNestedValue(dynamic value, List<String> keys, {int depth = 4}) {
    final values = _readNestedValues(value, keys, depth: depth);
    return values.isEmpty ? null : values.first;
  }

  List<dynamic> _readNestedValues(
    dynamic value,
    List<String> keys, {
    int depth = 4,
  }) {
    final results = <dynamic>[];
    void collect(dynamic current, int remainingDepth) {
      if (current == null || remainingDepth <= 0) return;
      if (current is Map) {
        for (final key in keys) {
          if (current.containsKey(key)) {
            final direct = current[key];
            if (direct != null && direct.toString().trim().isNotEmpty) {
              results.add(direct);
            }
          }
        }
        for (final key in const [
          "payment",
          "transaction",
          "order",
          "data",
          "details",
        ]) {
          collect(current[key], remainingDepth - 1);
        }
      } else if (current is Iterable) {
        for (final item in current) {
          collect(item, remainingDepth - 1);
        }
      }
    }

    collect(value, depth);
    return results;
  }

  List<bool> _readNestedBools(dynamic value, List<String> keys,
      {int depth = 4}) {
    return _readNestedValues(value, keys, depth: depth)
        .map(_toBoolValue)
        .whereType<bool>()
        .toList();
  }

  bool? _toBoolValue(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return null;
    if (const {"1", "true", "yes", "y", "paid", "success", "successful"}
        .contains(text)) {
      return true;
    }
    if (const {"0", "false", "no", "n", "pending", "unpaid", "failed"}
        .contains(text)) {
      return false;
    }
    return null;
  }

  double _getAmount(dynamic o) {
    final v = o["grand_total"] ??
        o["total"] ??
        o["amount"] ??
        o["total_amount"] ??
        o["paid_amount"] ??
        0;
    return _toDouble(v);
  }

  String _formatOrderDate(dynamic o) {
    final dt = _parseOrderCreatedAt(o);
    if (dt == null) return "N/A";
    return IndiaTime.formatWall(dt, 'dd MMM yyyy, hh:mm a');
  }

  String _getTxnId(dynamic o) {
    final id = _findTxnId(o);
    if (id == null) return "N/A";
    final s = id.toString().trim();
    return s.isEmpty ? "N/A" : s;
  }

  String? _extractRestaurantName(dynamic data) {
    const keys = [
      "restaurant_name",
      "restaurantName",
      "store_name",
      "branch_name",
      "outlet_name",
      "name",
    ];
    final map = data is Map ? data : null;
    final direct = _stringFromMap(map, keys);
    if (direct != null) return direct;
    final containers = [
      map?["restaurant"],
      map?["branch"],
      map?["store"],
      map?["outlet"],
      map?["company"],
      map?["data"],
      map?["order"],
    ];
    for (final c in containers) {
      final found = _stringFromMap(c is Map ? c : null, keys);
      if (found != null) return found;
    }
    return null;
  }

  String? _extractRestaurantAddress(dynamic data) {
    const keys = [
      "address",
      "restaurant_address",
      "store_address",
      "branch_address",
      "location",
    ];
    final map = data is Map ? data : null;
    final direct = _stringFromMap(map, keys);
    if (direct != null) return direct;
    final containers = [
      map?["restaurant"],
      map?["branch"],
      map?["store"],
      map?["outlet"],
      map?["company"],
      map?["data"],
      map?["order"],
    ];
    for (final c in containers) {
      final found = _stringFromMap(c is Map ? c : null, keys);
      if (found != null) return found;
    }
    return null;
  }

  String? _extractTaxId(dynamic data) {
    const keys = [
      "gst_number",
      "gst",
      "tax_id",
      "taxId",
      "gstin",
    ];
    final map = data is Map ? data : null;
    final direct = _stringFromMap(map, keys);
    if (direct != null) return direct;
    final containers = [
      map?["restaurant"],
      map?["branch"],
      map?["store"],
      map?["outlet"],
      map?["company"],
      map?["data"],
      map?["order"],
    ];
    for (final c in containers) {
      final found = _stringFromMap(c is Map ? c : null, keys);
      if (found != null) return found;
    }
    return null;
  }

  num? _extractTaxAmount(dynamic data) {
    const keys = ["tax", "tax_amount", "gst", "total_tax"];
    final map = data is Map ? data : null;
    final direct = _numFromMap(map, keys);
    if (direct != null) return direct;
    final order = map?["order"];
    return _numFromMap(order is Map ? order : null, keys);
  }

  num? _extractDiscountAmount(dynamic data) {
    const keys = ["discount", "discount_amount"];
    final map = data is Map ? data : null;
    final direct = _numFromMap(map, keys);
    if (direct != null) return direct;
    final order = map?["order"];
    return _numFromMap(order is Map ? order : null, keys);
  }

  String? _stringFromMap(Map? data, List<String> keys) {
    if (data == null) return null;
    for (final k in keys) {
      final v = data[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  num? _numFromMap(Map? data, List<String> keys) {
    if (data == null) return null;
    for (final k in keys) {
      final v = data[k];
      if (v == null) continue;
      if (v is num) return v;
      final n = num.tryParse(v.toString());
      if (n != null) return n;
    }
    return null;
  }

  dynamic _findTxnId(dynamic value) {
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

  String? _getItemImage(dynamic o) {
    final url = _findImageUrl(o);
    if (url == null) return null;
    final s = url.toString().trim();
    return s.isEmpty ? null : s;
  }

  dynamic _findImageUrl(dynamic value) {
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
      if (value.containsKey("order_items")) {
        final nested = _findImageUrl(value["order_items"]);
        if (nested != null) return nested;
      }
      if (value.containsKey("items")) {
        final nested = _findImageUrl(value["items"]);
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

  String _normalizeImageUrl(String raw) {
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

  bool _isPendingStatus(String status) {
    final s = status.toLowerCase();
    if (s.isEmpty) return false;
    return s.contains("pending") ||
        s.contains("processing") ||
        s.contains("created") ||
        s.contains("initiated") ||
        s.contains("unpaid");
  }

  bool _isPaidStatus(String status) {
    final s = status.toLowerCase();
    if (s.isEmpty) return false;
    return s.contains("paid") ||
        s.contains("completed") ||
        s.contains("success") ||
        s.contains("successful") ||
        s.contains("captured") ||
        s.contains("settled");
  }

  bool _isFailedStatus(String status) {
    final s = status.toLowerCase();
    if (s.isEmpty) return false;
    return s.contains("failed") ||
        s.contains("failure") ||
        s.contains("declined") ||
        s.contains("expired") ||
        s.contains("void") ||
        s.contains("refund");
  }

  bool _isCancelledStatus(String status) {
    final s = status.toLowerCase();
    if (s.isEmpty) return false;
    return s.contains("cancel");
  }
}

enum _OrderStatusFilter { all, paid, pending, cancelled }

class _MachineOrderScope {
  final String? terminalId;
  final String? deviceUuid;
  final String? deviceId;
  final String? kioskName;

  const _MachineOrderScope({
    this.terminalId,
    this.deviceUuid,
    this.deviceId,
    this.kioskName,
  });

  factory _MachineOrderScope.fromPrefs(SharedPreferences prefs) {
    String? read(String key) {
      String? value;
      try {
        value = prefs.get(key)?.toString().trim();
      } catch (_) {
        value = null;
      }
      return value == null || value.isEmpty ? null : value;
    }

    return _MachineOrderScope(
      terminalId: read("terminal_id") ?? read("kiosk_terminal_id"),
      deviceUuid: read("device_uuid"),
      deviceId: read("device_id"),
      kioskName: read("kiosk_name"),
    );
  }

  String get cacheKey =>
      "${terminalId ?? ''}|${deviceUuid ?? ''}|${deviceId ?? ''}|${kioskName ?? ''}";

  bool matches(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return normalized == terminalId?.toLowerCase() ||
        normalized == deviceUuid?.toLowerCase() ||
        normalized == deviceId?.toLowerCase() ||
        normalized == kioskName?.toLowerCase();
  }
}

enum _DateRangeFilter {
  today,
  yesterday,
  thisWeek,
  lastWeek,
  last7Days,
  currentMonth,
  lastMonth,
}
