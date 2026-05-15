import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'payment_screen.dart';

// Note: Replace with your actual Welcome Screen import if needed
// import 'package:api_selfxo_project/screens/welcome_screen.dart';

class CartPage extends StatefulWidget {
  final List<Map<String, dynamic>> cart;
  final List<Map<String, dynamic>> recommendedProducts;
  final bool isActive;
  final String orderType;
  final Function(
    int id,
    String name,
    String category,
    int price,
    String image,
    int qty,
    Map<String, dynamic>? variation,
    List<Map<String, dynamic>> modifiers,
    Rect? imageRect,
  ) onAddRecommended;
  final VoidCallback onBack;
  final VoidCallback onCartUpdated;

  const CartPage({
    super.key,
    required this.cart,
    required this.recommendedProducts,
    required this.isActive,
    required this.orderType,
    required this.onAddRecommended,
    required this.onBack,
    required this.onCartUpdated,
  });

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> with TickerProviderStateMixin {
  static const Color kGreen = Color(0xFF9F342C);

  // 🔴 GST SETTINGS
  final bool gstEnabled = true;
  final double gstPercent = 5;
  bool gstExpanded = false;

  String _normalizeOrderType(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll("-", "_")
        .replaceAll(RegExp(r"\s+"), "_");
  }

  bool get _isTakeAway {
    final type = _normalizeOrderType(widget.orderType);
    return type == "pickup" || type == "takeaway" || type == "take_away";
  }

  late AnimationController _payController;
  late Animation<double> _payScale;
  int _lastCartCount = 0;
  final ScrollController _cartScrollController = ScrollController();
  VoidCallback? _maintenanceListener;
  @override
  void initState() {
    super.initState();
    _lastCartCount = widget.cart.length;
    _payController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _payScale = Tween<double>(
      begin: 1,
      end: 1.06,
    ).chain(CurveTween(curve: Curves.easeInOut)).animate(_payController);
    if (widget.cart.isNotEmpty && KioskConfig.enableDecorativeAnimations) {
      _payController.repeat(reverse: true);
    }

    _maintenanceListener = _handleMaintenanceTick;
    KioskMemoryService.instance.maintenanceTick.addListener(
      _maintenanceListener!,
    );
  }

  @override
  void didUpdateWidget(covariant CartPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.cart.length;
    if (count > 0 && _lastCartCount == 0) {
      _startPayBounce();
    } else if (count == 0 && _lastCartCount > 0) {
      _stopPayBounce();
    }
    _lastCartCount = count;
  }

  @override
  void dispose() {
    if (_payController.isAnimating) {
      _payController.stop(canceled: true);
    }
    _payController.dispose();
    _cartScrollController..dispose();
    if (_maintenanceListener != null) {
      KioskMemoryService.instance.maintenanceTick.removeListener(
        _maintenanceListener!,
      );
    }
    super.dispose();
  }

  @override
  void deactivate() {
    if (_payController.isAnimating) {
      _payController.stop(canceled: true);
    }
    super.deactivate();
  }

  void _startPayBounce() {
    if (!mounted) return;
    if (!KioskConfig.enableDecorativeAnimations) return;
    if (!_payController.isAnimating) {
      _payController.repeat(reverse: true);
    }
  }

  void _stopPayBounce() {
    if (!mounted) return;
    if (_payController.isAnimating) {
      _payController.stop();
      _payController.reset();
    }
  }

  void _handleMaintenanceTick() {
    if (!mounted) return;
    try {
      if (!KioskConfig.enableDecorativeAnimations) return;
      if (widget.cart.isEmpty) return;
      _payController.reset();
      _payController.repeat(reverse: true);
    } catch (_) {}
  }

  void _updateQty(int index, int newQty) {
    final int oldQty = _asInt(widget.cart[index]["qty"]);
    setState(() {
      if (newQty <= 0) {
        widget.cart.removeAt(index);
      } else {
        widget.cart[index] = {...widget.cart[index], "qty": newQty};
      }
    });
    widget.onCartUpdated();
    if (widget.cart.isNotEmpty) {
      _startPayBounce();
    }
    if (widget.cart.isEmpty) {
      _stopPayBounce();
      Future.microtask(widget.onBack);
    }
  }

  double _calculateSubtotal() {
    return widget.cart.fold<double>(0.0, (sum, item) {
      return sum + (_asDouble(item["price"]) * _asInt(item["qty"]));
    });
  }

  double _calculateParcelTotal() {
    if (!_isTakeAway) return 0.0;
    return widget.cart.fold<double>(0.0, (sum, item) {
      return sum + (_asDouble(item["take_away_charge"]) * _asInt(item["qty"]));
    });
  }

  double _calculateTotal() {
    return _calculateSubtotal() + _calculateParcelTotal();
  }

  double _calculateGstInclusive(double total) {
    if (!gstEnabled) return 0;
    return (total * gstPercent) / (100 + gstPercent);
  }

  double _calculateBaseAmount(double total) {
    return total - _calculateGstInclusive(total);
  }

  int _totalQtyForProduct(int id) {
    return widget.cart.fold<int>(
      0,
      (sum, item) => sum + (item["id"] == id ? _asInt(item["qty"]) : 0),
    );
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  double _asDouble(dynamic v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? "") ?? 0.0;
  }

  List<Map<String, dynamic>> _filteredRecommendations() {
    if (widget.cart.isEmpty) return [];
    final recs = widget.recommendedProducts
        .take(5)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return recs;
  }

  Rect? _rectFromContext(BuildContext? context) {
    if (context == null) return null;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached) return null;
    final topLeft = render.localToGlobal(Offset.zero);
    return topLeft & render.size;
  }

