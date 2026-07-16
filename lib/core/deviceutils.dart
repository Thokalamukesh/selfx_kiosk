import '../services/auth_service.dart';

class DeviceUtils {
  static Future<void> ensureDeviceReady() async {
    await AuthService().initializeKiosk();
  }
}
