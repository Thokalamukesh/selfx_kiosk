import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';
import '../modules/product_model.dart';

class BestSellingWidget extends StatefulWidget {
  final List<ProductModel> products;
  final bool isActive;
  final void Function(
    int id,
    String name,
    String category,
    int price,
    String image,
    int qty,
    Map<String, dynamic>? variation,
    List<Map<String, dynamic>> modifiers,
    Rect? imageRect,
  ) onAddToCart;

  const BestSellingWidget({
    super.key,
    required this.products,
    this.isActive = true,
    required this.onAddToCart,
  });

  @override
  State<BestSellingWidget> createState() => _BestSellingWidgetState();
}

class _BestSellingWidgetState extends State<BestSellingWidget> {
  PageController _pageController = PageController(viewportFraction: 0.78);
  int currentIndex = 0;
  List<ProductModel> displayedProducts = [];
  final Map<int, int> qtyMap = {};
  Timer? _autoScrollTimer;
  double _viewportFraction = 0.78;
  VoidCallback? _maintenanceListener;

  static const Color kGreen = Colors.green;

  @override
  void initState() {
    super.initState();
    _prepareData();
    _maintenanceListener = _handleMaintenanceTick;
    KioskMemoryService.instance.maintenanceTick.addListener(
      _maintenanceListener!,
    );
  }

