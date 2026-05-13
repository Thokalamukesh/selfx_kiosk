import 'dart:async';

import 'package:api_selfxo_project/background_image/background_image.dart';

import 'package:api_selfxo_project/screens/payment_success.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/kiosk_api.dart';
import '../core/device_info.dart';
import '../core/idle_timer.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';

class PaymentScreen extends StatefulWidget {
  final int totalAmount;
  final List<Map<String, dynamic>> cart;
  final String orderType;

  const PaymentScreen({
    super.key,
    required this.totalAmount,
    required this.cart,
    required this.orderType,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with WidgetsBindingObserver {
  static const Color kPrimaryOrange = Color(0xFFFF5722);
  static const Color kBgGrey = Color(0xFFF1F3F6);
  static const int _paymentTimeoutSeconds = 300;

  int _remainingSeconds = _paymentTimeoutSeconds;
  Timer? countdownTimer;
  static const int _failAutoCloseSeconds = 3;
  int _failSeconds = _failAutoCloseSeconds;
  double _failProgress = 1.0;
  double _failProgressTarget = 1.0;

  bool loading = true;
  bool _started = false;
  String? errorMessage;
  bool _active = true;

  int? orderId;
  String? qrData;
  double? payableAmount;

  String displayRestaurantName = "OUR KITCHEN";

  Timer? paymentTimer;
  Timer? timeoutTimer;
  Timer? _paymentFailTimer;

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  @override
  void initState() {
    super.initState();
    IdleTimer.pause();
    KioskMemoryService.instance.pause();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      preloadRestaurantData();
      _startPaymentFlow();
      _startTimeout();
    });
  }

  // --- POPUP DIALOG LOGIC ---
  void _showCancelConfirmation(
    BuildContext context, {
    required bool isStartAgain,
  }) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isTablet ? 40 : 26),
          ),
          contentPadding: EdgeInsets.all(isTablet ? 40 : 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // --- THEMED ICON ---
              Container(
                padding: EdgeInsets.all(isTablet ? 30 : 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBAA30).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isStartAgain
                      ? Icons.refresh_rounded
                      : Icons.cancel_presentation_rounded,
                  color: const Color(0xFFFBAA30),
                  size: isTablet ? 100 : 60,
                ),
              ),
              SizedBox(height: isTablet ? 30 : 20),

              // --- TITLE ---
              Text(
                isStartAgain ? "RESTART ORDER?" : "CANCEL PAYMENT?",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isTablet ? 32 : 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 15),

              // --- CONTENT TEXT ---
              Text(
                isStartAgain
                    ? "Are you sure you want to go back to the start?\nYour current progress will be lost."
                    : "Are you sure you want to cancel this payment\nand go back to the beginning?",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isTablet ? 20 : 15.5,
                  color: Colors.black54,
                  height: 1.5,
                ),
              ),
              SizedBox(height: isTablet ? 45 : 30),

              // --- BUTTON ROW ---
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: isTablet ? 85 : 55,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: Colors.grey.shade300,
                            width: 2,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              isTablet ? 20 : 12,
                            ),
                          ),
                        ),
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(
                          "NO, STAY",
                          style: TextStyle(
                            fontSize: isTablet ? 18 : 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: isTablet ? 20 : 12),
                  Expanded(
                    child: SizedBox(
                      height: isTablet ? 85 : 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFBAA30),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              isTablet ? 20 : 12,
                            ),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const WelcomeScreen(),
                            ),
                            (route) => false,
                          );
                        },
                        child: Text(
                          "YES, CANCEL",
                          style: TextStyle(
                            fontSize: isTablet ? 18 : 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // 🔥 FETCH SAVED NAME
  Future<void> preloadRestaurantData() async {
    try {
      final res = await KioskApi().getRestaurantData();
      final restaurant = res.data["data"]?["restaurant"];
      final name = restaurant?["name"] ?? "OUR KITCHEN";

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("restaurant_name", name);

      if (mounted) {
        setState(() {
          displayRestaurantName = name.toUpperCase();
        });
      }
    } catch (e) {
      debugPrint("Failed to preload restaurant data: $e");
    }
  }

  Future<void> _startPaymentFlow() async {
    if (_started) return;
    _startCountdown();
    _started = true;

    try {
      final orderItems = widget.cart.map((item) {
        final basePrice = _asInt(item["price"]);
        final variation = item["variation"];
        final modifiers = (item["modifiers"] as List? ?? []);
        final finalUnitPrice = basePrice +
            _asInt(variation?["price"]) +
            modifiers.fold<int>(
              0,
              (sum, m) => sum + _asInt(m["price"]),
            );

        return {
          "id": item["id"],
          "item_name": item["name"],
          "quantity": _asInt(item["qty"]),
          "price": finalUnitPrice,
          "itemPrice": finalUnitPrice,
          "item_photo_url": item["image"],
          "variation_id": variation?["id"],
          "variation_name": variation?["variation"],
          "has_modifiers": modifiers.isNotEmpty,
          "modifiers": modifiers
              .map(
                (m) => {"id": m["id"], "name": m["name"], "price": m["price"]},
              )
              .toList(),
        };
      }).toList();

      final createRes = await KioskApi().createOrder(
        orderType: widget.orderType,
        orderItems: orderItems,
      );

      orderId = createRes.data["order"]?["id"];

      final prefs = await SharedPreferences.getInstance();
      final restaurantId = prefs.getString("restaurant_id");
      await DeviceInfoUtil.getDeviceId(restaurantId: restaurantId!);

      final qrRes = await KioskApi().generateQr(orderId: orderId!);

      qrData = _extractQrString(qrRes.data);
      if (qrData != null) {
        final uri = Uri.tryParse(qrData!);
        final pn = uri?.queryParameters["pn"];
        if (pn != null && mounted) displayRestaurantName = pn.toUpperCase();
      }

      final amountPaise = _extractAmountPaise(qrRes.data);
      payableAmount = amountPaise != null
          ? amountPaise / 100
          : widget.totalAmount.toDouble();

      if (mounted) setState(() => loading = false);
      _startPaymentPolling();
    } catch (e) {
      _handleError(e.toString());
    }
  }

  String? _extractQrString(dynamic payload) {
    String? asString(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    dynamic readKey(Map map, List<String> keys) {
      for (final key in keys) {
        if (map.containsKey(key)) return map[key];
      }
      final wanted = keys.map((e) => e.toLowerCase()).toSet();
      for (final entry in map.entries) {
        final k = entry.key.toString().toLowerCase();
        if (wanted.contains(k)) return entry.value;
      }
      return null;
    }

    String? findIn(dynamic data, int depth) {
      if (data == null || depth <= 0) return null;
      if (data is String) return asString(data);
      if (data is Map) {
        final direct = readKey(data, const [
          "qrCode",
          "qr_code",
          "qr",
          "qrData",
          "qr_data",
          "upi_qr",
          "upiQr",
          "upi_string",
          "upiString",
          "payload",
        ]);
        final directStr = asString(direct);
        if (directStr != null) return directStr;

        for (final key in const [
          "data",
          "result",
          "response",
          "payload",
          "order",
          "qr_info",
        ]) {
          if (data.containsKey(key)) {
            final nested = findIn(data[key], depth - 1);
            if (nested != null) return nested;
          }
        }
      }
      return null;
    }

    return findIn(payload, 4);
  }

  num? _extractAmountPaise(dynamic payload) {
    num? asNum(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      return num.tryParse(v.toString());
    }

    num? findIn(dynamic data, int depth) {
      if (data == null || depth <= 0) return null;
      if (data is Map) {
        if (data.containsKey("amount")) {
          final val = asNum(data["amount"]);
          if (val != null) return val;
        }
        for (final key in const [
          "data",
          "result",
          "response",
          "payload",
          "order",
        ]) {
          if (data.containsKey(key)) {
            final nested = findIn(data[key], depth - 1);
            if (nested != null) return nested;
          }
        }
      }
      return null;
    }

    return findIn(payload, 4);
  }

  bool _looksLikeImageUrl(String value) {
    final v = value.toLowerCase();
    if (!(v.startsWith("http://") || v.startsWith("https://"))) return false;
    return v.contains(".png") ||
        v.contains(".jpg") ||
        v.contains(".jpeg") ||
        v.contains(".webp");
  }

  void _startPaymentPolling() {
    paymentTimer?.cancel();
    paymentTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_active || !mounted) return;
      if (orderId == null) return;

      try {
        final res = await KioskApi().checkPayment(orderId!);

        if (res.data["status"] == "paid") {
          paymentTimer?.cancel();

          await _handlePaymentSuccess();
        }
      } catch (_) {}
    });
  }

  bool _receiptPrinted = false;

  Future<void> _handlePaymentSuccess() async {
    if (_receiptPrinted) return;
    _receiptPrinted = true;
    countdownTimer?.cancel();
    timeoutTimer?.cancel();
    _paymentFailTimer?.cancel();

    // 🎉 Always continue
    if (!_active || !mounted) return;
    _showSuccess();
  }

  void _handleError(String msg) {
    paymentTimer?.cancel();
    countdownTimer?.cancel();
    _paymentFailTimer?.cancel();
    if (_active && mounted) {
      setState(() {
        loading = false;
        errorMessage = msg;
      });
    }
    _startFailAutoClose();
  }

  void _startCountdown() {
    countdownTimer?.cancel();
    countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_active || !mounted) return;
      if (_remainingSeconds <= 0) {
        timer.cancel();
        if (errorMessage == null) {
          _handleError("Payment timed out");
        }
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  void _startTimeout() {
    timeoutTimer?.cancel();
    timeoutTimer = Timer(
      Duration(seconds: _remainingSeconds),
      () {
        if (!_active || !mounted) return;
        _handleError("Payment timed out");
      },
    );
  }

  void _showSuccess() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => _ScanToPrintScreen(
          cart: widget.cart,
          orderNumber: orderId!,
          restaurantName: displayRestaurantName,
          orderType: widget.orderType,
        ),
      ),
    );
  }

  void _startFailAutoClose() {
    _paymentFailTimer?.cancel();
    _failSeconds = _failAutoCloseSeconds;
    _failProgress = 1.0;
    _failProgressTarget = 1.0;
    _paymentFailTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_active || !mounted) {
        timer.cancel();
        return;
      }
      if (_failSeconds <= 1) {
        timer.cancel();
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (route) => false,
        );
      } else {
        try {
          setState(() {
            _failSeconds--;
            _failProgressTarget = _failSeconds / _failAutoCloseSeconds;
          });
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    paymentTimer?.cancel();
    timeoutTimer?.cancel();
    countdownTimer?.cancel();
    _paymentFailTimer?.cancel();
    IdleTimer.resume();
    KioskMemoryService.instance.resume();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          _showCancelConfirmation(context, isStartAgain: false);
        }
      },
      child: Scaffold(
        backgroundColor: kBgGrey,
        appBar: _buildAppBar(),
        body: Stack(
          children: [
            loading
                ? const Center(
                    child: CircularProgressIndicator(color: kPrimaryOrange),
                  )
                : Column(
                    children: [
                      _buildTimerHeader(),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _buildPaymentCard(),
                        ),
                      ),
                      _buildBottomAction(),
                    ],
                  ),
            if (errorMessage != null) _buildErrorOverlay(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    return AppBar(
      toolbarHeight: isTablet ? 100 : 80,
      backgroundColor: const Color(0xFF9F342C),
      elevation: 0,
      leadingWidth: 140, // enough space for logo
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Image.asset(
            "assets/self.png",
            height: 36,
            fit: BoxFit.contain,
          ),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16, top: 10, bottom: 10),
          child: OutlinedButton(
            onPressed: () =>
                _showCancelConfirmation(context, isStartAgain: true),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.home_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text(
                  "Start Again",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimerHeader() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ⏱ ICON + SECONDS (SAME ROW, CENTERED)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.orange, width: 3),
                ),
                child: const Icon(
                  Icons.access_time_filled,
                  color: Colors.orange,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                  children: [
                    TextSpan(
                      text: "$_remainingSeconds ",
                      style: const TextStyle(color: Colors.orange),
                    ),
                    const TextSpan(
                      text: "Seconds",
                      style: TextStyle(color: Colors.black),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // 🧾 SUBTEXT
          const Text(
            "remaining to complete Payment",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.black87,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentCard() {
    final bool isTablet = _isTabletDevice(context);
    final String qrValue = qrData?.trim() ?? "";
    final String fallbackQrValue =
        "upi://pay?pa=test@upi&pn=Shop&am=${(payableAmount ?? widget.totalAmount.toDouble()).toStringAsFixed(0)}";
    final String effectiveQrValue =
        qrValue.isNotEmpty ? qrValue : fallbackQrValue;
    final String amountLabel =
        "₹${(payableAmount ?? widget.totalAmount.toDouble()).toStringAsFixed(2)}";

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isTablet ? 500 : 420,
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(isTablet ? 24 : 12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            children: [
              SizedBox(height: isTablet ? 40 : 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  displayRestaurantName,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isTablet ? 26 : 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: Colors.black,
                  ),
                ),
              ),
              SizedBox(height: isTablet ? 20 : 12),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: isTablet ? 24 : 18),
                child: isTablet
                    ? TabletPaymentView(
                        amountLabel: amountLabel,
                        qrValue: effectiveQrValue,
                        isImageUrl: _looksLikeImageUrl(effectiveQrValue),
                        qrCornerBuilder: ({
                          double? top,
                          double? bottom,
                          double? left,
                          double? right,
                          required bool isTop,
                          required bool isLeft,
                        }) =>
                            _qrCorner(
                          top: top,
                          bottom: bottom,
                          left: left,
                          right: right,
                          isTop: isTop,
                          isLeft: isLeft,
                          isTablet: true,
                        ),
                      )
                    : MobilePaymentView(
                        amountLabel: amountLabel,
                        onPayNow: _handleMobilePayNow,
                      ),
              ),
              SizedBox(height: isTablet ? 40 : 24),
            ],
          ),
        ),
      ),
    );
  }

  bool _isTabletDevice(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.width >= 600 || size.shortestSide >= 600;
  }

  Future<void> _handleMobilePayNow() async {
    final double amount = payableAmount ?? widget.totalAmount.toDouble();
    final String fallbackUpi =
        "upi://pay?pa=test@upi&pn=${Uri.encodeComponent(displayRestaurantName)}&am=${amount.toStringAsFixed(2)}";
    final String upiValue = (qrData?.trim().startsWith("upi://pay") ?? false)
        ? qrData!.trim()
        : fallbackUpi;
    final Uri genericUpiUri = Uri.parse(upiValue);
    final Uri phonePeUri = Uri.parse(
      upiValue.replaceFirst("upi://pay", "phonepe://pay"),
    );

    if (await canLaunchUrl(genericUpiUri)) {
      debugPrint("Proceed to payment");
      await launchUrl(genericUpiUri, mode: LaunchMode.externalApplication);
      return;
    }

    if (await canLaunchUrl(phonePeUri)) {
      debugPrint("Proceed to payment");
      await launchUrl(phonePeUri, mode: LaunchMode.externalApplication);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("No supported UPI app found on this device"),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // 🎯 Updated _qrCorner to handle thickness on tablet
  Widget _qrCorner({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required bool isTop,
    required bool isLeft,
    required bool isTablet,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: Container(
        width: isTablet ? 50 : 35,
        height: isTablet ? 50 : 35,
        decoration: BoxDecoration(
          border: Border(
            top: isTop
                ? BorderSide(color: kPrimaryOrange, width: isTablet ? 6 : 4)
                : BorderSide.none,
            bottom: !isTop
                ? BorderSide(color: kPrimaryOrange, width: isTablet ? 6 : 4)
                : BorderSide.none,
            left: isLeft
                ? BorderSide(color: kPrimaryOrange, width: isTablet ? 6 : 4)
                : BorderSide.none,
            right: !isLeft
                ? BorderSide(color: kPrimaryOrange, width: isTablet ? 6 : 4)
                : BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction() {
    final mediaQuery = MediaQuery.of(context);
    final bool isTablet = mediaQuery.size.width > 600;
    final double bottomPadding = mediaQuery.padding.bottom;

    return Container(
      width: double.infinity,
      // Add extra padding for tablet to prevent the button from looking stretched
      padding: EdgeInsets.fromLTRB(
        isTablet ? 80 : 16,
        16,
        isTablet ? 80 : 16,
        bottomPadding > 0 ? bottomPadding : 16,
      ),
      color: Colors.white,
      child: Center(
        // Center helps keep the button size reasonable on large tablets
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // Limits the width on tablet so it doesn't span 1000px+
            maxWidth: isTablet ? 400 : double.infinity,
          ),
          child: SizedBox(
            width: double.infinity,
            // Taller button for easier tapping on tablet
            height: isTablet ? 70 : 56,
            child: ElevatedButton.icon(
              onPressed: () =>
                  _showCancelConfirmation(context, isStartAgain: false),
              icon: Icon(
                Icons.close,
                color: Colors.red,
                size: isTablet ? 28 : 20,
              ),
              label: Text(
                "Cancel Order",
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: isTablet ? 20 : 16,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFEBEE),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(isTablet ? 16 : 12),
                  side: const BorderSide(color: Colors.red, width: 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final bool isTimeout = (errorMessage ?? "").toLowerCase().contains(
          "timed out",
        );
    return Positioned.fill(
      child: Material(
        color: Colors.black.withOpacity(0.25),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isTablet ? 520 : double.infinity,
            ),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: EdgeInsets.symmetric(
                horizontal: isTablet ? 40 : 24,
                vertical: isTablet ? 36 : 26,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(isTablet ? 26 : 18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(isTablet ? 20 : 16),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      color: Colors.red,
                      size: isTablet ? 70 : 54,
                    ),
                  ),
                  SizedBox(height: isTablet ? 24 : 18),
                  Text(
                    isTimeout ? "Order Timed Out" : "Payment Failed",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isTablet ? 28 : 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    errorMessage ??
                        "Your payment has been failed. Please try again.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isTablet ? 18 : 14,
                      color: Colors.black54,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: isTablet ? 18 : 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: _failProgress,
                        end: _failProgressTarget,
                      ),
                      duration: const Duration(milliseconds: 450),
                      onEnd: () {
                        if (!mounted) return;
                        if (_failProgress != _failProgressTarget) {
                          setState(() => _failProgress = _failProgressTarget);
                        }
                      },
                      builder: (_, value, __) {
                        return Directionality(
                          textDirection: TextDirection.rtl,
                          child: LinearProgressIndicator(
                            value: value.clamp(0, 1),
                            minHeight: isTablet ? 10 : 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.redAccent,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Returning to Welcome in ${_failSeconds}s",
                    style: TextStyle(
                      fontSize: isTablet ? 16 : 13,
                      color: Colors.black54,
                      fontWeight: FontWeight.w600,
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

class TabletPaymentView extends StatelessWidget {
  final String amountLabel;
  final String qrValue;
  final bool isImageUrl;
  final Widget Function({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required bool isTop,
    required bool isLeft,
  }) qrCornerBuilder;

  const TabletPaymentView({
    super.key,
    required this.amountLabel,
    required this.qrValue,
    required this.isImageUrl,
    required this.qrCornerBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          amountLabel,
          style: const TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w900,
            color: Colors.orange,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          "Scan to Pay",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isImageUrl)
                Image.network(
                  qrValue,
                  width: 320,
                  height: 320,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _buildQrFallback(),
                )
              else
                QrImageView(
                  data: qrValue,
                  size: 320,
                  padding: const EdgeInsets.all(16),
                  errorStateBuilder: (_, __) => _buildQrFallback(),
                ),
              qrCornerBuilder(top: 0, left: 0, isTop: true, isLeft: true),
              qrCornerBuilder(top: 0, right: 0, isTop: true, isLeft: false),
              qrCornerBuilder(
                bottom: 0,
                left: 0,
                isTop: false,
                isLeft: true,
              ),
              qrCornerBuilder(
                bottom: 0,
                right: 0,
                isTop: false,
                isLeft: false,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQrFallback() {
    return Container(
      width: 320,
      height: 320,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const Text(
        "Invalid QR data",
        style: TextStyle(
          color: Colors.redAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class MobilePaymentView extends StatelessWidget {
  final String amountLabel;
  final VoidCallback onPayNow;

  const MobilePaymentView({
    super.key,
    required this.amountLabel,
    required this.onPayNow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              const Text(
                "Total Bill",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                amountLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  color: Colors.orange,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: onPayNow,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9F342C),
              foregroundColor: Colors.white,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text(
              "Pay Now",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScanToPrintScreen extends StatefulWidget {
  final List<Map<String, dynamic>> cart;
  final int orderNumber;
  final String? restaurantName;
  final String? orderType;

  const _ScanToPrintScreen({
    required this.cart,
    required this.orderNumber,
    this.restaurantName,
    this.orderType,
  });

  @override
  State<_ScanToPrintScreen> createState() => _ScanToPrintScreenState();
}

class _ScanToPrintScreenState extends State<_ScanToPrintScreen> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'scan-print-keyboard');
  final FocusNode _scanInputFocusNode =
      FocusNode(debugLabel: 'scan-print-input');
  final TextEditingController _scanController = TextEditingController();
  final StringBuffer _scanBuffer = StringBuffer();
  Timer? _scanIdleTimer;
  Timer? _focusKeepAliveTimer;
  bool _openingPrint = false;
  String? _lastScan;
  String _scanStatusText = "Scanner is ready.";
  final List<String> _scanDebugLines = [];

  String get _scanCode => widget.orderNumber.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScannerInput();
      _addScanDebug('ready expected="$_scanCode"');
      _focusKeepAliveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_openingPrint && mounted) {
          _focusScannerInput();
        }
      });
    });
  }

  @override
  void dispose() {
    _scanIdleTimer?.cancel();
    _focusKeepAliveTimer?.cancel();
    _scanController.dispose();
    _scanInputFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _focusScannerInput() {
    if (_scanInputFocusNode.canRequestFocus) {
      _scanInputFocusNode.requestFocus();
      _addScanDebug('scanner input focused');
      return;
    }
    if (_focusNode.canRequestFocus) {
      _focusNode.requestFocus();
      _addScanDebug('keyboard focus requested');
    }
  }

  void _addScanDebug(String message) {
    final line =
        '${DateTime.now().toIso8601String().substring(11, 19)} $message';
    debugPrint('[scan-to-print] $message');
    if (!mounted) return;
    setState(() {
      _scanDebugLines.insert(0, line);
      if (_scanDebugLines.length > 8) {
        _scanDebugLines.removeLast();
      }
    });
  }

  void _showScanSnack(String message, {Duration? duration}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: duration ?? const Duration(seconds: 2),
        ),
      );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _openingPrint) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final captured = _scanBuffer.toString();
      _scanBuffer.clear();
      _addScanDebug('keyboard enter="$captured"');
      if (captured.trim().isNotEmpty) {
        _consumeScan(captured, source: 'keyboard-enter');
      }
      return KeyEventResult.handled;
    }

    final character =
        event.character ?? _characterFromLogicalKey(event.logicalKey);
    if (character != null &&
        character.isNotEmpty &&
        !_isControlCharacter(character)) {
      _scanBuffer.write(character);
      _scanIdleTimer?.cancel();
      _scanIdleTimer = Timer(const Duration(milliseconds: 350), () {
        final captured = _scanBuffer.toString();
        _scanBuffer.clear();
        _addScanDebug('keyboard idle="$captured"');
        if (captured.trim().isNotEmpty) {
          _consumeScan(captured, source: 'keyboard-idle');
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  String? _characterFromLogicalKey(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) return label;
    return null;
  }

  bool _isControlCharacter(String value) {
    final code = value.codeUnitAt(0);
    return code < 32 || code == 127;
  }

  void _handleScannerTextChanged(String value) {
    if (_openingPrint) return;
    final visibleValue = value.trim();
    if (visibleValue.isNotEmpty) {
      setState(() {
        _lastScan = visibleValue;
        _scanStatusText = 'Scanner typing "$visibleValue"';
      });
    }
    _scanIdleTimer?.cancel();
    _scanIdleTimer = Timer(const Duration(milliseconds: 550), () {
      final captured = _scanController.text;
      _scanController.clear();
      _addScanDebug('input idle="$captured"');
      _consumeScan(captured, source: 'input-idle');
    });
  }

  void _handleScannerSubmitted(String value) {
    if (_openingPrint) return;
    _scanIdleTimer?.cancel();
    _scanController.clear();
    _addScanDebug('input submit="$value"');
    _consumeScan(value, source: 'input-submit');
  }

  void _consumeScan(String raw, {required String source}) {
    final value = raw.trim();
    _addScanDebug('$source raw="$raw" value="$value" expected="$_scanCode"');
    if (value.isEmpty) {
      _showScanSnack('Scanner read empty value. Scan again.');
      _focusScannerInput();
      return;
    }

    setState(() {
      _lastScan = value;
      _scanStatusText = 'Scanner read "$value"';
    });

    if (_matchesExpectedCode(value)) {
      _addScanDebug('MATCH value="$value" order="$_scanCode"');
      setState(() {
        _scanStatusText = 'Scanner matched "$value". Opening print...';
      });
      _showScanSnack(
        'Scanner read "$value". Match found. Opening print...',
        duration: const Duration(milliseconds: 1200),
      );
      _openPrintScreen();
      return;
    }

    _addScanDebug('MISMATCH value="$value" order="$_scanCode"');
    setState(() {
      _scanStatusText = 'Scanner read "$value". Expected $_scanCode.';
    });
    _showScanSnack(
      'Scanner read "$value". Expected order $_scanCode.',
      duration: const Duration(seconds: 3),
    );
    _focusScannerInput();
  }

  bool _matchesExpectedCode(String value) {
    final normalized = value.trim().toLowerCase();
    final expected = _scanCode.toLowerCase();
    if (normalized == expected) return true;

    if (_digitCandidatesForMatching(normalized).contains(_scanCode)) {
      return true;
    }

    final accepted = <String>{
      'order:$expected',
      'order-$expected',
      'order_$expected',
      'selfx-$expected',
      'selfx${widget.orderNumber}',
      'selfx-order-$expected',
    };
    return accepted.contains(normalized);
  }

  Set<String> _digitCandidatesForMatching(String value) {
    return {
      value.replaceAll(RegExp(r'[^0-9]'), ''),
      value
          .replaceAll(RegExp(r'[qQoO]'), '0')
          .replaceAll(RegExp(r'[^0-9]'), ''),
    }..removeWhere((v) => v.isEmpty);
  }

  Future<void> _openPrintScreen() async {
    if (_openingPrint || !mounted) return;
    setState(() {
      _openingPrint = true;
      _scanStatusText = "Scanner matched. Opening print screen...";
    });

    _showScanSnack(
      'Scanner matched. Opening print screen...',
      duration: const Duration(milliseconds: 1200),
    );

    _addScanDebug('opening PaymentSuccessDialog');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentSuccessDialog(
          cart: widget.cart,
          orderNumber: widget.orderNumber,
          language: "en",
          restaurantName: widget.restaurantName,
          orderType: widget.orderType,
          debugSource: [
            'scan screen order=${widget.orderNumber}',
            'last scan=${_lastScan ?? ""}',
            ..._scanDebugLines,
          ].join('\n'),
        ),
      ),
    );
  }

  Widget _scanDebugPanel() {
    if (_scanDebugLines.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF101828),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _scanDebugLines.join('\n'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          height: 1.35,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = media.size.width < 720;
    final qrSize = compact ? 190.0 : 260.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F6),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _focusScannerInput,
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Container(
                        padding: EdgeInsets.all(compact ? 22 : 34),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 24,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              "Payment successful",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 28 : 36,
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF1D1D1D),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              "Scan this order QR or barcode to print the receipt.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 14 : 18,
                                height: 1.4,
                                color: Colors.black54,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              "Order #${widget.orderNumber}",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 18 : 24,
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF22643B),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _openingPrint
                                  ? "Scanner matched. Opening print..."
                                  : _scanStatusText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 14 : 17,
                                color: _openingPrint
                                    ? const Color(0xFF22643B)
                                    : Colors.black54,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _scanDebugPanel(),
                            const SizedBox(height: 24),
                            Center(
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFBF7),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color(0xFFEADCCD),
                                  ),
                                ),
                                child: QrImageView(
                                  data: _scanCode,
                                  size: qrSize,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Container(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 22, 20, 18),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFBF7),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: const Color(0xFFEADCCD),
                                ),
                              ),
                              child: Column(
                                children: [
                                  BarcodeWidget(
                                    barcode: Barcode.code128(),
                                    data: _scanCode,
                                    width: double.infinity,
                                    height: compact ? 76 : 96,
                                    drawText: false,
                                    color: const Color(0xFF1D1D1D),
                                    backgroundColor: Colors.white,
                                  ),
                                  const SizedBox(height: 12),
                                  SelectableText(
                                    _scanCode,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: compact ? 20 : 28,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 4,
                                      color: const Color(0xFF1D1D1D),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              _openingPrint
                                  ? "Scanner matched. Opening print..."
                                  : _scanStatusText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 14 : 17,
                                color: _openingPrint
                                    ? const Color(0xFF22643B)
                                    : Colors.black54,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _scanController,
                              focusNode: _scanInputFocusNode,
                              autofocus: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: TextInputType.text,
                              textInputAction: TextInputAction.done,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                              onChanged: _handleScannerTextChanged,
                              onSubmitted: _handleScannerSubmitted,
                              decoration: InputDecoration(
                                hintText: "Scanner input",
                                filled: true,
                                fillColor: const Color(0xFFF7FAFC),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFD8E0E8),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFD8E0E8),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF22643B),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                            if (_lastScan != null &&
                                _lastScan!.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                "Last scan: $_lastScan",
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.black45,
                                ),
                              ),
                            ],
                          ],
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
}
