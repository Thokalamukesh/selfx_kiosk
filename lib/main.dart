import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:api_selfxo_project/printer/register_kiosk.dart';
import 'package:api_selfxo_project/screens/register_screen.dart';
import 'package:api_selfxo_project/screens/web_qr_menu_entry.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:api_selfxo_project/core/idle_timer.dart';
import 'package:api_selfxo_project/core/kiosk_background_service.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/core/kiosk_power.dart';
import 'package:api_selfxo_project/core/kiosk_watchdog.dart';
import 'package:api_selfxo_project/providers/restaurant_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initializeKioskBackgroundService();
    // Send an early heartbeat so the background watchdog doesn't relaunch
    // the app during cold start.
    sendUiHeartbeat();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      reportUiCrash(details.exception, details.stack ?? StackTrace.current);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      reportUiCrash(error, stack);
      return true;
    };
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    PaintingBinding.instance.imageCache.maximumSizeBytes = 120 << 20; // 120MB
    PaintingBinding.instance.imageCache.maximumSize = 300;
    WakelockPlus.enable();
    final prefs = await SharedPreferences.getInstance();
    final restaurantId = prefs.getString("restaurant_id");
    final setupDone = prefs.getBool("kiosk_setup_done") ?? false;
    final Widget initialHome = kIsWeb
        ? _resolveInitialWebHome()
        : (restaurantId == null || restaurantId.trim().isEmpty)
            ? const UserIdScreen()
            : (setupDone ? const WelcomeScreen() : const RegisterKioskScreen());

    runApp(
      ChangeNotifierProvider(
        create: (_) => RestaurantProvider(),
        child: MyApp(initialHome: initialHome),
      ),
    );
  }, (error, stack) {
    reportUiCrash(error, stack);
  });
}

Widget _resolveInitialWebHome() {
  final uri = Uri.base;
  final restaurantId = _extractWebRestaurantId(uri);
  final orderType = uri.queryParameters["order_type"] ??
      uri.queryParameters["orderType"] ??
      uri.queryParameters["type"];

  if (restaurantId != null && restaurantId.isNotEmpty) {
    return WebQrMenuEntryScreen(
      restaurantId: restaurantId,
      requestedOrderType: orderType,
    );
  }

  return const UserIdScreen();
}

String? _extractWebRestaurantId(Uri uri) {
  final segments = uri.pathSegments
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();

  for (var i = 0; i < segments.length - 1; i++) {
    final current = segments[i].toLowerCase();
    if (current == "restaurant" ||
        current == "restaurants" ||
        current == "menu" ||
        current == "kiosk") {
      final next = segments[i + 1].trim();
      if (next.isNotEmpty) return next;
    }
  }

  final queryRestaurant = uri.queryParameters["restaurant_id"] ??
      uri.queryParameters["restaurantId"] ??
      uri.queryParameters["restaurant"] ??
      uri.queryParameters["slug"];
  if (queryRestaurant != null && queryRestaurant.trim().isNotEmpty) {
    return queryRestaurant.trim();
  }

  return null;
}

class MyApp extends StatefulWidget {
  final Widget initialHome;

  const MyApp({super.key, required this.initialHome});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  Timer? _idleTimer;
  late final VoidCallback _idleListener;
  Timer? _heartbeatTimer;
  Timer? _serviceHeartbeatTimer;
  bool _tickersEnabled = true;
  late final KioskWatchdog _watchdog;
  final FocusNode _appFocusNode = FocusNode(debugLabel: 'app-root');
  DateTime _lastActivityResetAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _welcomeRecoveryInProgress = false;

  static const bool _enableHeartbeatLogs = false;
  static const Duration _idleTimeout = Duration(minutes: 3);
  static const Duration _activityThrottle = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetIdleTimer();
    _startServiceHeartbeat();

    ConnectivityService.instance.start();
    _idleListener = _handleIdleState;
    IdleTimer.enabled.addListener(_idleListener);

    _watchdog = KioskWatchdog(
      onFreezeDetected: _handleFreezeDetected,
      onJankDetected: (_) {},
    );
    _watchdog.start();

