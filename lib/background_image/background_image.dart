import 'dart:async';

import 'package:api_selfxo_project/core/kiosk_bootstrap.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/kiosk_api.dart';
import '../screens/main_navigation.dart';
import '../screens/pin_screen.dart';
import '../screens/register_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with WidgetsBindingObserver {
  static const String _defaultClosedMessage =
      "Restaurant closed. Please check back later.";
  Timer? _sliderTimer;
  Timer? _adminTapResetTimer;
  VoidCallback? _maintenanceListener;
  VoidCallback? _mediaRefreshListener;
  VoidCallback? _restaurantInfoListener;
  int _mediaRefreshKey = 0;
  int _welcomeLoadSeq = 0;

  bool isLoading = true;
  bool hasError = false;
  bool _bootstrapForbidden = false;
  String? _errorDetails;
  bool _openingAdmin = false;
  bool _openingOrder = false;
  bool _loadingRestaurant = false;
  bool _restaurantClosed = false;
  String? _restaurantClosedMessage;
  VoidCallback? _onlineListener;
  int _adminTapCount = 0;

  String restaurantName = "Start Your Order";
  String? restaurantLogoUrl;
  Color restaurantPrimaryColor = const Color(0xFF9F342C);
  List<String> banners = [];
  int currentIndex = 0;
  int _sliderIntervalSeconds = 6;
  bool _showDineIn = true;
  bool _showPickup = true;

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
      if (online && !_bootstrapForbidden && (hasError || isLoading)) {
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
    if (_loadingRestaurant) {
      kioskLog("load skipped reason=in_flight", tag: "WELCOME");
      return;
    }
    _loadingRestaurant = true;
    _bootstrapForbidden = false;
    final loadId = ++_welcomeLoadSeq;
    final startedAt = DateTime.now();
    kioskLog("load#$loadId start", tag: "WELCOME");
    try {
      await DeviceBootstrap.ensureDeviceReady();
      kioskLog("load#$loadId device-ready", tag: "WELCOME");
      final prefs = await SharedPreferences.getInstance();
      final savedDisplayName = _storedDisplayName(prefs);
      final res = await KioskApi().getRestaurantData();
      kioskLog(
        "load#$loadId bootstrap status=${res.statusCode} keys=${res.data is Map ? (res.data as Map).keys.take(12).join(',') : res.data.runtimeType}",
        tag: "WELCOME",
      );

      final restaurant = res.data["restaurant"];
      final media = restaurant?["media"];
      final kioskSettings = res.data["kiosk_settings"];
      final rawLogoUrl = _resolveLogoUrl(
            root: res.data is Map ? res.data : null,
            restaurant: restaurant is Map ? restaurant : null,
            kioskSettings: kioskSettings is Map ? kioskSettings : null,
          ) ??
          prefs.getString("restaurant_logo_url");
      final normalizedLogoUrl = normalizeImageUrl(rawLogoUrl);
      kioskLog(
        "bootstrap logo raw=${rawLogoUrl ?? '-'} normalized=${normalizedLogoUrl.isEmpty ? '-' : normalizedLogoUrl}",
        tag: "WELCOME",
      );
      final parsedPrimaryColor = _parseHexColor(
            restaurant is Map
                ? (restaurant["primary_color"] ?? restaurant["primaryColor"])
                : null,
          ) ??
          _parseHexColor(
            kioskSettings is Map
                ? (kioskSettings["primary_color"] ??
                    kioskSettings["primaryColor"])
                : null,
          );

      final backendDeviceId = kioskSettings?["device_id"];
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

      List<String> tempBanners = _extractWelcomeBackgroundSlides(
        root: res.data is Map ? res.data : null,
        restaurant: restaurant is Map ? restaurant : null,
        kioskSettings: kioskSettings is Map ? kioskSettings : null,
      );

      if (media is List) {
        final mediaBanners = media
            .whereType<Map>()
            .where((m) => !_isLogoLikeMedia(m))
            .map<String?>((m) => _firstImageUrl(m))
            .whereType<String>()
            .map<String>(normalizeImageUrl)
            .where(isSupportedRasterImageUrl)
            .toList();
        tempBanners = [
          ...tempBanners,
          ...mediaBanners.where((url) => !tempBanners.contains(url)),
        ];
      }
      kioskLog(
        "load#$loadId slides extracted count=${tempBanners.length} urls=${_shortUrlList(tempBanners)}",
        tag: "WELCOME",
      );

      if (tempBanners.isEmpty) {
        final savedBackgroundUrl = normalizeImageUrl(
          prefs.getString("home_background_url") ??
              prefs.getString("home_banner_url"),
        );
        if (isSupportedRasterImageUrl(savedBackgroundUrl)) {
          tempBanners.add(savedBackgroundUrl);
          kioskLog(
            "load#$loadId using saved background ${_safeLogUrl(savedBackgroundUrl)}",
            tag: "WELCOME",
          );
        }
      }

      if (tempBanners.isEmpty) {
        for (final source in [
          kioskSettings is Map ? kioskSettings : null,
          restaurant is Map ? restaurant : null,
          res.data is Map ? res.data : null,
        ]) {
          final rawUrl = _firstImageUrl(source);
          final bannerUrl = normalizeImageUrl(rawUrl);
          if (isSupportedRasterImageUrl(bannerUrl)) {
            tempBanners.add(bannerUrl);
            kioskLog(
              "load#$loadId using first image fallback ${_safeLogUrl(bannerUrl)}",
              tag: "WELCOME",
            );
            break;
          }
        }
      }

      if (!mounted) return;

      final types = KioskRestaurantMeta.resolveWelcomeOrderTypes(
        root: res.data is Map ? res.data : null,
        restaurant: restaurant is Map ? restaurant : null,
        kioskSettings: kioskSettings is Map ? kioskSettings : null,
      );
      final sliderIntervalSeconds = _resolveSliderIntervalSeconds(
        root: res.data is Map ? res.data : null,
        restaurant: restaurant is Map ? restaurant : null,
        kioskSettings: kioskSettings is Map ? kioskSettings : null,
      );
      setState(() {
        restaurantName = KioskRestaurantMeta.resolveRestaurantName(
          restaurant: restaurant is Map ? restaurant : null,
          kioskSettings: kioskSettings is Map ? kioskSettings : null,
          fallback: savedDisplayName ?? "Start Your Order",
        );
        restaurantLogoUrl = isSupportedRasterImageUrl(normalizedLogoUrl)
            ? normalizedLogoUrl
            : null;
        restaurantPrimaryColor = parsedPrimaryColor ?? const Color(0xFF9F342C);
        banners = tempBanners;
        currentIndex =
            tempBanners.isEmpty ? 0 : currentIndex % tempBanners.length;
        _sliderIntervalSeconds = sliderIntervalSeconds;
        _showDineIn = types["dine_in"] ?? true;
        _showPickup = types["pickup"] ?? true;
        _restaurantClosed = false;
        _restaurantClosedMessage = null;
        isLoading = false;
        hasError = false;
        _errorDetails = null;
      });

      kioskLog(
        "load#$loadId ready ms=${DateTime.now().difference(startedAt).inMilliseconds} name=$restaurantName banners=${banners.length} current=${banners.isEmpty ? '-' : _safeLogUrl(banners[currentIndex])} logo=${restaurantLogoUrl == null ? '-' : _safeLogUrl(restaurantLogoUrl!)} dine=$_showDineIn pickup=$_showPickup",
        tag: "WELCOME",
      );
      _startSlider();
    } catch (e) {
      final forbidden = KioskApi.isBootstrapForbiddenError(e);
      if (!forbidden && KioskApi.isKioskAuthError(e)) {
        await _returnToPairingScreen();
        return;
      }
      kioskLogError(
        "load#$loadId failed ms=${DateTime.now().difference(startedAt).inMilliseconds}",
        tag: "WELCOME",
        error: e,
      );
      final userError = KioskApi.kioskLoadMessageFrom(e);

      if (!mounted) return;
      final closedReason = _closedReasonFromMessage(userError);
      setState(() {
        hasError = closedReason == null;
        _bootstrapForbidden = forbidden;
        isLoading = false;
        _restaurantClosed = closedReason != null;
        _restaurantClosedMessage = closedReason;
        _errorDetails = userError;
      });
    } finally {
      _loadingRestaurant = false;
      kioskLog(
        "load#$loadId end loading=$_loadingRestaurant isLoading=$isLoading hasError=$hasError closed=$_restaurantClosed",
        tag: "WELCOME",
      );
    }
  }

  String? _closedReasonFromMessage(String? message) {
    if (message == null) return null;
    final text = message.toLowerCase();
    final isClosed = text.contains("restaurant closed") ||
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
    return isClosed ? _defaultClosedMessage : null;
  }

  String _shortUrlList(List<String> urls) {
    if (urls.isEmpty) return "-";
    return urls.take(4).map(_safeLogUrl).join(" | ");
  }

  String _safeLogUrl(String value) {
    final clean = value.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    return clean.length <= 140 ? clean : "${clean.substring(0, 140)}...";
  }

  String? _firstImageUrl(Map? data) {
    if (data == null) return null;
    for (final key in const [
      "home_background_url",
      "homeBackgroundUrl",
      "home_background",
      "homeBackground",
      "home_banner_url",
      "homeBannerUrl",
      "banner_url",
      "bannerUrl",
      "background_image_url",
      "backgroundImageUrl",
      "cover_url",
      "coverUrl",
      "image_url",
      "imageUrl",
      "path",
      "url",
    ]) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != "null") {
        return value;
      }
    }
    return null;
  }

  List<String> _extractWelcomeBackgroundSlides({
    required Map? root,
    required Map? restaurant,
    required Map? kioskSettings,
  }) {
    final urls = <String>[];
    final rootKiosk = _mapValue(root?["kiosk"]);
    final rootSettings = _mapValue(root?["settings"]);
    final rootAppearance = _mapValue(root?["appearance"]);
    final normalizedSettings = _mapValue(root?["kiosk_settings"]);
    final kioskAppearance = _mapValue(kioskSettings?["appearance"]);
    final rootKioskAppearance = _mapValue(rootKiosk?["appearance"]);
    final rootSettingsAppearance = _mapValue(rootSettings?["appearance"]);
    final restaurantAppearance = _mapValue(restaurant?["appearance"]);

    final sources = <Map?>[
      root,
      rootKiosk,
      rootKioskAppearance,
      rootSettings,
      rootSettingsAppearance,
      rootAppearance,
      normalizedSettings,
      kioskSettings,
      kioskAppearance,
      restaurant,
      restaurantAppearance,
    ];

    for (final source in sources.whereType<Map>()) {
      for (final key in const [
        "home_background_url",
        "homeBackgroundUrl",
        "home_background",
        "homeBackground",
        "background_image_url",
        "backgroundImageUrl",
        "home_background_images",
        "homeBackgroundImages",
        "background_images",
        "backgroundImages",
        "screensaver_images",
        "screensaverImages",
        "screen_saver_images",
        "screenSaverImages",
        "screensaver_slides",
        "screensaverSlides",
        "screen_saver_slides",
        "screenSaverSlides",
        "screensaver",
        "screen_saver",
        "idle_slides",
        "idleSlides",
        "kiosk_slides",
        "kioskSlides",
        "slides",
      ]) {
        _collectSlideUrls(source[key], urls);
      }
    }

    return urls.toSet().toList();
  }

  Map? _mapValue(dynamic value) {
    return value is Map ? value : null;
  }

  void _collectSlideUrls(dynamic raw, List<String> urls) {
    if (raw == null) return;

    if (raw is List) {
      for (final item in raw) {
        _collectSlideUrls(item, urls);
      }
      return;
    }

    final rawUrl = _firstSlideUrl(raw);
    final url = normalizeImageUrl(rawUrl);
    if (isSupportedRasterImageUrl(url) && !urls.contains(url)) {
      urls.add(url);
    }

    if (raw is Map) {
      for (final key in const [
        "data",
        "slides",
        "items",
        "files",
        "images",
        "media",
      ]) {
        _collectSlideUrls(raw[key], urls);
      }
    }
  }

  String? _firstSlideUrl(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return raw.trim();
    if (raw is! Map) return null;

    for (final key in const [
      "home_background_url",
      "homeBackgroundUrl",
      "home_background",
      "homeBackground",
      "background_image_url",
      "backgroundImageUrl",
      "media_url",
      "mediaUrl",
      "file_url",
      "fileUrl",
      "image_url",
      "imageUrl",
      "gif_url",
      "gifUrl",
      "full_url",
      "fullUrl",
      "original_url",
      "originalUrl",
      "preview_url",
      "previewUrl",
      "thumbnail_url",
      "thumbnailUrl",
      "src",
      "source",
      "path",
      "url",
    ]) {
      final value = raw[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != "null") {
        return value;
      }
    }

    for (final key in const [
      "media",
      "file",
      "image",
      "asset",
      "data",
      "item",
    ]) {
      final value = raw[key];
      final nested = _firstSlideUrl(value);
      if (nested != null && nested.isNotEmpty) return nested;
    }

    for (final key in const [
      "slides",
      "items",
      "files",
      "images",
      "videos",
    ]) {
      final value = raw[key];
      if (value is List && value.isNotEmpty) {
        final nested = _firstSlideUrl(value.first);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }

    return null;
  }

  bool _isLogoLikeMedia(Map item) {
    final marker = [
      item["collection_name"],
      item["collectionName"],
      item["type"],
      item["name"],
      item["key"],
      item["tag"],
    ].whereType<Object>().join(" ").toLowerCase();

    return marker.contains("logo") ||
        marker.contains("brand") ||
        marker.contains("restaurant_logo");
  }

  String? _resolveLogoUrl({
    required Map? root,
    required Map? restaurant,
    required Map? kioskSettings,
  }) {
    for (final source in [restaurant, kioskSettings, root].whereType<Map>()) {
      final direct = _firstLogoUrl(source);
      if (direct != null) return direct;
    }

    for (final source in [restaurant, kioskSettings, root].whereType<Map>()) {
      final mediaLogo = _logoFromMedia(source["media"]);
      if (mediaLogo != null) return mediaLogo;
    }

    return null;
  }

  String? _firstLogoUrl(dynamic data, {int depth = 4}) {
    if (data == null || depth <= 0) return null;
    if (data is String) {
      final value = data.trim();
      return value.isNotEmpty && value.toLowerCase() != "null" ? value : null;
    }
    if (data is List) {
      for (final item in data) {
        final nested = _firstLogoUrl(item, depth: depth - 1);
        if (nested != null) return nested;
      }
      return null;
    }
    if (data is! Map) return null;

    for (final key in const [
      "logo_url",
      "logoUrl",
      "logo_full_url",
      "logoFullUrl",
      "logo_path",
      "logoPath",
      "brand_logo_url",
      "brandLogoUrl",
      "restaurant_logo_url",
      "restaurantLogoUrl",
      "restaurant_logo",
      "restaurantLogo",
    ]) {
      if (!data.containsKey(key)) continue;
      final nested = _firstLogoUrl(data[key], depth: depth - 1);
      if (nested != null) return nested;
    }

    for (final key in const [
      "logo",
      "brand_logo",
      "brandLogo",
      "branding",
      "appearance",
      "image",
      "file",
    ]) {
      if (!data.containsKey(key)) continue;
      final nested = _firstLogoUrl(data[key], depth: depth - 1);
      if (nested != null) return nested;
    }

    for (final key in const [
      "url",
      "path",
      "src",
      "source",
      "media_url",
      "mediaUrl",
      "file_url",
      "fileUrl",
      "full_url",
      "fullUrl",
      "original_url",
      "originalUrl",
      "preview_url",
      "previewUrl",
      "image_url",
      "imageUrl",
    ]) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != "null") {
        return value;
      }
    }

    return null;
  }

  int _resolveSliderIntervalSeconds({
    required Map? root,
    required Map? restaurant,
    required Map? kioskSettings,
  }) {
    final rootKiosk = _mapValue(root?["kiosk"]);
    final rootSettings = _mapValue(root?["settings"]);
    final normalizedSettings = _mapValue(root?["kiosk_settings"]);

    for (final source in [
      kioskSettings,
      normalizedSettings,
      rootKiosk,
      rootSettings,
      restaurant,
      root,
    ].whereType<Map>()) {
      for (final key in const [
        "screensaver_interval_seconds",
        "screensaverIntervalSeconds",
        "screen_saver_interval_seconds",
        "screenSaverIntervalSeconds",
        "slide_interval_seconds",
        "slideIntervalSeconds",
      ]) {
        final value = int.tryParse(source[key]?.toString() ?? "");
        if (value != null && value > 0) {
          return value.clamp(2, 60).toInt();
        }
      }
    }
    return 6;
  }

  String? _logoFromMedia(dynamic media) {
    if (media is! List) return null;

    String? fallback;
    for (final item in media.whereType<Map>()) {
      final url = _firstLogoUrl(item);
      if (url == null) continue;
      fallback ??= url;

      final marker = [
        item["collection_name"],
        item["collectionName"],
        item["type"],
        item["name"],
        item["key"],
        item["tag"],
      ].whereType<Object>().join(" ").toLowerCase();

      if (marker.contains("logo") ||
          marker.contains("brand") ||
          marker.contains("restaurant")) {
        return url;
      }
    }
    return fallback;
  }

  Color? _parseHexColor(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final normalized = text.startsWith("#") ? text.substring(1) : text;
    if (normalized.length != 6 && normalized.length != 8) return null;
    final value = int.tryParse(normalized, radix: 16);
    if (value == null) return null;
    return Color(normalized.length == 6 ? 0xFF000000 | value : value);
  }

  void _startSlider() {
    _sliderTimer?.cancel();
    if (!KioskConfig.enableAutoScroll) {
      kioskLog("slider disabled", tag: "WELCOME");
      return;
    }
    if (banners.length < 2) {
      kioskLog("slider not-started banners=${banners.length}", tag: "WELCOME");
      return;
    }
    kioskLog(
      "slider start interval=${_sliderIntervalSeconds}s banners=${banners.length}",
      tag: "WELCOME",
    );
    _sliderTimer = Timer.periodic(
      Duration(seconds: _sliderIntervalSeconds),
      (_) {
        if (!mounted || banners.isEmpty) return;
        setState(() {
          currentIndex = (currentIndex + 1) % banners.length;
        });
        kioskLog(
          "slider tick index=$currentIndex url=${_safeLogUrl(banners[currentIndex])}",
          tag: "WELCOME",
        );
      },
    );
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
    kioskLog("media refresh key=$_mediaRefreshKey", tag: "WELCOME");
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
    if (hasError) {
      if (_bootstrapForbidden) {
        return _buildBootstrapUnavailableScreen();
      }
      if (kIsWeb) {
        return _buildWebErrorScreen();
      }
      return _buildLocalErrorScreen();
    }
    if (isLoading) {
      if (kIsWeb) {
        return _buildWebLoadingScreen();
      }
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
              child: _welcomeBackground(
                bannerUrl: bannerUrl,
                bannerCacheWidth: bannerCacheWidth,
                bannerCacheHeight: bannerCacheHeight,
                isTablet: isTablet,
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
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    isTablet ? 20 : 10,
                    isTablet ? 10 : 6,
                    isTablet ? 20 : 10,
                    0,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isTablet ? 560 : screenSize.width * 0.78,
                      ),
                      child: _glassContainer(
                        isTablet: isTablet,
                        child: Text(
                          restaurantName.toUpperCase(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isTablet ? 22 : 14,
                            height: 1.08,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
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

  Widget _buildLocalErrorScreen() {
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
                    child: const Icon(
                      Icons.sync_problem_rounded,
                      size: 38,
                      color: Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Kiosk could not load",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    (_errorDetails == null || _errorDetails!.trim().isEmpty)
                        ? "Retry loading, or pair this kiosk again from the admin panel."
                        : _errorDetails!,
                    style: const TextStyle(
                      color: Colors.black87,
                      height: 1.45,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          isLoading = true;
                          hasError = false;
                          _bootstrapForbidden = false;
                        });
                        _loadRestaurant();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9F342C),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("Retry"),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _returnToPairingScreen,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF9F342C),
                        side: const BorderSide(color: Color(0xFF9F342C)),
                      ),
                      child: const Text("Pair again"),
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

  Widget _buildBootstrapUnavailableScreen() {
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
                    color: Colors.black.withOpacity(0.08),
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
                    child: const Icon(
                      Icons.store_mall_directory_outlined,
                      size: 38,
                      color: Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Kiosk ordering is disabled",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _errorDetails ??
                        "Enable kiosk ordering for this restaurant in the admin panel, then retry.",
                    style: const TextStyle(
                      color: Colors.black87,
                      height: 1.45,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          isLoading = true;
                          hasError = false;
                          _bootstrapForbidden = false;
                        });
                        _loadRestaurant();
                      },
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

  Future<void> _returnToPairingScreen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");
    await prefs.remove("admin_token");
    await prefs.setBool("kiosk_setup_done", false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const UserIdScreen()),
      (_) => false,
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

  Widget _welcomeBackground({
    required String bannerUrl,
    required int bannerCacheWidth,
    required int bannerCacheHeight,
    required bool isTablet,
  }) {
    final hasBanner = bannerUrl.trim().isNotEmpty;
    if (!hasBanner) {
      kioskLog("background fallback reason=no_banner", tag: "WELCOME");
      return _brandedFallbackBackground(isTablet: isTablet);
    }
    kioskLog(
      "background render key=$_mediaRefreshKey index=$currentIndex url=${_safeLogUrl(bannerUrl)}",
      tag: "WELCOME",
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 900),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: AppNetworkImage(
        key: ValueKey(
          "banner-refresh-$_mediaRefreshKey-${currentIndex % banners.length}",
        ),
        url: bannerUrl,
        fit: BoxFit.cover,
        cacheWidth: bannerCacheWidth,
        cacheHeight: bannerCacheHeight,
        fallback: _brandedFallbackBackground(isTablet: isTablet),
        debugLabel: "welcome-background index=$currentIndex",
      ),
    );
  }

  Widget _brandedFallbackBackground({required bool isTablet}) {
    final base = restaurantPrimaryColor;
    return _plainBrandBackground(base);
  }

  Widget _plainBrandBackground(Color base) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base,
            Color.lerp(base, Colors.black, 0.45) ?? Colors.black,
          ],
        ),
      ),
    );
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
    if (_restaurantClosed) {
      return Container(
        padding: EdgeInsets.all(isTablet ? 24 : 20),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.42),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withOpacity(0.22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storefront_rounded,
              color: Colors.white,
              size: isTablet ? 58 : 42,
            ),
            const SizedBox(height: 14),
            Text(
              "RESTAURANT CLOSED",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isTablet ? 38 : 25,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _restaurantClosedMessage ?? _defaultClosedMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isTablet ? 18 : 14,
                height: 1.35,
                color: Colors.white.withOpacity(0.88),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  isLoading = true;
                  hasError = false;
                  _restaurantClosed = false;
                  _restaurantClosedMessage = null;
                });
                _loadRestaurant();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
                padding: EdgeInsets.symmetric(
                  horizontal: isTablet ? 26 : 20,
                  vertical: isTablet ? 16 : 12,
                ),
              ),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text("Retry"),
            ),
          ],
        ),
      );
    }

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
                        "EAT HERE",
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

  Widget _orderButton(
    String label,
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
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label.trim(),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: isTablet ? 30 : 18,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glassContainer({required Widget child, required bool isTablet}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: isTablet ? 520 : 300,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: isTablet ? 12 : 8,
          vertical: isTablet ? 7 : 5,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.28),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.24)),
        ),
        child: child,
      ),
    );
  }
}
