import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/printer/epson_usb_printer_service.dart';
import 'package:api_selfxo_project/printer/printer_s.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RegisterKioskScreen extends StatefulWidget {
  const RegisterKioskScreen({super.key});

  @override
  State<RegisterKioskScreen> createState() => _RegisterKioskScreenState();
}

class _RegisterKioskScreenState extends State<RegisterKioskScreen> {
  final PrinterService _printerService = PrinterService();
  final EpsonUSBPrinterService _usbService = EpsonUSBPrinterService();
  final TextEditingController _kioskNameCtrl = TextEditingController();

  bool isLoading = true;
  bool _savingKioskName = false;
  bool _finishing = false;
  bool _active = true;

  String restaurantName = "Restaurant";
  String? restaurantAddress;
  Map<String, dynamic>? _settingsData;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _active = false;
    _kioskNameCtrl.dispose();
    super.dispose();
  }

  /* ================= LOGIC (UNCHANGED) ================= */

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

      if (!mounted) return;
      setState(() {
        _settingsData = settings;
        restaurantName = KioskRestaurantMeta.resolveRestaurantName(
          restaurant: restaurant,
          kioskSettings: settings,
        );
        restaurantAddress = restaurant["address"]?.toString();
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
        final branch = (raw["branch"] as Map?)?.cast<String, dynamic>();

        await ReceiptPrintMode.storeFromMap(kioskSettings);
        await ReceiptPrintMode.storeFromMap(restaurant);
        await KioskRestaurantMeta.storeFromMaps(
          restaurant: restaurant,
          kioskSettings: kioskSettings,
        );

        final mergedSettings = <String, dynamic>{};
        if (kioskSettings != null) {
          mergedSettings.addAll(kioskSettings);
        }
        final branchId = mergedSettings["branch_id"] ?? branch?["id"];
        if (branchId != null) mergedSettings["branch_id"] = branchId;
        final restaurantId = mergedSettings["restaurant_id"] ??
            restaurant["restaurant_id"] ??
            restaurant["id"];
        if (restaurantId != null) {
          mergedSettings["restaurant_id"] = restaurantId;
        }

        if (!mounted) return;
        setState(() {
          _settingsData =
              mergedSettings.isNotEmpty ? mergedSettings : kioskSettings;
          restaurantName = KioskRestaurantMeta.resolveRestaurantName(
            restaurant: restaurant,
            kioskSettings: kioskSettings,
          );
          restaurantAddress = restaurant["address"]?.toString();
          _kioskNameCtrl.text =
              (savedName != null && savedName.trim().isNotEmpty)
                  ? savedName.trim()
                  : "";
          isLoading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          restaurantName = "Restaurant";
          restaurantAddress = null;
          _kioskNameCtrl.text = "";
          isLoading = false;
        });
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
      if (mounted) {
        setState(() {
          _settingsData ??= {};
          _settingsData?["name"] = name;
          _settingsData?["kiosk_name"] = name;
          _settingsData?["kiosk_display_name"] = name;
          _settingsData?["device_name"] = name;
        });
      }
      OrderUtils.notifyInfoUpdated();
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("kiosk_name", name);
      await prefs.setString(KioskRestaurantMeta.kioskDisplayNameKey, name);
      await prefs.setString(KioskRestaurantMeta.restaurantNameKey, name);
      _showSnackBar("Saved locally.", Color(0xFF1B8E3E));
      OrderUtils.notifyInfoUpdated();
    } finally {
      if (mounted) setState(() => _savingKioskName = false);
    }
  }

  Future<void> _runTestPrint() async {
    try {
      await _printerService.testPrint(
        restaurantName: restaurantName,
        address: restaurantAddress,
      );
      _showSnackBar("Test print started", Colors.blue);
    } on PlatformException catch (e) {
      if (e.code == "USB_PERMISSION_REQUIRED") {
        final printer = await _printerService.getSelectedUsbPrinter();
        if (printer == null) {
          _showSnackBar("No USB printer selected", Colors.red);
          return;
        }
        final requested = await _usbService.requestUsbPermission(printer);
        if (requested) {
          await Future.delayed(const Duration(milliseconds: 600));
          if (!_active || !mounted) return;
          await _printerService.testPrint(
            restaurantName: restaurantName,
            address: restaurantAddress,
          );
        } else {
          _showSnackBar("USB permission denied", Colors.red);
        }
      } else {
        _showSnackBar(e.message ?? e.toString(), Colors.red);
      }
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
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
      if (_savingKioskName) {
        final end = DateTime.now().add(const Duration(seconds: 6));
        while (_savingKioskName && DateTime.now().isBefore(end)) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!_active || !mounted) return;
        }
      }
      if (!_savingKioskName) {
        await _saveKioskName();
      }
      if (_savingKioskName) {
        _showSnackBar("Please wait, saving...", Colors.orange);
        return;
      }

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

  /* ================= UI ================= */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
        elevation: 0,

        // 👈 Increase leading width so logo can grow
        leadingWidth: 90,

        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(
            child: Image.asset(
              "assets/self.png",
              height: 44, // 👈 visible, not cramped
              fit: BoxFit.contain,
            ),
          ),
        ),

        title: const Text(
          "Initial Setup",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              children: [
                _sectionTitle("Restaurant Info"),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        restaurantName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (restaurantAddress != null &&
                          restaurantAddress!.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          restaurantAddress!,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _sectionTitle("Device Setup"),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Device Name",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _kioskNameCtrl,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: const InputDecoration(
                          hintText: "Enter device name",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 48,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _savingKioskName ? null : _saveKioskName,
                          icon: _savingKioskName
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.save_rounded,
                                  color: Colors.white,
                                ),
                          label: const Text(
                            "Save Device Name",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF9F342C),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _sectionTitle("Printer Setup"),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Test Printer",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "Print a sample receipt to verify the printer is connected correctly.",
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 48,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _runTestPrint,
                          icon: const Icon(
                            Icons.print_rounded,
                            color: Colors.white,
                          ),
                          label: const Text(
                            "Run Test Print",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF9F342C),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _finishing ? null : _finishSetup,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B8E3E),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _finishing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            "Continue",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: Colors.grey.shade800,
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}