  void _addRecommended(Map<String, dynamic> item, Rect? imageRect) {
    final id = int.tryParse(item["id"].toString()) ?? 0;
    if (id == 0) return;
    final name =
        item["name"]?.toString() ?? item["item_name"]?.toString() ?? "";
    final category = item["category"]?.toString() ?? "";
    final price = int.tryParse(item["price"].toString()) ?? 0;
    final image =
        item["image"]?.toString() ?? item["item_photo_url"]?.toString() ?? "";
    final variation = item["variation"] as Map<String, dynamic>? ??
        (item["variations"] is List && (item["variations"] as List).isNotEmpty
            ? Map<String, dynamic>.from(item["variations"][0])
            : null);
    final modifiers = item["modifiers"] is List
        ? (item["modifiers"] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];

    final newQty = _totalQtyForProduct(id) + 1;
    widget.onAddRecommended(
      id,
      name,
      category,
      price,
      image,
      newQty,
      variation,
      modifiers,
      imageRect,
    );
    widget.onCartUpdated();
  }

  void _showStartOverDialog(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isTablet ? 40 : 26),
          ),
          contentPadding: EdgeInsets.all(isTablet ? 40 : 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(isTablet ? 30 : 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBAA30).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.restaurant_rounded,
                  color: const Color(0xFFFBAA30),
                  size: isTablet ? 100 : 50,
                ),
              ),
              SizedBox(height: isTablet ? 30 : 20),
              Text(
                "CANCEL ORDER?",
                style: TextStyle(
                  fontSize: isTablet ? 32 : 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 15),
              Text(
                "Are you sure you want to cancel this order\nand start again?",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isTablet ? 20 : 15.5,
                  color: Colors.black54,
                  height: 1.5,
                ),
              ),
              SizedBox(height: isTablet ? 45 : 30),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: isTablet ? 85 : 55,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: Colors.grey.shade300,
                            width: 2,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              isTablet ? 20 : 12,
                            ),
                          ),
                        ),
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: Icon(
                          Icons.close_rounded,
                          size: isTablet ? 22 : 18,
                          color: Colors.grey.shade700,
                        ),
                        label: Text(
                          "NO, KEEP",
                          style: TextStyle(
                            fontSize: isTablet ? 18 : 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: isTablet ? 20 : 12),
                  Expanded(
                    child: SizedBox(
                      height: isTablet ? 85 : 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFBAA30),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              isTablet ? 20 : 12,
                            ),
                          ),
                        ),
                        onPressed: () {
                          widget.cart.clear();
                          widget.onCartUpdated();
                          Navigator.pop(dialogContext);
                          widget.onBack();
                        },
                        child: Text(
                          "YES, CANCEL",
                          style: TextStyle(
                            fontSize: isTablet ? 18 : 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F5),
      appBar: AppBar(
        toolbarHeight: isTablet ? 100 : 80,
        backgroundColor: kGreen,
        elevation: 0,
        leadingWidth: isTablet ? 160 : 120,
        leading: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios,
                  color: Colors.white,
                  size: isTablet ? 30 : 24,
                ),
                onPressed: widget.onBack,
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: isTablet ? 96 : 72,
                    height: isTablet ? 46 : 36,
                    child: Image.asset(
                      "assets/self.png",
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        title: Text(
          "Your Cart (${widget.cart.length})",
          style: TextStyle(
            fontSize: isTablet ? 28 : 20,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: EdgeInsets.only(right: isTablet ? 20 : 12),
            child: SizedBox(
              height: isTablet ? 50 : 40,
              child: ElevatedButton.icon(
                onPressed: () => _showStartOverDialog(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFFFBAA30),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                icon: Icon(Icons.home, size: isTablet ? 22 : 18),
                label: Text(
                  "Start Again",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: isTablet ? 18 : 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _tableHeader(isTablet),
          Expanded(
            child: Scrollbar(
              controller: _cartScrollController,
              thumbVisibility: true,
              thickness: 5,
              radius: const Radius.circular(8),
              child: ListView.builder(
                controller: _cartScrollController,
                padding: const EdgeInsets.all(10),
                itemCount: widget.cart.length,
                itemBuilder: (context, i) =>
                    _cartItem(widget.cart[i], i, isTablet),
              ),
            ),
          ),
          _buildRecommendedSection(isTablet),
          _totalSection(isTablet),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, isTablet ? 30 : 20),
            child: Row(
              children: [
                SizedBox(
                  height: isTablet ? 80 : 60,
                  child: OutlinedButton.icon(
                    onPressed: widget.onBack,
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: isTablet ? 26 : 18,
                        vertical: isTablet ? 18 : 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(
                          color: Color.fromARGB(255, 86, 159, 44),
                          width: 1.5,
                        ),
                      ),
                    ),
                    icon: Icon(
                      Icons.add_circle_outline,
                      color: const Color.fromARGB(255, 96, 179, 45),
                      size: isTablet ? 28 : 22,
                    ),
                    label: Text(
                      "Add More Items",
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: isTablet ? 18 : 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      height: isTablet ? 64 : 52,
                      width: isTablet ? 220 : 170,
                      child: ScaleTransition(
                        scale: _payScale,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                            elevation: 4,
                            shadowColor: Colors.green.withOpacity(0.3),
                            padding: EdgeInsets.symmetric(
                              vertical: isTablet ? 14 : 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _goToPayment,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.shopping_cart,
                                  size: isTablet ? 20 : 16,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  "PROCEED TO PAY",
                                  style: TextStyle(
                                    fontSize: isTablet ? 16 : 12,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.6,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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

  Widget _tableHeader(bool isTablet) {
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int imagePx = ((isTablet ? 70 : 34) * dpr).round();
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: 12,
        horizontal: isTablet ? 24 : 8,
      ),
      color: const Color(0xFFE9F4EC),
      child: Row(
        children: [
          SizedBox(width: isTablet ? 80 : 50), // Matches image width + spacing
          _headerText("ITEM", 3, isTablet),
          _headerText("PRICE", 2, isTablet, true),
          _headerText(isTablet ? "QUANTITY" : "QTY", 2, isTablet, true),
          _headerText("TOTAL", 2, isTablet, true),
          _headerText(isTablet ? "ACTION" : "ACT", 1, isTablet, true),
        ],
      ),
    );
  }

  Widget _buildRecommendedSection(bool isTablet) {
    final borderRadius = BorderRadius.circular(5);
    final recs = _filteredRecommendations();

    if (widget.cart.isEmpty || recs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, isTablet ? 10 : 6, 16, 6),
      child: Container(
        decoration: BoxDecoration(
          color: const Color.fromARGB(255, 242, 220, 188),
          borderRadius: BorderRadius.circular(isTablet ? 24 : 16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== HEADER =====
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: isTablet ? 26 : 24,
                    color: const Color(0xFF22E6C7),
                  ),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (bounds) {
                      return const LinearGradient(
                        colors: [
                          Color(0xFF22E6C7),
                          Color(0xFF3A7BFF),
                          Color(0xFF9B4DFF),
                        ],
                      ).createShader(bounds);
                    },
                    child: Text(
                      "Recommended for You",
                      style: TextStyle(
                        fontSize: isTablet ? 24 : 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ===== HORIZONTAL SCROLL =====
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double cardWidth = isTablet ? 210 : 160;
                  final double cardHeight = isTablet ? 232 : 200;
                  final double imageHeight =
                      (cardHeight - (isTablet ? 76 : 68)).clamp(80, cardHeight);
                  final double dpr = MediaQuery.of(context).devicePixelRatio;
                  final int cacheWidth =
                      (cardWidth * dpr).round().clamp(1, 2048);
                  final int cacheHeight =
                      (imageHeight * dpr).round().clamp(1, 2048);

                  return SizedBox(
                    height: cardHeight,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: recs.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(width: isTablet ? 12 : 10),
                      itemBuilder: (_, index) {
                        final item = recs[index];
                        BuildContext? imageContext;
                        final name = item["name"]?.toString() ??
                            item["item_name"]?.toString() ??
                            "";
                        final price = item["price"] ?? 0;
                        final image = item["image"]?.toString() ?? "";

                        return SizedBox(
                          width: cardWidth,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.04),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // IMAGE
                                SizedBox(
                                  height: imageHeight,
                                  child: ClipRRect(
                                    borderRadius: borderRadius,
                                    child: Container(
                                      color: Colors.grey.shade100,
                                      child: Builder(
                                        builder: (ctx) {
                                          imageContext = ctx;
                                          return image.isNotEmpty
                                              ? Image.network(
                                                  image,
                                                  fit: BoxFit.cover,
                                                  width: double.infinity,
                                                  height: double.infinity,
                                                  cacheWidth: cacheWidth,
                                                  cacheHeight: cacheHeight,
                                                  errorBuilder: (_, __, ___) =>
                                                      const Center(
                                                    child: Icon(
                                                      Icons.fastfood,
                                                      size: 24,
                                                    ),
                                                  ),
                                                )
                                              : const Center(
                                                  child: Icon(
                                                    Icons.fastfood,
                                                    size: 24,
                                                  ),
                                                );
                                        },
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 6),

                                // NAME
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: isTablet ? 14 : 12,
                                  ),
                                ),

                                const SizedBox(height: 2),

                                // PRICE + ADD
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      "₹$price",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: kGreen,
                                        fontSize: isTablet ? 14 : 12,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 28,
                                      width: 28,
                                      child: ElevatedButton(
                                        onPressed: () => _addRecommended(
                                          item,
                                          _rectFromContext(imageContext),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          padding: EdgeInsets.zero,
                                          backgroundColor: kGreen,
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.add,
                                          size: 18,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerText(
    String label,
    int flex,
    bool isTablet, [
    bool center = false,
  ]) {
    return Expanded(
      flex: flex,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: center ? Alignment.center : Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: center ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontSize: isTablet ? 16 : 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _cartItem(Map<String, dynamic> item, int index, bool isTablet) {
    final int price = item["price"];
    final int qty = item["qty"];
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int imagePx = ((isTablet ? 70 : 34) * dpr).round();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: EdgeInsets.all(isTablet ? 20 : 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              item["image"],
              width: isTablet ? 70 : 34,
              height: isTablet ? 70 : 34,
              cacheWidth: imagePx,
              cacheHeight: imagePx,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.fastfood, size: isTablet ? 70 : 34),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              item["name"],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isTablet ? 18 : 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                "₹$price",
                style: TextStyle(fontSize: isTablet ? 18 : 13),
              ),
            ),
          ),

          // Fixed Quantity Selector for Mobile
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _iconTap(
                    Icons.remove,
                    Colors.red,
                    () => _updateQty(index, qty - 1),
                    isTablet,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      "$qty",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isTablet ? 20 : 15,
                      ),
                    ),
                  ),
                  _iconTap(
                    Icons.add,
                    Colors.green,
                    () => _updateQty(index, qty + 1),
                    isTablet,
                  ),
                ],
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                "₹${price * qty}",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: kGreen,
                  fontSize: isTablet ? 18 : 13,
                ),
              ),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              Icons.delete_outline,
              color: Color(0xFF9F342C),
              size: isTablet ? 30 : 20,
            ),
            onPressed: () {
              setState(() => widget.cart.removeAt(index));
              widget.onCartUpdated();
              if (widget.cart.isEmpty) widget.onBack();
            },
          ),
        ],
      ),
    );
  }

  Widget _totalSection(bool isTablet) {
    final subtotal = _calculateSubtotal();
    final parcelTotal = _calculateParcelTotal();
    final total = subtotal + parcelTotal;
    final gstAmount = _calculateGstInclusive(total);
    final baseAmount = _calculateBaseAmount(total);

    return Container(
      padding: EdgeInsets.all(isTablet ? 30 : 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          _summaryRow(
            "Grand Total",
            "₹${total.toStringAsFixed(2)}",
            isBold: true,
            fontSize: isTablet ? 27 : 22,
            color: const Color.fromARGB(255, 0, 0, 0),
            isTablet: isTablet,
          ),
          if (_isTakeAway && parcelTotal > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _summaryRow(
                "Parcel Charge",
                "₹${parcelTotal.toStringAsFixed(2)}",
                isSmall: true,
                isTablet: isTablet,
              ),
            ),
          const Divider(height: 20),
          if (gstEnabled) ...[
            InkWell(
              onTap: () => setState(() => gstExpanded = !gstExpanded),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        "GST Included",
                        style: TextStyle(
                          color: Colors.black54,
                          fontSize: isTablet ? 18 : 14,
                        ),
                      ),
                      Icon(
                        gstExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: isTablet ? 24 : 18,
                        color: Colors.black54,
                      ),
                    ],
                  ),
                  if (gstExpanded)
                    Text(
                      "₹${gstAmount.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: const Color.fromARGB(136, 255, 255, 255),
                        fontSize: isTablet ? 18 : 14,
                      ),
                    ),
                ],
              ),
            ),
            if (gstExpanded)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  children: [
                    _summaryRow(
                      "GST Amount",
                      "₹${gstAmount.toStringAsFixed(2)}",
                      isSmall: true,
                      isTablet: isTablet,
                    ),
                    const SizedBox(height: 6),
                    _summaryRow(
                      "Base Amount",
                      "₹${baseAmount.toStringAsFixed(2)}",
                      isSmall: true,
                      isTablet: isTablet,
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    bool isBold = false,
    double fontSize = 16,
    Color? color,
    bool isSmall = false,
    required bool isTablet,
  }) {
    double finalFontSize = isTablet ? (fontSize * 1.2) : fontSize;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: finalFontSize,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isSmall ? Colors.grey : Colors.black87,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: finalFontSize,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: color ?? (isSmall ? Colors.grey : Colors.black87),
          ),
        ),
      ],
    );
  }

  Widget _iconTap(
    IconData icon,
    Color color,
    VoidCallback onTap,
    bool isTablet,
  ) {
    final double size = isTablet ? 34 : 28;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: isTablet ? 20 : 18),
      ),
    );
  }

  void _goToPayment() {
    final total = _calculateTotal();
    if (total <= 0) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentScreen(
          cart: List<Map<String, dynamic>>.from(widget.cart),
          totalAmount: total.toInt(),
          orderType: widget.orderType,
        ),
      ),
    );
  }
}
