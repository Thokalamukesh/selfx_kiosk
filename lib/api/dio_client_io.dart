import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:api_selfxo_project/core/connectivity_service.dart';

class DioClient {
  static const String baseUrl = "https://selfposdev.sirixo.com/api/";
  static const int _maxRetries = 3;
  static const Duration _retryBaseDelay = Duration(milliseconds: 500);

  static Dio _createBaseDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
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
          final body = e.response?.data.toString() ?? "";
          final isNetworkError = e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.error is SocketException;

          if (isNetworkError) {
            final extra = e.requestOptions.extra;
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

          if (path.contains("admin/authenticate")) {
            return handler.next(e);
          }

          if (body.contains("MAC is invalid")) {
            return handler.next(e);
          }

          if (status == 401 || status == 403) {
            final prefs = await SharedPreferences.getInstance();
            if (path.contains("admin/")) {
              await prefs.remove("admin_token");
            } else {
              await prefs.remove("auth_token");
            }
          }

          handler.next(e);
        },
      ),
    );

    return dio;
  }

  static Dio getDio() => _createBaseDio();

  static Future<Dio> getAuthedDio() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token");

    if (token == null || token.isEmpty) {
      throw Exception("Kiosk token missing");
    }

    final dio = _createBaseDio();
    dio.options.headers["Authorization"] = "Bearer $token";
    return dio;
  }

  static Future<Dio> getAdminDio() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("admin_token");

    if (token == null || token.isEmpty) {
      throw Exception("Admin token missing");
    }

    final dio = _createBaseDio();
    dio.options.headers["Authorization"] = "Bearer $token";
    return dio;
  }
}
