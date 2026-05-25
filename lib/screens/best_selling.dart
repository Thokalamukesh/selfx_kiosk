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
  PageController _pageController = PageController(viewportFraction: 0.86);
  int currentIndex = 0;
  List<ProductModel> displayedProducts = [];
  final Map<int, int> qtyMap = {};
  Timer? _autoScrollTimer;
  double _viewportFraction = 0.86;
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
    final media = MediaQuery.of(context);
    _scheduleViewportFraction(
      _viewportFractionForWidth(
        media.size.width,
        orientation: media.orientation,
      ),
    );
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

    final media = MediaQuery.of(context);
    final double screenWidth = media.size.width;
    final bool isTablet = screenWidth >= 600;

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
            _scheduleViewportFraction(
              _viewportFractionForWidth(
                availableWidth,
                orientation: media.orientation,
              ),
            );

            final bannerHeight = _bannerHeightForWidth(
              availableWidth,
              orientation: media.orientation,
            );

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 10 : 8,
                vertical: isTablet ? 8 : 6,
              ),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: isTablet ? 8 : 5),
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
                          "best-selling-${isTablet ? 'tablet' : 'mobile'}-${_viewportFraction.toStringAsFixed(3)}",
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

  double _viewportFractionForWidth(
    double width, {
    required Orientation orientation,
  }) {
    if (width < 340) return 0.92;
    if (width < 600) return 0.84;
    if (width < 760) return orientation == Orientation.landscape ? 0.70 : 0.66;
    if (width < 980) return orientation == Orientation.landscape ? 0.54 : 0.58;
    if (width < 1280) return orientation == Orientation.landscape ? 0.43 : 0.48;
    return orientation == Orientation.landscape ? 0.36 : 0.40;
  }

  double _bannerHeightForWidth(
    double width, {
    required Orientation orientation,
  }) {
    // Height grows independently from viewport fraction so tablet cards have
    // enough vertical room for title, price, variants text, and action button.
    if (width < 340) return 142;
    if (width < 600) return _responsiveClamp(width * 0.40, 148, 162);
    if (width < 760) return _responsiveClamp(width * 0.28, 174, 196);
    if (width < 980) return _responsiveClamp(width * 0.23, 194, 214);
    if (width < 1280) {
      return orientation == Orientation.landscape
          ? _responsiveClamp(width * 0.18, 206, 226)
          : _responsiveClamp(width * 0.20, 210, 232);
    }
    return _responsiveClamp(width * 0.16, 224, 248);
  }

  void _scheduleViewportFraction(double nextFraction) {
    if ((_viewportFraction - nextFraction).abs() < 0.001) return;
    _viewportFraction = nextFraction;
    final int page = currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final oldController = _pageController;
      _pageController = PageController(
        viewportFraction: _viewportFraction,
        initialPage: page.clamp(0, max(displayedProducts.length - 1, 0)),
      );
      oldController.dispose();
      if (mounted) setState(() {});
    });
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
        final cardHeight = constraints.maxHeight;
        final bool compactCard = cardWidth < 340;
        final bool largeCard = cardWidth >= 520;
        final bool landscapeTablet = isTablet &&
            MediaQuery.of(context).orientation == Orientation.landscape;

        // The image is a real right-side region, not an overlay. This prevents
        // tablet images from covering the title, price, or button.
        final imageFraction = isTablet
            ? (landscapeTablet || largeCard ? 0.34 : 0.36)
            : (compactCard ? 0.38 : 0.40);
        final maxImageWidth = cardWidth * (isTablet ? 0.40 : 0.43);
        final minImageWidth = min(compactCard ? 104.0 : 118.0, maxImageWidth);
        final imagePanelWidth = _responsiveClamp(
          cardWidth * imageFraction,
          minImageWidth,
          maxImageWidth,
        );

        final contentHorizontalPadding = isTablet
            ? _responsiveClamp(cardWidth * 0.045, 16, 24)
            : _responsiveClamp(cardWidth * 0.040, 10, 14);
        final verticalPadding = isTablet
            ? _responsiveClamp(cardHeight * 0.085, 15, 22)
            : _responsiveClamp(cardHeight * 0.070, 9, 13);
        final contentWidth = max(
          0.0,
          cardWidth - imagePanelWidth - (contentHorizontalPadding * 2),
        );
        final titleFont = isTablet
            ? _responsiveClamp(contentWidth * 0.082, 16, 21)
            : _responsiveClamp(contentWidth * 0.086, 12, 15);
        final priceFont = isTablet
            ? _responsiveClamp(contentWidth * 0.088, 18, 23)
            : _responsiveClamp(contentWidth * 0.095, 14, 17);
        final variantFont = isTablet
            ? _responsiveClamp(contentWidth * 0.045, 9.5, 11.5)
            : _responsiveClamp(contentWidth * 0.045, 7.5, 9);
        final contentGap = isTablet
            ? _responsiveClamp(cardHeight * 0.035, 6, 10)
            : _responsiveClamp(cardHeight * 0.030, 3, 6);
        final maxActionWidth = min(contentWidth, isTablet ? 142.0 : 112.0);
        final minActionWidth = min(compactCard ? 78.0 : 92.0, maxActionWidth);
        final actionWidth = _responsiveClamp(
          contentWidth * (isTablet ? 0.58 : 0.62),
          minActionWidth,
          maxActionWidth,
        );
        final actionHeight = isTablet
            ? _responsiveClamp(cardHeight * 0.19, 38, 44)
            : _responsiveClamp(cardHeight * 0.21, 29, 34);

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
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      contentHorizontalPadding,
                      verticalPadding,
                      contentHorizontalPadding * 0.75,
                      verticalPadding,
                    ),
                    // Flexible title and fixed price/action keep every element
                    // visible even on compact phone widths and wide tablet cards.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              p.name,
                              maxLines: compactCard ? 2 : 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: const Color(0xFF1A1A1A),
                                fontWeight: FontWeight.w900,
                                fontSize: titleFont,
                                height: 1.08,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: contentGap),
                        Text(
                          "₹${p.price}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _brandColor,
                            fontSize: priceFont,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                          ),
                        ),
                        if (needsCustomization) ...[
                          SizedBox(height: contentGap * 0.35),
                          Text(
                            "Variants Available",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: variantFont,
                              color: const Color(0xFFB46622),
                              fontWeight: FontWeight.w800,
                              height: 1.0,
                            ),
                          ),
                        ],
                        SizedBox(height: contentGap),
                        qty == 0
                            ? _addButton(
                                handleAdd,
                                isTablet,
                                cardWidth: cardWidth,
                                width: actionWidth,
                                height: actionHeight,
                              )
                            : _counter(
                                p,
                                qty,
                                isTablet,
                                () => _rectFromContext(imageContext),
                                cardWidth: cardWidth,
                                width: actionWidth,
                                height: actionHeight,
                              ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: imagePanelWidth,
                  height: double.infinity,
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
    required double width,
    required double height,
  }) {
    return SizedBox(
      width: width,
      height: height,
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
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "Order Now",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: isTablet
                        ? _responsiveClamp(cardWidth * 0.032, 12, 14)
                        : _responsiveClamp(cardWidth * 0.040, 9.5, 11.5),
                  ),
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
    required double width,
    required double height,
  }) {
    return SizedBox(
      height: height,
      width: width,
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
                height: height,
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
                height: height,
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