  @override
  void didUpdateWidget(covariant BestSellingWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (!widget.isActive) {
        _autoScrollTimer?.cancel();
      } else {
        _startAutoScroll();
      }
    }
    if (widget.products != oldWidget.products) {
      _prepareData();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final double nextFraction = isTablet ? 0.42 : 0.78;
    if (_viewportFraction != nextFraction) {
      _viewportFraction = nextFraction;
      final int page = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final oldController = _pageController;
        _pageController = PageController(
          viewportFraction: _viewportFraction,
          initialPage: page,
        );
        oldController.dispose();
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pageController.dispose();
    if (_maintenanceListener != null) {
      KioskMemoryService.instance.maintenanceTick.removeListener(
        _maintenanceListener!,
      );
    }
    super.dispose();
  }

  @override
  void deactivate() {
    _autoScrollTimer?.cancel();
    super.deactivate();
  }

  void _prepareData() {
    if (widget.products.isEmpty) return;
    List<ProductModel> all = List.from(widget.products);
    List<ProductModel> fastSelling =
        all.where((p) => p.isBestSeller ?? false).toList();

    if (fastSelling.length < 5) {
      List<ProductModel> remaining =
          all.where((p) => !fastSelling.contains(p)).toList();
      remaining.shuffle(Random());
      fastSelling.addAll(remaining.take(5 - fastSelling.length));
    }

    final nextProducts = fastSelling.take(5).toList();
    setState(() {
      displayedProducts = nextProducts;
      if (currentIndex >= displayedProducts.length) {
        currentIndex = 0;
      }
    });
    _resetPager();
    _startAutoScroll();
  }

  void _resetPager() {
    if (displayedProducts.isEmpty) return;
    currentIndex = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pageController.hasClients) return;
      try {
        _pageController.jumpToPage(currentIndex);
      } catch (_) {}
    });
  }

  void _handleMaintenanceTick() {
    if (!mounted) return;
    if (!widget.isActive) return;
    _autoScrollTimer?.cancel();
    _resetPager();
    _startAutoScroll();
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    if (!widget.isActive) return;
    if (!KioskConfig.enableAutoScroll) return;
    if (displayedProducts.length < 2) return;

    _autoScrollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      try {
        if (!mounted) return;
        if (!widget.isActive) return;
        if (!_pageController.hasClients) return;

        final int currentPage = _pageController.page?.round() ?? currentIndex;
        final next = (currentPage + 1) % displayedProducts.length;
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    if (displayedProducts.isEmpty) return const SizedBox();

    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isTablet = screenWidth > 600;

    // ✅ TABLET → EXACTLY 2 ITEMS
    // Controller is managed in didChangeDependencies.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 🌈 GRADIENT TITLE WITH ICON
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 16 : 12,
            vertical: isTablet ? 12 : 8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.auto_awesome,
                size: isTablet ? 26 : 20,
                color: const Color(0xFF22E6C7), // sparkle color
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    return const LinearGradient(
                      colors: [
                        Color(0xFF22E6C7), // teal
                        Color(0xFF3A7BFF), // blue
                        Color(0xFF9B4DFF), // purple
                      ],
                    ).createShader(bounds);
                  },
                  child: Text(
                    "Top Selling Items (Today)",
                    maxLines: isTablet ? 1 : 2,
                    softWrap: true,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isTablet ? 24 : 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.white, // required for ShaderMask
                      letterSpacing: isTablet ? 0.3 : 0.1,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 📦 PRODUCT SLIDER CONTAINER
        Padding(
          padding: EdgeInsets.all(isTablet ? 10 : 8),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(vertical: isTablet ? 20 : 12),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 242, 220, 188),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                if (isTablet)
                  SizedBox(
                    height: 155,
                    child: PageView.builder(
                      key: ValueKey(_viewportFraction),
                      controller: _pageController,
                      padEnds: false,
                      itemCount: displayedProducts.length,
                      onPageChanged: (i) {
                        final next = i;
                        if (next != currentIndex && mounted) {
                          setState(() => currentIndex = next);
                        }
                      },
                      itemBuilder: (_, i) => _buildProductCard(
                        displayedProducts[i],
                        true,
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 112,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      itemCount: displayedProducts.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => SizedBox(
                        width: (screenWidth * 0.56).clamp(160.0, 210.0),
                        child: _buildProductCard(displayedProducts[i], false),
                      ),
                    ),
                  ),
                if (isTablet) ...[
                  const SizedBox(height: 12),
                  _buildDots(displayedProducts.length, true),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Rect? _rectFromContext(BuildContext? context) {
    if (context == null) return null;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached) return null;
    final topLeft = render.localToGlobal(Offset.zero);
    return topLeft & render.size;
  }

  Widget _buildProductCard(ProductModel p, bool isTablet) {
    BuildContext? imageContext;
    final int qty = qtyMap[p.id] ?? 0;

    final bool needsCustomization =
        p.variations.isNotEmpty || p.modifiers.isNotEmpty;

    void handleAdd() {
      setState(() => qtyMap[p.id] = qty + 1);
      widget.onAddToCart(
        p.id,
        p.name,
        p.category,
        p.price,
        p.image,
        qty + 1,
        null,
        const [],
        _rectFromContext(imageContext),
      );
    }

    return Container(
      margin: EdgeInsets.symmetric(horizontal: isTablet ? 6 : 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _imageSection(
            p,
            isTablet,
            onContextReady: (ctx) => imageContext = ctx,
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 10 : 8,
                vertical: isTablet ? 6 : 5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: isTablet ? 16 : 11,
                    ),
                  ),
                  SizedBox(height: isTablet ? 2 : 1),
                  Text(
                    "₹${p.price}",
                    style: TextStyle(
                      color: const Color.fromARGB(255, 0, 0, 0),
                      fontSize: isTablet ? 18 : 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (needsCustomization)
                    Text(
                      "Variants Available",
                      style: TextStyle(
                        fontSize: isTablet ? 10 : 8.5,
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  SizedBox(height: isTablet ? 6 : 4),
                  qty == 0
                      ? _addButton(handleAdd, isTablet)
                      : _counter(
                          p,
                          qty,
                          isTablet,
                          () => _rectFromContext(imageContext),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageSection(
    ProductModel p,
    bool isTablet, {
    required ValueChanged<BuildContext> onContextReady,
  }) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final double size = isTablet ? 110 : 64;
    final double cardHeight = isTablet ? 155 : 112;
    final int cacheWidth = (size * dpr).round();
    final int cacheHeight = (cardHeight * dpr).round();

    return SizedBox(
      width: size,
      height: cardHeight,
      child: Builder(
        builder: (ctx) {
          onContextReady(ctx);
          final imageUrl = normalizeImageUrl(p.image);
          return ClipRRect(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(14),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: imageUrl.isNotEmpty
                      ? AppNetworkImage(
                          key: ValueKey("best-selling-image-${p.id}"),
                          url: imageUrl,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          gaplessPlayback: true,
                          cacheWidth: cacheWidth,
                          cacheHeight: cacheHeight,
                          fallback: Container(
                            color: Colors.grey.shade200,
                            child: Icon(
                              Icons.fastfood,
                              size: isTablet ? 24 : 18,
                            ),
                          ),
                        )
                      : Container(
                          color: Colors.grey.shade200,
                          child: Icon(
                            Icons.fastfood,
                            size: isTablet ? 24 : 18,
                          ),
                        ),
                ),
                Positioned(
                  top: isTablet ? 8 : 6,
                  left: isTablet ? 8 : 6,
                  child: _vegIcon(p.isVeg),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _vegIcon(bool isVeg) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white,
          border:
              Border.all(color: isVeg ? Colors.green : Colors.red, width: 1),
        ),
        child: Icon(
          Icons.circle,
          size: 6,
          color: isVeg ? Colors.green : Colors.red,
        ),
      );

  Widget _addButton(VoidCallback onTap, bool isTablet) {
    return SizedBox(
      width: double.infinity,
      height: isTablet ? 44 : 28,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFFF4C66A),
          foregroundColor: const Color(0xFF1F1F1F),
          side: const BorderSide(color: Color(0xFFE2B85E), width: 1),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              color: const Color(0xFF1F1F1F),
              size: isTablet ? 18 : 13,
            ),
            SizedBox(width: isTablet ? 6 : 4),
            Text(
              "Add",
              style: TextStyle(
                color: const Color(0xFF1F1F1F),
                fontWeight: FontWeight.w800,
                fontSize: isTablet ? 16 : 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _counter(
    ProductModel p,
    int qty,
    bool isTablet,
    Rect? Function() imageRectBuilder,
  ) {
    final double buttonHeight = isTablet ? 40 : 28;
    return SizedBox(
      height: buttonHeight,
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: _qtyInnerButton(
                label: "-",
                onTap: () {
                  final newQty = (qty - 1).clamp(0, 99);
                  setState(() => qtyMap[p.id] = newQty);
                  widget.onAddToCart(
                    p.id,
                    p.name,
                    p.category,
                    p.price,
                    p.image,
                    newQty,
                    null,
                    const [],
                    imageRectBuilder(),
                  );
                },
                backgroundColor: Colors.red,
                textColor: Colors.white,
                height: buttonHeight,
                isTablet: isTablet,
              ),
            ),
            Expanded(
              flex: 3,
              child: Center(
                child: Text(
                  "$qty",
                  style: TextStyle(
                    fontSize: isTablet ? 18 : 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _qtyInnerButton(
                label: "+",
                onTap: () {
                  final newQty = qty + 1;
                  setState(() => qtyMap[p.id] = newQty);
                  widget.onAddToCart(
                    p.id,
                    p.name,
                    p.category,
                    p.price,
                    p.image,
                    newQty,
                    null,
                    const [],
                    imageRectBuilder(),
                  );
                },
                backgroundColor: kGreen,
                textColor: Colors.white,
                height: buttonHeight,
                isTablet: isTablet,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyInnerButton({
    required String label,
    required VoidCallback onTap,
    required Color backgroundColor,
    required Color textColor,
    required double height,
    required bool isTablet,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.bold,
            fontSize: isTablet ? 18 : 14,
          ),
        ),
      ),
    );
  }

  Widget _buildDots(int count, bool isTablet) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        count,
        (i) => AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: currentIndex == i ? (isTablet ? 24 : 18) : 8,
          height: 8,
          decoration: BoxDecoration(
            color: currentIndex == i
                ? const Color.fromARGB(255, 255, 255, 255)
                : const Color.fromARGB(255, 214, 199, 151),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
