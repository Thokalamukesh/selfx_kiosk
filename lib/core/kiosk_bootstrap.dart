import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_service.dart';

class DeviceBootstrap {
  static Future<void> ensureDeviceReady() async {
    final prefs = await SharedPreferences.getInstance();
    final existingToken = prefs.getString("auth_token");
    if (existingToken != null && existingToken.isNotEmpty) {
      return;
    }

    await AuthService().initializeKiosk();
  }
}
