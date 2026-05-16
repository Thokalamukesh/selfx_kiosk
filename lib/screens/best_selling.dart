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
  static const Color _brandColor = Color(0xFF9F342C);

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

        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth;
            final isCompactPhone = !isTablet && availableWidth < 300;
            final isWidePhone = !isTablet && availableWidth >= 360;
            final bannerHeight = isTablet
                ? 178.0
                : isCompactPhone
                    ? 116.0
                    : isWidePhone
                        ? 132.0
                        : 124.0;

            return Padding(
              padding: EdgeInsets.all(isTablet ? 10 : 8),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: isTablet ? 10 : 6),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: bannerHeight,
                      child: PageView.builder(
                        key: ValueKey(
                          "best-selling-${isTablet ? 'tablet' : 'mobile'}-$_viewportFraction",
                        ),
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
                          isTablet,
                        ),
                      ),
                    ),
                    if (displayedProducts.length > 1) ...[
                      const SizedBox(height: 12),
                      _buildDots(displayedProducts.length, isTablet),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  double _responsiveValue({
    required double width,
    required double small,
    required double large,
    double smallAt = 210,
    double largeAt = 300,
  }) {
    final t = ((width - smallAt) / (largeAt - smallAt)).clamp(0.0, 1.0);
    return small + ((large - small) * t);
  }

  double _responsiveClamp(double value, double min, double max) {
    return value.clamp(min, max).toDouble();
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final imagePanelWidth = isTablet
            ? _responsiveClamp(cardWidth * 0.48, 180, 250)
            : _responsiveClamp(cardWidth * 0.52, 108, 150);
        final leftPadding = isTablet
            ? _responsiveClamp(cardWidth * 0.06, 18, 26)
            : _responsiveValue(width: cardWidth, small: 10, large: 14);
        final rightPadding = imagePanelWidth + (isTablet ? 12 : 8);
        final titleFont = isTablet
            ? _responsiveClamp(cardWidth * 0.048, 18, 22)
            : _responsiveClamp(cardWidth * 0.062, 12, 14.5);
        final priceFont = isTablet
            ? _responsiveClamp(cardWidth * 0.052, 19, 23)
            : _responsiveClamp(cardWidth * 0.068, 14, 16);

        return Container(
          margin: EdgeInsets.symmetric(horizontal: isTablet ? 8 : 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFEFE1),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFB44A1D).withOpacity(0.10),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: imagePanelWidth,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _topSellingImage(
                          p,
                          isTablet,
                          onContextReady: (ctx) => imageContext = ctx,
                        ),
                      ),
                      Positioned(
                        top: isTablet ? 12 : 8,
                        left: isTablet ? 12 : 8,
                        child: _vegIcon(p.isVeg),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    leftPadding,
                    isTablet ? 18 : 10,
                    rightPadding,
                    isTablet ? 14 : 9,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: isTablet ? 8 : 5),
                      Text(
                        p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFF1A1A1A),
                          fontWeight: FontWeight.w900,
                          fontSize: titleFont,
                          height: 1.05,
                        ),
                      ),
                      SizedBox(height: isTablet ? 7 : 4),
                      Text(
                        "₹${p.price}",
                        style: TextStyle(
                          color: _brandColor,
                          fontSize: priceFont,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (needsCustomization)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            "Variants Available",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isTablet ? 10 : 8,
                              color: const Color(0xFFB46622),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      SizedBox(height: isTablet ? 10 : 6),
                      qty == 0
                          ? _addButton(handleAdd, isTablet,
                              cardWidth: cardWidth)
                          : _counter(
                              p,
                              qty,
                              isTablet,
                              () => _rectFromContext(imageContext),
                              cardWidth: cardWidth,
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _topSellingImage(
    ProductModel p,
    bool isTablet, {
    required ValueChanged<BuildContext> onContextReady,
  }) {
    final dpr = MediaQuery.of(context).devicePixelRatio;

    return Builder(
      builder: (ctx) {
        onContextReady(ctx);
        final imageUrl = normalizeImageUrl(p.image);
        return LayoutBuilder(
          builder: (context, constraints) {
            final cacheWidth =
                (constraints.maxWidth * dpr).round().clamp(1, 4096);
            final cacheHeight =
                (constraints.maxHeight * dpr).round().clamp(1, 4096);
            return imageUrl.isNotEmpty
                ? AppNetworkImage(
                    key: ValueKey('best-selling-image-${p.id}'),
                    url: imageUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    cacheWidth: cacheWidth,
                    cacheHeight: cacheHeight,
                    fallback: Container(
                      color: Colors.transparent,
                      child: Icon(
                        Icons.fastfood,
                        color: const Color(0xFFC40012),
                        size: isTablet ? 40 : 26,
                      ),
                    ),
                  )
                : Container(
                    color: Colors.transparent,
                    child: Icon(
                      Icons.fastfood,
                      color: const Color(0xFFC40012),
                      size: isTablet ? 40 : 26,
                    ),
                  );
          },
        );
      },
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

  Widget _addButton(
    VoidCallback onTap,
    bool isTablet, {
    required double cardWidth,
  }) {
    final buttonWidth = isTablet
        ? _responsiveClamp(cardWidth * 0.30, 118, 138)
        : _responsiveClamp(cardWidth * 0.38, 76, 94);
    final buttonHeight =
        isTablet ? 42.0 : _responsiveClamp(cardWidth * 0.13, 28, 32);

    return SizedBox(
      width: buttonWidth,
      height: buttonHeight,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(isTablet ? 11 : 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(isTablet ? 11 : 8),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: _brandColor,
              borderRadius: BorderRadius.circular(isTablet ? 11 : 8),
              boxShadow: [
                BoxShadow(
                  color: _brandColor.withOpacity(0.24),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                "Order Now",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: isTablet
                      ? 14
                      : _responsiveClamp(cardWidth * 0.044, 9.5, 11),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _counter(
    ProductModel p,
    int qty,
    bool isTablet,
    Rect? Function() imageRectBuilder, {
    required double cardWidth,
  }) {
    final double buttonHeight =
        isTablet ? 40 : _responsiveClamp(cardWidth * 0.13, 28, 32);
    final double counterWidth = isTablet
        ? _responsiveClamp(cardWidth * 0.30, 118, 138)
        : _responsiveClamp(cardWidth * 0.38, 76, 94);
    return SizedBox(
      height: buttonHeight,
      width: counterWidth,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFFE1D2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE7AF9D)),
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
          width: currentIndex == i ? (isTablet ? 24 : 16) : (isTablet ? 9 : 7),
          height: isTablet ? 8 : 7,
          decoration: BoxDecoration(
            color: currentIndex == i
                ? const Color(0xFF9F342C)
                : Colors.white.withOpacity(0.75),
            border: Border.all(
              color: currentIndex == i
                  ? const Color(0xFF9F342C)
                  : const Color(0xFFD9C8A8),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
