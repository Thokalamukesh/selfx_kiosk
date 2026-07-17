import 'dart:async';
import 'dart:convert';

import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/menu_sync.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/modules/product_model.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';
import 'package:api_selfxo_project/widget/product_card.dart';
import 'best_selling.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SelectionPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path();
    // This value controls how "deep" the curve goes into the red area
    const double curveDepth = 25.0;

    // Start at top right
    path.moveTo(size.width, 0);

    // 1. Top Outward Curve (Concave)
    path.quadraticBezierTo(
      size.width,
      curveDepth,
      size.width - curveDepth,
      curveDepth,
    );

    // 2. Main Body with rounded inner corners
    path.lineTo(curveDepth, curveDepth);
    path.quadraticBezierTo(0, curveDepth, 0, curveDepth * 2);
    path.lineTo(0, size.height - (curveDepth * 2));
    path.quadraticBezierTo(
      0,
      size.height - curveDepth,
      curveDepth,
      size.height - curveDepth,
    );
    path.lineTo(size.width - curveDepth, size.height - curveDepth);

    // 3. Bottom Outward Curve (Concave)
    path.quadraticBezierTo(
      size.width,
      size.height - curveDepth,
      size.width,
      size.height,
    );

    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HomePage2 extends StatefulWidget {
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
  ) onAddToCart;
  final ValueChanged<Rect?> onCartIconRect;
  final Function(List<dynamic>) onProductsLoaded;
  final VoidCallback onRestart;
  final VoidCallback onViewCart;
  final VoidCallback onClearCart;
  final List<Map<String, dynamic>> cart;
  final int Function(int productId) getQtyForProduct;
  final bool isActive;

  const HomePage2({
    super.key,
    required this.onAddToCart,
    required this.onRestart,
    required this.onViewCart,
    required this.onClearCart,
    required this.onCartIconRect,
    required this.onProductsLoaded,
    required this.cart,
    required this.getQtyForProduct,
    required this.isActive,
  });

  @override
  State<HomePage2> createState() => _HomePage2State();
}

class _HomePage2State extends State<HomePage2> with TickerProviderStateMixin {
  final Map<int, List<Map<String, dynamic>>> variationsMap = {};
  final Map<int, List<Map<String, dynamic>>> modifiersMap = {};
  Rect? _lastCartIconRect;
  List<dynamic> _rawProducts = [];
  Map<String, List<ProductModel>> _productsByCategory = {};
  List<String> _sectionCategoriesCache = const [];
  final Map<int, Map<String, dynamic>> _productOverrides = {};
  static const String _overridesKey = "admin_product_overrides";
  static const String _categoryOverridesKey = "admin_category_overrides";
  static const String _menuCacheKey = "kiosk_menu_products_cache_v1";
  static const String _restaurantClosedMessage =
      "Restaurant closed. Please check back later.";
  final Map<int, Map<String, dynamic>> _categoryOverrides = {};

