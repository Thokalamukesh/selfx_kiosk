import 'dart:async';

import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KioskPairingSession {
  final String deviceUuid;
  final String? pairingCode;
  final String? expiresAt;
  final String? statusPath;

  const KioskPairingSession({
    required this.deviceUuid,
    this.pairingCode,
    this.expiresAt,
    this.statusPath,
  });
}

class _PairingEndpoint {
  const _PairingEndpoint({
    required this.startPath,
    required this.statusPath,
  });

  final String startPath;
  final String statusPath;
}

class _PairingStartResult {
  const _PairingStartResult({
    required this.data,
    required this.statusPath,
  });

  final Map<String, dynamic> data;
  final String statusPath;
}

class AuthService {
  static const bool _enableAuthLogs = true;
  static const Duration _pairPollInterval = Duration(seconds: 5);
  static const Duration _webPairPollInterval = Duration(seconds: 5);
  static const Duration _rateLimitBackoff = Duration(seconds: 15);
  static const Duration _pairPollTimeout = Duration(minutes: 10);
  static const Duration _webPairPollTimeout = Duration(minutes: 10);
  static const List<_PairingEndpoint> _pairingEndpoints = [
    _PairingEndpoint(
      startPath: "kiosk/pairing/start",
      statusPath: "kiosk/pairing/status",
    ),
    _PairingEndpoint(
      startPath: "kiosks/pairing/start",
      statusPath: "kiosks/pairing/status",
    ),
    _PairingEndpoint(
      startPath: "kiosk/start-pairing",
      statusPath: "kiosk/pairing/status",
    ),
    _PairingEndpoint(
      startPath: "kiosks/start-pairing",
      statusPath: "kiosks/pairing/status",
    ),
    _PairingEndpoint(
      startPath: "kiosk/pair",
      statusPath: "kiosk/pairing/status",
    ),
    _PairingEndpoint(
      startPath: "kiosks/pair",
      statusPath: "kiosks/pairing/status",
    ),
  ];

  void _log(String message) {
    if (_enableAuthLogs) {
      kioskLog(message, tag: 'AUTH');
    }
  }

  void _logTokenForTesting(String token, {required String source}) {
    if (!_enableAuthLogs) return;
    kioskLog(
      "KIOSK_TOKEN_FOR_TEST source=$source X-Kiosk-Token=$token",
      tag: "AUTH_TOKEN",
    );
  }

