import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _offlineDelayTimer;
  bool _started = false;
  bool _checkingInitial = false;
  bool _pendingOffline = false;
  bool _refreshing = false;
  DateTime _lastInternetCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _cachedInternetReachable;
  int _reachabilityFailures = 0;

  // Connectivity changes are still handled immediately by the platform stream;
  // this slower poll is only a safety net and avoids needless socket work.
  static const Duration _pollInterval = Duration(seconds: 30);
  static const Duration _minInternetCheckInterval = Duration(seconds: 20);
  static const int _failThreshold = 2;

  void start() {
    if (_started) return;
    _started = true;
    _init();
  }

  Future<void> _init() async {
    if (_checkingInitial) return;
    _checkingInitial = true;

    try {
      final results = await Connectivity().checkConnectivity();
      await _updateOnlineFromResults(results);
    } catch (_) {
      _setOnlineImmediate(true);
    } finally {
      _checkingInitial = false;
    }

    _subscription?.cancel();
    _subscription = Connectivity().onConnectivityChanged.listen(
          _handleConnectivityChange,
        );

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      _refreshConnectivity();
    });
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    _debounceTimer?.cancel();
    if (results.every((r) => r == ConnectivityResult.none)) {
      _scheduleOffline();
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 120), () {
      _updateOnlineFromResults(results);
    });
  }

  Future<void> _refreshConnectivity() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final results = await Connectivity().checkConnectivity();
      await _updateOnlineFromResults(results);
    } catch (_) {}
    _refreshing = false;
  }

  Future<void> _updateOnlineFromResults(
    List<ConnectivityResult> results,
  ) async {
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    if (!hasNetwork) {
      _reachabilityFailures = _failThreshold;
      _scheduleOffline();
      return;
    }

    _offlineDelayTimer?.cancel();
    _pendingOffline = false;

    final now = DateTime.now();
    if (now.difference(_lastInternetCheck) < _minInternetCheckInterval &&
        _cachedInternetReachable != null) {
      if (_cachedInternetReachable == true) {
        _reachabilityFailures = 0;
        if (!isOnline.value) _setOnlineImmediate(true);
      } else {
        _reachabilityFailures++;
        if (_reachabilityFailures >= _failThreshold) {
          _setOnlineImmediate(false);
        }
      }
      return;
    }

    final reachable = await _hasInternetAccess();
    _cachedInternetReachable = reachable;
    _lastInternetCheck = now;
    if (reachable) {
      _reachabilityFailures = 0;
      if (!isOnline.value) _setOnlineImmediate(true);
    } else {
      _reachabilityFailures++;
      if (_reachabilityFailures >= _failThreshold) {
        _setOnlineImmediate(false);
      }
    }
  }

  Future<bool> _hasInternetAccess() async {
    for (int i = 0; i < 2; i++) {
      try {
        final socket = await Socket.connect(
          "app.selfx.in",
          443,
          timeout: const Duration(seconds: 3),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return false;
  }

  void markOffline() {
    _scheduleOffline();
  }

  void _setOnlineImmediate(bool online) {
    _offlineDelayTimer?.cancel();
    _pendingOffline = false;
    if (isOnline.value != online) {
      isOnline.value = online;
    }
    if (online) {
      _reachabilityFailures = 0;
    }
  }

  void _scheduleOffline() {
    if (isOnline.value == false) {
      _pendingOffline = false;
      _offlineDelayTimer?.cancel();
      return;
    }
    if (_pendingOffline && _offlineDelayTimer?.isActive == true) {
      return;
    }
    _pendingOffline = true;
    _offlineDelayTimer?.cancel();
    _offlineDelayTimer = Timer(const Duration(seconds: 5), () async {
      if (!_pendingOffline) return;
      bool offline = true;
      try {
        final results = await Connectivity().checkConnectivity();
        final hasNetwork = results.any(
          (r) => r != ConnectivityResult.none,
        );
        if (hasNetwork) {
          final reachable = await _hasInternetAccess();
          offline = !reachable;
        }
      } catch (_) {}
      if (offline && _pendingOffline) {
        _setOnlineImmediate(false);
      }
    });
  }

  void dispose() {
    _subscription?.cancel();
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _offlineDelayTimer?.cancel();
  }
}
