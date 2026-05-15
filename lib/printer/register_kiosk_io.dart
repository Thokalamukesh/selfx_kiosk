import 'dart:convert';

import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/printer/epson_usb_printer_service.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/printer/register_kiosk.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';

import '../services/auth_service.dart';

class UserIdScreen extends StatefulWidget {
  const UserIdScreen({super.key});

  @override
  State<UserIdScreen> createState() => _UserIdScreenState();
}

class _UserIdScreenState extends State<UserIdScreen> {
  final TextEditingController controller = TextEditingController();
  final EpsonUSBPrinterService _usbPrinterService = EpsonUSBPrinterService();

  bool loading = false;
  bool hasError = false;

  @override
  void initState() {
    super.initState();
    _loadSavedRestaurantId();
  }

  Future<void> _loadSavedRestaurantId() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRestaurantId = prefs.getString("restaurant_id")?.trim() ?? "";
    if (!mounted || savedRestaurantId.isEmpty || controller.text.isNotEmpty) {
      return;
    }
    controller.text = savedRestaurantId;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (loading) return;
    final restaurantId = controller.text.trim();
    if (restaurantId.isEmpty) {
      _showError("Please enter a Restaurant ID");
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("restaurant_id", restaurantId);

    if (!ConnectivityService.instance.isOnline.value) {
      _showError("No internet connection");
      return;
    }

    setState(() {
      loading = true;
      hasError = false;
    });

    try {
      final ok = await AuthService().initializeKiosk(force: true);
      if (!ok) throw Exception("Registration failed");

      final res = await KioskApi().getRestaurantData();
      final data = res.data?["restaurant"];
      final gst = data?["gst_number"] ??
          data?["gstin"] ??
          data?["tax_id"] ??
          data?["taxId"] ??
          data?["gst_no"] ??
          data?["gst"];
      if (gst != null && gst.toString().trim().isNotEmpty) {
        await prefs.setString("gst_number", gst.toString().trim());
      }

      if (!mounted) return;

      await _handleUSBPrinterSelection();

      final setupDone = prefs.getBool("kiosk_setup_done") ?? false;
      if (!mounted) return;
      if (!setupDone) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const RegisterKioskScreen()),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        );
      }
    } on DioException catch (e) {
      setState(() => hasError = true);
      final data = e.response?.data;
      String message = "Registration failed. Check ID and Internet.";
      if (data is Map) {
        final apiMessage =
            data["message"] ?? data["error"] ?? data["errors"]?.toString();
        if (apiMessage != null && apiMessage.toString().trim().isNotEmpty) {
          message = apiMessage.toString();
        }
      }
      _showError(message);
    } catch (_) {
      setState(() => hasError = true);
      _showError("Registration failed. Check ID and Internet.");
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _handleUSBPrinterSelection() async {
    try {
      final List<Map<String, dynamic>> printers =
          await _usbPrinterService.getPrinterList();

      if (printers.isEmpty) {
        await _showNoPrinterDialog();
        return;
      }

      Map<String, dynamic>? selectedPrinter;

      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text("USB Printer Detected"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Select the Epson printer for this Kiosk:"),
              const SizedBox(height: 16),
              SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: printers.length,
                  itemBuilder: (context, index) {
                    final p = printers[index];
                    return Card(
                      color: Colors.grey.shade100,
                      child: ListTile(
                        leading: const Icon(Icons.usb, color: Colors.blue),
                        title: Text(
                          p["name"] ?? p["productName"] ?? "USB Printer",
                        ),
                        subtitle: Text(
                          "Device: ${p["deviceId"] ?? "-"} • VID: ${p["vendorId"] ?? "-"} • PID: ${p["productId"] ?? "-"}",
                        ),
                        onTap: () {
                          selectedPrinter = p;
                          Navigator.pop(context);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );

      if (selectedPrinter != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("printer_type", "usb");
        await prefs.setString(
          "selected_usb_printer",
          jsonEncode(selectedPrinter),
        );
        await _usbPrinterService.setSelectedPrinter(selectedPrinter!);
        await _usbPrinterService.scanAndConnect();

        _showSuccessSnackBar(
          "Printer Configured: ${selectedPrinter!["name"] ?? selectedPrinter!["productName"] ?? "USB Printer"}",
        );
      }
    } catch (_) {}
  }

  Future<void> _showNoPrinterDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("No Printer Found"),
        content: const Text(
          "Ensure your Epson USB printer is plugged in and turned on. You can configure this later in Settings.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade800),
    );
  }

  void _showSuccessSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.green.shade800),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width > 700;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
        elevation: 0,
        centerTitle: true,
        leadingWidth: isTablet ? 0 : 120,
        leading: isTablet
            ? null
            : Padding(
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
          "Kiosk",
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 28,
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isTablet) ...[
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          "assets/selfxfavicon.jpg",
                          width: 108,
                          height: 108,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  const Text(
                    "Please Register kiosk with your Restaurant",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 20),
                  CupertinoTextField(
                    controller: controller,
                    placeholder: "Enter Restaurant ID",
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9F342C),
                        foregroundColor: Colors.white,
                      ),
                      child: loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text("Continue"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