  Future<bool> initializeKiosk({
    bool force = false,
    void Function(KioskPairingSession session)? onPairingStarted,
    void Function()? onPairingCompleted,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!force) {
        final token = prefs.getString("auth_token");
        if (token != null && token.isNotEmpty) {
          _log("Using existing kiosk token");
          _logTokenForTesting(token, source: "existing");
          return true;
        }
      }

      final session = await startPairing(force: force);
      onPairingStarted?.call(session);

      final immediateToken = prefs.getString("auth_token");
      if (immediateToken != null && immediateToken.isNotEmpty) {
        onPairingCompleted?.call();
        return true;
      }

      return waitForPairing(
        session,
        onPairingCompleted: onPairingCompleted,
      );
    } catch (e) {
      _log("INIT ERROR: $e");
      rethrow;
    }
  }

  Future<KioskPairingSession> startPairing({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (force) {
      _log("Force mode: clearing old kiosk token");
      await prefs.remove("auth_token");
      await prefs.remove("admin_token");
      await prefs.remove("kiosk_api_base_url");
      await prefs.remove("kiosk_server_url");
    }

    final deviceName = _resolveDeviceName(prefs);
    final startResult = await _startPairing(deviceName: deviceName);
    final started = startResult.data;
    final deviceUuid = _readFirstString(started, const [
      "device_uuid",
      "deviceUuid",
      "uuid",
      "device_id",
      "deviceId",
    ]);
    final pairingCode = _readFirstString(started, const [
      "pairing_code",
      "pairingCode",
      "code",
      "pin",
    ]);

    if (deviceUuid == null || deviceUuid.isEmpty) {
      throw Exception("Pairing failed: device UUID missing");
    }

    await prefs.setString("device_uuid", deviceUuid);
    await prefs.setString("device_id", deviceUuid);
    if (pairingCode != null && pairingCode.isNotEmpty) {
      await prefs.setString("pairing_code", pairingCode);
    }

    _log("Pairing started for $deviceUuid code=${pairingCode ?? '-'}");

    final token = _extractKioskToken(started);
    if (token != null) {
      await _storeKioskCredentials(prefs, started, token: token);
      await prefs.remove("pending_kiosk_device_name");
    }

    return KioskPairingSession(
      deviceUuid: deviceUuid,
      pairingCode: pairingCode,
      expiresAt: _readFirstString(started, const ["expires_at", "expiresAt"]),
      statusPath: startResult.statusPath,
    );
  }

  Future<bool> waitForPairing(
    KioskPairingSession session, {
    void Function()? onPairingCompleted,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token");
    if (token != null && token.isNotEmpty) {
      _logTokenForTesting(token, source: "existing");
      onPairingCompleted?.call();
      return true;
    }
    return _waitForPairing(
      deviceUuid: session.deviceUuid,
      pairingCode: session.pairingCode,
      statusPath: session.statusPath ?? _pairingEndpoints.first.statusPath,
      onPairingCompleted: onPairingCompleted,
    );
  }

  Future<_PairingStartResult> _startPairing({
    required String deviceName,
  }) async {
    final dio = DioClient.getDio();
    final missingRoutes = <String>[];

    for (final endpoint in _pairingEndpoints) {
      _logPairingRequest("POST", dio.options.baseUrl, endpoint.startPath);

      late final Response res;
      try {
        res = await dio.post(
          endpoint.startPath,
          data: {
            "platform": kIsWeb ? "web" : "android",
            "app_version": "1.0.0",
            "device_name": deviceName,
          },
          options: Options(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
            sendTimeout: const Duration(seconds: 5),
            extra: const {"no_retry": true},
            headers: {
              "X-Kiosk-Platform": kIsWeb ? "web" : "android",
              "X-Kiosk-App-Version": "1.0.0",
            },
          ),
        );
      } on DioException catch (e) {
        _logPairingDioError("start", e);
        rethrow;
      }

      final data = _payloadMap(res.data);
      _logPairingResponse("start", res);
      if (_isMissingRoute(res, data)) {
        missingRoutes.add(endpoint.startPath);
        _log("Pairing route missing: ${endpoint.startPath}; trying next");
        continue;
      }
      if ((res.statusCode ?? 0) >= 400) {
        throw Exception(data["message"] ?? "Pairing start failed");
      }

      return _PairingStartResult(
        data: data,
        statusPath: endpoint.statusPath,
      );
    }

    throw Exception(
      "Pairing API route not found. Tried: ${missingRoutes.join(', ')}",
    );
  }

  Future<bool> _waitForPairing({
    required String deviceUuid,
    required String? pairingCode,
    required String statusPath,
    void Function()? onPairingCompleted,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final dio = DioClient.getDio();
    const timeout = kIsWeb ? _webPairPollTimeout : _pairPollTimeout;
    const pollInterval = kIsWeb ? _webPairPollInterval : _pairPollInterval;
    final endAt = DateTime.now().add(timeout);
    var nextDelay = pollInterval;

    while (DateTime.now().isBefore(endAt)) {
      _logPairingRequest("GET", dio.options.baseUrl, statusPath, {
        "device_uuid": deviceUuid,
      });

      late final Response res;
      try {
        res = await dio.get(
          statusPath,
          queryParameters: {"device_uuid": deviceUuid},
          options: Options(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
            extra: const {"no_retry": true},
          ),
        );
      } on DioException catch (e) {
        _logPairingDioError("status", e);
        rethrow;
      }
      final data = _payloadMap(res.data);
      _logPairingResponse("status", res);
      if (_isMissingRoute(res, data)) {
        throw Exception("Pairing status API route not found: $statusPath");
      }
      if (res.statusCode == 429) {
        nextDelay = _retryAfterDelay(res) ?? _rateLimitBackoff;
        _log(
          "Pairing status rate limited; waiting ${nextDelay.inSeconds}s before retry",
        );
        await Future.delayed(nextDelay);
        nextDelay = nextDelay + const Duration(seconds: 5);
        if (nextDelay > const Duration(seconds: 45)) {
          nextDelay = const Duration(seconds: 45);
        }
        continue;
      }
      if ((res.statusCode ?? 0) >= 400) {
        throw Exception(data["message"] ?? "Pairing status failed");
      }
      nextDelay = pollInterval;
      final token = _extractKioskToken(data);
      if (token != null) {
        await _storeKioskCredentials(prefs, data, token: token);
        await prefs.remove("pairing_code");
        await prefs.remove("pending_kiosk_device_name");
        _log("Pairing completed");
        onPairingCompleted?.call();
        return true;
      }

      final status = data["status"]?.toString().toLowerCase().trim();
      if (status == "linked" ||
          status == "paired" ||
          status == "approved" ||
          status == "completed") {
        _log("Pairing approved but kiosk token was missing in status response");
      }
      if (status == "expired" || status == "failed" || status == "rejected") {
        throw Exception("Pairing $status. Start pairing again.");
      }

      await Future.delayed(nextDelay);
    }

    final codeText = pairingCode == null || pairingCode.isEmpty
        ? "Pair this device in the admin panel, then try again."
        : "Pairing code: $pairingCode. Approve it in the admin panel, then try again.";
    throw Exception(codeText);
  }

  String _resolveDeviceName(SharedPreferences prefs) {
    final pending = prefs.getString("pending_kiosk_device_name")?.trim();
    if (pending != null && pending.isNotEmpty) return pending;
    final saved = prefs.getString("kiosk_name")?.trim();
    if (saved != null && saved.isNotEmpty) return saved;
    final input = prefs.getString("restaurant_id")?.trim();
    if (input != null && input.isNotEmpty) return input;
    return kIsWeb ? "Web kiosk" : "Kiosk Device";
  }

  void _logPairingRequest(
    String method,
    String baseUrl,
    String path, [
    Map<String, dynamic>? queryParameters,
  ]) {
    if (!_enableAuthLogs) return;
    final uri = Uri.parse(baseUrl).resolve(path).replace(
          queryParameters: queryParameters,
        );
    _log("$method $uri");
  }

  void _logPairingResponse(String step, Response response) {
    if (!_enableAuthLogs) return;
    _log(
      "PAIRING $step RESPONSE status=${response.statusCode} url=${response.requestOptions.uri} body=${_safeLogBody(response.data)}",
    );
  }

  void _logPairingDioError(String step, DioException e) {
    if (!_enableAuthLogs) return;
    _log(
      "PAIRING $step ERROR type=${e.type} status=${e.response?.statusCode ?? 'NO_STATUS'} url=${e.requestOptions.uri} message=${e.message ?? '-'} body=${_safeLogBody(e.response?.data)}",
    );
  }

  bool _isMissingRoute(Response response, Map<String, dynamic> data) {
    if ((response.statusCode ?? 0) != 404) return false;
    final message = data["message"]?.toString().toLowerCase() ?? "";
    return message.contains("route") && message.contains("could not be found");
  }

  Duration? _retryAfterDelay(Response response) {
    final retryAfter = response.headers.value("retry-after")?.trim();
    if (retryAfter == null || retryAfter.isEmpty) return null;
    final seconds = int.tryParse(retryAfter);
    if (seconds != null && seconds > 0) {
      return Duration(seconds: seconds);
    }
    final retryAt = DateTime.tryParse(retryAfter);
    if (retryAt == null) return null;
    final delay = retryAt.difference(DateTime.now());
    return delay.isNegative ? null : delay;
  }

  String _safeLogBody(dynamic value) {
    final text = _sanitizeForLog(value).toString();
    const maxLength = 1200;
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...<truncated>';
  }

  dynamic _sanitizeForLog(dynamic value) {
    if (value is Map) {
      return value.map((key, rawValue) {
        final normalized = _normalizeKey(key.toString());
        if (normalized.contains("token") ||
            normalized.contains("secret") ||
            normalized.contains("password")) {
          return MapEntry(key, "<redacted>");
        }
        return MapEntry(key, _sanitizeForLog(rawValue));
      });
    }
    if (value is List) {
      return value.map(_sanitizeForLog).toList();
    }
    return value;
  }

  String? _extractKioskToken(Map<String, dynamic> data) {
    final token = _findToken(data, depth: 5);
    if (token != null) return token;

    final terminal = _map(data["terminal"]);
    if (terminal.isNotEmpty) {
      final nested = _extractKioskToken(terminal);
      if (nested != null) return nested;
    }

    final kiosk = _map(data["kiosk"]);
    if (kiosk.isNotEmpty) return _extractKioskToken(kiosk);

    final nestedData = _map(data["data"]);
    return nestedData.isEmpty ? null : _extractKioskToken(nestedData);
  }

  String? _readFirstString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != "null") {
        return value;
      }
    }
    final normalizedKeys = keys.map(_normalizeKey).toSet();
    for (final entry in data.entries) {
      if (!normalizedKeys.contains(_normalizeKey(entry.key.toString()))) {
        continue;
      }
      final value = entry.value?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != "null") {
        return value;
      }
    }
    return null;
  }

  Future<void> _storeKioskCredentials(
    SharedPreferences prefs,
    Map<String, dynamic> payload, {
    required String token,
  }) async {
    await prefs.setString("auth_token", token);
    _logTokenForTesting(token, source: "pairing");
    if (!kIsWeb) {
      await prefs.setBool("kiosk_setup_done", false);
    }

    final credentials = _findMap(payload, const ["credentials"], depth: 5);
    final terminal = _findMap(payload, const ["terminal", "kiosk"], depth: 5);
    final restaurant = _findMap(payload, const ["restaurant"], depth: 5);
    final branch = _findMap(payload, const ["branch"], depth: 5);

    final apiBaseUrl = _firstNonEmpty([
      credentials?["api_base_url"],
      credentials?["apiBaseUrl"],
      payload["api_base_url"],
      payload["apiBaseUrl"],
    ]);
    if (apiBaseUrl != null) {
      await prefs.setString("kiosk_api_base_url", apiBaseUrl);
    }

    final restaurantName = _firstNonEmpty([
      credentials?["restaurant_name"],
      credentials?["restaurantName"],
      restaurant?["name"],
      payload["restaurant_name"],
    ]);
    if (restaurantName != null) {
      await prefs.setString("restaurant_name", restaurantName);
    }

    final branchName = _firstNonEmpty([
      credentials?["branch_name"],
      credentials?["branchName"],
      branch?["name"],
    ]);
    if (branchName != null) {
      await prefs.setString("branch_name", branchName);
    }

    final terminalName = _firstNonEmpty([
      credentials?["terminal_name"],
      credentials?["terminalName"],
      terminal?["name"],
    ]);
    if (terminalName != null) {
      await prefs.setString("kiosk_name", terminalName);
    }

    final restaurantSlug = _firstNonEmpty([
      credentials?["restaurant_slug"],
      credentials?["restaurantSlug"],
      restaurant?["slug"],
      restaurant?["hash"],
    ]);
    if (restaurantSlug != null) {
      await prefs.setString("restaurant_slug", restaurantSlug);
    }
  }

  String? _findToken(dynamic value, {required int depth}) {
    if (depth <= 0 || value == null) return null;
    if (value is Map) {
      for (final entry in value.entries) {
        final key = _normalizeKey(entry.key.toString());
        if (const {
          "apitoken",
          "kiosktoken",
          "token",
          "authtoken",
          "xkiosktoken",
          "accesstoken",
          "terminaltoken",
          "plaintexttoken",
        }.contains(key)) {
          final token = entry.value?.toString().trim();
          if (token != null &&
              token.isNotEmpty &&
              token.toLowerCase() != "null") {
            return token;
          }
        }
      }

      for (final entry in value.entries) {
        final found = _findToken(entry.value, depth: depth - 1);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findToken(item, depth: depth - 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _normalizeKey(String value) {
    return value.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");
  }

  Map<String, dynamic>? _findMap(
    dynamic value,
    Iterable<String> normalizedKeys, {
    required int depth,
  }) {
    if (depth <= 0 || value == null) return null;
    if (value is Map) {
      for (final entry in value.entries) {
        if (normalizedKeys.contains(_normalizeKey(entry.key.toString()))) {
          final map = _map(entry.value);
          if (map.isNotEmpty) return map;
        }
      }
      for (final entry in value.entries) {
        final found = _findMap(
          entry.value,
          normalizedKeys,
          depth: depth - 1,
        );
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findMap(item, normalizedKeys, depth: depth - 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  String? _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
        return text;
      }
    }
    return null;
  }

  Map<String, dynamic> _payloadMap(dynamic value) {
    final root = _map(value);
    final data = _map(root["data"]);
    return data.isEmpty ? root : {...root, ...data};
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry("$key", value));
  }
}