    KioskMemoryService.instance.start(
      cacheClearInterval: KioskConfig.memoryCacheClearInterval,
      maintenanceInterval: KioskConfig.maintenanceInterval,
      mediaRefreshInterval: KioskConfig.mediaRefreshInterval,
      activityCooldown: KioskConfig.activityCooldown,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      KioskPower.requestIgnoreBatteryOptimizations();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      sendUiReady();
    });

    _heartbeatTimer?.cancel();
    if (_enableHeartbeatLogs) {
      _heartbeatTimer = Timer.periodic(const Duration(minutes: 5), (_) {});
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_appFocusNode.canRequestFocus) {
        _appFocusNode.requestFocus();
      }
    });
  }

  void _handleFreezeDetected(String reason) {
    _scheduleImageCacheClear();
  }

  Future<bool> _isKioskSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    final restaurantId = prefs.getString("restaurant_id")?.trim() ?? "";
    final setupDone = prefs.getBool("kiosk_setup_done") ?? false;
    return restaurantId.isNotEmpty && setupDone;
  }

  Future<void> _returnToWelcomeWhenSetupDone({bool resetIdle = false}) async {
    if (_welcomeRecoveryInProgress) {
      if (resetIdle) _resetIdleTimer();
      return;
    }
    _welcomeRecoveryInProgress = true;
    try {
      if (!await _isKioskSetupDone()) {
        if (resetIdle) _resetIdleTimer();
        return;
      }

      _scheduleImageCacheClear();
      final nav = rootNavigatorKey.currentState;
      if (nav == null) {
        if (resetIdle) _resetIdleTimer();
        return;
      }
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (_) => false,
      );
      if (resetIdle) _resetIdleTimer();
    } finally {
      _welcomeRecoveryInProgress = false;
    }
  }

  @override
  void dispose() {
    ConnectivityService.instance.dispose();
    IdleTimer.enabled.removeListener(_idleListener);
    _idleTimer?.cancel();
    _heartbeatTimer?.cancel();
    _serviceHeartbeatTimer?.cancel();
    _watchdog.stop();
    KioskMemoryService.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    _appFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final content = TickerMode(
          enabled: _tickersEnabled,
          child: Focus(
            focusNode: _appFocusNode,
            autofocus: true,
            onKeyEvent: (node, event) {
              _registerUserActivity(force: true, allowUnfocus: false);
              return KeyEventResult.ignored;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _registerUserActivity(force: true);
              },
              onPointerMove: (_) {
                _registerUserActivity();
              },
              onPointerSignal: (_) {
                _registerUserActivity(force: true, allowUnfocus: false);
              },
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );

        return ValueListenableBuilder<bool>(
          valueListenable: ConnectivityService.instance.isOnline,
          builder: (context, online, _) {
            return Stack(
              children: [
                content,
                if (!online) _buildNoInternetOverlay(),
              ],
            );
          },
        );
      },
      home: widget.initialHome,
    );
  }

  Widget _buildNoInternetOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  color: Colors.black.withOpacity(0.55),
                ),
              ),
            ),
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFFBFB), Color(0xFFFFEAEA)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: const Color(0xFFFFC9C9)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFFFFEBEE), Color(0xFFFFCDD2)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.wifi_off_rounded,
                          color: Colors.redAccent,
                          size: 64,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE3E3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons
                                  .signal_wifi_statusbar_connected_no_internet_4,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            SizedBox(width: 6),
                            Text(
                              "Offline",
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        "No Internet Connection",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Trying to reconnect automatically",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black54,
                          fontSize: 15,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: const LinearProgressIndicator(
                          minHeight: 6,
                          backgroundColor: Color(0xFFFFD7D7),
                          color: Color(0xFFB71C1C),
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
    );
  }

  void _registerUserActivity({
    bool force = false,
    bool allowUnfocus = true,
  }) {
    final now = DateTime.now();
    if (!force && now.difference(_lastActivityResetAt) < _activityThrottle) {
      return;
    }
    _lastActivityResetAt = now;
    _resetIdleTimer();
    _watchdog.reportUserActivity();
    KioskMemoryService.instance.reportUserActivity();
    if (allowUnfocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (!IdleTimer.enabled.value) {
      return;
    }
    _idleTimer = Timer(_idleTimeout, _handleIdleTimeout);
  }

  void _handleIdleTimeout() {
    if (!IdleTimer.enabled.value) return;
    unawaited(_returnToWelcomeWhenSetupDone(resetIdle: true));
  }

  void _startServiceHeartbeat() {
    _serviceHeartbeatTimer?.cancel();
    sendUiHeartbeat();
    _serviceHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => sendUiHeartbeat(),
    );
  }

  void _scheduleImageCacheClear() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  }

  void _handleIdleState() {
    if (!IdleTimer.enabled.value) {
      _idleTimer?.cancel();
    } else {
      _resetIdleTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resetIdleTimer();
      _tickersEnabled = true;
      WakelockPlus.enable();
      _watchdog.start();
      KioskMemoryService.instance.resume();
      _startServiceHeartbeat();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _idleTimer?.cancel();
      _tickersEnabled = false;
      _watchdog.stop();
      KioskMemoryService.instance.pause();
      if (mounted) setState(() {});
    }
  }

  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}
