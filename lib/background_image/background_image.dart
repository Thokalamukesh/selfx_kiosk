import 'dart:async';

import 'package:api_selfxo_project/core/kiosk_bootstrap.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/kiosk_api.dart';
import '../screens/register_screen.dart';
import '../screens/main_navigation.dart';
import '../screens/pin_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with WidgetsBindingObserver {
  Timer? _sliderTimer;
  Timer? _adminTapResetTimer;
  VoidCallback? _maintenanceListener;
  VoidCallback? _mediaRefreshListener;
  VoidCallback? _restaurantInfoListener;
  int _mediaRefreshKey = 0;

  bool isLoading = true;
  bool hasError = false;
  String? _errorDetails;
  bool _openingAdmin = false;
  bool _openingOrder = false;
  bool _loadingRestaurant = false;
  bool _webMenuRedirected = false;
  VoidCallback? _onlineListener;
  int _adminTapCount = 0;

  String restaurantName = "Start Your Order";
  List<String> banners = [];
  int currentIndex = 0;
  bool _showDineIn = true;
  bool _showPickup = true;

  Future<void> _redirectToRegisterScreen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");
    await prefs.remove("admin_token");
    await prefs.remove("device_uuid");
    await prefs.remove("device_id");
    await prefs.setBool("kiosk_setup_done", false);

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const UserIdScreen()),
      (_) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      WidgetsBinding.instance.addObserver(this);
    }

    _loadRestaurant();

    _restaurantInfoListener = _handleRestaurantInfoUpdated;
    OrderUtils.infoRevision.addListener(_restaurantInfoListener!);

    ConnectivityService.instance.start();
    _onlineListener = () {
      final online = ConnectivityService.instance.isOnline.value;
      if (online && (hasError || isLoading)) {
        if (!mounted) return;
        setState(() {
          isLoading = true;
          hasError = false;
        });
        _loadRestaurant();
      }
    };
    ConnectivityService.instance.isOnline.addListener(_onlineListener!);

    if (!kIsWeb) {
      _maintenanceListener = _handleMaintenanceTick;
      KioskMemoryService.instance.maintenanceTick.addListener(
        _maintenanceListener!,
      );
      _mediaRefreshListener = _handleMediaRefreshTick;
      KioskMemoryService.instance.mediaRefreshTick.addListener(
        _mediaRefreshListener!,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _sliderTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _startSlider();
    }
  }

  Future<void> _loadRestaurant() async {
    if (_loadingRestaurant) return;
    _loadingRestaurant = true;
    try {
      await DeviceBootstrap.ensureDeviceReady();
      final prefs = await SharedPreferences.getInstance();
      final savedDisplayName = _storedDisplayName(prefs);
      final res = await KioskApi().getRestaurantData();

      final restaurant = res.data["restaurant"];
      final media = restaurant?["media"];
      final kioskSettings = res.data["kiosk_settings"];

      final backendDeviceId = kioskSettings?["device_id"];
      final hasBackendDeviceId = backendDeviceId != null &&
          backendDeviceId.toString().trim().isNotEmpty;
      if (!hasBackendDeviceId) {
        await _redirectToRegisterScreen();
        return;
      }

      if (backendDeviceId != null && backendDeviceId.toString().isNotEmpty) {
        await prefs.setString("device_uuid", backendDeviceId.toString());
      }

      final gst = _extractTaxId(
        restaurant is Map ? restaurant : null,
        kioskSettings is Map ? kioskSettings : null,
      );
      if (gst != null && gst.toString().trim().isNotEmpty) {
        await prefs.setString("gst_number", gst.toString().trim());
      }

      await ReceiptPrintMode.storeFromMap(
        kioskSettings is Map ? kioskSettings : null,
      );
      await ReceiptPrintMode.storeFromMap(
        restaurant is Map ? restaurant : null,
      );
      await KioskRestaurantMeta.storeFromMaps(
        restaurant: restaurant is Map ? restaurant : null,
        kioskSettings: kioskSettings is Map ? kioskSettings : null,
      );

      List<String> tempBanners = [];
      if (media is List) {
        tempBanners = media
            .whereType<Map>()
            .where((m) => m["path"] != null)
            .map<String>((m) => normalizeImageUrl(m["path"].toString()))
            .where(isSupportedRasterImageUrl)
            .toList();
      }

      if (tempBanners.isEmpty &&
          kioskSettings is Map &&
          kioskSettings["home_banner_url"] != null) {
        final bannerUrl = normalizeImageUrl(
          kioskSettings["home_banner_url"].toString(),
        );
        if (isSupportedRasterImageUrl(bannerUrl)) {
          tempBanners.add(bannerUrl);
        }
      }

      if (!mounted) return;

      final types = _resolveOrderTypeAvailability(
        restaurant is Map ? restaurant : null,
        kioskSettings is Map ? kioskSettings : null,
      );

      setState(() {
        restaurantName = savedDisplayName ??
            KioskRestaurantMeta.resolveRestaurantName(
              restaurant: restaurant is Map ? restaurant : null,
              kioskSettings: kioskSettings is Map ? kioskSettings : null,
              fallback: "Start Your Order",
            );
        banners = tempBanners;
        currentIndex =
            tempBanners.isEmpty ? 0 : currentIndex % tempBanners.length;
        _showDineIn = types["dine_in"] ?? true;
        _showPickup = types["pickup"] ?? true;
        isLoading = false;
        hasError = false;
        _errorDetails = null;
      });

      if (kIsWeb && !_webMenuRedirected) {
        _webMenuRedirected = true;
        final orderType = _resolveInitialWebOrderType(types);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => MainNavigation(orderType: orderType),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          );
        });
        return;
      }

      _startSlider();
    } catch (e) {
      final rawError = e.toString();
      final isRestaurantNotConfigured =
          rawError.contains("RESTAURANT_NOT_CONFIGURED");

      if (kIsWeb && isRestaurantNotConfigured) {
        await _redirectToRegisterScreen();
        return;
      }

      if (!mounted) return;
      setState(() {
        hasError = true;
        isLoading = false;
        _errorDetails = rawError;
      });
    } finally {
      _loadingRestaurant = false;
    }
  }

  String _resolveInitialWebOrderType(Map<String, bool> types) {
    final requested = Uri.base.queryParameters["order_type"] ??
        Uri.base.queryParameters["orderType"] ??
        Uri.base.queryParameters["type"];
    final normalizedRequested =
        requested == null ? null : _normalizeOrderType(requested);

    if (normalizedRequested == "pickup" ||
        normalizedRequested == "takeaway" ||
        normalizedRequested == "take_away") {
      if (types["pickup"] == true) return "pickup";
    }

    if (normalizedRequested == "dine_in" || normalizedRequested == "dinein") {
      if (types["dine_in"] == true) return "dine_in";
    }

    if (types["dine_in"] == true) return "dine_in";
    if (types["pickup"] == true) return "pickup";
    return "dine_in";
  }

  void _startSlider() {
    _sliderTimer?.cancel();
    if (!KioskConfig.enableAutoScroll) return;
    if (banners.length < 2) return;
    _sliderTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || banners.isEmpty) return;
      setState(() {
        currentIndex = (currentIndex + 1) % banners.length;
      });
    });
  }

  void _handleMaintenanceTick() {
    if (!mounted) return;
    try {
      _sliderTimer?.cancel();
      if (banners.length < 2) return;
      _startSlider();
    } catch (_) {}
  }

  void _handleMediaRefreshTick() {
    if (!mounted) return;
    _mediaRefreshKey = KioskMemoryService.instance.mediaRefreshTick.value;
    setState(() {});
  }

  Future<void> _handleRestaurantInfoUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final displayName = _storedDisplayName(prefs);
    if (!mounted || displayName == null) return;
    setState(() => restaurantName = displayName);
  }

  String? _storedDisplayName(SharedPreferences prefs) {
    for (final key in const [
      KioskRestaurantMeta.kioskDisplayNameKey,
      "kiosk_name",
      KioskRestaurantMeta.restaurantNameKey,
    ]) {
      final value = prefs.getString(key)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      WidgetsBinding.instance.removeObserver(this);
    }
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
    if (_restaurantInfoListener != null) {
      OrderUtils.infoRevision.removeListener(_restaurantInfoListener!);
    }
    _adminTapResetTimer?.cancel();
    _sliderTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      if (hasError) {
        return _buildWebErrorScreen();
      }
      return _buildWebLoadingScreen();
    }

    if (hasError) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    if (isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final bool isTablet = MediaQuery.of(context).size.width > 600;

    final Size screenSize = MediaQuery.of(context).size;
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int bannerCacheWidth = (screenSize.width * dpr).round();
    final int bannerCacheHeight = (screenSize.height * dpr).round();

    final bannerUrl =
        banners.isEmpty ? "" : banners[currentIndex % banners.length];

    return Scaffold(
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (_openingAdmin) return;
          _handleHiddenAdminTap();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: banners.isEmpty
                  ? Container(color: Colors.black)
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 900),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Image.network(
                        bannerUrl,
                        key: ValueKey(
                          "banner-refresh-$_mediaRefreshKey-${currentIndex % banners.length}",
                        ),
                        fit: BoxFit.cover,
                        cacheWidth: bannerCacheWidth,
                        cacheHeight: bannerCacheHeight,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, __, ___) =>
                            Container(color: Colors.black),
                      ),
                    ),
            ),
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black38,
                      Colors.transparent,
                      Colors.black87
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: -5,
              left: -30,
              right: -10, // 🔒 full width so right alignment works
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isTablet ? 40 : 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _glassContainer(
                            isTablet: isTablet,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  restaurantName.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: isTablet ? 24 : 16,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "(A PRODUCT OF SIRIXO)",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: isTablet ? 12 : 10,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: isTablet ? 80 : 40,
              left: isTablet ? 100 : 20,
              right: isTablet ? 80 : 20,
              child: _orderPanel(isTablet),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebLoadingScreen() {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _buildWebErrorScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                color: Colors.white,
                size: 44,
              ),
              const SizedBox(height: 16),
              const Text(
                "Web startup failed",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                "This usually means a web-only startup problem such as CORS or mobile-only code being used in the browser.",
                style: TextStyle(color: Colors.white70, height: 1.4),
                textAlign: TextAlign.center,
              ),
              if (_errorDetails != null &&
                  _errorDetails!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.12),
                    ),
                  ),
                  child: Text(
                    _errorDetails!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.35,
                    ),
                    textAlign: TextAlign.left,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    isLoading = true;
                    hasError = false;
                  });
                  _loadRestaurant();
                },
                child: const Text("Retry"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleHiddenAdminTap() {
    _adminTapResetTimer?.cancel();
    _adminTapCount += 1;

    if (_adminTapCount >= 5) {
      _adminTapCount = 0;
      _openAdminPin();
      return;
    }

    _adminTapResetTimer = Timer(const Duration(seconds: 3), () {
      _adminTapCount = 0;
    });
  }

  Future<void> _openAdminPin() async {
    if (_openingAdmin || !mounted) return;
    setState(() => _openingAdmin = true);
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PinScreen(),
    );
    if (!mounted) return;
    setState(() {
      _openingAdmin = false;
      isLoading = true;
    });
    _loadRestaurant();
  }

  Widget _orderPanel(bool isTablet) {
    return Container(
      padding: EdgeInsets.all(isTablet ? 15 : 25),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Text(
            "TAP TO START BELOW",
            style: TextStyle(
              fontSize: isTablet ? 42 : 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 40),
          if (_showDineIn || _showPickup)
            Builder(
              builder: (_) {
                if (_showDineIn && !_showPickup) {
                  return Center(
                    child: SizedBox(
                      width: isTablet ? 360 : 240,
                      child: _orderButton(
                        "   EAT HERE",
                        Icons.restaurant_rounded,
                        Colors.green.shade700,
                        "dine_in",
                        isTablet,
                      ),
                    ),
                  );
                }
                if (_showPickup && !_showDineIn) {
                  return Column(
                    children: [
                      SizedBox(
                        width: isTablet ? 360 : 240,
                        child: _orderButton(
                          "TAKE AWAY",
                          Icons.shopping_bag_rounded,
                          Colors.orange.shade800,
                          "pickup",
                          isTablet,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Eat Here not available",
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  );
                }
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_showDineIn)
                      Expanded(
                        child: _orderButton(
                          "EAT HERE",
                          Icons.restaurant_rounded,
                          Colors.green.shade700,
                          "dine_in",
                          isTablet,
                        ),
                      ),
                    if (_showDineIn && _showPickup)
                      SizedBox(width: isTablet ? 45 : 12),
                    if (_showPickup)
                      Expanded(
                        child: _orderButton(
                          "TAKE AWAY",
                          Icons.shopping_bag_rounded,
                          Colors.orange.shade800,
                          "pickup",
                          isTablet,
                        ),
                      ),
                  ],
                );
              },
            )
          else
            const Text(
              "Ordering unavailable",
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
        ],
      ),
    );
  }

  Map<String, bool> _resolveOrderTypeAvailability(
    Map? restaurant,
    Map? kioskSettings,
  ) {
    bool? dineIn;
    bool? pickup;

    final sources = [kioskSettings, restaurant];
    for (final src in sources) {
      if (src is! Map) continue;

      final listVal = _readList(src, const [
        "order_types",
        "orderTypes",
        "available_order_types",
        "order_type_list",
        "orderTypeList",
        "order_type",
        "orderType",
      ]);
      if (listVal != null && listVal.isNotEmpty) {
        final types = listVal.map(_normalizeOrderType).toSet();
        if (types.any((t) => t == "dine_in" || t == "dinein")) {
          dineIn = true;
        }
        if (types.any(
          (t) => t == "pickup" || t == "takeaway" || t == "take_away",
        )) {
          pickup = true;
        }
        if (dineIn != true) dineIn = false;
        if (pickup != true) pickup = false;
      }

      dineIn ??= _readBool(src, const [
        "dine_in",
        "dinein",
        "eat_here",
        "eatHere",
        "is_dine_in",
        "dine_in_enabled",
        "eat_here_enabled",
        "allow_dine_in_orders",
      ]);

      pickup ??= _readBool(src, const [
        "pickup",
        "takeaway",
        "take_away",
        "takeAway",
        "is_pickup",
        "pickup_enabled",
        "takeaway_enabled",
        "take_away_enabled",
        "allow_customer_pickup_orders",
      ]);

      final allowCustomerOrders = _readBool(src, const [
        "allow_customer_orders",
        "customer_orders_enabled",
        "allow_orders",
      ]);
      if (allowCustomerOrders == false) {
        dineIn = false;
        pickup = false;
      }
    }

    return {"dine_in": dineIn ?? true, "pickup": pickup ?? true};
  }

  String? _extractTaxId(Map? restaurant, Map? kioskSettings) {
    final sources = [kioskSettings, restaurant];
    for (final src in sources) {
      if (src is! Map) continue;
      final v = src["gst_number"] ??
          src["gstin"] ??
          src["tax_id"] ??
          src["taxId"] ??
          src["gst_no"] ??
          src["gst"];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString().trim();
      }
    }
    return null;
  }

  bool? _readBool(Map src, List<String> keys) {
    for (final k in keys) {
      if (!src.containsKey(k)) continue;
      final v = src[k];
      if (v is bool) return v;
      if (v is num) return v > 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == "true" || s == "1" || s == "yes") return true;
        if (s == "false" || s == "0" || s == "no") return false;
      }
    }
    return null;
  }

  List<String>? _readList(Map src, List<String> keys) {
    for (final k in keys) {
      if (!src.containsKey(k)) continue;
      final v = src[k];
      if (v is List) {
        return v.map((e) => e.toString()).toList();
      }
      if (v is String && v.isNotEmpty) {
        return v.split(",").map((e) => e.trim()).toList();
      }
    }
    return null;
  }

  String _normalizeOrderType(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll("-", "_")
        .replaceAll(RegExp(r"\s+"), "_");
  }

  Widget _orderButton(
    String label,
    IconData icon,
    Color color,
    String type,
    bool isTablet,
  ) {
    return InkWell(
      onTap: _openingOrder
          ? null
          : () {
              setState(() => _openingOrder = true);
              Navigator.pushReplacement(
                context,
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) => MainNavigation(orderType: type),
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                ),
              );
            },
      child: Container(
        height: isTablet ? 100 : 100, // Reduced height for horizontal layout
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          // Changed from Column to Row
          children: [
            Icon(icon, size: isTablet ? 60 : 30, color: Colors.white),
            SizedBox(width: isTablet ? 15 : 8),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: isTablet ? 30 : 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassContainer({required Widget child, required bool isTablet}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: Container(
        constraints: BoxConstraints(
          minWidth: isTablet ? 260 : 0,
          maxWidth: isTablet ? 420 : 220,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: isTablet ? 20 : 14,
          vertical: isTablet ? 10 : 8,
        ),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white24),
        ),
        child: child,
      ),
    );
  }
}