  String? _extractBackendErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final message = data["message"] ?? data["error"] ?? data["errors"];
        if (message != null && message.toString().trim().isNotEmpty) {
          return message.toString().trim();
        }
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }
    return null;
  }

  bool _isNetworkError(Object error) {
    if (error is! DioException) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout;
  }

  bool _isClosedMenuMessage(String? message) {
    if (message == null) return false;
    final text = message.toLowerCase();
    return text.contains("restaurant closed") ||
        text.contains("store closed") ||
        text.contains("kitchen closed") ||
        text.contains("outside business") ||
        text.contains("outside opening") ||
        text.contains("not accepting") ||
        text.contains("not available") ||
        text.contains("unavailable") ||
        text.contains("no item") ||
        text.contains("no menu") ||
        text.contains("time up") ||
        text.contains("closed now");
  }

  String _menuErrorMessage(String? backendMessage) {
    return _isClosedMenuMessage(backendMessage)
        ? _restaurantClosedMessage
        : (backendMessage ?? "Failed to load products");
  }

  Future<void> _goToWelcome(BuildContext context) async {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  List<ProductModel> allProducts = [];
  List<String> categories = [];
  Map<String, String> categoryImages = {};
  bool _showItemImages = true;
  bool _showCategoryImages = true;
  bool isLoading = true;
  bool hasError = false;
  String errorMessage = "Failed to load products";
  int selectedIndex = 0;
  int _activeCategoryIndex = 0;
  String searchQuery = "";

  final TextEditingController searchCtrl = TextEditingController();
  final ScrollController scrollCtrl = ScrollController();
  // Separate scroll for categories

  final ScrollController _categoryScrollController = ScrollController();
  bool _showScrollArrow = false;
  bool _showProductScrollHint = false;
  late AnimationController _leftScrollHintController;
  Timer? _categorySyncTimer;
  Timer? _imagePrecacheTimer;
  final Map<String, BuildContext> _leftCategoryContexts = {};
  final Map<String, BuildContext> _rightCategoryContexts = {};
  VoidCallback? _categoryScrollListener;
  Timer? _retryTimer;
  bool _loadingProducts = false;
  VoidCallback? _onlineListener;
  bool _showScrollToTop = false;
  VoidCallback? _maintenanceListener;
  VoidCallback? _mediaRefreshListener;
  VoidCallback? _menuSyncListener;
  bool _pendingMenuReload = false;

  // Bottom bar animations
  late AnimationController _cartBounceController;
  late Animation<double> _cartBounceAnim;
  late AnimationController _viewCartController;
  late Animation<double> _viewCartScale;
  int _lastItemCount = 0;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _menuSyncListener = () {
      if (!mounted) return;
      if (_loadingProducts) {
        _pendingMenuReload = true;
        return;
      }
      _loadProducts(forceRefresh: true);
    };
    MenuSync.revision.addListener(_menuSyncListener!);

    ConnectivityService.instance.start();
    _onlineListener = () {
      final online = ConnectivityService.instance.isOnline.value;
      if (online && hasError) {
        _retryTimer?.cancel();
        if (mounted) {
          setState(() {
            hasError = false;
            isLoading = true;
          });
        }
        _loadProducts();
      }
    };
    ConnectivityService.instance.isOnline.addListener(_onlineListener!);

    _cartBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _cartBounceAnim = Tween<double>(
      begin: 1,
      end: 1.15,
    ).chain(CurveTween(curve: Curves.easeOut)).animate(_cartBounceController);
    _cartBounceController.addStatusListener((s) {
      if (!mounted) return;
      try {
        if (s == AnimationStatus.completed) {
          _cartBounceController.reverse();
        }
      } catch (_) {}
    });

    _viewCartController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _viewCartScale = Tween<double>(
      begin: 1,
      end: 1.06,
    ).chain(CurveTween(curve: Curves.easeInOut)).animate(_viewCartController);

    _leftScrollHintController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (KioskConfig.enableDecorativeAnimations) {
      _leftScrollHintController.repeat(reverse: true);
    }

    _categoryScrollListener = () {
      if (_categoryScrollController.hasClients) {
        final pos = _categoryScrollController.position;

        // Show only when the list is scrollable and the user is still at top.
        final bool shouldShow =
            pos.maxScrollExtent > 0 && pos.pixels < (pos.maxScrollExtent - 4);

        if (_showScrollArrow != shouldShow) {
          setState(() => _showScrollArrow = shouldShow);
        }
      }
    };
    _categoryScrollController.addListener(_categoryScrollListener!);

    // Product list scroll listener (add once to avoid duplicates)
    scrollCtrl.addListener(_onProductScroll);

    // Check on first build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_categoryScrollController.hasClients) {
        setState(() {
          _showScrollArrow =
              _categoryScrollController.position.maxScrollExtent > 0 &&
                  _categoryScrollController.position.pixels <
                      (_categoryScrollController.position.maxScrollExtent - 4);
        });
      }
    });

    _lastItemCount = _totalItems();
    if (_lastItemCount > 0 && KioskConfig.enableDecorativeAnimations) {
      _cartBounceController.forward(from: 0);
      _viewCartController.repeat(reverse: true);
    }

    _maintenanceListener = _handleMaintenanceTick;
    KioskMemoryService.instance.maintenanceTick.addListener(
      _maintenanceListener!,
    );
    _mediaRefreshListener = _handleMediaRefreshTick;
    KioskMemoryService.instance.mediaRefreshTick.addListener(
      _mediaRefreshListener!,
    );
  }

  @override
  void dispose() {
    widget.onCartIconRect(null);
    // ✅ ALWAYS dispose controllers to prevent memory leaks
    scrollCtrl.removeListener(_onProductScroll);
    searchCtrl.dispose();
    if (_cartBounceController.isAnimating) {
      _cartBounceController.stop(canceled: true);
    }
    if (_viewCartController.isAnimating) {
      _viewCartController.stop(canceled: true);
    }
    if (_leftScrollHintController.isAnimating) {
      _leftScrollHintController.stop(canceled: true);
    }
    _cartBounceController.dispose();
    _viewCartController.dispose();
    _leftScrollHintController.dispose();
    if (_categoryScrollListener != null) {
      _categoryScrollController.removeListener(_categoryScrollListener!);
    }
    _categoryScrollController.dispose();

    if (_onlineListener != null) {
      ConnectivityService.instance.isOnline.removeListener(_onlineListener!);
    }
    if (_maintenanceListener != null) {
      KioskMemoryService.instance.maintenanceTick.removeListener(
        _maintenanceListener!,
      );
    }
    if (_mediaRefreshListener != null) {
      KioskMemoryService.instance.mediaRefreshTick.removeListener(
        _mediaRefreshListener!,
      );
    }
    _retryTimer?.cancel();
    _categorySyncTimer?.cancel();
    _imagePrecacheTimer?.cancel();
    if (_menuSyncListener != null) {
      MenuSync.revision.removeListener(_menuSyncListener!);
    }
    super.dispose();
  }

  @override
  void deactivate() {
    _retryTimer?.cancel();
    _categorySyncTimer?.cancel();
    _imagePrecacheTimer?.cancel();
    if (_cartBounceController.isAnimating) {
      _cartBounceController.stop(canceled: true);
    }
    if (_viewCartController.isAnimating) {
      _viewCartController.stop(canceled: true);
    }
    if (_leftScrollHintController.isAnimating) {
      _leftScrollHintController.stop(canceled: true);
    }
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant HomePage2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = _totalItems();
    if (count > _lastItemCount && KioskConfig.enableDecorativeAnimations) {
      _cartBounceController.forward(from: 0);
      if (!_viewCartController.isAnimating) {
        _viewCartController.repeat(reverse: true);
      }
    }
    if (count == 0) {
      if (_viewCartController.isAnimating) {
        _viewCartController.stop(canceled: true);
      }
      _viewCartController.reset();
    }
    _lastItemCount = count;

    if (!widget.isActive && oldWidget.isActive) {
      _retryTimer?.cancel();
    }
    if (widget.isActive != oldWidget.isActive) {
      if (!widget.isActive) {
        if (KioskConfig.enableDecorativeAnimations) {
          _leftScrollHintController.stop(canceled: true);
        }
        if (_cartBounceController.isAnimating) {
          _cartBounceController.stop(canceled: true);
        }
        if (_viewCartController.isAnimating) {
          _viewCartController.stop(canceled: true);
        }
      } else if (KioskConfig.enableDecorativeAnimations &&
          !_leftScrollHintController.isAnimating) {
        _leftScrollHintController.repeat(reverse: true);
      }
    }
  }

  Future<void> _loadProducts({bool forceRefresh = false}) async {
    if (_loadingProducts) return;
    _loadingProducts = true;
    _retryTimer?.cancel();
    final hadProducts = allProducts.isNotEmpty;
    if (mounted) {
      setState(() {
        isLoading = !hadProducts;
        hasError = false;
      });
    }
    try {
      await _loadDisplayPreferences();
      await _loadProductOverrides();
      await _loadCategoryOverrides();

      if (!hadProducts) {
        final cachedRaw = await _readCachedMenuProducts();
        if (cachedRaw != null && cachedRaw.isNotEmpty) {
          await _applyRawProducts(cachedRaw, fromCache: true);
        }
      }

      final res = await KioskApi().getProducts(forceRefresh: forceRefresh);

      final List raw = _cloneRawProducts(res.data["products"] ?? []);
      await _writeCachedMenuProducts(raw);
      await _applyRawProducts(raw);
    } catch (e) {
      final online = ConnectivityService.instance.isOnline.value;
      final hasCachedData = allProducts.isNotEmpty;
      final backendMessage = _extractBackendErrorMessage(e);
      final isNetworkIssue = _isNetworkError(e);

      if (!mounted) return;

      if (online && !isNetworkIssue && backendMessage != null) {
        setState(() {
          errorMessage = _menuErrorMessage(backendMessage);
          hasError = !hasCachedData;
          isLoading = false;
        });
      } else if (online) {
        // If internet is back, don't block UI—just retry.
        setState(() {
          hasError = false;
          isLoading = !hasCachedData;
        });
        _retryTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) _loadProducts();
        });
      } else {
        // Offline: keep showing existing data if we have it
        setState(() {
          errorMessage = "Kiosk is Offline";
          hasError = !hasCachedData;
          isLoading = false;
        });
      }
    } finally {
      _loadingProducts = false;
      if (_pendingMenuReload && mounted) {
        _pendingMenuReload = false;
        Future<void>.microtask(_loadProducts);
      }
    }
  }

  Future<void> _loadDisplayPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _showItemImages =
        prefs.getBool(KioskRestaurantMeta.showItemImagesKey) ?? true;
    _showCategoryImages =
        prefs.getBool(KioskRestaurantMeta.showCategoryImagesKey) ?? true;
  }

  Future<List?> _readCachedMenuProducts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_menuCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return _cloneRawProducts(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCachedMenuProducts(List raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_menuCacheKey, jsonEncode(raw));
    } catch (_) {}
  }

  Future<void> _applyRawProducts(
    List rawProducts, {
    bool fromCache = false,
  }) async {
    final raw = _cloneRawProducts(rawProducts);
    _applyOverridesToRawProducts(raw);
    _rawProducts = raw;
    widget.onProductsLoaded(raw);

    final parsed = await compute(_parseProductsIsolate, raw);
    if (!mounted) return;

    final productMaps = List<Map<String, dynamic>>.from(
      parsed["products"] ?? const [],
    );
    final hiddenCategoryKeys = _hiddenCategoryKeys();
    _applyOverridesToProductMaps(
      productMaps,
      hiddenCategoryKeys: hiddenCategoryKeys,
    );
    final tempProducts = productMaps
        .map(
          (p) => ProductModel(
            id: p["id"],
            name: p["name"] ?? "",
            category: p["category"] ?? "",
            price: int.tryParse(p["price"].toString()) ?? 0,
            image: normalizeImageUrlValue(p["image"]),
            description: p["description"]?.toString() ?? "",
            type: p["type"],
          ),
        )
        .toList();

    if (tempProducts.isEmpty) {
      if (!mounted) return;
      setState(() {
        allProducts = const [];
        categories = const [];
        categoryImages = const {};
        _productsByCategory = {};
        _sectionCategoriesCache = const [];
        variationsMap.clear();
        modifiersMap.clear();
        _leftCategoryContexts.clear();
        _rightCategoryContexts.clear();
        errorMessage = _restaurantClosedMessage;
        hasError = true;
        isLoading = false;
        selectedIndex = 0;
        _activeCategoryIndex = 0;
      });
      return;
    }

    final tempCategories = List<String>.from(
      parsed["categories"] ?? const <String>[],
    ).where(_isVisibleCategoryName).toList();
    if (_productOverrides.isNotEmpty) {
      final overrideCats = _productOverrides.values
          .map((o) => _categoryLabel(o["category_name"] ?? o["category"]))
          .where((o) => o.trim().isNotEmpty)
          .where(_isVisibleCategoryName)
          .where((o) => !hiddenCategoryKeys.contains(_categoryKey(o)))
          .toSet();
      for (final c in overrideCats) {
        if (!tempCategories.contains(c)) {
          tempCategories.add(c);
        }
      }
    }
    if (tempCategories.isEmpty || tempCategories.first != "All") {
      tempCategories.insert(0, "All");
    }

    final tempSectionCategories =
        tempCategories.where((c) => c != "All").toList(growable: false);
    final tempProductsByCategory = <String, List<ProductModel>>{};
    for (final product in tempProducts) {
      (tempProductsByCategory[product.category] ??= <ProductModel>[])
          .add(product);
    }

    final tempCatImages = Map<String, String>.from(
      parsed["categoryImages"] ?? const <String, String>{},
    ).map(
      (key, value) => MapEntry(key, normalizeImageUrl(value)),
    );

    variationsMap
      ..clear()
      ..addAll(
        (parsed["variationsMap"] as Map? ?? const {}).map(
          (k, v) => MapEntry(
            int.tryParse(k.toString()) ?? 0,
            List<Map<String, dynamic>>.from(v ?? const []),
          ),
        )..removeWhere((key, value) => key == 0),
      );

    modifiersMap
      ..clear()
      ..addAll(
        (parsed["modifiersMap"] as Map? ?? const {}).map(
          (k, v) => MapEntry(
            int.tryParse(k.toString()) ?? 0,
            List<Map<String, dynamic>>.from(v ?? const []),
          ),
        )..removeWhere((key, value) => key == 0),
      );

    if (!mounted) return;
    setState(() {
      allProducts = tempProducts;
      categories = tempCategories;
      _sectionCategoriesCache = tempSectionCategories;
      _productsByCategory = tempProductsByCategory;
      categoryImages = tempCatImages;
      _leftCategoryContexts.clear();
      _rightCategoryContexts.clear();
      isLoading = false;
      hasError = false;
      if (selectedIndex >= categories.length) {
        selectedIndex = 0;
      }
      if (_activeCategoryIndex >= categories.length) {
        _activeCategoryIndex = 0;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (_categoryScrollController.hasClients) {
          _showScrollArrow =
              _categoryScrollController.position.maxScrollExtent > 0;
        }
        if (scrollCtrl.hasClients) {
          _showProductScrollHint = scrollCtrl.position.maxScrollExtent > 0 &&
              scrollCtrl.position.pixels <= 4;
        }
      });
      if (!fromCache) {
        _scheduleProductImagePrecache();
      }
    });
  }

  void _scheduleProductImagePrecache() {
    _imagePrecacheTimer?.cancel();
    _imagePrecacheTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      _precacheProductImages();
    });
  }

  void _precacheProductImages() {
    if (!mounted) return;
    if (kIsWeb) return;
    final context = this.context;
    const int maxItems = 24;
    final productsToCache = allProducts.take(maxItems);
    for (final p in productsToCache) {
      final url = p.image.trim();
      if (isSupportedRasterImageUrl(url)) {
        precacheImage(
          NetworkImage(url),
          context,
          onError: (_, __) {},
        );
      }
    }
    int cached = 0;
    for (final url in categoryImages.values) {
      if (cached >= 8) break;
      final u = url.trim();
      if (!isSupportedRasterImageUrl(u)) continue;
      precacheImage(
        NetworkImage(u),
        context,
        onError: (_, __) {},
      );
      cached++;
    }
  }

  void _onProductScroll() {
    if (!scrollCtrl.hasClients) return;
    final pos = scrollCtrl.position;
    final bool shouldShow = pos.maxScrollExtent > 0 && pos.pixels <= 4;
    if (_showProductScrollHint != shouldShow) {
      setState(() => _showProductScrollHint = shouldShow);
    }
    final bool showTop = pos.pixels > 240;
    if (_showScrollToTop != showTop) {
      setState(() => _showScrollToTop = showTop);
    }
    _scheduleCategorySync();
  }

  void _scheduleCategorySync() {
    if (selectedIndex != 0) return;
    if (_categorySyncTimer?.isActive ?? false) return;
    _categorySyncTimer = Timer(const Duration(milliseconds: 120), () {
      _categorySyncTimer = null;
      if (!mounted) return;
      _updateActiveCategoryFromScroll();
    });
  }

  void _updateActiveCategoryFromScroll() {
    if (!scrollCtrl.hasClients) return;
    if (categories.length <= 1) return;

    final sectionCategories = _sectionCategories();
    if (sectionCategories.isEmpty) return;

    final currentOffset = scrollCtrl.offset;
    double? firstOffset;
    double bestOffset = -double.infinity;
    int bestIndex = 0;

    for (final cat in sectionCategories) {
      final ctx = _rightCategoryContexts[cat];
      if (ctx == null) continue;
      final render = ctx.findRenderObject();
      if (render == null || !render.attached) continue;
      final viewport = RenderAbstractViewport.of(render);

      final offset = viewport.getOffsetToReveal(render, 0).offset;
      firstOffset ??= offset;

      if (offset <= currentOffset + 6 && offset > bestOffset) {
        bestOffset = offset;
        bestIndex = categories.indexOf(cat);
      }
    }

    if (firstOffset != null && currentOffset < (firstOffset - 8)) {
      bestIndex = 0;
    }

    if (bestIndex != _activeCategoryIndex && mounted) {
      setState(() => _activeCategoryIndex = bestIndex);
      _scrollLeftCategoryIntoView(bestIndex);
    }
  }

  void _scrollLeftCategoryIntoView(int index) {
    if (index < 0 || index >= categories.length) return;
    final ctx = _leftCategoryContexts[categories[index]];
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      alignment: 0.5,
      curve: Curves.easeOut,
    );
  }

  void _handleMaintenanceTick() {
    if (!mounted) return;
    try {
      if (KioskConfig.enableDecorativeAnimations) {
        if (_leftScrollHintController.isAnimating) {
          _leftScrollHintController.reset();
          _leftScrollHintController.repeat(reverse: true);
        }
        if (_totalItems() > 0) {
          if (_viewCartController.isAnimating) {
            _viewCartController.reset();
          }
          _viewCartController.repeat(reverse: true);
        } else if (_viewCartController.isAnimating) {
          _viewCartController.stop(canceled: true);
          _viewCartController.reset();
        }
        if (_cartBounceController.isAnimating) {
          _cartBounceController.reset();
          _cartBounceController.forward();
        }
      }
      _categorySyncTimer?.cancel();
    } catch (_) {}
  }

  void _handleMediaRefreshTick() {
    if (!mounted) return;
    if (_loadingProducts) return;
    _loadProducts();
  }

  Future<void> _loadProductOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_overridesKey);
      if (raw == null || raw.isEmpty) {
        _productOverrides.clear();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _productOverrides
        ..clear()
        ..addAll(
          decoded.map((k, v) {
            final override =
                v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
            final normalizedCategory = _categoryLabel(
              override["category_name"] ?? override["category"],
              fallback: "",
            );
            if (normalizedCategory.isNotEmpty) {
              override["category_name"] = normalizedCategory;
              override["category"] = normalizedCategory;
            }
            return MapEntry(int.tryParse(k.toString()) ?? 0, override);
          })
            ..removeWhere((key, value) => key == 0),
        );
    } catch (_) {}
  }

  Future<void> _loadCategoryOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_categoryOverridesKey);
      if (raw == null || raw.isEmpty) {
        _categoryOverrides.clear();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _categoryOverrides
        ..clear()
        ..addAll(
          decoded.map(
            (k, v) => MapEntry(
              int.tryParse(k.toString()) ?? 0,
              v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{},
            ),
          )..removeWhere((key, value) => key == 0),
        );
    } catch (_) {}
  }

  List _cloneRawProducts(List rawProducts) {
    return rawProducts.map((category) {
      if (category is! Map) return category;
      final map = Map<String, dynamic>.from(category);
      final items = map["items"];
      if (items is List) {
        map["items"] = items.map((item) {
          if (item is! Map) return item;
          final itemMap = Map<String, dynamic>.from(item);
          final nested = itemMap["item"];
          if (nested is Map) {
            itemMap["item"] = Map<String, dynamic>.from(nested);
          }
          return itemMap;
        }).toList();
      }
      return map;
    }).toList();
  }

  int? _rawCategoryId(Map<String, dynamic> category) {
    final raw = category["category_id"] ?? category["id"];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? "");
  }

  String _categoryLabel(dynamic raw, {String fallback = ""}) {
    if (raw is Map) {
      final nested = raw["category_name"] ??
          raw["name"] ??
          raw["category"] ??
          raw["title"];
      if (!identical(nested, raw)) {
        return _categoryLabel(nested, fallback: fallback);
      }
    }

    final text = raw?.toString().trim() ?? "";
    if (text.isEmpty) return fallback;

    if (text.startsWith("{") && text.endsWith("}")) {
      final categoryMatch = RegExp(
        r"category_name\s*:\s*([^,}]+)",
      ).firstMatch(text);
      if (categoryMatch != null) {
        final value = categoryMatch.group(1)?.trim();
        if (value != null && value.isNotEmpty) return value;
      }

      final nameMatch = RegExp(r"name\s*:\s*([^,}]+)").firstMatch(text);
      if (nameMatch != null) {
        final value = nameMatch.group(1)?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }

    return text;
  }

  bool _isVisibleCategoryName(String category) {
    final key = category.trim().toLowerCase();
    final normalized = key.replaceAll(RegExp(r"[^a-z0-9]"), "");
    const hiddenNames = {
      "other",
      "others",
      "othercategory",
      "othercategories",
      "otherscategory",
      "otherscategories",
      "unknown",
      "unknowncategory",
      "unknowncategories",
      "uncategorized",
    };
    return key.isNotEmpty &&
        normalized.isNotEmpty &&
        !hiddenNames.contains(normalized);
  }

  void _applyOverridesToRawProducts(List rawProducts) {
    for (final category in rawProducts) {
      if (category is! Map) continue;
      final categoryMap = Map<String, dynamic>.from(category);
      final categoryId = _rawCategoryId(categoryMap);
      if (categoryId != null) {
        final categoryOverride = _categoryOverrides[categoryId];
        if (categoryOverride != null) {
          categoryMap.addAll(categoryOverride);
        }
      }

      final items = categoryMap["items"];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final itemMap = Map<String, dynamic>.from(item);
          final itemId = _resolveItemId(itemMap);
          if (itemId == 0) continue;
          final override = _productOverrides[itemId];
          if (override == null) continue;
          itemMap.addAll(override);
          final nestedAfter = itemMap["item"];
          if (nestedAfter is Map) {
            for (final entry in override.entries) {
              nestedAfter[entry.key] = entry.value;
            }
          }
          item
            ..clear()
            ..addAll(itemMap);
        }
      }

      category
        ..clear()
        ..addAll(categoryMap);
    }
  }

  String _categoryKey(dynamic raw) {
    return _categoryLabel(raw, fallback: "").toLowerCase().trim();
  }

  bool _isCategoryEntryActive(Map? category) {
    final raw = _debugReadKey(category, const [
      "is_active",
      "isActive",
      "active",
      "is_available",
      "isAvailable",
      "available",
      "enabled",
      "status",
      "category_status",
      "categoryStatus",
    ]);
    return raw == null || _debugIsTruthy(raw);
  }

  Set<String> _hiddenCategoryKeys() {
    final hidden = <String>{};
    for (final category in _rawProducts) {
      if (category is! Map) continue;
      final categoryMap = Map<String, dynamic>.from(category);
      if (_isCategoryEntryActive(categoryMap)) continue;
      final key = _categoryKey(
        categoryMap["category_name"] ?? categoryMap["name"],
      );
      if (key.isNotEmpty) hidden.add(key);
    }

    for (final override in _categoryOverrides.values) {
      if (_isCategoryEntryActive(override)) continue;
      final key = _categoryKey(
        override["category_name"] ?? override["name"] ?? override["category"],
      );
      if (key.isNotEmpty) hidden.add(key);
    }
    return hidden;
  }

  void _applyOverridesToProductMaps(
    List<Map<String, dynamic>> productMaps, {
    Set<String> hiddenCategoryKeys = const {},
  }) {
    if (_productOverrides.isEmpty) {
      productMaps.removeWhere(
        (p) => hiddenCategoryKeys.contains(_categoryKey(p["category"])),
      );
      return;
    }
    final Set<int> seenIds = {};
    for (final p in productMaps) {
      final id = p["id"];
      final pid = id is int ? id : int.tryParse(id?.toString() ?? "");
      if (pid == null) continue;
      seenIds.add(pid);
      final override = _productOverrides[pid];
      if (override == null) continue;
      final isAvailable = _isProductEntryAvailable(p, override: override);
      p["is_available"] = isAvailable ? 1 : 0;
      p["isAvailable"] = isAvailable ? 1 : 0;
      p["available"] = isAvailable ? 1 : 0;
      final name = override["item_name"] ?? override["name"];
      if (name != null && name.toString().trim().isNotEmpty) {
        p["name"] = name;
      }
      final price = override["price"] ?? override["item_price"];
      if (price != null) {
        p["price"] = price;
      }
      final category = override["category_name"] ?? override["category"];
      final normalizedCategory = _categoryLabel(category, fallback: "");
      if (normalizedCategory.isNotEmpty) {
        p["category"] = normalizedCategory;
      }
      final type = override["type"];
      if (type != null) {
        p["type"] = type;
      }
      final image = override["item_photo_url"] ?? override["image"];
      if (image != null && image.toString().trim().isNotEmpty) {
        p["image"] = normalizeImageUrlValue(image);
      }
      final description = override["description"] ??
          override["item_description"] ??
          override["itemDescription"] ??
          override["short_description"] ??
          override["shortDescription"];
      if (description != null) {
        p["description"] = description.toString();
      }
    }

    productMaps.removeWhere(
      (p) =>
          !_isProductEntryAvailable(p) ||
          hiddenCategoryKeys.contains(_categoryKey(p["category"])),
    );

    // Add missing items from overrides (newly created products)
    for (final entry in _productOverrides.entries) {
      if (seenIds.contains(entry.key)) continue;
      final o = entry.value;
      if (!_isProductEntryAvailable(o)) continue;
      final categoryName = _categoryLabel(
        o["category_name"] ?? o["category"],
        fallback: "",
      );
      if (hiddenCategoryKeys.contains(_categoryKey(categoryName))) continue;
      final name = (o["item_name"] ?? o["name"] ?? "").toString();
      final price = o["price"] ?? o["item_price"] ?? 0;
      if (name.trim().isEmpty) continue;
      productMaps.add({
        "id": entry.key,
        "name": name,
        "category": categoryName,
        "price": price,
        "image": normalizeImageUrlValue(o["item_photo_url"] ?? o["image"]),
        "description": (o["description"] ??
                o["item_description"] ??
                o["itemDescription"] ??
                o["short_description"] ??
                o["shortDescription"] ??
                "")
            .toString(),
        "type": o["type"],
      });
    }
  }

  List<String> _sectionCategories() {
    return _sectionCategoriesCache;
  }

  List<ProductModel> _filterProductsForCategory(String? category) {
    final base = category == null
        ? allProducts
        : (_productsByCategory[category] ?? const <ProductModel>[]);
    if (searchQuery.isEmpty) return base;
    return base
        .where((p) => p.name.toLowerCase().contains(searchQuery))
        .toList(growable: false);
  }

  bool _debugIsTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final s = value.toString().toLowerCase().trim();
    if (s == "0" ||
        s == "false" ||
        s == "no" ||
        s == "n" ||
        s == "off" ||
        s == "inactive" ||
        s == "disabled" ||
        s == "hidden" ||
        s == "unavailable" ||
        s == "not_available" ||
        s == "not available" ||
        s == "out_of_stock" ||
        s == "out of stock") {
      return false;
    }
    if (s == "1" ||
        s == "true" ||
        s == "yes" ||
        s == "y" ||
        s == "on" ||
        s == "active" ||
        s == "enabled" ||
        s == "available" ||
        s == "in_stock" ||
        s == "in stock") {
      return true;
    }
    final parsed = num.tryParse(s);
    return parsed != null && parsed != 0;
  }

  bool _isProductEntryAvailable(
    Map? item, {
    Map<String, dynamic>? override,
  }) {
    final nested = item?["item"];
    final nestedMap = nested is Map ? Map<String, dynamic>.from(nested) : null;
    final raw = override?["is_available"] ??
        override?["isAvailable"] ??
        override?["available"] ??
        item?["is_available"] ??
        item?["isAvailable"] ??
        item?["available"] ??
        item?["enabled"] ??
        item?["status"] ??
        item?["item_status"] ??
        item?["itemStatus"] ??
        nestedMap?["is_available"] ??
        nestedMap?["isAvailable"] ??
        nestedMap?["available"] ??
        nestedMap?["enabled"] ??
        nestedMap?["status"] ??
        nestedMap?["item_status"] ??
        nestedMap?["itemStatus"];
    return raw == null || _debugIsTruthy(raw);
  }

  String _debugNormKey(String k) =>
      k.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");

  dynamic _debugReadKey(Map? item, List<String> keys) {
    if (item == null) return null;
    for (final key in keys) {
      if (item.containsKey(key)) return item[key];
    }
    final wanted = keys.map(_debugNormKey).toSet();
    for (final entry in item.entries) {
      final nk = _debugNormKey(entry.key.toString());
      if (wanted.contains(nk)) return entry.value;
    }
    return null;
  }

  int _debugToInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? "") ?? 0;
  }

  int _resolveItemId(Map item) {
    return _debugToInt(
      item["item_id"] ??
          item["itemId"] ??
          (item["item"] is Map ? item["item"]["item_id"] : null) ??
          (item["item"] is Map ? item["item"]["itemId"] : null) ??
          (item["item"] is Map ? item["item"]["id"] : null) ??
          item["id"] ??
          item["Id"] ??
          item["ID"],
    );
  }

  List<Map<String, dynamic>> _collectRecommendationDebugItems() {
    final List<Map<String, dynamic>> out = [];
    for (final category in _rawProducts) {
      if (category is! Map) continue;
      final catName =
          category["category_name"] ?? category["name"] ?? "Category";
      final items = category["items"];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final rec = _debugReadKey(item, [
          "is_recommended",
          "isRecommended",
          "recommended",
          "is_recommend",
          "is_recommanded",
        ]);
        final id = _debugToInt(
          _debugReadKey(item, ["id", "Id", "ID", "item_id", "itemId"]),
        );
        final name = (item["item_name"] ?? item["name"] ?? "").toString();
        out.add({
          "id": id,
          "name": name,
          "category": catName.toString(),
          "recRaw": rec,
          "isRecommended": _debugIsTruthy(rec),
        });
      }
    }
    return out;
  }

  void _showRecommendedDebug() {
    if (!kDebugMode) return;
    final data = _collectRecommendationDebugItems();
    final int total = data.length;
    final int recCount = data.where((e) => e["isRecommended"] == true).length;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        "Recommended Debug",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text("Total items: $total"),
                  Text("Recommended (is_recommended=1): $recCount"),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Expanded(
                    child: data.isEmpty
                        ? const Center(child: Text("No items found"))
                        : ListView.separated(
                            itemCount: data.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final row = data[i];
                              final bool isRec = row["isRecommended"] == true;
                              return ListTile(
                                dense: true,
                                title: Text(
                                  "${row["name"]} (id: ${row["id"]})",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  "Cat: ${row["category"]} | raw: ${row["recRaw"]}",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Icon(
                                  isRec ? Icons.check_circle : Icons.cancel,
                                  color: isRec
                                      ? const Color(0xFF1B8E3E)
                                      : Colors.red,
                                  size: 18,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (hasError) {
      final bool restaurantClosed = errorMessage == _restaurantClosedMessage ||
          _isClosedMenuMessage(errorMessage);
      return Scaffold(
        backgroundColor: const Color(0xFFF7F7F7),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFFF1EE),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        restaurantClosed
                            ? Icons.storefront_rounded
                            : Icons.error_outline_rounded,
                        size: 38,
                        color: const Color(0xFF9F342C),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      restaurantClosed
                          ? "Restaurant Closed"
                          : "Unable to load menu",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F8F9),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE3E6EA)),
                      ),
                      child: Text(
                        errorMessage,
                        style: const TextStyle(
                          color: Colors.black87,
                          height: 1.45,
                        ),
                        textAlign: TextAlign.left,
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loadProducts,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF9F342C),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text("Retry"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final bool sectionMode = selectedIndex == 0;
    final filtered = sectionMode
        ? _filterProductsForCategory(null)
        : _filterProductsForCategory(categories[selectedIndex]);

    final width = MediaQuery.of(context).size.width;
    final bool isTablet = width > 600;
    final gridCount = width < 600
        ? 2
        : width < 900
            ? 3
            : 4;

    // 🎯 FIX: We wrap the whole body in a Row so the Left Bar is independent
    // of the main content scroll and spans the full height.
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ================= LEFT BAR (FULL HEIGHT) =================
              _buildLeftCategoryBar(),

              // ================= RIGHT CONTENT AREA =================
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: _buildRightArea(filtered, gridCount),
                ),
              ),
            ],
          ),
          if (_showScrollToTop)
            Positioned(
              right: 18,
              bottom: _bottomBarBaseHeight(isTablet) + 14,
              child: FloatingActionButton(
                onPressed: () {
                  if (!scrollCtrl.hasClients) return;
                  scrollCtrl.animateTo(
                    0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                  );
                },
                backgroundColor: const Color(0xFF9F342C),
                elevation: 4,
                child: const Icon(
                  Icons.keyboard_arrow_up,
                  color: Color.fromARGB(255, 255, 255, 255),
                  size: 55,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLeftCategoryBar() {
    // Determine device type
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final double radius = isTablet ? 35 : 28;
    final double scale = isTablet ? 1.4 : 0.8;

    return Container(
      // Updated width logic: 140 for Tablet, 100 for Mobile
      width: isTablet ? 170 : 100,
      color: const Color.fromARGB(255, 120, 33, 27),
      child: Stack(
        children: [
          Column(
            children: [
              const SizedBox(height: 20),
              // Adjusted logo height for mobile
              InkWell(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                    (_) => false,
                  );
                },
                onLongPress: kDebugMode ? _showRecommendedDebug : null,
                child: Image.asset(
                  "assets/self.png",
                  height: isTablet ? 50 : 40,
                ),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: Column(
                  children: [
                    // ================= CATEGORY LIST =================
                    Expanded(
                      child: ListView.builder(
                        controller: _categoryScrollController,
                        padding: EdgeInsets.only(bottom: isTablet ? 90 : 80),
                        itemCount: categories.length,
                        itemBuilder: (_, i) {
                          final selected = selectedIndex == 0
                              ? i == _activeCategoryIndex
                              : i == selectedIndex;
                          final catName = categories[i];
                          final double cacheScale = scale < 1 ? 1 : scale;
                          final int imageSize =
                              (radius * 2 * cacheScale * dpr).round();
                          final String categoryImageUrl = normalizeImageUrl(
                            _showCategoryImages ? categoryImages[catName] : "",
                          );
                          void selectCategory() {
                            setState(() {
                              selectedIndex = i;
                              _activeCategoryIndex = i;
                              searchQuery = "";
                              searchCtrl.clear();
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!scrollCtrl.hasClients) return;
                              scrollCtrl.jumpTo(0);
                            });
                          }

                          if (!_showCategoryImages) {
                            return Builder(
                              builder: (ctx) {
                                _leftCategoryContexts[catName] = ctx;
                                return GestureDetector(
                                  key: ValueKey("left-cat-$catName"),
                                  onTap: selectCategory,
                                  child: _textOnlyCategoryTile(
                                    catName,
                                    selected: selected,
                                    isTablet: isTablet,
                                  ),
                                );
                              },
                            );
                          }

                          return Builder(
                            builder: (ctx) {
                              _leftCategoryContexts[catName] = ctx;
                              return GestureDetector(
                                key: ValueKey("left-cat-$catName"),
                                onTap: selectCategory,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    if (selected)
                                      Positioned(
                                        top: -25,
                                        bottom: -15,
                                        left: 15,
                                        right: 0,
                                        child: CustomPaint(
                                          painter: SelectionPainter(),
                                        ),
                                      ),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        vertical: isTablet ? 20 : 15,
                                      ),
                                      width: double.infinity,
                                      constraints: BoxConstraints(
                                        minHeight: isTablet ? 120 : 90,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AnimatedScale(
                                            scale: scale,
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: selected
                                                      ? Colors.white
                                                      : Colors.transparent,
                                                  width: 2,
                                                ),
                                                boxShadow: selected
                                                    ? [
                                                        BoxShadow(
                                                          color: Colors.black
                                                              .withValues(
                                                                  alpha: 0.2),
                                                          blurRadius: 10,
                                                          offset: const Offset(
                                                            0,
                                                            5,
                                                          ),
                                                        ),
                                                      ]
                                                    : [],
                                              ),
                                              child: ClipOval(
                                                child: SizedBox(
                                                  width: radius * 2,
                                                  height: radius * 2,
                                                  child: catName == "All"
                                                      ? Image.asset(
                                                          "assets/catall.jpg",
                                                          fit: BoxFit.cover,
                                                          filterQuality:
                                                              FilterQuality
                                                                  .high,
                                                          errorBuilder:
                                                              (_, __, ___) =>
                                                                  Container(
                                                            color:
                                                                Colors.white10,
                                                            child: Icon(
                                                              Icons.fastfood,
                                                              color: Colors
                                                                  .white70,
                                                              size:
                                                                  radius * 0.9,
                                                            ),
                                                          ),
                                                        )
                                                      : categoryImageUrl
                                                              .isNotEmpty
                                                          ? AppNetworkImage(
                                                              url:
                                                                  categoryImageUrl,
                                                              fit: BoxFit.cover,
                                                              cacheWidth:
                                                                  imageSize,
                                                              cacheHeight:
                                                                  imageSize,
                                                              fallback:
                                                                  Container(
                                                                color: Colors
                                                                    .white10,
                                                                child: Icon(
                                                                  Icons
                                                                      .fastfood,
                                                                  color: Colors
                                                                      .white70,
                                                                  size: isTablet
                                                                      ? 32
                                                                      : 24,
                                                                ),
                                                              ),
                                                            )
                                                          : Container(
                                                              color: Colors
                                                                  .white10,
                                                              child: Icon(
                                                                Icons.fastfood,
                                                                color: Colors
                                                                    .white70,
                                                                size: isTablet
                                                                    ? 32
                                                                    : 24,
                                                              ),
                                                            ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          SizedBox(height: isTablet ? 12 : 6),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                vertical: 4,
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  8.0,
                                                ),
                                                child: AnimatedDefaultTextStyle(
                                                  duration: const Duration(
                                                    milliseconds: 250,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: selected
                                                        ? Colors.black
                                                        : const Color.fromARGB(
                                                            255,
                                                            242,
                                                            220,
                                                            188,
                                                          ),
                                                    fontSize:
                                                        isTablet ? 16 : 14,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                  child: Text(
                                                    catName,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
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
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_showScrollArrow)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _leftScrollHintController,
                  builder: (_, __) {
                    return Transform.translate(
                      offset: Offset(0, 18 * _leftScrollHintController.value),
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Color.fromARGB(255, 255, 255, 255),
                        size: 68,
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textOnlyCategoryTile(
    String name, {
    required bool selected,
    required bool isTablet,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: EdgeInsets.fromLTRB(
        isTablet ? 14 : 8,
        isTablet ? 8 : 6,
        selected ? 0 : (isTablet ? 12 : 8),
        isTablet ? 8 : 6,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 16 : 10,
        vertical: isTablet ? 18 : 14,
      ),
      constraints: BoxConstraints(minHeight: isTablet ? 72 : 56),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFFFFF6E8)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(isTablet ? 22 : 16),
          right: Radius.circular(selected ? 0 : (isTablet ? 22 : 16)),
        ),
        border: Border.all(
          color: selected
              ? const Color(0xFFFFD89C)
              : Colors.white.withValues(alpha: 0.14),
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ]
            : const [],
      ),
      alignment: Alignment.center,
      child: Text(
        name,
        textAlign: TextAlign.center,
        maxLines: isTablet ? 3 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? const Color(0xFF5F1711) : const Color(0xFFFFE7C8),
          fontSize: isTablet ? 17 : 14,
          height: 1.1,
          fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildRightArea(List<ProductModel> filtered, int gridCount) {
    final double width = MediaQuery.of(context).size.width;
    final bool isTablet = width > 600;
    final bool sectionMode = selectedIndex == 0;
    final double leftBarWidth = isTablet ? 170 : 100;
    final double rightAreaWidth = (width - leftBarWidth).clamp(320.0, width);
    const double gridPadding = 24; // SliverPadding left + right
    final double crossAxisSpacing = isTablet ? 17 : 12;
    final double gridWidth = (rightAreaWidth - gridPadding).clamp(200.0, width);
    final double itemWidth =
        (gridWidth - ((gridCount - 1) * crossAxisSpacing)) / gridCount;
    final double imageHeight = itemWidth / 1.2;
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int imageCacheWidth = (itemWidth * dpr).round().clamp(1, 4096);
    final int imageCacheHeight = (imageHeight * dpr).round().clamp(1, 4096);
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double bottomBarHeight = _bottomBarBaseHeight(isTablet);
    final double bottomSpace = bottomBarHeight + bottomInset + 16;
    return Column(
      children: [
        Padding(padding: const EdgeInsets.all(12), child: _buildSearchRow()),
        Expanded(
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(overscroll: false),
                      child: CustomScrollView(
                        controller: scrollCtrl,
                        physics: const ClampingScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: BestSellingWidget(
                              products: allProducts,
                              isActive: widget.isActive,
                              onAddToCart: widget.onAddToCart,
                            ),
                          ),
                          const SliverToBoxAdapter(child: SizedBox(height: 8)),
                          if (sectionMode)
                            ..._buildCategorySections(
                              gridCount,
                              isTablet,
                              imageCacheWidth: imageCacheWidth,
                              imageCacheHeight: imageCacheHeight,
                              showHeaders: true,
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.all(12),
                              sliver: SliverGrid(
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  i,
                                ) {
                                  final p = filtered[i];
                                  return ProductCardRef(
                                    id: p.id,
                                    name: p.name,
                                    category: p.category,
                                    price: p.price,
                                    imagePath: _showItemImages ? p.image : "",
                                    description: p.description,
                                    isVeg: p.isVeg,
                                    qty: widget.getQtyForProduct(p.id),
                                    onAddToCart: widget.onAddToCart,
                                    imageCacheWidth: imageCacheWidth,
                                    imageCacheHeight: imageCacheHeight,
                                    variations: variationsMap[p.id] ?? [],
                                    modifiers: modifiersMap[p.id] ?? [],
                                  );
                                }, childCount: filtered.length),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: gridCount,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: isTablet ? 17 : 12,
                                  childAspectRatio: isTablet ? 0.69 : 0.62,
                                ),
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: SizedBox(height: bottomSpace),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showProductScrollHint && filtered.length > gridCount * 2)
                    const SizedBox.shrink(),
                ],
              ),
              Align(alignment: Alignment.bottomCenter, child: _bottomBar()),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildCategorySections(
    int gridCount,
    bool isTablet, {
    required int imageCacheWidth,
    required int imageCacheHeight,
    required bool showHeaders,
  }) {
    final List<Widget> slivers = [];
    for (final cat in _sectionCategories()) {
      final items = _filterProductsForCategory(cat);
      if (items.isEmpty) continue;

      if (showHeaders) {
        slivers.add(
          SliverToBoxAdapter(
            child: Builder(
              builder: (ctx) {
                _rightCategoryContexts[cat] = ctx;
                return Container(
                  key: ValueKey("cat-header-$cat"),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    cat,
                    style: TextStyle(
                      fontSize: isTablet ? 22 : 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      } else {
        slivers.add(
          SliverToBoxAdapter(
            child: Builder(
              builder: (ctx) {
                _rightCategoryContexts[cat] = ctx;
                return SizedBox(key: ValueKey("cat-spacer-$cat"), height: 10);
              },
            ),
          ),
        );
      }

      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate((context, i) {
              final p = items[i];
              return ProductCardRef(
                id: p.id,
                name: p.name,
                category: p.category,
                price: p.price,
                imagePath: _showItemImages ? p.image : "",
                description: p.description,
                isVeg: p.isVeg,
                qty: widget.getQtyForProduct(p.id),
                onAddToCart: widget.onAddToCart,
                imageCacheWidth: imageCacheWidth,
                imageCacheHeight: imageCacheHeight,
                variations: variationsMap[p.id] ?? [],
                modifiers: modifiersMap[p.id] ?? [],
              );
            }, childCount: items.length),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: gridCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: isTablet ? 17 : 12,
              childAspectRatio: isTablet ? 0.69 : 0.62,
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  int _totalItems() {
    return widget.cart.fold<int>(
      0,
      (sum, item) => sum + ((item["qty"] ?? 0) as int),
    );
  }

  int _totalPrice() {
    return widget.cart.fold<int>(
      0,
      (sum, item) =>
          sum + ((item["price"] ?? 0) as int) * ((item["qty"] ?? 0) as int),
    );
  }

  double _bottomBarBaseHeight(bool isTablet) {
    return isTablet ? 100 : 132;
  }

  Widget _bottomBar() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double baseHeight = _bottomBarBaseHeight(isTablet);
    final bool hasItems = _totalItems() > 0;
    final int totalItems = _totalItems();
    final int totalPrice = _totalPrice();

    const Color accentOrange = Color(0xFF9F342C);
    const Color cartGreen = Color.fromARGB(255, 65, 159, 44);

    return SizedBox(
      height: baseHeight + bottomInset,
      child: Container(
        padding: EdgeInsets.only(
          left: isTablet ? 24 : 16,
          right: isTablet ? 24 : 16,
          top: 10,
          bottom: 10 + bottomInset,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            topRight: Radius.circular(10),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.89),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: isTablet
            ? Row(
                children: [
                  SizedBox(
                    width: 130,
                    height: 54,
                    child: OutlinedButton.icon(
                      onPressed:
                          hasItems ? widget.onClearCart : _showEmptyCartDialog,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color.fromARGB(255, 120, 33, 27),
                        side: const BorderSide(color: accentOrange, width: 1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 24,
                        color: Color.fromARGB(255, 120, 33, 27),
                      ),
                      label: const Text(
                        "CLEAR",
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child:
                          _buildBottomBarSummary(totalItems, totalPrice, true)),
                  const SizedBox(width: 12),
                  SizedBox(
                      width: 180,
                      child: _buildViewCartButton(hasItems, true, cartGreen)),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildBottomBarSummary(totalItems, totalPrice, false),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: OutlinedButton(
                            onPressed: hasItems
                                ? widget.onClearCart
                                : _showEmptyCartDialog,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color.fromARGB(
                                255,
                                120,
                                33,
                                27,
                              ),
                              side: const BorderSide(
                                color: accentOrange,
                                width: 1,
                              ),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: Color.fromARGB(255, 120, 33, 27),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 42,
                          child:
                              _buildViewCartButton(hasItems, false, cartGreen),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildBottomBarSummary(int totalItems, int totalPrice, bool isTablet) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isTablet ? 16 : 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.shopping_bag,
                size: isTablet ? 62 : 42,
                color: const Color(0xFFFFA726),
              ),
              Transform.translate(
                offset: Offset(0, isTablet ? 8 : 5),
                child: Text(
                  "$totalItems",
                  style: TextStyle(
                    fontSize: isTablet ? 19 : 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(width: isTablet ? 12 : 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Your order",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: isTablet ? 12 : 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "RS $totalPrice.00",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: isTablet ? 13 : 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewCartButton(bool hasItems, bool isTablet, Color cartGreen) {
    return ScaleTransition(
      scale: _viewCartScale,
      child: ElevatedButton(
        onPressed: () {
          if (!hasItems) {
            _showEmptyCartDialog();
            return;
          }
          widget.onViewCart();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: cartGreen,
          foregroundColor: Colors.white,
          elevation: 4,
          shadowColor: cartGreen.withValues(alpha: 0.4),
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isTablet ? 16 : 12),
          ),
          minimumSize: Size(double.infinity, isTablet ? 54 : 42),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _cartBounceAnim,
              child: Builder(
                builder: (ctx) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final render = ctx.findRenderObject();
                    if (render is! RenderBox || !render.attached) {
                      return;
                    }
                    final rect =
                        render.localToGlobal(Offset.zero) & render.size;
                    if (rect != _lastCartIconRect) {
                      _lastCartIconRect = rect;
                      widget.onCartIconRect(rect);
                    }
                  });
                  return Icon(
                    Icons.shopping_cart,
                    size: isTablet ? 18 : 16,
                    color: Colors.white,
                  );
                },
              ),
            ),
            SizedBox(width: isTablet ? 8 : 6),
            Flexible(
              child: Text(
                "VIEW CART",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: isTablet ? 15 : 11,
                  letterSpacing: isTablet ? 0.4 : 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEmptyCartDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_cart_outlined,
                size: 32,
                color: Colors.orange.shade600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Cart is Empty",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
          ],
        ),
        content: const Text(
          "Please add a product before viewing the cart.",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Colors.black54, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.only(bottom: 20),
        actions: [
          SizedBox(
            width: 160,
            height: 44,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade600,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                "ADD ITEMS",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildNoNetworkIndicator() {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.wifi_off_rounded,
                color: Colors.redAccent,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "No INTERNET",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  "Offline",
                  style: TextStyle(
                    color: Colors.black54,
                    fontWeight: FontWeight.w600,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: [
        Flexible(
          flex: 3,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Padding(
              padding: const EdgeInsets.only(right: 20),
              child: TextField(
                controller: searchCtrl,
                onChanged: (v) => setState(() => searchQuery = v.toLowerCase()),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  prefixIcon: const Icon(Icons.search),
                  hintText: "Search items...",
                  suffixIcon: searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            searchCtrl.clear();
                            setState(() => searchQuery = "");
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 20),
        OutlinedButton(
          onPressed: () {
            _showRestartDialog(context);
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF9F342C),
            side: const BorderSide(
              color: Color.fromARGB(255, 0, 0, 0),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.home_outlined,
                size: 18,
                color: Color.fromARGB(255, 0, 0, 0),
              ),
              SizedBox(width: 6),
              Text(
                "Restart",
                style: TextStyle(color: Color.fromARGB(255, 0, 0, 0)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showRestartDialog(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;

    showDialog(
      context: context,
      barrierDismissible: false, // kiosk-safe
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isTablet ? 40 : 26),
        ),
        contentPadding: EdgeInsets.all(isTablet ? 40 : 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Theme-matching Icon Container
            Container(
              padding: EdgeInsets.all(isTablet ? 30 : 20),
              decoration: BoxDecoration(
                color: const Color(0xFFFBAA30).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.refresh_rounded, // Refresh icon for "Restart"
                color: const Color(0xFFFBAA30),
                size: isTablet ? 80 : 50,
              ),
            ),
            SizedBox(height: isTablet ? 30 : 20),

            // Header Text
            Text(
              "RESTART ORDER?",
              style: TextStyle(
                fontSize: isTablet ? 32 : 22,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 15),

            // Descriptive Text
            Text(
              "Are you sure you want to restart?\nYour current selection will be cleared.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isTablet ? 20 : 15.5,
                color: Colors.black54,
                height: 1.5,
              ),
            ),
            SizedBox(height: isTablet ? 45 : 30),

            // Action Buttons
            Row(
              children: [
                // "No" Button
                Expanded(
                  child: SizedBox(
                    height: isTablet ? 75 : 55,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade300, width: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            isTablet ? 20 : 12,
                          ),
                        ),
                      ),
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: Icon(
                        Icons.close_rounded,
                        size: isTablet ? 20 : 16,
                        color: Colors.black54,
                      ),
                      label: Text(
                        "NO, GO BACK",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isTablet ? 16 : 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: isTablet ? 20 : 12),

                // "Yes" Button
                Expanded(
                  child: SizedBox(
                    height: isTablet ? 75 : 55,
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
                        Navigator.pop(dialogContext); // Close dialog
                        _goToWelcome(context); // Execute reset logic
                      },
                      child: Text(
                        "YES, RESTART",
                        style: TextStyle(
                          fontSize: isTablet ? 16 : 14,
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
      ),
    );
  }
}

Map<String, dynamic> _parseProductsIsolate(List<dynamic> raw) {
  bool? truthyStatus(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final s = value.toString().toLowerCase().trim();
    if (s.isEmpty) return null;
    if (s == "0" ||
        s == "false" ||
        s == "no" ||
        s == "n" ||
        s == "off" ||
        s == "inactive" ||
        s == "disabled" ||
        s == "hidden" ||
        s == "unavailable" ||
        s == "not_available") {
      return false;
    }
    if (s == "1" ||
        s == "true" ||
        s == "yes" ||
        s == "y" ||
        s == "on" ||
        s == "active" ||
        s == "enabled" ||
        s == "available") {
      return true;
    }
    return null;
  }

  String normKey(String key) =>
      key.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");

  dynamic readKey(Map? item, List<String> keys) {
    if (item == null) return null;
    for (final key in keys) {
      if (item.containsKey(key)) return item[key];
    }
    final wanted = keys.map(normKey).toSet();
    for (final entry in item.entries) {
      if (wanted.contains(normKey(entry.key.toString()))) return entry.value;
    }
    return null;
  }

  String categoryLabel(dynamic raw) {
    if (raw is Map) {
      final nested = raw["category_name"] ??
          raw["name"] ??
          raw["category"] ??
          raw["title"];
      if (!identical(nested, raw)) {
        return categoryLabel(nested);
      }
    }

    final text = raw?.toString().trim() ?? "";
    if (text.isEmpty) return "";

    if (text.startsWith("{") && text.endsWith("}")) {
      final categoryMatch = RegExp(
        r"category_name\s*:\s*([^,}]+)",
      ).firstMatch(text);
      if (categoryMatch != null) {
        final value = categoryMatch.group(1)?.trim() ?? "";
        if (value.isNotEmpty) return value;
      }

      final nameMatch = RegExp(r"name\s*:\s*([^,}]+)").firstMatch(text);
      if (nameMatch != null) {
        final value = nameMatch.group(1)?.trim() ?? "";
        if (value.isNotEmpty) return value;
      }
    }

    return text;
  }

  bool isVisibleCategoryName(String category) {
    final key = category.trim().toLowerCase();
    final normalized = key.replaceAll(RegExp(r"[^a-z0-9]"), "");
    const hiddenNames = {
      "other",
      "others",
      "othercategory",
      "othercategories",
      "otherscategory",
      "otherscategories",
      "unknown",
      "unknowncategory",
      "unknowncategories",
      "uncategorized",
    };
    return key.isNotEmpty &&
        normalized.isNotEmpty &&
        !hiddenNames.contains(normalized);
  }

  int toInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? "") ?? 0;
  }

  int resolveItemId(Map item) {
    return toInt(
      item["item_id"] ??
          item["itemId"] ??
          (item["item"] is Map ? item["item"]["item_id"] : null) ??
          (item["item"] is Map ? item["item"]["itemId"] : null) ??
          (item["item"] is Map ? item["item"]["id"] : null) ??
          item["id"] ??
          item["Id"] ??
          item["ID"],
    );
  }

  dynamic firstNonEmptyType(List<dynamic> values) {
    for (final v in values) {
      if (v == null) continue;
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) continue;
        return s;
      }
      return v;
    }
    return null;
  }

  final List<Map<String, dynamic>> products = [];
  final Map<String, String> categoryImages = {};
  final Map<int, List<Map<String, dynamic>>> variationsMap = {};
  final Map<int, List<Map<String, dynamic>>> modifiersMap = {};
  final Set<String> categories = {};

  for (final category in raw) {
    if (category is! Map) continue;
    final rawCategoryActive = readKey(category, const [
      "is_active",
      "isActive",
      "active",
      "is_available",
      "isAvailable",
      "available",
      "enabled",
      "status",
      "category_status",
      "categoryStatus",
    ]);
    final bool catActive = truthyStatus(rawCategoryActive) ?? true;
    if (!catActive) continue;

    final String catName = categoryLabel(
      category["category_name"] ??
          category["name"] ??
          category["category"] ??
          category["title"],
    );
    final String catImage = category["item_photo_url"]?.toString() ??
        category["category_image"]?.toString() ??
        category["category_image_url"]?.toString() ??
        category["image_url"]?.toString() ??
        category["image"]?.toString() ??
        category["photo_url"]?.toString() ??
        "";
    final String normalizedCatImage = normalizeImageUrl(catImage);

    if (catName.isNotEmpty && catImage.isNotEmpty) {
      categoryImages[catName] = normalizedCatImage;
    }

    final items = category["items"];
    if (items is! List) continue;

    for (final item in items) {
      if (item is! Map) continue;
      final nested = item["item"];
      final nestedMap =
          nested is Map ? Map<String, dynamic>.from(nested) : null;
      final rawAvailability = item["is_available"] ??
          item["isAvailable"] ??
          item["available"] ??
          item["enabled"] ??
          item["status"] ??
          item["item_status"] ??
          item["itemStatus"] ??
          nestedMap?["is_available"] ??
          nestedMap?["isAvailable"] ??
          nestedMap?["available"] ??
          nestedMap?["enabled"] ??
          nestedMap?["status"] ??
          nestedMap?["item_status"] ??
          nestedMap?["itemStatus"];
      if (!(truthyStatus(rawAvailability) ?? true)) continue;

      final int itemId = resolveItemId(item);
      if (itemId == 0) continue;

      final variationsRaw = item["variations"];
      final List<Map<String, dynamic>> variations = variationsRaw is List
          ? variationsRaw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];

      final rawModifiers = item["modifiers"];
      final List<Map<String, dynamic>> modifiers =
          rawModifiers is Map && rawModifiers["options"] is List
              ? (rawModifiers["options"] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
              : <Map<String, dynamic>>[];

      variationsMap[itemId] = variations;
      modifiersMap[itemId] = modifiers;

      final preferredType = firstNonEmptyType([
        item["type"],
        item["veg_type"],
        item["vegType"],
        item["food_type"],
        item["foodType"],
        item["item_type"],
        item["itemType"],
        nestedMap?["type"],
        nestedMap?["veg_type"],
        nestedMap?["vegType"],
        nestedMap?["food_type"],
        nestedMap?["foodType"],
        nestedMap?["item_type"],
        nestedMap?["itemType"],
      ]);
      final fallbackType = firstNonEmptyType([
        item["is_veg"],
        item["isVeg"],
        item["is_vegetarian"],
        item["isVegetarian"],
        item["vegetarian"],
        nestedMap?["is_veg"],
        nestedMap?["isVeg"],
        nestedMap?["is_vegetarian"],
        nestedMap?["isVegetarian"],
        nestedMap?["vegetarian"],
      ]);
      final rawType = preferredType ?? fallbackType;

      String pickName() {
        final direct = item["item_name"] ?? item["name"];
        if (direct != null && direct.toString().trim().isNotEmpty) {
          return direct.toString();
        }
        final nestedName = nestedMap?["item_name"] ?? nestedMap?["name"];
        return nestedName?.toString() ?? "";
      }

      dynamic pickPrice() {
        final direct = item["price"] ?? item["item_price"];
        if (direct != null) return direct;
        return nestedMap?["price"] ?? nestedMap?["item_price"] ?? 0;
      }

      String pickImage() {
        final direct = item["item_photo_url"] ??
            item["image_url"] ??
            item["image"] ??
            item["photo_url"];
        if (direct != null && direct.toString().trim().isNotEmpty) {
          return normalizeImageUrlValue(direct);
        }
        final nestedImage = nestedMap?["item_photo_url"] ??
            nestedMap?["image_url"] ??
            nestedMap?["image"] ??
            nestedMap?["photo_url"];
        final normalizedNestedImage = normalizeImageUrlValue(nestedImage);
        return normalizedNestedImage.isNotEmpty
            ? normalizedNestedImage
            : normalizedCatImage;
      }

      String pickDescription() {
        final direct = item["description"] ??
            item["item_description"] ??
            item["itemDescription"] ??
            item["short_description"] ??
            item["shortDescription"];
        if (direct != null && direct.toString().trim().isNotEmpty) {
          return direct.toString();
        }
        final nestedDescription = nestedMap?["description"] ??
            nestedMap?["item_description"] ??
            nestedMap?["itemDescription"] ??
            nestedMap?["short_description"] ??
            nestedMap?["shortDescription"];
        return nestedDescription?.toString() ?? "";
      }

      final String name = pickName();
      final dynamic price = pickPrice();
      final String image = pickImage();
      final String description = pickDescription();

      products.add({
        "id": itemId,
        "name": name,
        "category": catName,
        "price": price,
        "image": image,
        "description": description,
        "type": ProductModel.normalizeType(rawType),
      });

      if (isVisibleCategoryName(catName)) {
        categories.add(catName);
      }
    }
  }

  return {
    "products": products,
    "categories": categories.toList(),
    "categoryImages": categoryImages,
    "variationsMap": variationsMap,
    "modifiersMap": modifiersMap,
  };
}

///
///
///
