import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/device_info.dart';
import 'package:api_selfxo_project/core/idle_timer.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/screens/payment_success.dart';
import 'package:api_selfxo_project/screens/register_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/kiosk_api.dart';

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

class _PaymentScreenState extends State<PaymentScreen> {
  static const Color _brand = Color(0xFF9F342C);
  static const Color _canvas = Color(0xFFF6F1EA);
  static const int _failAutoCloseSeconds = 3;
  static const int _paymentTimeoutSeconds = 300;

  int _remainingSeconds = _paymentTimeoutSeconds;
  int _failSeconds = _failAutoCloseSeconds;
  double _failProgress = 1.0;
  double _failProgressTarget = 1.0;

  Timer? _countdownTimer;
  Timer? _paymentTimer;
  Timer? _timeoutTimer;
  Timer? _paymentFailTimer;

  bool _loading = true;
  bool _started = false;
  bool _active = true;
  bool _receiptPrinted = false;
  bool _openedSuccessScreen = false;
  bool _waitingForPaymentCompletion = false;
  String _selectedPaymentLabel = "UPI";

  String? _errorMessage;
  int? _orderId;
  String? _qrData;
  double? _payableAmount;
  String _displayRestaurantName = "OUR KITCHEN";

  @override
  void initState() {
    super.initState();
    IdleTimer.pause();
    KioskMemoryService.instance.pause();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadRestaurantData();
      _startPaymentFlow();
      _startTimeout();
    });
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  Future<void> _preloadRestaurantData() async {
    try {
      final res = await KioskApi().getRestaurantData();
      final restaurant = res.data["data"]?["restaurant"];
      final name = restaurant?["name"] ?? "OUR KITCHEN";

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("restaurant_name", name);

      if (!mounted) return;
      setState(() {
        _displayRestaurantName = name.toUpperCase();
      });
    } catch (_) {}
  }

  Future<void> _startPaymentFlow() async {
    if (_started) return;
    _started = true;
    _startCountdown();

    try {
      final orderItems = widget.cart.map((item) {
        final basePrice = _asInt(item["price"]);
        final variation = item["variation"];
        final modifiers = (item["modifiers"] as List? ?? []);
        final finalUnitPrice = basePrice +
            _asInt(variation?["price"]) +
            modifiers.fold<int>(0, (sum, m) => sum + _asInt(m["price"]));

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
              .map((m) =>
                  {"id": m["id"], "name": m["name"], "price": m["price"]})
              .toList(),
        };
      }).toList();

      final createRes = await KioskApi().createOrder(
        orderType: widget.orderType,
        orderItems: orderItems,
      );

      _orderId = createRes.data["order"]?["id"];

      final prefs = await SharedPreferences.getInstance();
      final restaurantId = prefs.getString("restaurant_id");
      if (restaurantId != null && restaurantId.trim().isNotEmpty) {
        await DeviceInfoUtil.getDeviceId(restaurantId: restaurantId);
      }

      final qrRes = await KioskApi().generateQr(orderId: _orderId!);

      _qrData = _extractQrString(qrRes.data);
      if (_qrData != null) {
        final uri = Uri.tryParse(_qrData!);
        final pn = uri?.queryParameters["pn"];
        if (pn != null && pn.trim().isNotEmpty) {
          _displayRestaurantName = pn.toUpperCase();
        }
      }

      final amountPaise = _extractAmountPaise(qrRes.data);
      _payableAmount = amountPaise != null
          ? amountPaise / 100
          : widget.totalAmount.toDouble();

      if (!mounted) return;
      setState(() {
        _loading = false;
        _waitingForPaymentCompletion = false;
      });
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

  void _startPaymentPolling() {
    _paymentTimer?.cancel();
    _paymentTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_active || !mounted || _orderId == null) return;

      try {
        final res = await KioskApi().checkPayment(_orderId!);
        if (_isPaymentCompleted(res.data)) {
          _paymentTimer?.cancel();
          await _handlePaymentSuccess();
        }
      } catch (_) {}
    });
  }

  bool _isPaymentCompleted(dynamic data) {
    bool isPaidStatus(dynamic status) {
      if (status == true) return true;
      if (status is num) return status == 1;
      final s = status?.toString().trim().toLowerCase() ?? "";
      if (s.isEmpty) return false;
      if (s.contains("cancel") ||
          s.contains("refund") ||
          s.contains("failed") ||
          s.contains("void") ||
          s.contains("unpaid") ||
          s.contains("pending")) {
        return false;
      }
      return s.contains("paid") ||
          s.contains("completed") ||
          s.contains("success") ||
          s.contains("successful") ||
          s.contains("captured") ||
          s.contains("authorized");
    }

    bool findIn(dynamic value, int depth) {
      if (value == null || depth <= 0) return false;
      if (value is Map) {
        for (final key in const [
          "status",
          "payment_status",
          "paymentStatus",
          "order_status",
          "orderStatus",
          "state",
          "payment_state",
          "paymentState",
          "paid",
          "is_paid",
          "isPaid",
          "success",
          "is_success",
          "isSuccess",
          "result",
          "message",
        ]) {
          if (value.containsKey(key) && isPaidStatus(value[key])) {
            return true;
          }
        }
        for (final nestedKey in const [
          "data",
          "order",
          "payment",
          "response",
          "result",
          "payload",
        ]) {
          if (value.containsKey(nestedKey) &&
              findIn(value[nestedKey], depth - 1)) {
            return true;
          }
        }
        for (final entry in value.entries) {
          if (findIn(entry.value, depth - 1)) {
            return true;
          }
        }
      } else if (value is List) {
        for (final item in value) {
          if (findIn(item, depth - 1)) {
            return true;
          }
        }
      } else if (isPaidStatus(value)) {
        return true;
      }
      return false;
    }

    return findIn(data, 5);
  }

  Future<void> _handlePaymentSuccess() async {
    if (_receiptPrinted) return;
    _receiptPrinted = true;
    _countdownTimer?.cancel();
    _timeoutTimer?.cancel();
    _paymentFailTimer?.cancel();

    if (!_active || !mounted) return;
    setState(() {
      _waitingForPaymentCompletion = false;
    });
    _openedSuccessScreen = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => _WebScanToPrintScreen(
          cart: widget.cart,
          orderNumber: _orderId!,
          restaurantName: _displayRestaurantName,
          orderType: widget.orderType,
        ),
      ),
    );
  }

  void _handleError(String msg) {
    _paymentTimer?.cancel();
    _countdownTimer?.cancel();
    _paymentFailTimer?.cancel();
    if (!mounted || !_active || _receiptPrinted) return;
    setState(() {
      _loading = false;
      _errorMessage = msg;
      _waitingForPaymentCompletion = false;
    });
    _startFailAutoClose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_active || !mounted) return;
      if (_remainingSeconds <= 0) {
        timer.cancel();
        if (_errorMessage == null && !_receiptPrinted) {
          _handleError("Payment timed out");
        }
      } else {
        setState(() {
          _remainingSeconds--;
        });
      }
    });
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(seconds: _remainingSeconds), () {
      if (!_active || !mounted || _receiptPrinted) return;
      _handleError("Payment timed out");
    });
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
        setState(() {
          _failSeconds--;
          _failProgressTarget = _failSeconds / _failAutoCloseSeconds;
        });
      }
    });
  }

  Future<void> _handlePayNow([_WebUpiApp app = _WebUpiApp.generic]) async {
    final upiValue = _resolveUpiPaymentLink();
    if (upiValue == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Payment link is not ready yet. Please wait a moment and try again.",
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (mounted) {
      setState(() {
        _waitingForPaymentCompletion = true;
        _selectedPaymentLabel = app.label;
      });
    }

    final launched = _launchPreferredUpiTarget(upiValue, app);
    if (launched) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            app == _WebUpiApp.generic
                ? "Complete payment in your UPI app. After payment, scan to print will open automatically."
                : "Complete payment in ${app.label}. After payment, scan to print will open automatically.",
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _waitingForPaymentCompletion = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "Unable to open a UPI app on this device. Please try another UPI app.",
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String? _resolveUpiPaymentLink() {
    final raw = _qrData?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith("upi://pay")) {
      return raw;
    }
    return null;
  }

  bool _launchPreferredUpiTarget(String upiValue, _WebUpiApp app) {
    final targets = _preferredLaunchTargets(upiValue, app);
    for (final target in targets) {
      if (_launchUpiInBrowser(target)) {
        return true;
      }
    }
    return false;
  }

  bool _launchUpiInBrowser(String target) {
    try {
      final anchor = html.AnchorElement(href: target)
        ..target = "_self"
        ..style.display = "none";
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      return true;
    } catch (_) {
      return false;
    }
  }

  List<String> _preferredLaunchTargets(String upiValue, _WebUpiApp app) {
    final uri = Uri.parse(upiValue);
    final query = uri.hasQuery ? '?${uri.query}' : '';
    switch (app) {
      case _WebUpiApp.googlePay:
        return [
          'tez://upi/pay$query',
          'gpay://upi/pay$query',
          'intent://upi/pay$query#Intent;scheme=tez;package=com.google.android.apps.nbu.paisa.user;end',
        ];
      case _WebUpiApp.phonePe:
        return [
          'phonepe://pay$query',
          'intent://pay$query#Intent;scheme=phonepe;package=com.phonepe.app;end',
        ];
      case _WebUpiApp.paytm:
        return [
          'paytmmp://pay$query',
          'intent://pay$query#Intent;scheme=paytmmp;package=net.one97.paytm;end',
        ];
      case _WebUpiApp.generic:
        return [upiValue];
    }
  }

  void _showCancelConfirmation({required bool isStartAgain}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.16),
                  blurRadius: 30,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0EB),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Icon(
                    isStartAgain
                        ? Icons.refresh_rounded
                        : Icons.cancel_presentation_rounded,
                    color: _brand,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  isStartAgain ? "Start again?" : "Cancel payment?",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1D1D1D),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  isStartAgain
                      ? "Your current order progress will be cleared."
                      : "This payment session will be closed and the order will be cancelled.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14.5,
                    height: 1.5,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text("Stay"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                              builder: (_) => isStartAgain
                                  ? const UserIdScreen()
                                  : const WelcomeScreen(),
                            ),
                            (route) => false,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          backgroundColor: _brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          "Confirm",
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _active = false;
    _paymentTimer?.cancel();
    _timeoutTimer?.cancel();
    _countdownTimer?.cancel();
    _paymentFailTimer?.cancel();
    if (!_openedSuccessScreen) {
      IdleTimer.resume();
      KioskMemoryService.instance.resume();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amountLabel =
        "₹${(_payableAmount ?? widget.totalAmount.toDouble()).toStringAsFixed(2)}";

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          _showCancelConfirmation(isStartAgain: false);
        }
      },
      child: Scaffold(
        backgroundColor: _canvas,
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFFF8F2EA),
                      Color(0xFFF0E7DC),
                      Color(0xFFEDE6DE)
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),
            Positioned(
              top: -120,
              right: -60,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFD97C59).withOpacity(0.12),
                ),
              ),
            ),
            Positioned(
              top: 180,
              left: -90,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFB1493C).withOpacity(0.08),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              right: -50,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFC7B39E).withOpacity(0.18),
                ),
              ),
            ),
            SafeArea(
              child: _loading
                  ? _WebPaymentLoading(
                      onCancel: () =>
                          _showCancelConfirmation(isStartAgain: true),
                    )
                  : _WebPaymentLayout(
                      remainingSeconds: _remainingSeconds,
                      restaurantName: _displayRestaurantName,
                      amountLabel: amountLabel,
                      viewportHeight: MediaQuery.sizeOf(context).height,
                      paymentQrData: _qrData,
                      paymentHint: _waitingForPaymentCompletion
                          ? "Complete payment in $_selectedPaymentLabel. After payment, the scan-to-print screen will open automatically."
                          : "For testing, scan the QR below to pay, or choose any UPI app below.",
                      onGooglePay: () => _handlePayNow(_WebUpiApp.googlePay),
                      onPhonePe: () => _handlePayNow(_WebUpiApp.phonePe),
                      onPaytm: () => _handlePayNow(_WebUpiApp.paytm),
                      onOtherUpi: () => _handlePayNow(_WebUpiApp.generic),
                      onCancel: () =>
                          _showCancelConfirmation(isStartAgain: false),
                      onStartAgain: () =>
                          _showCancelConfirmation(isStartAgain: true),
                    ),
            ),
            if (_errorMessage != null)
              _WebPaymentErrorOverlay(
                message: _errorMessage!,
                seconds: _failSeconds,
                progress: _failProgress,
                targetProgress: _failProgressTarget,
                onProgressEnd: () {
                  if (!mounted) return;
                  if (_failProgress != _failProgressTarget) {
                    setState(() {
                      _failProgress = _failProgressTarget;
                    });
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _WebPaymentLoading extends StatelessWidget {
  final VoidCallback onCancel;

  const _WebPaymentLoading({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFFFFF), Color(0xFFFFF8F2)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: const Color(0xFFEBDFD3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 34,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Image.asset(
                      "assets/self.png",
                      height: 42,
                      fit: BoxFit.contain,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: onCancel,
                      child: const Text("Cancel"),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFB3483A), Color(0xFF8E2E25)],
                    ),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(22),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Preparing payment",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1D1D1D),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Creating your order and preparing your payment apps.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.5,
                    color: Colors.black54,
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

class _WebPaymentLayout extends StatelessWidget {
  final int remainingSeconds;
  final String restaurantName;
  final String amountLabel;
  final double viewportHeight;
  final String? paymentQrData;
  final String paymentHint;
  final VoidCallback onGooglePay;
  final VoidCallback onPhonePe;
  final VoidCallback onPaytm;
  final VoidCallback onOtherUpi;
  final VoidCallback onCancel;
  final VoidCallback onStartAgain;

  const _WebPaymentLayout({
    required this.remainingSeconds,
    required this.restaurantName,
    required this.amountLabel,
    required this.viewportHeight,
    required this.paymentQrData,
    required this.paymentHint,
    required this.onGooglePay,
    required this.onPhonePe,
    required this.onPaytm,
    required this.onOtherUpi,
    required this.onCancel,
    required this.onStartAgain,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenSize = media.size;
    final safeVertical = media.padding.top + media.padding.bottom;
    final shortScreen = screenSize.height < 820;
    final topPadding = shortScreen ? 14.0 : 20.0;
    final bottomPadding = shortScreen ? 18.0 : 24.0;
    final availableHeight =
        (screenSize.height - safeVertical - topPadding - bottomPadding)
            .clamp(420.0, screenSize.height);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            width: double.infinity,
            height: availableHeight,
            child: _WebPaymentMainCard(
              remainingSeconds: remainingSeconds,
              restaurantName: restaurantName,
              amountLabel: amountLabel,
              paymentQrData: paymentQrData,
              paymentHint: paymentHint,
              onGooglePay: onGooglePay,
              onPhonePe: onPhonePe,
              onPaytm: onPaytm,
              onOtherUpi: onOtherUpi,
              onCancel: onCancel,
              onStartAgain: onStartAgain,
            ),
          ),
        ),
      ),
    );
  }
}

class _WebPaymentMainCard extends StatelessWidget {
  final int remainingSeconds;
  final String restaurantName;
  final String amountLabel;
  final String? paymentQrData;
  final String paymentHint;
  final VoidCallback onGooglePay;
  final VoidCallback onPhonePe;
  final VoidCallback onPaytm;
  final VoidCallback onOtherUpi;
  final VoidCallback onCancel;
  final VoidCallback onStartAgain;

  const _WebPaymentMainCard({
    required this.remainingSeconds,
    required this.restaurantName,
    required this.amountLabel,
    required this.paymentQrData,
    required this.paymentHint,
    required this.onGooglePay,
    required this.onPhonePe,
    required this.onPaytm,
    required this.onOtherUpi,
    required this.onCancel,
    required this.onStartAgain,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final ultraShortCard = constraints.maxHeight < 620;
        final outerPadding = compact ? 16.0 : 22.0;
        final heroPadding = compact ? 18.0 : 24.0;
        final sectionPadding = compact ? 14.0 : 18.0;
        final heroActionHeight = compact ? 68.0 : 72.0;
        final footerActionHeight = compact ? 48.0 : 54.0;
        final amountSize = ultraShortCard ? 24.0 : (compact ? 30.0 : 36.0);
        final timerValueSize = ultraShortCard ? 22.0 : 28.0;

        return Padding(
          padding: EdgeInsets.all(outerPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.all(heroPadding),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFAA4337),
                      Color(0xFF862A22),
                      Color(0xFF6E211A),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Image.asset(
                          "assets/self.png",
                          height: compact ? 32 : 38,
                          fit: BoxFit.contain,
                        ),
                        const Spacer(),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 14 : 18,
                            vertical: compact ? 10 : 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                "Time left",
                                style: TextStyle(
                                  color: Color(0xFFFDEAE2),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "${remainingSeconds}s",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: timerValueSize,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: compact ? 16 : 18),
                    const SizedBox(height: 6),
                    Text(
                      restaurantName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFFFDE4DB),
                        fontSize: compact ? 12.5 : 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    SizedBox(height: compact ? 14 : 18),
                    SizedBox(
                      height: heroActionHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Flexible(
                            fit: FlexFit.tight,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 14 : 18,
                                vertical: compact ? 8 : 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.account_balance_wallet_rounded,
                                    color: Colors.white,
                                    size: compact ? 22 : 26,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          "Amount to pay",
                                          style: TextStyle(
                                            color: Color(0xFFFDEAE2),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            height: 1.1,
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        Expanded(
                                          child: Align(
                                            alignment: Alignment.bottomLeft,
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                amountLabel,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: amountSize,
                                                  fontWeight: FontWeight.w900,
                                                  height: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: onStartAgain,
                              icon: Icon(
                                Icons.refresh_rounded,
                                size: compact ? 16 : 18,
                              ),
                              label: Text(compact ? "Restart" : "Start Again"),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withOpacity(0.34),
                                ),
                                padding: EdgeInsets.symmetric(
                                  horizontal: compact ? 12 : 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: compact ? 14 : 18),
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(sectionPadding),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFF0E5D9)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        "Choose your payment app",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: compact ? 17 : 19,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF1D1D1D),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        paymentHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: compact ? 12.5 : 13.5,
                          height: 1.45,
                          color: Colors.black54,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: compact ? 14 : 16),
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          physics: const BouncingScrollPhysics(),
                          children: [
                            if (paymentQrData != null) ...[
                              _WebPaymentQrCard(
                                qrData: paymentQrData!,
                                amountLabel: amountLabel,
                                compact: compact,
                              ),
                              SizedBox(height: compact ? 12 : 14),
                            ],
                            _WebPayAppTile(
                              title: "Google Pay",
                              subtitle: "Open Google Pay",
                              assetPath: "assets/payment_icons/google_pay.svg",
                              accent: const Color(0xFFEAF2FF),
                              foreground: const Color(0xFF1A73E8),
                              compact: compact,
                              onTap: onGooglePay,
                            ),
                            SizedBox(height: compact ? 10 : 12),
                            _WebPayAppTile(
                              title: "PhonePe",
                              subtitle: "Open PhonePe",
                              assetPath: "assets/payment_icons/phonepe.svg",
                              accent: const Color(0xFFF4ECFF),
                              foreground: const Color(0xFF5F259F),
                              compact: compact,
                              onTap: onPhonePe,
                            ),
                            SizedBox(height: compact ? 10 : 12),
                            _WebPayAppTile(
                              title: "Paytm",
                              subtitle: "Open Paytm",
                              assetPath: "assets/payment_icons/paytm.svg",
                              accent: const Color(0xFFEAF8FF),
                              foreground: const Color(0xFF20336B),
                              compact: compact,
                              onTap: onPaytm,
                            ),
                            SizedBox(height: compact ? 10 : 12),
                            _WebPayAppTile(
                              title: "Open Any UPI",
                              subtitle: "Open any UPI app",
                              icon: Icons.account_balance_wallet_rounded,
                              accent: const Color(0xFFFFF0E5),
                              foreground: const Color(0xFFB55A21),
                              compact: compact,
                              onTap: onOtherUpi,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: compact ? 12 : 14),
                      SizedBox(
                        height: footerActionHeight,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Flexible(
                              fit: FlexFit.tight,
                              child: OutlinedButton(
                                onPressed: onOtherUpi,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF9F342C),
                                  side: const BorderSide(
                                    color: Color(0xFFD8C6B4),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: Text(
                                  "Open Any UPI",
                                  style: TextStyle(
                                    fontSize: compact ? 13.5 : 14.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              height: double.infinity,
                              child: TextButton(
                                onPressed: onCancel,
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF9F342C),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 8 : 12,
                                  ),
                                ),
                                child: Text(
                                  compact ? "Cancel" : "Cancel Order",
                                  style: TextStyle(
                                    fontSize: compact ? 13.5 : 14.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WebPaymentQrCard extends StatelessWidget {
  final String qrData;
  final String amountLabel;
  final bool compact;

  const _WebPaymentQrCard({
    required this.qrData,
    required this.amountLabel,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final qrSize = compact ? 170.0 : 196.0;

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFEADCCD)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF9F342C).withOpacity(0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              "TEST PAYMENT QR",
              style: TextStyle(
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: const Color(0xFF9F342C),
              ),
            ),
          ),
          SizedBox(height: compact ? 10 : 12),
          Text(
            "Scan this QR with any UPI app to pay $amountLabel.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 12.5 : 13.5,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF3B3028),
            ),
          ),
          SizedBox(height: compact ? 12 : 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: QrImageView(
              data: qrData,
              size: qrSize,
              backgroundColor: Colors.white,
            ),
          ),
          SizedBox(height: compact ? 10 : 12),
          Text(
            "After payment is completed, the order QR and barcode screen will open automatically for scanner printing.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 11.5 : 12.5,
              height: 1.45,
              color: Colors.black54,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _WebPayAppTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? assetPath;
  final IconData? icon;
  final Color accent;
  final Color foreground;
  final bool compact;
  final VoidCallback onTap;

  const _WebPayAppTile({
    required this.title,
    required this.subtitle,
    this.assetPath,
    this.icon,
    required this.accent,
    required this.foreground,
    this.compact = false,
    required this.onTap,
  }) : assert(assetPath != null || icon != null);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 10 : 14,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE8DDD2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.035),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: compact ? 40 : 48,
                height: compact ? 40 : 48,
                padding: EdgeInsets.all(compact ? 8 : 10),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: assetPath != null
                    ? SvgPicture.asset(
                        assetPath!,
                        colorFilter: ColorFilter.mode(
                          foreground,
                          BlendMode.srcIn,
                        ),
                      )
                    : Icon(icon, color: foreground, size: compact ? 22 : 28),
              ),
              SizedBox(width: compact ? 10 : 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 13.5 : 15.5,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1D1D1D),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 11.5 : 13,
                        color: Colors.black54,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: compact ? 6 : 8),
              Icon(
                Icons.arrow_forward_rounded,
                color: foreground,
                size: compact ? 16 : 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _WebUpiApp {
  googlePay("Google Pay"),
  phonePe("PhonePe"),
  paytm("Paytm"),
  generic("UPI");

  const _WebUpiApp(this.label);
  final String label;
}

class _WebPaymentErrorOverlay extends StatelessWidget {
  final String message;
  final int seconds;
  final double progress;
  final double targetProgress;
  final VoidCallback onProgressEnd;

  const _WebPaymentErrorOverlay({
    required this.message,
    required this.seconds,
    required this.progress,
    required this.targetProgress,
    required this.onProgressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final isTimeout = message.toLowerCase().contains("timed out");

    return Positioned.fill(
      child: Material(
        color: Colors.black.withOpacity(0.28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 28,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF0EB),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Color(0xFF9F342C),
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    isTimeout ? "Order Timed Out" : "Payment Failed",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1D1D1D),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14.5,
                      height: 1.5,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: TweenAnimationBuilder<double>(
                      tween:
                          Tween<double>(begin: progress, end: targetProgress),
                      duration: const Duration(milliseconds: 450),
                      onEnd: onProgressEnd,
                      builder: (_, value, __) {
                        return Directionality(
                          textDirection: TextDirection.rtl,
                          child: LinearProgressIndicator(
                            value: value.clamp(0, 1),
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF9F342C),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Returning in ${seconds}s",
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.black54,
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

class _WebScanToPrintScreen extends StatefulWidget {
  final List<Map<String, dynamic>> cart;
  final int orderNumber;
  final String? restaurantName;
  final String? orderType;

  const _WebScanToPrintScreen({
    required this.cart,
    required this.orderNumber,
    this.restaurantName,
    this.orderType,
  });

  @override
  State<_WebScanToPrintScreen> createState() => _WebScanToPrintScreenState();
}

class _WebScanToPrintScreenState extends State<_WebScanToPrintScreen> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'web-scan-print');
  final StringBuffer _scanBuffer = StringBuffer();
  Timer? _scanIdleTimer;
  Timer? _focusKeepAliveTimer;
  Timer? _partialScanResetTimer;
  StreamSubscription<html.KeyboardEvent>? _htmlWindowKeyDownSub;
  StreamSubscription<html.KeyboardEvent>? _htmlWindowKeyPressSub;
  StreamSubscription<html.Event>? _htmlWindowFocusSub;
  StreamSubscription<html.KeyboardEvent>? _htmlDocumentKeyDownSub;
  StreamSubscription<html.ClipboardEvent>? _htmlPasteSub;
  html.InputElement? _domScannerInput;
  StreamSubscription<html.KeyboardEvent>? _domScannerKeyDownSub;
  StreamSubscription<html.KeyboardEvent>? _domScannerKeyUpSub;
  StreamSubscription<html.Event>? _domScannerInputSub;
  StreamSubscription<html.Event>? _domScannerBlurSub;
  Timer? _domScannerIdleTimer;
  final StringBuffer _domScannerBuffer = StringBuffer();
  bool _openingPrint = false;
  String? _lastScan;
  String _pendingScanPrefix = '';
  String _scanStatusText =
      "Keep scanner focused on this screen and scan QR or barcode.";
  late final KeyEventCallback _globalKeyHandler;
  DateTime _lastFlutterKeyAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastHtmlKey = '';
  DateTime _lastHtmlKeyAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastConsumedValue = '';
  DateTime _lastConsumedAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get _scanCode => widget.orderNumber.toString();

  @override
  void initState() {
    super.initState();
    _globalKeyHandler = (event) {
      if (!mounted || _openingPrint || event is! KeyDownEvent) {
        return false;
      }
      return _captureKeyDown(event, source: 'global-key');
    };
    HardwareKeyboard.instance.addHandler(_globalKeyHandler);
    _htmlWindowKeyDownSub = html.window.onKeyDown.listen((event) {
      _handleHtmlKeyboardEvent(event, source: 'html-window-key');
    });
    _htmlWindowKeyPressSub = html.window.onKeyPress.listen((event) {
      _handleHtmlKeyboardEvent(event, source: 'html-window-keypress');
    });
    _htmlWindowFocusSub = html.window.onFocus.listen((_) {
      if (!mounted || _openingPrint) return;
      _focusScannerInput(quiet: true);
    });
    _htmlDocumentKeyDownSub = html.document.onKeyDown.listen((event) {
      _handleHtmlKeyboardEvent(event, source: 'html-document-key');
    });
    _htmlPasteSub = html.document.onPaste.listen((event) {
      if (!mounted || _openingPrint) return;
      final raw = event.clipboardData?.getData('text') ?? '';
      final value = _sanitizeScan(raw);
      if (value.isEmpty) return;
      _logScan('html-paste captured="$raw"');
      // ignore: avoid_print
      print("FULL SCAN VALUE: $value");
      _setScanStatus("Scanner input received. Verifying...");
      _consumeScan(value, source: 'html-paste');
      event.preventDefault();
    });
    _setupDomScannerCapture();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusScannerInput();
      _logScan('screen ready; expected order="$_scanCode"');
    });
    _focusKeepAliveTimer = Timer.periodic(const Duration(milliseconds: 900), (
      _,
    ) {
      if (!mounted || _openingPrint) return;
      _focusScannerInput(quiet: true);
    });
  }

  @override
  void dispose() {
    _scanIdleTimer?.cancel();
    _focusKeepAliveTimer?.cancel();
    _partialScanResetTimer?.cancel();
    _htmlWindowKeyDownSub?.cancel();
    _htmlWindowKeyPressSub?.cancel();
    _htmlWindowFocusSub?.cancel();
    _htmlDocumentKeyDownSub?.cancel();
    _htmlPasteSub?.cancel();
    _domScannerIdleTimer?.cancel();
    _domScannerKeyDownSub?.cancel();
    _domScannerKeyUpSub?.cancel();
    _domScannerInputSub?.cancel();
    _domScannerBlurSub?.cancel();
    _domScannerInput?.remove();
    _domScannerInput = null;
    HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    _focusNode.dispose();
    super.dispose();
  }

  bool _isDuplicateHtmlKey(String key) {
    final now = DateTime.now();
    if (_lastHtmlKey == key &&
        now.difference(_lastHtmlKeyAt) < const Duration(milliseconds: 30)) {
      return true;
    }
    _lastHtmlKey = key;
    _lastHtmlKeyAt = now;
    return false;
  }

  void _handleHtmlKeyboardEvent(
    html.KeyboardEvent event, {
    required String source,
  }) {
    if (!mounted || _openingPrint) return;
    final now = DateTime.now();
    if (now.difference(_lastFlutterKeyAt) < const Duration(milliseconds: 150)) {
      return;
    }
    final key = _normalizedHtmlKey(event);
    if (key.isEmpty) return;
    if (_isDuplicateHtmlKey(key)) return;
    final handled = _captureHtmlKey(key, source: source);
    if (handled) {
      event.preventDefault();
    }
  }

  void _setupDomScannerCapture() {
    try {
      _domScannerInput?.remove();
      final input = html.InputElement()
        ..id = 'selfx-dom-scanner-capture'
        ..tabIndex = 0
        ..autocomplete = 'off'
        ..autocapitalize = 'off'
        ..spellcheck = false
        ..style.position = 'fixed'
        ..style.left = '0'
        ..style.top = '0'
        ..style.width = '1px'
        ..style.height = '1px'
        ..style.opacity = '0.01'
        ..style.zIndex = '2147483647'
        ..style.border = '0'
        ..style.background = 'transparent'
        ..style.pointerEvents = 'none';

      html.document.body?.append(input);
      _domScannerInput = input;

      _domScannerKeyDownSub?.cancel();
      _domScannerKeyUpSub?.cancel();
      _domScannerInputSub?.cancel();
      _domScannerBlurSub?.cancel();

      _domScannerKeyDownSub = input.onKeyDown.listen((event) {
        if (!mounted || _openingPrint) return;
        final key = _normalizedHtmlKey(event);
        if (key.isEmpty) return;
        if (key == 'Enter' || key == 'NumpadEnter') {
          _flushDomScannerBuffer(trigger: 'enter');
          event.preventDefault();
          return;
        }
        if (key == 'Tab') {
          _flushDomScannerBuffer(trigger: 'tab');
          event.preventDefault();
          return;
        }
        if (key == 'Backspace') {
          if (_domScannerBuffer.isNotEmpty) {
            final cur = _domScannerBuffer.toString();
            _domScannerBuffer
              ..clear()
              ..write(cur.substring(0, cur.length - 1));
          }
          _scheduleDomScannerIdleFlush();
          event.preventDefault();
          return;
        }
        if (key.length == 1 && !_isControlCharacter(key)) {
          _domScannerBuffer.write(key);
          _setScanStatus("Receiving scanner input...");
          _scheduleDomScannerIdleFlush();
          event.preventDefault();
        }
      });

      _domScannerInputSub = input.onInput.listen((_) {
        if (!mounted || _openingPrint) return;
        final raw = input.value ?? '';
        if (raw.isEmpty) return;
        _domScannerBuffer.write(raw);
        input.value = '';
        _setScanStatus("Receiving scanner input...");
        _scheduleDomScannerIdleFlush();
      });

      _domScannerKeyUpSub = input.onKeyUp.listen((event) {
        if (!mounted || _openingPrint) return;
        final key = _normalizedHtmlKey(event);
        if (key == 'Enter' || key == 'NumpadEnter' || key == 'Tab') {
          _flushDomScannerBuffer(trigger: 'keyup');
          event.preventDefault();
        }
      });

      _domScannerBlurSub = input.onBlur.listen((_) {
        if (!mounted || _openingPrint) return;
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (!mounted || _openingPrint) return;
          _focusDomScannerInput(quiet: true);
        });
      });
    } catch (e) {
      _logScan('dom scanner capture setup failed: $e');
    }
  }

  bool _isDomScannerActive() {
    final input = _domScannerInput;
    if (input == null) return false;
    return identical(html.document.activeElement, input);
  }

  bool _focusDomScannerInput({bool quiet = false}) {
    final input = _domScannerInput;
    if (input == null) return false;
    try {
      input.click();
      input.focus();
      final active = _isDomScannerActive();
      if (!quiet) {
        _logScan(
          active
              ? 'dom scanner input focused'
              : 'dom scanner input focus requested (not active)',
        );
      }
      return active;
    } catch (_) {
      return false;
    }
  }

  void _scheduleDomScannerIdleFlush() {
    _domScannerIdleTimer?.cancel();
    _domScannerIdleTimer = Timer(const Duration(milliseconds: 900), () {
      _flushDomScannerBuffer(trigger: 'idle');
    });
  }

  void _flushDomScannerBuffer({required String trigger}) {
    _domScannerIdleTimer?.cancel();
    final inputValue = _domScannerInput?.value ?? '';
    if (inputValue.isNotEmpty) {
      _domScannerBuffer.write(inputValue);
      _domScannerInput?.value = '';
    }
    final captured = _domScannerBuffer.toString();
    _domScannerBuffer.clear();
    _logScan('dom-input $trigger captured="$captured"');
    if (captured.trim().isEmpty) return;
    // ignore: avoid_print
    print("FULL SCAN VALUE: $captured");
    _setScanStatus("Scanner input received. Verifying...");
    _consumeScan(captured, source: 'dom-input-$trigger');
  }

  String _normalizedHtmlKey(html.KeyboardEvent event) {
    final rawKey = event.key ?? '';
    if (rawKey.isNotEmpty && rawKey != 'Unidentified') {
      return rawKey;
    }

    final charCode = event.charCode;
    if (charCode >= 32 && charCode <= 126) {
      return String.fromCharCode(charCode);
    }

    final code = event.keyCode;
    if (code >= 48 && code <= 57) {
      return String.fromCharCode(code);
    }
    if (code >= 96 && code <= 105) {
      return (code - 96).toString();
    }
    if (code == 13) return 'Enter';
    if (code == 9) return 'Tab';
    if (code == 8) return 'Backspace';
    return '';
  }

  void _logScan(String message) {
    final line = '[scan-to-print] $message';
    debugPrint(line);
    html.window.console.log(line);
  }

  void _focusScannerInput({bool quiet = false}) {
    final domFocused = _focusDomScannerInput(quiet: quiet);
    if (domFocused) return;
    if (_focusNode.canRequestFocus) {
      if (!_focusNode.hasFocus) {
        _focusNode.requestFocus();
        if (!quiet) _logScan('keyboard focus fallback requested');
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _openingPrint) {
      return KeyEventResult.ignored;
    }
    final handled = _captureKeyDown(event, source: 'focus-key');
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _flushScanBuffer({required String source, required String trigger}) {
    _scanIdleTimer?.cancel();
    final captured = _scanBuffer.toString();
    _scanBuffer.clear();
    _logScan('$source $trigger captured="$captured"');
    if (captured.trim().isEmpty) return;
    // ignore: avoid_print
    print("FULL SCAN VALUE: $captured");
    _setScanStatus("Scanner input received. Verifying...");
    _consumeScan(captured, source: '$source-$trigger');
  }

  void _scheduleIdleFlush({required String source}) {
    _scanIdleTimer?.cancel();
    _scanIdleTimer = Timer(const Duration(milliseconds: 900), () {
      _flushScanBuffer(source: source, trigger: 'idle');
    });
  }

  void _appendScanCharacter(String character, {required String source}) {
    _scanBuffer.write(character);
    _setScanStatus("Receiving scanner input...");
    _scheduleIdleFlush(source: source);
  }

  void _popScanCharacter({required String source}) {
    if (_scanBuffer.isNotEmpty) {
      final current = _scanBuffer.toString();
      _scanBuffer
        ..clear()
        ..write(current.substring(0, current.length - 1));
    }
    _scheduleIdleFlush(source: source);
  }

  bool _captureKeyDown(KeyDownEvent event, {required String source}) {
    _lastFlutterKeyAt = DateTime.now();

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _flushScanBuffer(source: source, trigger: 'enter');
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _flushScanBuffer(source: source, trigger: 'tab');
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _popScanCharacter(source: source);
      return true;
    }

    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        !_isControlCharacter(character)) {
      _appendScanCharacter(character, source: source);
      return true;
    }

    return false;
  }

  bool _captureHtmlKey(String key, {required String source}) {
    if (key == 'Enter' || key == 'NumpadEnter') {
      _flushScanBuffer(source: source, trigger: 'enter');
      return true;
    }
    if (key == 'Tab') {
      _flushScanBuffer(source: source, trigger: 'tab');
      return true;
    }
    if (key == 'Backspace') {
      _popScanCharacter(source: source);
      return true;
    }
    if (key.length == 1 && !_isControlCharacter(key)) {
      _appendScanCharacter(key, source: source);
      return true;
    }
    return false;
  }

  bool _isControlCharacter(String value) {
    final code = value.codeUnitAt(0);
    return code < 32 || code == 127;
  }

  void _setScanStatus(String message) {
    if (!mounted) return;
    setState(() {
      _scanStatusText = message;
    });
  }

  String _sanitizeScan(String raw) {
    return raw
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  num _asNum(dynamic value) {
    if (value is num) return value;
    return num.tryParse(value?.toString() ?? "") ?? 0;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? "") ?? 0;
  }

  List<Map<String, dynamic>> _receiptLines() {
    return widget.cart.map((item) {
      final qty = _asInt(item["qty"] ?? item["quantity"] ?? 1).clamp(1, 9999);
      final variation =
          item["variation"] is Map ? item["variation"] as Map : null;
      final modifiers =
          item["modifiers"] is List ? item["modifiers"] as List : const [];

      final basePrice = _asNum(
        item["price"] ?? item["unit_price"] ?? item["item_price"] ?? 0,
      );
      final variationPrice = _asNum(variation?["price"]);
      final modifierPrice = modifiers.fold<num>(
        0,
        (sum, m) => sum + _asNum((m is Map) ? m["price"] : null),
      );
      final computedUnitPrice = basePrice + variationPrice + modifierPrice;
      final providedLineTotal = _asNum(
        item["amount"] ?? item["line_total"] ?? item["total"],
      );
      final lineTotal =
          providedLineTotal > 0 ? providedLineTotal : computedUnitPrice * qty;

      final possibleName = (item["name"] ??
              item["item_name"] ??
              item["title"] ??
              item["menu_item_name"] ??
              "Item")
          .toString()
          .trim();
      final name = possibleName.isEmpty ? "Item" : possibleName;

      return {
        "name": name,
        "qty": qty,
        "lineTotal": lineTotal,
      };
    }).toList();
  }

  Widget _buildReceiptPreview({required bool compact}) {
    final lines = _receiptLines();
    final total = lines.fold<num>(
      0,
      (sum, line) => sum + _asNum(line["lineTotal"]),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEADCCD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "ORDER RECEIPT",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF7B5A43),
            ),
          ),
          const SizedBox(height: 10),
          if (lines.isEmpty)
            const Text(
              "No order items available.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black54,
                fontSize: 13,
              ),
            )
          else
            ...lines.map((line) {
              final qty = _asInt(line["qty"]);
              final name = line["name"]?.toString() ?? "Item";
              final lineTotal = _asNum(line["lineTotal"]);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        "$qty",
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF3A3A3A),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: Color(0xFF2C2C2C),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Rs ${lineTotal.toStringAsFixed(2)}",
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF2C2C2C),
                      ),
                    ),
                  ],
                ),
              );
            }),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFFE6D8CA)),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "TOTAL",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1D1D1D),
                    ),
                  ),
                ),
                Text(
                  "Rs ${total.toStringAsFixed(2)}",
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1D1D1D),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _consumeScan(String raw, {required String source}) {
    final merged = _pendingScanPrefix.isEmpty ? raw : '$_pendingScanPrefix$raw';
    final value = _sanitizeScan(merged);
    _logScan(
      '$source raw="$raw" merged="$merged" trimmed="$value" expected="$_scanCode"',
    );
    if (value.isEmpty) {
      _logScan('$source ignored empty scan');
      _setScanStatus("Scanner input empty. Please scan again.");
      _focusScannerInput();
      return;
    }

    if (_isLikelyPartialInput(value)) {
      _pendingScanPrefix = value;
      _partialScanResetTimer?.cancel();
      _partialScanResetTimer = Timer(const Duration(seconds: 2), () {
        _pendingScanPrefix = '';
      });
      _logScan('$source partial scan kept="$value"');
      _setScanStatus("Scan in progress... please finish the code.");
      _focusScannerInput(quiet: true);
      return;
    }

    _pendingScanPrefix = '';
    _partialScanResetTimer?.cancel();

    final now = DateTime.now();
    if (_lastConsumedValue == value &&
        now.difference(_lastConsumedAt) < const Duration(milliseconds: 800)) {
      _logScan('$source duplicate scan ignored "$value"');
      return;
    }
    _lastConsumedValue = value;
    _lastConsumedAt = now;

    setState(() {
      _lastScan = value;
    });

    if (_matchesExpectedCode(value)) {
      _logScan('$source scan matched order ${widget.orderNumber}');
      _setScanStatus("Scanner matched. Printing receipt...");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scanner matched. Printing receipt...'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
      _openPrintScreen();
      return;
    }

    _logScan(
      '$source scan mismatch: received="$value" expected="$_scanCode"',
    );
    _setScanStatus(
      'Scanned "$value" does not match order $_scanCode. Please rescan.',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Scanned code "$value" does not match this order.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _focusScannerInput();
  }

  bool _isLikelyPartialInput(String value) {
    final normalized = _sanitizeScan(value).toLowerCase();
    if (normalized.isEmpty) return false;

    final expected = _scanCode.toLowerCase();
    if (expected.startsWith(normalized) &&
        normalized.length < expected.length) {
      return true;
    }

    final expectedDigits = expected.replaceAll(RegExp(r'[^0-9]'), '');
    if (expectedDigits.isEmpty) return false;
    for (final candidate in _digitCandidatesForMatching(normalized)) {
      if (candidate.isEmpty) continue;
      if (expectedDigits.startsWith(candidate) &&
          candidate.length < expectedDigits.length) {
        return true;
      }
    }
    return false;
  }

  bool _matchesExpectedCode(String value) {
    final normalized = value.trim().toLowerCase();
    final expected = _scanCode;
    final expectedNormalized = expected.toLowerCase();
    final expectedDigits = expected.replaceAll(RegExp(r'[^0-9]'), '');

    if (normalized == expectedNormalized) return true;

    for (final candidate in _digitCandidatesForMatching(normalized)) {
      if (candidate == expectedDigits) return true;
      final trimmedCandidate = candidate.replaceFirst(RegExp(r'^0+'), '');
      final trimmedExpected = expectedDigits.replaceFirst(RegExp(r'^0+'), '');
      if (trimmedCandidate.isNotEmpty && trimmedCandidate == trimmedExpected) {
        return true;
      }
      if (expectedDigits.isNotEmpty &&
          candidate.endsWith(expectedDigits) &&
          candidate.length <= expectedDigits.length + 2) {
        return true;
      }
    }

    final accepted = <String>{
      'order:$expectedNormalized',
      'order-$expectedNormalized',
      'order_$expectedNormalized',
      'selfx-$expectedNormalized',
      'selfx${widget.orderNumber}',
      'selfx-order-$expectedNormalized',
    };
    return accepted.contains(normalized);
  }

  Set<String> _digitCandidatesForMatching(String value) {
    final rawDigits = value.replaceAll(RegExp(r'[^0-9]'), '');
    final qAsZero = value
        .replaceAll(RegExp(r'[qQoO]'), '0')
        .replaceAll(RegExp(r'[^0-9]'), '');
    final candidates = <String>{
      rawDigits,
      qAsZero,
      rawDigits.replaceFirst(RegExp(r'^0+'), ''),
      qAsZero.replaceFirst(RegExp(r'^0+'), ''),
    };
    candidates.removeWhere((v) => v.isEmpty);
    return candidates;
  }

  Future<void> _openPrintScreen() async {
    if (_openingPrint) return;
    if (!mounted) return;

    setState(() {
      _openingPrint = true;
    });

    _logScan('scan accepted; trying print before opening success dialog');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Scan matched. Printing receipt...'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    bool printed = false;
    Object? printError;

    Future<void> tryPrint(
      Future<void> Function() printerCall,
      String source,
    ) async {
      if (printed) return;
      try {
        await printerCall();
        printed = true;
        _logScan('print success via $source');
      } catch (e) {
        printError = e;
        _logScan('print failed via $source: $e');
      }
    }

    await tryPrint(() {
      return PaymentSuccessDialog.printReceiptUsingTabletFlow(
        cart: widget.cart,
        orderNumber: widget.orderNumber,
        restaurantName: widget.restaurantName,
        orderType: widget.orderType,
      );
    }, 'tablet-flow');

    await tryPrint(() async {
      await KioskApi().printReceipt(widget.orderNumber);
    }, 'backend-printReceipt');

    await tryPrint(() async {
      html.window.print();
    }, 'window.print');

    if (!mounted) return;
    if (printed) {
      _setScanStatus("Print command sent successfully.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Print sent successfully.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    } else {
      _setScanStatus("Print failed. Opening success screen for retry.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Print failed. Opening success screen for retry.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PaymentSuccessDialog(
          cart: widget.cart,
          orderNumber: widget.orderNumber,
          language: "en",
          restaurantName: widget.restaurantName,
          orderType: widget.orderType,
          autoPrint: !printed,
          debugSource: printed
              ? "scan->print: pre-print success"
              : "scan->print: pre-print failed ($printError)",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = media.size.width < 720;
    final qrSize = compact ? 180.0 : 230.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F1EA),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            _focusScannerInput();
          },
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
                        padding: EdgeInsets.all(compact ? 20 : 28),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: const Color(0xFFE7D9CB)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 26,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Image.asset(
                                  "assets/self.png",
                                  height: compact ? 34 : 40,
                                  fit: BoxFit.contain,
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEEF7F0),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    "Order #${widget.orderNumber}",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF22643B),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Text(
                              "Payment successful",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 28 : 34,
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF1D1D1D),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              "Scan the QR code below to print the receipt using the same printer flow as tablet.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 13.5 : 15,
                                height: 1.5,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 22),
                            if (widget.restaurantName != null &&
                                widget.restaurantName!.trim().isNotEmpty)
                              Text(
                                widget.restaurantName!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF9F342C),
                                  letterSpacing: 0.4,
                                ),
                              ),
                            if (widget.restaurantName != null &&
                                widget.restaurantName!.trim().isNotEmpty)
                              const SizedBox(height: 16),
                            Center(
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFBF7),
                                  borderRadius: BorderRadius.circular(26),
                                  border: Border.all(
                                      color: const Color(0xFFEADCCD)),
                                ),
                                child: QrImageView(
                                  data: _scanCode,
                                  size: qrSize,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _buildReceiptPreview(compact: compact),
                            const SizedBox(height: 16),
                            Text(
                              _scanStatusText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: compact ? 12.5 : 13.5,
                                color: _scanStatusText.toLowerCase().contains(
                                              "does not match",
                                            ) ||
                                        _scanStatusText
                                            .toLowerCase()
                                            .contains("failed")
                                    ? Colors.red.shade700
                                    : (_openingPrint ||
                                            _scanStatusText
                                                .toLowerCase()
                                                .contains("matched") ||
                                            _scanStatusText
                                                .toLowerCase()
                                                .contains("success"))
                                        ? const Color(0xFF22643B)
                                        : Colors.black54,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (_lastScan != null &&
                                _lastScan!.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                "Last scan: $_lastScan",
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12.5,
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
