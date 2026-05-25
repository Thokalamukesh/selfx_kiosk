import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/screens/register_screen_web.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RegisterKioskScreen extends StatefulWidget {
  const RegisterKioskScreen({super.key});

  @override
  State<RegisterKioskScreen> createState() => _RegisterKioskScreenState();
}

class _RegisterKioskScreenState extends State<RegisterKioskScreen> {
  final TextEditingController _kioskNameCtrl = TextEditingController();

  bool isLoading = true;
  bool _savingKioskName = false;
  bool _finishing = false;

  String restaurantName = "Restaurant";
  Map<String, dynamic>? _settingsData;

  bool _hasUsableKioskSettings(Map<String, dynamic>? settings) {
    final deviceId = settings?["device_id"]?.toString().trim() ?? "";
    return deviceId.isNotEmpty;
  }

  Future<void> _redirectToRestaurantRegistration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const UserIdScreen()),
      (_) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _kioskNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedName = prefs.getString("kiosk_name");
      final res = await AdminApi().getSettings();
      final data = res.data ?? {};
      final settings =
          (data["settings"] as Map?)?.cast<String, dynamic>() ?? {};
      final restaurant =
          (data["restaurant"] as Map?)?.cast<String, dynamic>() ?? {};

      await ReceiptPrintMode.storeFromMap(settings);
      await ReceiptPrintMode.storeFromMap(restaurant);
      await KioskRestaurantMeta.storeFromMaps(
        restaurant: restaurant,
        kioskSettings: settings,
      );

      if (!_hasUsableKioskSettings(settings)) {
        await _redirectToRestaurantRegistration();
        return;
      }

      if (!mounted) return;
      setState(() {
        _settingsData = settings;
        restaurantName = KioskRestaurantMeta.resolveRestaurantName(
          restaurant: restaurant,
          kioskSettings: settings,
        );
        _kioskNameCtrl.text = (savedName != null && savedName.trim().isNotEmpty)
            ? savedName.trim()
            : "";
        isLoading = false;
      });
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedName = prefs.getString("kiosk_name");
        final res = await KioskApi().getRestaurantData();
        final raw = res.data ?? {};
        final restaurant =
            (raw["restaurant"] as Map?)?.cast<String, dynamic>() ??
                (raw as Map?)?.cast<String, dynamic>() ??
                {};
        final kioskSettings =
            (raw["kiosk_settings"] as Map?)?.cast<String, dynamic>();

        await ReceiptPrintMode.storeFromMap(kioskSettings);
        await ReceiptPrintMode.storeFromMap(restaurant);
        await KioskRestaurantMeta.storeFromMaps(
          restaurant: restaurant,
          kioskSettings: kioskSettings,
        );

        if (!_hasUsableKioskSettings(kioskSettings)) {
          await _redirectToRestaurantRegistration();
          return;
        }

        if (!mounted) return;
        setState(() {
          _settingsData = kioskSettings;
          restaurantName = KioskRestaurantMeta.resolveRestaurantName(
            restaurant: restaurant,
            kioskSettings: kioskSettings,
          );
          _kioskNameCtrl.text =
              (savedName != null && savedName.trim().isNotEmpty)
                  ? savedName.trim()
                  : "";
          isLoading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> _saveKioskName() async {
    final name = _kioskNameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnackBar("Enter device name", Colors.red);
      return;
    }
    if (_savingKioskName) return;

    setState(() => _savingKioskName = true);
    try {
      final body = <String, dynamic>{
        "name": name,
        "kiosk_name": name,
        "kiosk_display_name": name,
        "device_name": name,
      };
      if (_settingsData != null) {
        final branchId = _settingsData?["branch_id"];
        final printerId = _settingsData?["printer_id"];
        final deviceId = _settingsData?["device_id"];
        final restaurantId = _settingsData?["restaurant_id"];
        if (branchId != null) body["branch_id"] = branchId;
        if (printerId != null) body["printer_id"] = printerId;
        if (deviceId != null) body["device_id"] = deviceId;
        if (restaurantId != null) body["restaurant_id"] = restaurantId;
      }
      await AdminApi().updateSettings(body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("kiosk_name", name);
      await prefs.setString(KioskRestaurantMeta.kioskDisplayNameKey, name);
      await prefs.setString(KioskRestaurantMeta.restaurantNameKey, name);
      _showSnackBar("Device name updated", Colors.green);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("kiosk_name", name);
      await prefs.setString(KioskRestaurantMeta.kioskDisplayNameKey, name);
      await prefs.setString(KioskRestaurantMeta.restaurantNameKey, name);
      _showSnackBar("Saved locally.", const Color(0xFF1B8E3E));
    } finally {
      if (mounted) setState(() => _savingKioskName = false);
    }
  }

  Future<void> _finishSetup() async {
    if (_finishing) return;
    final name = _kioskNameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnackBar("Enter device name", Colors.red);
      return;
    }

    _finishing = true;
    try {
      await _saveKioskName();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool("kiosk_setup_done", true);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      );
    } finally {
      _finishing = false;
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
        title: const Text("Web Kiosk Setup"),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        restaurantName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Browser mode skips printer setup so you can preview the kiosk flow on web.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _kioskNameCtrl,
                        decoration: const InputDecoration(
                          labelText: "Kiosk name",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _savingKioskName ? null : _saveKioskName,
                        child: Text(_savingKioskName ? "Saving..." : "Save"),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: _finishing ? null : _finishSetup,
                        child: const Text("Finish Setup"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
