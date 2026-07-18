import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/printer/epson_usb_printer_service.dart';
import 'package:api_selfxo_project/printer/printer_s.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/menu_sync.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _appVersion = "SELFX 4.01";
  final printerService = PrinterService();
  final EpsonUSBPrinterService _usbService = EpsonUSBPrinterService();
  final TextEditingController _kioskNameCtrl = TextEditingController();

  bool isLoading = true;
  bool isCheckingPrinter = false;
  bool _savingKioskName = false;
  bool _savingDisplaySettings = false;
  bool _showItemImages = true;
  bool _showCategoryImages = true;
  bool _printReceiptOnComplete = true;
  String _taxBreakdownDisplay = "always";
  String _variantPriceDisplay = "from_amount";

  String restaurantName = "Loading...";
  String kioskName = "Loading...";
  String? restaurantAddress;
  Map<String, dynamic>? _settingsData;

  PrinterType? selectedPrinterType;
  PrinterStatus? printerStatus;
  String? _connectedPrinterName;
  final List<String> _printerLogs = [];
  final ScrollController _logScrollController = ScrollController();
  bool _pendingTestPrint = false;

  // ✅ FIXED: Must match MainActivity.kt
  static const MethodChannel _usbEvents = MethodChannel(
    'com.whimsicaldev/usb_events',
  );
  static const MethodChannel _deviceSettings = MethodChannel(
    'com.selfx/device_settings',
  );

  @override
  void initState() {
    super.initState();
    _loadSettings();

    // ✅ FIXED USB attach / detach handling
    _usbEvents.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPrinterLog':
          final message = call.arguments?['message']?.toString() ?? '';
          final timestamp = call.arguments?['timestamp']?.toString();
          _appendLog(message, timestamp: timestamp);
          break;
        case 'onPrinterConnected':
          final name = call.arguments?['productName']?.toString() ??
              call.arguments?['manufacturerName']?.toString() ??
              'USB Printer';
          setState(() => _connectedPrinterName = name);
          _appendLog(
            "Connected to $name",
            timestamp: call.arguments?['timestamp']?.toString(),
          );
          await _checkPrinterStatus();
          break;
        case 'onPrinterError':
          final code = call.arguments?['code']?.toString() ?? 'ERROR';
          final message = call.arguments?['message']?.toString() ?? '';
          _appendLog(
            "Error [$code] $message",
            timestamp: call.arguments?['timestamp']?.toString(),
          );
          await _checkPrinterStatus();
          break;
        case 'usb_attached':
          if (selectedPrinterType == null ||
              selectedPrinterType == PrinterType.usb) {
            await _autoSelectUsbIfSingle();
          }
          await _checkPrinterStatus();
          break;
        case 'usb_permission_granted':
          if (_pendingTestPrint) {
            _pendingTestPrint = false;
            await Future.delayed(const Duration(milliseconds: 300));
            await _runTestPrint();
          }
          await _checkPrinterStatus();
          break;
        case 'usb_permission_denied':
          _pendingTestPrint = false;
          await _checkPrinterStatus();
          break;
        case 'usb_detached':
          await _checkPrinterStatus();
          break;
      }
    });
  }

  @override
  void dispose() {
    _usbEvents.setMethodCallHandler(null);
    _logScrollController.dispose();
    _kioskNameCtrl.dispose();
    super.dispose();
  }

  void _goToWelcome() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  Future<void> _openWifiSettings() async {
    try {
      await _deviceSettings.invokeMethod<void>('openWifiSettings');
    } on PlatformException catch (e) {
      _showSnackBar(e.message ?? "Unable to open WiFi settings", Colors.red);
    } catch (_) {
      _showSnackBar("Unable to open WiFi settings", Colors.red);
    }
  }

  Future<void> _openSystemSettings() async {
    try {
      await _deviceSettings.invokeMethod<void>('openSystemSettings');
    } on PlatformException catch (e) {
      _showSnackBar(e.message ?? "Unable to open system settings", Colors.red);
    } catch (_) {
      _showSnackBar("Unable to open system settings", Colors.red);
    }
  }

  // ================= LOAD SETTINGS =================
  Future<void> _loadSettings() async {
    if (mounted) setState(() => isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final savedType = prefs.getString("printer_type");

    if (savedType != null) {
      selectedPrinterType = PrinterType.values.firstWhere(
        (e) => e.name == savedType,
        orElse: () => PrinterType.internal,
      );
    }

    try {
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
      await _storeDisplaySettings(settings);
      setState(() {
        _settingsData = settings;
        _applyDisplaySettings(settings, prefs);
        restaurantName = KioskRestaurantMeta.resolveRestaurantName(
          restaurant: restaurant,
          kioskSettings: settings,
        );
        restaurantAddress = restaurant["address"]?.toString();
        final savedName = prefs.getString("kiosk_name");
        kioskName = (savedName != null && savedName.trim().isNotEmpty)
            ? savedName.trim()
            : (settings["kiosk_display_name"] ??
                settings["name"] ??
                settings["kiosk_name"] ??
                restaurant["kiosk_name"] ??
                "SELFX Kiosk");
        _kioskNameCtrl.text = kioskName;
        isLoading = false;
      });
    } catch (_) {
      try {
        final res = await KioskApi().getRestaurantData();
        final bundle = KioskRestaurantMeta.extractBundle(res.data);
        final data = bundle.restaurant ?? bundle.root ?? {};

        if (!mounted) return;
        setState(() {
          restaurantName = KioskRestaurantMeta.resolveRestaurantName(
            root: bundle.root,
            data: bundle.data,
            restaurant: bundle.restaurant,
            kioskSettings: bundle.kioskSettings,
          );
          restaurantAddress = data["address"]?.toString();
          final savedName = prefs.getString("kiosk_name");
          kioskName = (savedName != null && savedName.trim().isNotEmpty)
              ? savedName.trim()
              : (bundle.kioskSettings?["kiosk_display_name"] ??
                  data["kiosk_display_name"] ??
                  data["kiosk_name"] ??
                  "SELFX Kiosk");
          _kioskNameCtrl.text = kioskName;
          isLoading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          restaurantName = "Admin Panel";
          restaurantAddress = null;
          kioskName = "SELFX Kiosk";
          _kioskNameCtrl.text = kioskName;
          isLoading = false;
        });
      }
    }

    await _checkPrinterStatus();
    await _loadNativeLogs();
  }

  void _applyDisplaySettings(
    Map<String, dynamic> settings,
    SharedPreferences prefs,
  ) {
    _showItemImages = _boolSetting(
      settings["show_item_images"] ?? settings["showItemImages"],
      fallback: prefs.getBool(KioskRestaurantMeta.showItemImagesKey) ?? true,
    );
    _showCategoryImages = _boolSetting(
      settings["show_category_images"] ?? settings["showCategoryImages"],
      fallback:
          prefs.getBool(KioskRestaurantMeta.showCategoryImagesKey) ?? true,
    );
    _printReceiptOnComplete = _boolSetting(
      settings["print_receipt_on_complete"] ??
          settings["printReceiptOnComplete"],
      fallback: prefs.getBool("print_receipt_on_complete") ?? true,
    );
    _taxBreakdownDisplay = (settings["tax_breakdown_display"] ??
            settings["taxBreakdownDisplay"] ??
            prefs.getString(KioskRestaurantMeta.taxBreakdownDisplayKey) ??
            "always")
        .toString();
    _variantPriceDisplay = (settings["variant_price_display"] ??
            settings["variantPriceDisplay"] ??
            prefs.getString(KioskRestaurantMeta.variantPriceDisplayKey) ??
            "from_amount")
        .toString();
  }

  bool _boolSetting(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value == null) return fallback;
    final text = value.toString().trim().toLowerCase();
    if (text == "1" || text == "true" || text == "yes" || text == "on") {
      return true;
    }
    if (text == "0" || text == "false" || text == "no" || text == "off") {
      return false;
    }
    return fallback;
  }

  Future<void> _storeDisplaySettings(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    final showItem = _boolSetting(
      settings["show_item_images"] ?? settings["showItemImages"],
      fallback: prefs.getBool(KioskRestaurantMeta.showItemImagesKey) ?? true,
    );
    final showCategory = _boolSetting(
      settings["show_category_images"] ?? settings["showCategoryImages"],
      fallback:
          prefs.getBool(KioskRestaurantMeta.showCategoryImagesKey) ?? true,
    );
    final printReceipt = _boolSetting(
      settings["print_receipt_on_complete"] ??
          settings["printReceiptOnComplete"],
      fallback: prefs.getBool("print_receipt_on_complete") ?? true,
    );
    await prefs.setBool(KioskRestaurantMeta.showItemImagesKey, showItem);
    await prefs.setBool(
      KioskRestaurantMeta.showCategoryImagesKey,
      showCategory,
    );
    await prefs.setBool("print_receipt_on_complete", printReceipt);
    final tax =
        (settings["tax_breakdown_display"] ?? settings["taxBreakdownDisplay"])
            ?.toString();
    if (tax != null && tax.isNotEmpty) {
      await prefs.setString(KioskRestaurantMeta.taxBreakdownDisplayKey, tax);
    }
    final variant =
        (settings["variant_price_display"] ?? settings["variantPriceDisplay"])
            ?.toString();
    if (variant != null && variant.isNotEmpty) {
      await prefs.setString(
          KioskRestaurantMeta.variantPriceDisplayKey, variant);
    }
  }

  // ================= PRINTER STATUS =================
  Future<void> _checkPrinterStatus() async {
    if (isCheckingPrinter) return;

    setState(() => isCheckingPrinter = true);

    try {
      final status = await printerService.getPrinterStatus();
      if (!mounted) return;

      setState(() => printerStatus = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => printerStatus = PrinterStatus.offline);
    } finally {
      if (mounted) {
        setState(() => isCheckingPrinter = false);
      }
    }
  }

  // ================= SAVE PRINTER =================
  Future<void> _savePrinterType(PrinterType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("printer_type", type.name);

    setState(() => selectedPrinterType = type);

    if (type == PrinterType.lan) {
      await _askAndSaveEpsonIp();
    }

    await _checkPrinterStatus();
    _showSnackBar("Printer configured successfully", Colors.green);
  }

  Future<void> _selectUsbPrinter() async {
    final printers = await printerService.getUsbPrinters();
    if (!mounted) return;

    if (printers.isEmpty) {
      _showSnackBar("No USB printers found", Colors.red);
      return;
    }

    Map<String, dynamic>? selectedPrinter;

    if (printers.length == 1) {
      selectedPrinter = printers.first;
    } else {
      await showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text("Select USB Printer"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: printers.length,
              itemBuilder: (context, index) {
                final p = printers[index];
                return ListTile(
                  leading: const Icon(Icons.usb, color: Colors.blue),
                  title: Text(p["name"] ?? p["productName"] ?? "USB Printer"),
                  subtitle: Text(
                    "Device: ${p["deviceId"] ?? "-"} • VID: ${p["vendorId"] ?? "-"} • PID: ${p["productId"] ?? "-"}",
                  ),
                  onTap: () {
                    selectedPrinter = p;
                    Navigator.pop(dialogContext);
                  },
                );
              },
            ),
          ),
        ),
      );
    }

    if (selectedPrinter == null) return;

    await printerService.saveSelectedUsbPrinter(selectedPrinter!);
    await _savePrinterType(PrinterType.usb);
  }

  Future<void> _autoSelectUsbIfSingle() async {
    final printers = await printerService.getUsbPrinters();
    if (printers.length == 1) {
      await printerService.saveSelectedUsbPrinter(printers.first);
      await _savePrinterType(PrinterType.usb);
    }
  }

  // ================= EPSON IP (LAN) =================
  Future<void> _askAndSaveEpsonIp() async {
    final controller = TextEditingController();

    try {
      await showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text("Epson Printer IP"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: "192.168.1.100"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                final ip = controller.text.trim();
                if (ip.isEmpty) return;

                final prefs = await SharedPreferences.getInstance();
                await prefs.setString("epson_ip", ip);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  // ================= TEST PRINT =================
  Future<void> _runTestPrint() async {
    try {
      await printerService.testPrint(
        restaurantName: restaurantName,
        address: restaurantAddress,
      );
      _showSnackBar("Test print started", Colors.blue);
    } on PlatformException catch (e) {
      if (e.code == "USB_PERMISSION_REQUIRED") {
        final printer = await printerService.getSelectedUsbPrinter();
        if (printer == null) {
          _showSnackBar("No USB printer selected", Colors.red);
          return;
        }
        final requested = await _usbService.requestUsbPermission(printer);
        if (requested) {
          _pendingTestPrint = true;
          _showSnackBar("Grant USB permission to print", Colors.orange);
        } else {
          _showSnackBar("USB device not found", Colors.red);
        }
      } else {
        _showSnackBar(e.message ?? e.toString(), Colors.red);
      }
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
    }
  }

  // ================= KIOSK NAME =================
  Future<void> _saveKioskName() async {
    final name = _kioskNameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnackBar("Enter kiosk name", Colors.red);
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
      if (!mounted) return;
      setState(() {
        kioskName = name;
        _settingsData ??= {};
        _settingsData?["name"] = name;
        _settingsData?["kiosk_name"] = name;
        _settingsData?["kiosk_display_name"] = name;
        _settingsData?["device_name"] = name;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("kiosk_name", name);
      await prefs.setString(KioskRestaurantMeta.kioskDisplayNameKey, name);
      await prefs.setString(KioskRestaurantMeta.restaurantNameKey, name);
      OrderUtils.notifyInfoUpdated();
      _showSnackBar("Kiosk name updated", Colors.green);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("kiosk_name", name);
      await prefs.setString(KioskRestaurantMeta.kioskDisplayNameKey, name);
      await prefs.setString(KioskRestaurantMeta.restaurantNameKey, name);
      OrderUtils.notifyInfoUpdated();
      _showSnackBar("Failed to update name", Colors.red);
    } finally {
      if (mounted) {
        setState(() => _savingKioskName = false);
      }
    }
  }

  Future<void> _saveDisplaySettings() async {
    if (_savingDisplaySettings) return;
    setState(() => _savingDisplaySettings = true);
    final body = <String, dynamic>{
      "show_item_images": _showItemImages,
      "show_category_images": _showCategoryImages,
      "print_receipt_on_complete": _printReceiptOnComplete,
      "tax_breakdown_display": _taxBreakdownDisplay,
      "variant_price_display": _variantPriceDisplay,
    };
    try {
      await AdminApi().updateSettings(body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        KioskRestaurantMeta.showItemImagesKey,
        _showItemImages,
      );
      await prefs.setBool(
        KioskRestaurantMeta.showCategoryImagesKey,
        _showCategoryImages,
      );
      await prefs.setBool(
        "print_receipt_on_complete",
        _printReceiptOnComplete,
      );
      await prefs.setString(
        KioskRestaurantMeta.taxBreakdownDisplayKey,
        _taxBreakdownDisplay,
      );
      await prefs.setString(
        KioskRestaurantMeta.variantPriceDisplayKey,
        _variantPriceDisplay,
      );
      _settingsData ??= {};
      _settingsData!.addAll(body);
      OrderUtils.notifyInfoUpdated();
      MenuSync.notifyUpdated();
      _showSnackBar("Display settings updated", Colors.green);
    } catch (_) {
      _showSnackBar("Failed to update display settings", Colors.red);
    } finally {
      if (mounted) setState(() => _savingDisplaySettings = false);
    }
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      appBar: AppBar(
        toolbarHeight: 100,
        backgroundColor: const Color(0xFF9F342C),
        elevation: 0,
        leadingWidth: 120,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Image.asset(
              "assets/self.png",
              height: 36,
              fit: BoxFit.contain,
            ),
          ),
        ),
        title: const Text(
          "Version : SELFX4.01",
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _openSystemSettings,
            icon: const Icon(Icons.settings_rounded),
            color: Colors.white,
            tooltip: "System Settings",
          ),
          IconButton(
            onPressed: _openWifiSettings,
            icon: const Icon(Icons.wifi_rounded),
            color: Colors.white,
            tooltip: "WiFi Settings",
          ),
          IconButton(
            onPressed: _goToWelcome,
            icon: const Icon(Icons.logout_rounded),
            color: Colors.white,
            tooltip: "Logout",
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _settingsCard(),

                      const SizedBox(height: 224),

                      // ===== SOFTWARE UPDATE BUTTON =====
                      Center(
                        child: SizedBox(
                          width: 320, // 👈 adjust (280–360 works well)
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final uri = Uri.parse(
                                'https://selfpos.sirixo.com/apk/selfxnew.apk', // 👈 your link
                              );

                              if (await canLaunchUrl(uri)) {
                                await launchUrl(
                                  uri,
                                  mode: LaunchMode
                                      .externalApplication, // opens browser
                                );
                              } else {}
                            },
                            icon: const Icon(Icons.system_update_alt),
                            label: const Text(
                              "Software Update",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              elevation: 6,
                              backgroundColor: const Color(0xFF9F342C),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _settingsCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            restaurantName,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            "Version: $_appVersion",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 20),
          const Text(
            "Kiosk Settings",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          const Text(
            "Kiosk Name",
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _kioskNameCtrl,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveKioskName(),
            decoration: InputDecoration(
              hintText: "Enter kiosk name",
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(10),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: const BorderSide(color: Color(0xFF9F342C)),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _displaySettingsSection(),
          const SizedBox(height: 18),
          const Text(
            "Select Printer",
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _printerDropdown(),
          if (_connectedPrinterName != null &&
              _connectedPrinterName!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              "Connected: $_connectedPrinterName",
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    onPressed: _runTestPrint,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0E8A4D),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      "Test Print",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    onPressed: _savingKioskName ? null : _saveKioskName,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _savingKioskName
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            "Save",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _displaySettingsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEED9BC)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5F1711).withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                height: 42,
                width: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF9F342C).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.dashboard_customize_rounded,
                  color: Color(0xFF9F342C),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "Display Settings",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _settingsSwitch(
            icon: Icons.image_rounded,
            title: "Show menu item images",
            subtitle: "Product cards use item photos when enabled.",
            value: _showItemImages,
            onChanged: (value) => setState(() => _showItemImages = value),
          ),
          const SizedBox(height: 10),
          _settingsSwitch(
            icon: Icons.category_rounded,
            title: "Show category images",
            subtitle: "Turn off for a clean text-only category menu.",
            value: _showCategoryImages,
            onChanged: (value) => setState(() => _showCategoryImages = value),
          ),
          const SizedBox(height: 10),
          _settingsSwitch(
            icon: Icons.receipt_long_rounded,
            title: "Print receipt when order completes",
            subtitle: "Follows the admin receipt setting.",
            value: _printReceiptOnComplete,
            onChanged: (value) =>
                setState(() => _printReceiptOnComplete = value),
          ),
          const SizedBox(height: 14),
          _settingsDropdown(
            icon: Icons.percent_rounded,
            label: "Tax breakdown",
            value: _taxBreakdownDisplay,
            items: const {
              "hidden": "Hidden",
              "total_only": "Tax total only",
              "always": "Full breakdown",
              "expandable": "Expandable",
            },
            onChanged: (value) => setState(() => _taxBreakdownDisplay = value),
          ),
          const SizedBox(height: 10),
          _settingsDropdown(
            icon: Icons.sell_rounded,
            label: "Variant item price",
            value: _variantPriceDisplay,
            items: const {
              "from_amount": "From lowest price",
              "on_selection": "Price on selection",
            },
            onChanged: (value) => setState(() => _variantPriceDisplay = value),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _savingDisplaySettings ? null : _saveDisplaySettings,
              icon: _savingDisplaySettings
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.tune_rounded),
              label: const Text(
                "Save Display Settings",
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9F342C),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsSwitch({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: value ? const Color(0xFFFFF7EC) : const Color(0xFFF8F6F3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value
              ? const Color(0xFFEBC991)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: value
                  ? const Color(0xFF9F342C).withValues(alpha: 0.12)
                  : Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: value ? const Color(0xFF9F342C) : Colors.grey.shade600,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            activeThumbColor: const Color(0xFF9F342C),
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _settingsDropdown({
    required IconData icon,
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) {
    final normalizedValue = items.containsKey(value) ? value : items.keys.first;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6F3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF9F342C), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: normalizedValue,
              decoration: InputDecoration(
                labelText: label,
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF9F342C)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: [
                for (final entry in items.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _printerDropdown() {
    return DropdownButtonFormField<PrinterType>(
      initialValue: selectedPrinterType,
      hint: const Text("Select Printer"),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Color(0xFF9F342C)),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      items: const [
        DropdownMenuItem(
          value: PrinterType.internal,
          child: Text("Internal (Sunmi)"),
        ),
        DropdownMenuItem(value: PrinterType.usb, child: Text("USB Printer")),
        DropdownMenuItem(value: PrinterType.lan, child: Text("LAN (Epson IP)")),
      ],
      onChanged: (type) async {
        if (type == null) return;
        if (type == PrinterType.usb) {
          await _selectUsbPrinter();
          return;
        }
        await _savePrinterType(type);
      },
    );
  }

  // ================= HEADER =================
  // ignore: unused_element
  Widget _header() {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 60, 24, 30),
          decoration: const BoxDecoration(color: Color(0xFF9F342C)),
          child: Row(
            children: [
              Image.asset("assets/self.png", height: 32),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "SELFX 4.01",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    kioskName,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
              const Spacer(),
              IconButton(
                onPressed: _goToWelcome,
                icon: const Icon(Icons.logout_rounded),
                color: Colors.white,
                tooltip: "Exit",
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ================= HELPERS =================
  // ignore: unused_element
  Widget _statusCard() {
    final statusColor = _printerStatusColor();
    final statusText = _printerStatusText();
    final connected = _connectedPrinterName != null
        ? "Connected: $_connectedPrinterName"
        : "";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Row(
        children: [
          _iconBadge(Icons.print_rounded, statusColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Printer Status",
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (connected.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    connected,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _checkPrinterStatus,
            icon: const Icon(Icons.refresh),
            label: const Text("Refresh"),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _kioskNameCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Device Name",
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _kioskNameCtrl,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveKioskName(),
            decoration: const InputDecoration(
              hintText: "Enter kiosk name",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _savingKioskName ? null : _saveKioskName,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _savingKioskName
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded),
              label: const Text(
                "Save Name",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _testPrintCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconBadge(Icons.receipt_long, const Color(0xFF9F342C)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "Test Print",
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Print a sample receipt to confirm printer connection.",
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _runTestPrint,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.print_rounded),
              label: const Text(
                "Run Test Print",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const Row(children: []),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _pill(String label, String value, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (color ?? const Color(0xFF9F342C)).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (color ?? const Color(0xFF9F342C)).withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        "$label: $value",
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color ?? const Color(0xFF9F342C),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _sectionTitle(String title, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _actionRow() {
    final canTest = selectedPrinterType == PrinterType.internal ||
        selectedPrinterType == PrinterType.usb;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _actionButton(
          icon: Icons.refresh,
          label: "Refresh Status",
          onTap: _checkPrinterStatus,
        ),
        if (selectedPrinterType == PrinterType.usb)
          _actionButton(
            icon: Icons.usb,
            label: "Grant USB Permission",
            onTap: _runUsbProvisioning,
          ),
        if (canTest)
          _actionButton(
            icon: Icons.receipt_long,
            label: "Test Print",
            onTap: _runTestPrint,
            primary: true,
          ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final style = primary
        ? ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF9F342C),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          )
        : OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF9F342C),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          );

    final child = primary
        ? ElevatedButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
            style: style,
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
            style: style,
          );

    return child;
  }

  // ignore: unused_element
  Widget _card({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool selected,
    bool isStatusCard = false,
  }) {
    final highlightColor = isStatusCard ? _printerStatusColor() : Colors.green;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: _surfaceDecoration(
          borderColor: selected ? highlightColor : Colors.grey.shade200,
        ),
        child: Row(
          children: [
            _iconBadge(
              icon,
              isStatusCard
                  ? _printerStatusColor()
                  : (selected ? Colors.green : Colors.grey),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (selected)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  "Selected",
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _debugLogPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  "Printer Debug Logs",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(onPressed: _clearLogs, child: const Text("Clear")),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 220,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _printerLogs.isEmpty
                ? const Text(
                    "No logs yet",
                    style: TextStyle(color: Colors.white70),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    itemCount: _printerLogs.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _printerLogs[index],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _surfaceDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: borderColor ?? Colors.grey.shade200),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 12,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  Widget _iconBadge(IconData icon, Color color) {
    return Container(
      height: 40,
      width: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color),
    );
  }

  String _printerStatusText() {
    if (isCheckingPrinter) return "Checking printer...";
    switch (printerStatus) {
      case PrinterStatus.online:
        if (_connectedPrinterName != null) {
          return "ONLINE • $_connectedPrinterName";
        }
        return "ONLINE";
      case PrinterStatus.offline:
        return "OFFLINE";
      case PrinterStatus.notConfigured:
        return "NOT CONFIGURED";
      default:
        return "UNKNOWN";
    }
  }

  Color _printerStatusColor() {
    switch (printerStatus) {
      case PrinterStatus.online:
        return Colors.green;
      case PrinterStatus.offline:
        return Colors.red;
      case PrinterStatus.notConfigured:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(backgroundColor: color, content: Text(msg)));
  }

  Future<void> _loadNativeLogs() async {
    try {
      final logs = await _usbService.getNativeLogs();
      if (logs.isEmpty) return;
      for (final line in logs) {
        _appendLog(line, raw: true);
      }
    } catch (_) {}
  }

  Future<void> _clearLogs() async {
    if (!mounted) return;
    setState(() => _printerLogs.clear());
    try {
      await _usbService.clearNativeLogs();
    } catch (_) {}
  }

  void _appendLog(String message, {String? timestamp, bool raw = false}) {
    final entry = raw ? message : "[${timestamp ?? _formatNow()}] $message";

    if (!mounted) return;
    setState(() {
      _printerLogs.add(entry);
      if (_printerLogs.length > 200) {
        _printerLogs.removeAt(0);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) return;
      _logScrollController.jumpTo(
        _logScrollController.position.maxScrollExtent,
      );
    });
  }

  String _formatNow() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return "$h:$m:$s";
  }

  Future<void> _runUsbProvisioning() async {
    try {
      Map<String, dynamic>? printer =
          await printerService.getSelectedUsbPrinter();
      if (printer == null) {
        final list = await printerService.getUsbPrinters();
        if (list.isNotEmpty) {
          printer = list.first;
        }
      }
      if (printer == null) {
        _showSnackBar("No USB printer found", Colors.red);
        return;
      }
      final requested = await _usbService.requestUsbPermissionWithUi(
        printer,
        durationMs: 20000,
      );
      if (requested) {
        _showSnackBar(
          "USB permission request sent. Allow the popup.",
          Colors.orange,
        );
      } else {
        _showSnackBar("USB device not found", Colors.red);
      }
    } catch (e) {
      _showSnackBar(e.toString(), Colors.red);
    }
  }
}
