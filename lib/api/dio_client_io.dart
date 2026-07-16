import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:api_selfxo_project/core/connectivity_service.dart';

class DioClient {
  static const String baseUrl = "https://app.selfx.in/api/v1/";
  static const int _maxRetries = 3;
  static const Duration _retryBaseDelay = Duration(milliseconds: 500);
  static final Map<String, Dio> _dioByBaseUrl = {};

  static String _resolveBaseUrl(String? storedApiBaseUrl) {
    final raw = storedApiBaseUrl?.trim();
    if (raw == null || raw.isEmpty) return baseUrl;

    var normalized = raw;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/kiosk')) {
      normalized = normalized.substring(0, normalized.length - '/kiosk'.length);
    }
    return '$normalized/';
  }

  static Dio _getBaseDio({
    String? resolvedBaseUrl,
    String profile = "public",
  }) {
    final effectiveBaseUrl = resolvedBaseUrl ?? baseUrl;
    final cacheKey = '$profile|$effectiveBaseUrl';
    return _dioByBaseUrl.putIfAbsent(
      cacheKey,
      () => _createBaseDio(resolvedBaseUrl: effectiveBaseUrl),
    );
  }

  static Dio _createBaseDio({required String resolvedBaseUrl}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: resolvedBaseUrl,
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 18),
        sendTimeout: const Duration(seconds: 12),
        headers: const {
          "Accept": "application/json",
          "Content-Type": "application/json",
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    if (!kReleaseMode) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) {
          if (host.contains("sirixo.com")) return true;
          return false;
        };
        return client;
      };
    }

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.next(options);
        },
        onResponse: (response, handler) {
          handler.next(response);
        },
        onError: (DioException e, handler) async {
          final status = e.response?.statusCode;
          final path = e.requestOptions.path;
          final isNetworkError = e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.error is SocketException;

          if (isNetworkError) {
            final extra = e.requestOptions.extra;
            if (extra["no_retry"] == true) {
              return handler.next(e);
            }
            final int retries = (extra["retries"] as int?) ?? 0;
            if (retries < _maxRetries) {
              extra["retries"] = retries + 1;
              final delay = _retryBaseDelay * (1 << retries);
              await Future.delayed(delay);
              try {
                final response = await dio.fetch(e.requestOptions);
                return handler.resolve(response);
              } catch (_) {}
            }
          }

          if (isNetworkError) {
            ConnectivityService.instance.markOffline();
          }

          if (path.contains("kiosk/admin/unlock")) {
            return handler.next(e);
          }

          if (status == 401 || status == 403) {
            final prefs = await SharedPreferences.getInstance();
            if (path.contains("kiosk/admin/")) {
              await prefs.remove("admin_token");
            }
          }

          handler.next(e);
        },
      ),
    );

    return dio;
  }

  static Dio getDio({String? baseUrlOverride}) => _getBaseDio(
        resolvedBaseUrl: baseUrlOverride,
      );

  static Future<Dio> getAuthedDio() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token");

    if (token == null || token.isEmpty) {
      throw Exception("Kiosk token missing");
    }

    final dio = _getBaseDio(
      resolvedBaseUrl: _resolveBaseUrl(prefs.getString("kiosk_api_base_url")),
      profile: "kiosk",
    );
    dio.options.headers["X-Kiosk-Token"] = token;
    return dio;
  }

  static Future<Dio> getAdminDio() async {
    final prefs = await SharedPreferences.getInstance();
    final kioskToken = prefs.getString("auth_token");
    final token = prefs.getString("admin_token");

    if (kioskToken == null || kioskToken.isEmpty) {
      throw Exception("Kiosk token missing");
    }

    if (token == null || token.isEmpty) {
      throw Exception("Admin token missing");
    }

    final dio = _getBaseDio(
      resolvedBaseUrl: _resolveBaseUrl(prefs.getString("kiosk_api_base_url")),
      profile: "admin",
    );
    dio.options.headers["X-Kiosk-Token"] = kioskToken;
    dio.options.headers["X-Kiosk-Admin-Token"] = token;
    return dio;
  }
}
