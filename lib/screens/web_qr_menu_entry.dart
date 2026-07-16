import 'dart:async';

import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/receipt_print_mode.dart';
import 'package:api_selfxo_project/screens/main_navigation.dart';
import 'package:api_selfxo_project/screens/register_screen.dart';
import 'package:api_selfxo_project/services/auth_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebQrMenuEntryScreen extends StatefulWidget {
  final String restaurantId;
  final String? requestedOrderType;

  const WebQrMenuEntryScreen({
    super.key,
    required this.restaurantId,
    this.requestedOrderType,
  });

  @override
  State<WebQrMenuEntryScreen> createState() => _WebQrMenuEntryScreenState();
}

class _WebQrMenuEntryScreenState extends State<WebQrMenuEntryScreen> {
  bool _loading = true;
  String? _errorMessage;

  String _extractErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final message = data["message"] ?? data["error"] ?? data["errors"];
        if (message != null && message.toString().trim().isNotEmpty) {
          return message.toString().trim();
        }
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }

    final raw = error.toString().replaceFirst("Exception: ", "").trim();
    if (raw.isEmpty) {
      return "This restaurant menu could not be opened.";
    }
    return raw;
  }

  @override
  void initState() {
    super.initState();
    _bootstrapFromQr();
  }

  Future<void> _bootstrapFromQr() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final previousRestaurantId = prefs.getString("restaurant_id");
      final restaurantChanged = previousRestaurantId != null &&
          previousRestaurantId.trim().isNotEmpty &&
          previousRestaurantId.trim() != widget.restaurantId.trim();

      if (restaurantChanged) {
        await prefs.remove("auth_token");
        await prefs.remove("admin_token");
        await prefs.remove("branch_id");
        await prefs.remove("home_banner_url");
        await prefs.remove("gst_number");
      }

      await prefs.setString("restaurant_id", widget.restaurantId.trim());
      await prefs.setBool("kiosk_setup_done", true);

      final ok = await AuthService().initializeKiosk(force: restaurantChanged);
      if (!ok) {
        throw Exception("Unable to initialize this restaurant on web.");
      }

      Map<String, dynamic>? restaurant;
      Map<String, dynamic>? kioskSettings;
      try {
        final res = await KioskApi()
            .getRestaurantData()
            .timeout(const Duration(seconds: 4));
        final bundle = _extractRestaurantBundle(res.data);
        restaurant = bundle.restaurant;
        kioskSettings = bundle.kioskSettings;
        await _applyRestaurantMeta(
          prefs: prefs,
          restaurant: restaurant,
          kioskSettings: kioskSettings,
        );
      } catch (e) {
        if (KioskApi.isBootstrapForbiddenError(e)) {
          throw Exception(KioskApi.bootstrapDisabledHelpMessage(e));
        }
        unawaited(_refreshRestaurantMetaInBackground());
      }

      final orderType = _resolveInitialOrderType(
        requested: widget.requestedOrderType,
        restaurant: restaurant,
        kioskSettings: kioskSettings,
      );

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainNavigation(orderType: orderType),
        ),
      );
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("restaurant_id");
      await prefs.setBool("kiosk_setup_done", false);
      if (!mounted) return;
      setState(() {
        _errorMessage = _extractErrorMessage(e);
        _loading = false;
      });
      return;
    }
  }

  ({Map<String, dynamic>? restaurant, Map<String, dynamic>? kioskSettings})
      _extractRestaurantBundle(dynamic raw) {
    Map<String, dynamic>? toStringKeyedMap(dynamic value) {
      if (value is! Map) return null;
      return value.map((key, value) => MapEntry("$key", value));
    }

    final root = toStringKeyedMap(raw);
    final data = toStringKeyedMap(root?["data"]);

    final restaurant = toStringKeyedMap(root?["restaurant"]) ??
        toStringKeyedMap(data?["restaurant"]);
    final kioskSettings = toStringKeyedMap(root?["kiosk_settings"]) ??
        toStringKeyedMap(data?["kiosk_settings"]);

    return (restaurant: restaurant, kioskSettings: kioskSettings);
  }

  Future<void> _applyRestaurantMeta({
    required SharedPreferences prefs,
    required Map<String, dynamic>? restaurant,
    required Map<String, dynamic>? kioskSettings,
  }) async {
    final gst = _extractTaxId(restaurant, kioskSettings);
    if (gst != null && gst.trim().isNotEmpty) {
      await prefs.setString("gst_number", gst);
    }
    await KioskRestaurantMeta.storeFromMaps(
      restaurant: restaurant,
      kioskSettings: kioskSettings,
    );
    await ReceiptPrintMode.storeFromMap(kioskSettings);
    await ReceiptPrintMode.storeFromMap(restaurant);
  }

  Future<void> _refreshRestaurantMetaInBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final res = await KioskApi().getRestaurantData();
      final bundle = _extractRestaurantBundle(res.data);
      await _applyRestaurantMeta(
        prefs: prefs,
        restaurant: bundle.restaurant,
        kioskSettings: bundle.kioskSettings,
      );
    } catch (_) {}
  }

  String _resolveInitialOrderType({
    required String? requested,
    required Map<String, dynamic>? restaurant,
    required Map<String, dynamic>? kioskSettings,
  }) {
    final requestedType = _normalizeOrderType(requested);
    final availability = _resolveOrderTypeAvailability(
      restaurant,
      kioskSettings,
    );

    if (requestedType != null) {
      if (requestedType == "pickup" && availability["pickup"] == true) {
        return "pickup";
      }
      if (requestedType == "dine_in" && availability["dine_in"] == true) {
        return "dine_in";
      }
      if (requestedType == "take_away" && availability["pickup"] == true) {
        return "pickup";
      }
    }

    if (availability["dine_in"] == true) return "dine_in";
    if (availability["pickup"] == true) return "pickup";
    return "dine_in";
  }

  Map<String, bool> _resolveOrderTypeAvailability(
    Map<String, dynamic>? restaurant,
    Map<String, dynamic>? kioskSettings,
  ) =>
      KioskRestaurantMeta.resolveOrderTypeAvailability(
        restaurant: restaurant,
        kioskSettings: kioskSettings,
      );

  String? _extractTaxId(
    Map<String, dynamic>? restaurant,
    Map<String, dynamic>? kioskSettings,
  ) {
    final sources = [kioskSettings, restaurant];
    for (final src in sources) {
      if (src == null) continue;
      final v = src["gst_number"] ??
          src["gstin"] ??
          src["tax_id"] ??
          src["taxId"] ??
          src["gst_no"] ??
          src["gst"];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString().trim();
      }
    }
    return null;
  }

  String? _normalizeOrderType(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value
        .trim()
        .toLowerCase()
        .replaceAll("-", "_")
        .replaceAll(RegExp(r"\s+"), "_");
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFF1EE),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.error_outline_rounded,
                      size: 38,
                      color: Color(0xFF9F342C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Unable to open restaurant menu",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F8F9),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE3E6EA)),
                    ),
                    child: Text(
                      _errorMessage ??
                          "This restaurant menu could not be opened.",
                      style: const TextStyle(
                        color: Colors.black87,
                        height: 1.45,
                      ),
                      textAlign: TextAlign.left,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _bootstrapFromQr,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9F342C),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("Retry"),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => const UserIdScreen(),
                        ),
                      );
                    },
                    child: const Text("Open manual restaurant entry"),
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
