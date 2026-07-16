import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';

class RestaurantService {
  /// Fetch restaurant + kiosk data
  /// and FORCE-SYNC backend device_id
  Future<Map<String, dynamic>?> fetchRestaurantData() async {
    try {
      final dio = await DioClient.getAuthedDio();
      final res = await dio.get("kiosk/bootstrap");

      final prefs = await SharedPreferences.getInstance();

      final backendDeviceId =
          res.data?["terminal"]?["device_uuid"] ??
          res.data?["kiosk_settings"]?["device_id"];

      if (backendDeviceId != null && backendDeviceId.toString().isNotEmpty) {
        await prefs.setString("device_uuid", backendDeviceId.toString());

      }

      return res.data;
    } catch (e) {
      return null;
    }
  }
}
