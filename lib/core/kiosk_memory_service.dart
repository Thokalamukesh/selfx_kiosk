import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class KioskMemoryService {
  KioskMemoryService._();

  static final KioskMemoryService instance = KioskMemoryService._();

  final ValueNotifier<int> maintenanceTick = ValueNotifier<int>(0);
  final ValueNotifier<int> mediaRefreshTick = ValueNotifier<int>(0);

  Timer? _cacheTimer;
  Timer? _maintenanceTimer;
  Timer? _mediaTimer;
  bool _started = false;
  bool _paused = false;

  DateTime _lastActivity = DateTime.now();
  Duration _activityCooldown = const Duration(seconds: 30);

  void start({
    required Duration cacheClearInterval,
    required Duration maintenanceInterval,
    required Duration mediaRefreshInterval,
    Duration activityCooldown = const Duration(seconds: 30),
  }) {
    if (_started) return;
    _started = true;
    _paused = false;
    _activityCooldown = activityCooldown;
    _lastActivity = DateTime.now();

    _cacheTimer?.cancel();
    _maintenanceTimer?.cancel();
    _mediaTimer?.cancel();

    _cacheTimer = Timer.periodic(cacheClearInterval, (_) {
      if (_paused) return;
      _maybeClearImageCache();
    });

    _maintenanceTimer = Timer.periodic(maintenanceInterval, (_) {
      if (_paused) return;
      maintenanceTick.value++;
    });

    _mediaTimer = Timer.periodic(mediaRefreshInterval, (_) {
      if (_paused) return;
      mediaRefreshTick.value++;
    });
  }

  void stop() {
    _cacheTimer?.cancel();
    _maintenanceTimer?.cancel();
    _mediaTimer?.cancel();
    _cacheTimer = null;
    _maintenanceTimer = null;
    _mediaTimer = null;
    _started = false;
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
    _lastActivity = DateTime.now();
  }

  void reportUserActivity() {
    _lastActivity = DateTime.now();
  }

  void _maybeClearImageCache() {
    final now = DateTime.now();
    if (now.difference(_lastActivity) < _activityCooldown) return;
    // Cache clearing can be surprisingly expensive and can cause a burst of
    // image re-decodes. Run it as idle work and only when there is enough cache
    // pressure to justify the cleanup.
    SchedulerBinding.instance.scheduleTask<void>(() {
      final cache = PaintingBinding.instance.imageCache;
      if (cache.currentSizeBytes < (32 << 20) && cache.currentSize < 80) {
        return;
      }
      cache.clear();
      cache.clearLiveImages();
    }, Priority.idle);
  }
}
