import 'dart:async';

import 'package:api_selfxo_project/background_image/background_image.dart';

import 'package:api_selfxo_project/screens/payment_success.dart';
// Ensure this is imported
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/kiosk_api.dart';
import '../core/image_url.dart';
import '../core/device_info.dart';
import '../core/idle_timer.dart';
import '../core/kiosk_log.dart';
import '../core/kiosk_restaurant_meta.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';

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

int _paymentAsInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? "") ?? 0;
}

List<Map<String, dynamic>> _buildPaymentOrderItems(
  List<Map<String, dynamic>> cart,
) {
  return cart.map((item) {
    final unitPrice = _paymentAsInt(item["price"]);
    final variation = item["variation"];
    final modifiers = (item["modifiers"] as List? ?? const []);

    return {
      "id": item["id"],
      "item_name": item["name"],
      "quantity": _paymentAsInt(item["qty"]),
      "price": unitPrice,
      "itemPrice": unitPrice,
      "take_away_charge": _paymentAsInt(item["take_away_charge"]),
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
}

class _PaymentScreenState extends State<PaymentScreen>
    with WidgetsBindingObserver {
  static const Color kPrimaryOrange = Color(0xFFFF5722);
  static const Color kBgGrey = Color(0xFFF1F3F6);

  int _remainingSeconds = 300;
  late final ValueNotifier<int> _remainingSecondsNotifier;
  late final ValueNotifier<int> _failSecondsNotifier;
  late final ValueNotifier<double> _failProgressNotifier;
  Timer? countdownTimer;
  static const int _failAutoCloseSeconds = 3;
  static const Duration _normalPaymentPollDelay = Duration(seconds: 4);
  static const Duration _firstPaymentPollDelay = Duration(seconds: 2);
  static const Duration _maxPaymentPollDelay = Duration(seconds: 30);
  int _failSeconds = _failAutoCloseSeconds;

  bool loading = true;
  bool _started = false;
  bool _pollingPayment = false;
  String? errorMessage;
  bool _active = true;

  int? orderId;
  String? orderNumber;
  String? qrData;
  double? payableAmount;
  String? _transactionId;
  DateTime? _orderDate;
  bool _counterPayment = false;

  String displayRestaurantName = "OUR KITCHEN";

  Timer? paymentTimer;
  Timer? timeoutTimer;
  Timer? _paymentFailTimer;
  bool _paymentCompleted = false;
  int _paymentPollFailures = 0;

  @override
  void initState() {
    super.initState();
    _remainingSecondsNotifier = ValueNotifier<int>(_remainingSeconds);
    _failSecondsNotifier = ValueNotifier<int>(_failAutoCloseSeconds);
    _failProgressNotifier = ValueNotifier<double>(1.0);
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
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(KioskRestaurantMeta.kioskDisplayNameKey) ??
          prefs.getString(KioskRestaurantMeta.restaurantNameKey) ??
          "OUR KITCHEN";

      if (mounted) {
        setState(() {
          displayRestaurantName = name.toUpperCase();
        });
      }
    } catch (_) {
      // Non-critical: the payment flow can continue with the cached/default name.
    }
  }

  Future<void> _startPaymentFlow() async {
    if (_started) return;
    _startCountdown();
    _started = true;

    try {
      // Build the order payload away from the UI isolate. Large carts with
      // modifiers can otherwise cause a visible hitch before the QR appears.
      final orderItems = await compute(_buildPaymentOrderItems, widget.cart);
      if (!_active || !mounted) return;

      final createRes = await KioskApi().createOrder(
        orderType: widget.orderType,
        orderItems: orderItems,
      );

      orderId = createRes.data["order"]?["id"];
      orderNumber ??= _extractOrderNumber(createRes.data);
      _transactionId ??= _extractTransactionId(createRes.data);
      _orderDate ??= _extractOrderDate(createRes.data);
      if (_isCounterPayment(createRes.data)) {
        payableAmount = widget.totalAmount.toDouble();
        countdownTimer?.cancel();
        timeoutTimer?.cancel();
        if (mounted) {
          setState(() {
            _counterPayment = true;
            loading = false;
          });
        }
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final cachedDeviceId = prefs.getString("device_id")?.trim() ?? "";
      final restaurantId = prefs.getString("restaurant_id")?.trim();
      if (cachedDeviceId.isEmpty &&
          restaurantId != null &&
          restaurantId.isNotEmpty) {
        await DeviceInfoUtil.getDeviceId(restaurantId: restaurantId);
      }

      dynamic paymentPayload = createRes.data;
      qrData = _extractQrString(paymentPayload);
      if (qrData == null) {
        final qrRes = await KioskApi().generateQr(orderId: orderId!);
        paymentPayload = qrRes.data;
        qrData = _extractQrString(paymentPayload);
      }
      kioskLog(
        "QR value kind=${_qrValueKind(qrData)} length=${qrData?.length ?? 0} prefix=${_qrPrefix(qrData)}",
        tag: "PAYMENT",
      );

      final amountPaise = _extractAmountPaise(paymentPayload);
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
      if (v is Map || v is Iterable) return null;
      final s = v.toString().trim();
      if (s.isEmpty || s.toLowerCase() == "null") return null;
      return s;
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
          "qrData",
          "qr_data",
          "upi_qr",
          "upiQr",
          "upi_url",
          "upiUrl",
          "upi_string",
          "upiString",
          "payload",
          "intent_url",
          "intentUrl",
          "deep_link",
          "deepLink",
          "deeplink",
          "payment_url",
          "paymentUrl",
          "checkout_url",
          "checkoutUrl",
          "redirect_url",
          "redirectUrl",
        ]);
        final directStr = asString(direct);
        if (directStr != null) return directStr;

        final image = readKey(data, const [
          "qr_url",
          "qrUrl",
          "image_url",
          "imageUrl",
        ]);
        final imageStr = asString(image);
        if (imageStr != null) return imageStr;

        for (final key in const [
          "data",
          "result",
          "response",
          "payload",
          "order",
          "payment",
          "qr",
          "qrCode",
          "qr_code",
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

  bool _isCounterPayment(dynamic payload) {
    if (payload is! Map) return false;
    final root = Map<String, dynamic>.from(payload);
    final order = root["order"] is Map
        ? Map<String, dynamic>.from(root["order"] as Map)
        : const <String, dynamic>{};
    final payment = order["payment"] is Map
        ? Map<String, dynamic>.from(order["payment"] as Map)
        : root["payment"] is Map
            ? Map<String, dynamic>.from(root["payment"] as Map)
            : const <String, dynamic>{};

    final candidates = [
      payment["type"],
      payment["gateway"],
      payment["method"],
      payment["payment_method"],
      order["payment_method"],
      root["payment_method"],
    ];

    for (final candidate in candidates) {
      final value = candidate
          ?.toString()
          .trim()
          .toLowerCase()
          .replaceAll("-", "_")
          .replaceAll(" ", "_");
      if (value == "counter" ||
          value == "pay_at_counter" ||
          value == "cash" ||
          value == "cod") {
        return true;
      }
    }
    return false;
  }

  bool _looksLikeImageUrl(String value) {
    final v = value.toLowerCase();
    if (!(v.startsWith("http://") || v.startsWith("https://"))) return false;
    return isSupportedRasterImageUrl(v) &&
        (v.contains(".png") ||
            v.contains(".jpg") ||
            v.contains(".jpeg") ||
            v.contains(".webp"));
  }

  String _qrValueKind(String? value) {
    final text = value?.trim().toLowerCase() ?? "";
    if (text.isEmpty) return "empty";
    if (text.startsWith("upi://")) return "upi";
    if (text.startsWith("intent://")) return "intent";
    if (_looksLikeImageUrl(text)) return "image_url";
    if (text.startsWith("http://") || text.startsWith("https://")) {
      return "web_url";
    }
    return "raw";
  }

  String _qrPrefix(String? value) {
    final text = value?.trim() ?? "";
    if (text.isEmpty) return "-";
    final safe = text.replaceAll(RegExp(r"[\\r\\n\\t]"), " ");
    return safe.length <= 24 ? safe : "${safe.substring(0, 24)}...";
  }

  void _startPaymentPolling() {
    _paymentPollFailures = 0;
    _schedulePaymentPoll(_firstPaymentPollDelay);
  }

  void _schedulePaymentPoll(Duration delay) {
    paymentTimer?.cancel();
    if (!_active || !mounted || _paymentCompleted || errorMessage != null) {
      return;
    }
    paymentTimer = Timer(delay, () => unawaited(_pollPaymentStatus()));
  }

  Duration _rateLimitDelay(Object error) {
    if (error is DioException) {
      final retryAfter = error.response?.headers.value("retry-after")?.trim();
      if (retryAfter != null && retryAfter.isNotEmpty) {
        final seconds = int.tryParse(retryAfter);
        if (seconds != null && seconds > 0) {
          return _clampDuration(
            Duration(seconds: seconds),
            const Duration(seconds: 5),
            const Duration(minutes: 2),
          );
        }
        final retryAt = DateTime.tryParse(retryAfter);
        if (retryAt != null) {
          final delay = retryAt.difference(DateTime.now());
          if (!delay.isNegative) {
            return _clampDuration(
              delay,
              const Duration(seconds: 5),
              const Duration(minutes: 2),
            );
          }
        }
      }
    }
    return const Duration(seconds: 20);
  }

  Duration _clampDuration(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  bool _isRateLimitError(Object error) {
    return error is DioException && error.response?.statusCode == 429;
  }

  Future<void> _pollPaymentStatus() async {
    if (!_active || !mounted) return;
    if (orderId == null) return;
    if (_pollingPayment || _paymentCompleted) return;

    try {
      _pollingPayment = true;
      final res = await KioskApi().checkPayment(orderId!);
      if (!_active || !mounted) return;

      _transactionId ??= _extractTransactionId(res.data);
      _orderDate ??= _extractOrderDate(res.data);
      orderNumber ??= _extractOrderNumber(res.data);
      final status = _extractPaymentStatus(res.data);
      kioskLog(
        "Payment poll order=$orderId status=${status ?? 'unknown'} body=${res.data}",
        tag: "PAYMENT",
      );

      if (_isPaidStatus(status)) {
        paymentTimer?.cancel();
        await _handlePaymentSuccess();
      } else if (_isFailedStatus(status)) {
        _handleError("Payment ${status?.replaceAll('_', ' ') ?? 'failed'}");
      } else {
        _paymentPollFailures = 0;
        _schedulePaymentPoll(_normalPaymentPollDelay);
      }
    } catch (e, stackTrace) {
      if (_isRateLimitError(e)) {
        final delay = _rateLimitDelay(e);
        kioskLog(
          "Payment poll rate limited for order=$orderId; retrying in ${delay.inSeconds}s",
          tag: "PAYMENT",
        );
        _schedulePaymentPoll(delay);
        return;
      }

      _paymentPollFailures++;
      final backoffSeconds =
          (4 * _paymentPollFailures).clamp(6, _maxPaymentPollDelay.inSeconds);
      kioskLogError(
        "Payment poll failed for order=$orderId; retrying in ${backoffSeconds}s",
        tag: "PAYMENT",
        error: e,
        stackTrace: stackTrace,
      );
      _schedulePaymentPoll(Duration(seconds: backoffSeconds));
    } finally {
      _pollingPayment = false;
    }
  }

  String? _extractPaymentStatus(dynamic payload) {
    String? normalize(dynamic value) {
      final text = value?.toString().trim();
      if (text == null || text.isEmpty) return null;
      return text.toLowerCase().replaceAll("-", "_").replaceAll(" ", "_");
    }

    String? readStatus(Map data, List<String> keys) {
      for (final key in keys) {
        if (data.containsKey(key)) {
          final status = normalize(data[key]);
          if (status != null) return status;
        }
      }
      final wanted = keys.map((e) => e.toLowerCase()).toSet();
      for (final entry in data.entries) {
        if (wanted.contains(entry.key.toString().toLowerCase())) {
          final status = normalize(entry.value);
          if (status != null) return status;
        }
      }
      return null;
    }

    String? findIn(dynamic data, int depth) {
      if (data == null || depth <= 0) return null;
      if (data is Map) {
        final explicitPaymentStatus = readStatus(data, const [
          "payment_status",
          "paymentStatus",
          "transaction_status",
          "transactionStatus",
        ]);
        if (explicitPaymentStatus != null) return explicitPaymentStatus;

        for (final key in const [
          "data",
          "order",
          "payment",
          "transaction",
          "result",
          "response",
          "payload",
        ]) {
          if (data.containsKey(key)) {
            final nested = findIn(data[key], depth - 1);
            if (nested != null) return nested;
          }
        }

        return readStatus(data, const [
          "status",
          "order_status",
          "orderStatus",
        ]);
      }
      return null;
    }

    return findIn(payload, 5);
  }

  bool _isPaidStatus(String? status) {
    if (status == null) return false;
    return status == "paid" ||
        status == "success" ||
        status == "successful" ||
        status == "completed" ||
        status == "complete" ||
        status == "payment_success" ||
        status == "captured" ||
        status == "settled" ||
        status == "approved" ||
        status == "confirmed";
  }

  bool _isFailedStatus(String? status) {
    if (status == null) return false;
    return status == "failed" ||
        status == "failure" ||
        status == "cancelled" ||
        status == "canceled" ||
        status == "expired" ||
        status == "timeout" ||
        status == "timed_out" ||
        status == "declined";
  }

  String? _extractTransactionId(dynamic payload) {
    const keys = [
      "transaction_id",
      "transactionId",
      "payment_id",
      "paymentId",
      "txn_id",
      "txnId",
      "payment_reference",
      "payment_ref",
      "reference_id",
      "referenceId",
    ];

    String? read(dynamic value, int depth) {
      if (value == null || depth <= 0) return null;
      if (value is Map) {
        for (final key in keys) {
          if (!value.containsKey(key)) continue;
          final text = value[key]?.toString().trim();
          if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
            return text;
          }
        }
        for (final entry in value.entries) {
          final found = read(entry.value, depth - 1);
          if (found != null) return found;
        }
      } else if (value is Iterable) {
        for (final item in value) {
          final found = read(item, depth - 1);
          if (found != null) return found;
        }
      }
      return null;
    }

    return read(payload, 5);
  }

  DateTime? _extractOrderDate(dynamic payload) {
    const keys = [
      "created_at",
      "createdAt",
      "order_date",
      "orderDate",
      "paid_at",
      "paidAt",
      "updated_at",
      "updatedAt",
    ];

    DateTime? parse(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      return DateTime.tryParse(value.toString());
    }

    DateTime? read(dynamic value, int depth) {
      if (value == null || depth <= 0) return null;
      if (value is Map) {
        for (final key in keys) {
          if (!value.containsKey(key)) continue;
          final parsed = parse(value[key]);
          if (parsed != null) return parsed;
        }
        for (final entry in value.entries) {
          final found = read(entry.value, depth - 1);
          if (found != null) return found;
        }
      } else if (value is Iterable) {
        for (final item in value) {
          final found = read(item, depth - 1);
          if (found != null) return found;
        }
      }
      return null;
    }

    return read(payload, 5);
  }

  String? _extractOrderNumber(dynamic payload) {
    const keys = [
      "order_number",
      "orderNumber",
      "order_no",
      "orderNo",
      "invoice_number",
      "invoiceNumber",
      "number",
    ];

    String? read(dynamic value, int depth) {
      if (value == null || depth <= 0) return null;
      if (value is Map) {
        for (final key in keys) {
          if (!value.containsKey(key)) continue;
          final text = value[key]?.toString().trim();
          if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
            return text;
          }
        }
        for (final key in const ["order", "data", "payment", "result"]) {
          final found = read(value[key], depth - 1);
          if (found != null) return found;
        }
      } else if (value is Iterable) {
        for (final item in value) {
          final found = read(item, depth - 1);
          if (found != null) return found;
        }
      }
      return null;
    }

    return read(payload, 5);
  }

  bool _receiptPrinted = false;

  Future<void> _handlePaymentSuccess() async {
    if (_paymentCompleted || _receiptPrinted) return;
    _paymentCompleted = true;
    _receiptPrinted = true;
    countdownTimer?.cancel();
    timeoutTimer?.cancel();
    _paymentFailTimer?.cancel();
    paymentTimer?.cancel();

    if (!_active || !mounted) return;
    kioskLog(
      "Payment success order=${orderNumber ?? orderId} transaction=${_transactionId ?? '-'}",
      tag: "PAYMENT",
    );
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
        _remainingSeconds--;
        _remainingSecondsNotifier.value = _remainingSeconds;
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
        builder: (_) => PaymentSuccessDialog(
          cart: widget.cart,
          orderNumber: orderId!,
          publicOrderNumber: orderNumber,
          language: "en",
          restaurantName: displayRestaurantName,
          transactionId: _transactionId,
          orderDate: _orderDate,
          orderType: widget.orderType,
        ),
      ),
    );
  }

  void _startFailAutoClose() {
    _paymentFailTimer?.cancel();
    _failSeconds = _failAutoCloseSeconds;
    _failSecondsNotifier.value = _failAutoCloseSeconds;
    _failProgressNotifier.value = 1.0;
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
        _failSeconds--;
        // Keep the auto-close progress local to the overlay instead of
        // rebuilding the whole payment/QR page every second.
        _failSecondsNotifier.value = _failSeconds;
        _failProgressNotifier.value = _failSeconds / _failAutoCloseSeconds;
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
    _remainingSecondsNotifier.dispose();
    _failSecondsNotifier.dispose();
    _failProgressNotifier.dispose();
    IdleTimer.resume();
    KioskMemoryService.instance.resume();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                    _counterPayment
                        ? _buildCounterHeader()
                        : _buildTimerHeader(),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _counterPayment
                            ? _buildCounterPaymentCard()
                            : _buildPaymentCard(),
                      ),
                    ),
                    _buildBottomAction(),
                  ],
                ),
          if (errorMessage != null) _buildErrorOverlay(),
        ],
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
              ValueListenableBuilder<int>(
                valueListenable: _remainingSecondsNotifier,
                builder: (_, seconds, __) => RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    children: [
                      TextSpan(
                        text: "$seconds ",
                        style: const TextStyle(color: Colors.orange),
                      ),
                      const TextSpan(
                        text: "Seconds",
                        style: TextStyle(color: Colors.black),
                      ),
                    ],
                  ),
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

  Widget _buildCounterHeader() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7EE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFB9E6C5)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.point_of_sale_rounded, color: Color(0xFF167A3B)),
          SizedBox(width: 10),
          Text(
            "Pay at Counter",
            style: TextStyle(
              color: Color(0xFF167A3B),
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCounterPaymentCard() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final amount = payableAmount ?? widget.totalAmount.toDouble();

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isTablet ? 500 : double.infinity,
        ),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 34 : 22,
            vertical: isTablet ? 42 : 30,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(isTablet ? 24 : 14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: isTablet ? 118 : 92,
                height: isTablet ? 118 : 92,
                decoration: const BoxDecoration(
                  color: Color(0xFFEAF7EE),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.receipt_long_rounded,
                  size: isTablet ? 62 : 48,
                  color: const Color(0xFF167A3B),
                ),
              ),
              SizedBox(height: isTablet ? 26 : 20),
              Text(
                displayRestaurantName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isTablet ? 28 : 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
              ),
              SizedBox(height: isTablet ? 14 : 10),
              Text(
                "₹${amount.toStringAsFixed(2)}",
                style: TextStyle(
                  fontSize: isTablet ? 46 : 36,
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF167A3B),
                ),
              ),
              if ((orderNumber ?? "").isNotEmpty) ...[
                SizedBox(height: isTablet ? 16 : 12),
                Text(
                  "Order: $orderNumber",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isTablet ? 18 : 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ],
              SizedBox(height: isTablet ? 26 : 20),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(isTablet ? 22 : 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE3E6EA)),
                ),
                child: Text(
                  "Please pay at the counter. Your order has been created.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isTablet ? 18 : 15,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ),
              SizedBox(height: isTablet ? 20 : 14),
              const Text(
                "No QR is needed for counter payment.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black54,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentCard() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final String qrValue = qrData?.trim() ?? "";
    final bool hasQr = qrValue.isNotEmpty;
    final double qrSize = isTablet ? 360 : 280;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // 🎯 Prevents the card from becoming too wide on tablets
          maxWidth: isTablet ? 500 : double.infinity,
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

              // Restaurant Name
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

              // Amount
              Text(
                "To Pay : ₹${payableAmount?.toStringAsFixed(2)}",
                style: TextStyle(
                  fontSize: isTablet ? 40 : 30,
                  fontWeight: FontWeight.w900,
                  color: Colors.orange,
                ),
              ),

              // Divider Text
              Padding(
                padding: EdgeInsets.symmetric(
                  vertical: isTablet ? 30 : 20,
                  horizontal: 20,
                ),
                child: Text(
                  "--------------------------------------------------",
                  style: TextStyle(
                    color: Colors.grey.shade300,
                    letterSpacing: isTablet ? 4 : 2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),

              Text(
                "Scan Here to Pay!",
                style: TextStyle(
                  fontSize: isTablet ? 22 : 18,
                  fontWeight: FontWeight.w600,
                ),
              ),

              SizedBox(height: isTablet ? 30 : 20),

              // 🎯 QR Section
              Container(
                padding: const EdgeInsets.all(12),
                child: RepaintBoundary(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (!hasQr)
                        Container(
                          width: qrSize,
                          height: qrSize,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: const Text(
                            "QR not available",
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.black54,
                            ),
                          ),
                        )
                      else if (_looksLikeImageUrl(qrValue))
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(18),
                          child: AppNetworkImage(
                            url: normalizeImageUrl(qrValue),
                            width: qrSize,
                            height: qrSize,
                            fit: BoxFit.contain,
                            cacheWidth: qrSize.round(),
                            cacheHeight: qrSize.round(),
                            fallback: const SizedBox.shrink(),
                          ),
                        )
                      else
                        Container(
                          color: Colors.white,
                          child: QrImageView(
                            data: qrValue,
                            size: qrSize,
                            padding: const EdgeInsets.all(20),
                            gapless: false,
                            errorCorrectionLevel: QrErrorCorrectLevel.H,
                            backgroundColor: Colors.white,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Colors.black,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Colors.black,
                            ),
                            errorStateBuilder: (ctx, err) => Container(
                              width: qrSize,
                              height: qrSize,
                              alignment: Alignment.center,
                              child: const Text(
                                "Invalid QR data",
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ),
                        ),
                      _qrCorner(
                        top: 0,
                        left: 0,
                        isTop: true,
                        isLeft: true,
                        isTablet: isTablet,
                      ),
                      _qrCorner(
                        top: 0,
                        right: 0,
                        isTop: true,
                        isLeft: false,
                        isTablet: isTablet,
                      ),
                      _qrCorner(
                        bottom: 0,
                        left: 0,
                        isTop: false,
                        isLeft: true,
                        isTablet: isTablet,
                      ),
                      _qrCorner(
                        bottom: 0,
                        right: 0,
                        isTop: false,
                        isLeft: false,
                        isTablet: isTablet,
                      ),
                    ],
                  ),
                ),
              ),

              SizedBox(height: isTablet ? 40 : 30),
              _buildPaymentLogos(),
              SizedBox(height: isTablet ? 40 : 24),
            ],
          ),
        ),
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

  Widget _buildPaymentLogos() {
    return Wrap(
      spacing: 15,
      runSpacing: 16,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildPremiumIcon(
            FontAwesomeIcons.googlePay, const Color(0xFF4285F4), ""),
        _buildPremiumIcon(
            FontAwesomeIcons.amazonPay, const Color(0xFFFF9900), ""),
        _buildPremiumIcon(FontAwesomeIcons.wallet, const Color(0xFF5f259f), ""),
        _buildPremiumIcon(FontAwesomeIcons.bolt, const Color(0xFF00baf2), ""),
        _buildPremiumIcon(FontAwesomeIcons.shieldHalved, Colors.black, "CRED"),
      ],
    );
  }

  Widget _buildPremiumIcon(IconData icon, Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, size: 25, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey[800],
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomAction() {
    final mediaQuery = MediaQuery.of(context);
    final bool isTablet = mediaQuery.size.width > 600;
    final double bottomPadding = mediaQuery.padding.bottom;

    if (_counterPayment) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(
          isTablet ? 80 : 16,
          16,
          isTablet ? 80 : 16,
          bottomPadding > 0 ? bottomPadding : 16,
        ),
        color: Colors.white,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isTablet ? 520 : double.infinity,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: isTablet ? 70 : 56,
                    child: ElevatedButton.icon(
                      onPressed: () => _showCancelConfirmation(
                        context,
                        isStartAgain: false,
                      ),
                      icon: Icon(
                        Icons.close,
                        color: Colors.red,
                        size: isTablet ? 28 : 20,
                      ),
                      label: Text(
                        "Cancel",
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
                          borderRadius:
                              BorderRadius.circular(isTablet ? 16 : 12),
                          side: const BorderSide(color: Colors.red, width: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: isTablet ? 70 : 56,
                    child: ElevatedButton.icon(
                      onPressed: _paymentCompleted
                          ? null
                          : () => unawaited(_handlePaymentSuccess()),
                      icon: Icon(
                        Icons.check_circle_rounded,
                        size: isTablet ? 28 : 20,
                      ),
                      label: Text(
                        "Print Receipt",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: isTablet ? 20 : 16,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF167A3B),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(isTablet ? 16 : 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

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
                    child: ValueListenableBuilder<double>(
                      valueListenable: _failProgressNotifier,
                      builder: (_, value, __) => Directionality(
                        textDirection: TextDirection.rtl,
                        child: LinearProgressIndicator(
                          value: value.clamp(0, 1),
                          minHeight: isTablet ? 10 : 8,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.redAccent,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ValueListenableBuilder<int>(
                    valueListenable: _failSecondsNotifier,
                    builder: (_, seconds, __) => Text(
                      "Returning to Welcome in ${seconds}s",
                      style: TextStyle(
                        fontSize: isTablet ? 16 : 13,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
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
