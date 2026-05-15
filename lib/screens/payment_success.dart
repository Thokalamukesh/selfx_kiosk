import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_config.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/printer/printer_s.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';

enum PrinterStatus { printing, success, error }

class PaymentSuccessDialog extends StatefulWidget {
  final List<Map<String, dynamic>> cart;
  final int orderNumber;
  final String language;
  final String? restaurantName;
  final String? transactionId;
  final DateTime? orderDate;
  final String? orderType;

  const PaymentSuccessDialog({
    super.key,
    required this.cart,
    required this.orderNumber,
    this.language = "en",
    this.restaurantName,
    this.transactionId,
    this.orderDate,
    this.orderType,
  });

  @override
  State<PaymentSuccessDialog> createState() => _PaymentSuccessDialogState();
}

class _PaymentSuccessDialogState extends State<PaymentSuccessDialog>
    with TickerProviderStateMixin {
  static const Color kPrimary = Color(0xFF00C853);
  static const Color kBackground = Color(0xFFF1F5F9);
  static const Color kAccent = Color(0xFF00BFA5);

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late AnimationController _receiptController;
  late AnimationController _vibrateController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final bool _enableSuccessAnimations = KioskConfig.enableSuccessAnimations;

  Timer? autoCloseTimer;
  Timer? _pulseStopTimer;
  int _countdownSeconds = 3;
  bool isPrinting = false;
  bool _blockUi = false;
  VoidCallback? _maintenanceListener;

  PrinterStatus? printerStatus;
  String? printerStatusMessage;
  String _printStatusText = "Preparing...";
  String _restaurantName = "OUR KITCHEN";

  static const MethodChannel _usbEvents = MethodChannel(
    'com.whimsicaldev/usb_events',
  );
  final PrinterService _printerService = PrinterService();

  int get totalAmount => widget.cart.fold(
        0,
        (sum, item) => sum + _asInt(item["price"]) * _asInt(item["qty"]),
      );

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: _enableSuccessAnimations
          ? const Duration(milliseconds: 600)
          : const Duration(milliseconds: 1),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -0.04), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _receiptController = AnimationController(
      vsync: this,
      duration: _enableSuccessAnimations
          ? const Duration(milliseconds: 2000)
          : const Duration(milliseconds: 1),
    );
    _vibrateController = AnimationController(
      vsync: this,
      duration: _enableSuccessAnimations
          ? const Duration(milliseconds: 50)
          : const Duration(milliseconds: 1),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: _enableSuccessAnimations
          ? const Duration(milliseconds: 1800)
          : const Duration(milliseconds: 1),
    );
    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (_enableSuccessAnimations) {
      _animationController.forward();
      _pulseController.repeat(reverse: true);
      _pulseStopTimer?.cancel();
      _pulseStopTimer = Timer(const Duration(seconds: 3), () {
        if (_pulseController.isAnimating) {
          _pulseController.stop(canceled: true);
        }
      });
    } else {
      _animationController.value = 1;
    }

    _loadRestaurantName();

    _maintenanceListener = _handleMaintenanceTick;
    KioskMemoryService.instance.maintenanceTick.addListener(
      _maintenanceListener!,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handlePrintingProcess();
    });

    _usbEvents.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onPrinterPrintStatus') {
        final status = call.arguments?['status']?.toString() ?? '';
        final message = call.arguments?['message']?.toString() ?? '';
        _handlePrintStatus(status, message);
      }
    });
  }

  // ================= PRINT =================
  Future<void> _handlePrintingProcess() async {
    if (isPrinting) return;

    // Stop auto-close timer if reprinting
    autoCloseTimer?.cancel();
    bool hadError = false;

    setState(() {
      isPrinting = true;
      _blockUi = true;
      printerStatus = PrinterStatus.printing;
      printerStatusMessage = "Printing receipt...";
      _printStatusText = "Printing your receipt...";
      _countdownSeconds = 3; // Reset countdown
    });

    if (_enableSuccessAnimations) {
      _receiptController.forward(from: 0);
      _vibrateController.repeat(reverse: true);
    } else {
      _receiptController.value = 1;
    }

    try {
      String? restaurantName = widget.restaurantName;
      if (restaurantName == null || restaurantName.trim().isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        restaurantName = prefs.getString("restaurant_name");
      }
      restaurantName ??= "OUR KITCHEN";
      final prefs = await SharedPreferences.getInstance();
      final taxId = prefs.getString("gst_number") ?? prefs.getString("tax_id");

      String? transactionId = widget.transactionId;
      DateTime? orderDate = widget.orderDate;
      if (transactionId == null || orderDate == null) {
        try {
          final res = await KioskApi().getOrderDetails(widget.orderNumber);
          final raw = res.data;
          transactionId ??= _findTxnId(raw);
          orderDate ??= _parseOrderDate(raw);
        } catch (_) {}
      }

      await _printerService.printOrder(
        orderId: widget.orderNumber,
        cartItems: widget.cart,
        restaurantName: restaurantName,
        taxId: taxId,
        paymentMode: "PAID",
        transactionId: transactionId,
        orderDate: orderDate,
        orderType: widget.orderType,
        removeTaxLines: true,
      );

      if (!mounted) return;
      setState(() {
        printerStatus = PrinterStatus.success;
        printerStatusMessage = "Printer Ready";
        _printStatusText = "Print successful";
      });
    } on DioException catch (e) {
      if (!mounted) return;
      hadError = true;
      setState(() {
        printerStatus = PrinterStatus.error;
        printerStatusMessage = kDebugMode
            ? (e.response?.data?.toString() ?? e.message ?? "Backend error")
            : "Printer error. Contact staff.";
        _printStatusText = printerStatusMessage ?? "Printer error";
      });
    } catch (e) {
      if (!mounted) return;
      hadError = true;
      setState(() {
        printerStatus = PrinterStatus.error;
        printerStatusMessage = kDebugMode ? e.toString() : "Printer error.";
        _printStatusText = printerStatusMessage ?? "Printer error";
      });
    } finally {
      if (mounted) {
        _vibrateController.stop();
        setState(() {
          isPrinting = false;
          _blockUi = false;
        });
        if (printerStatus == PrinterStatus.success ||
            printerStatus == PrinterStatus.error) {
          _startAutoCloseTimer(seconds: 3);
        }
      }
    }
  }

  List<String> _counterFooterLines(List<Map<String, dynamic>> items) {
    String category = "";
    for (final item in items) {
      final c = item["category"]?.toString().trim() ?? "";
      if (c.isNotEmpty) {
        category = c.toUpperCase();
        break;
      }
    }
    if (category.isEmpty) {
      category = "CATEGORY";
    }
    return [category, "COUNTER"];
  }

  String? _findTxnId(dynamic value) {
    const keys = [
      "transaction_id",
      "payment_id",
      "txn_id",
      "transactionId",
      "paymentId",
      "razorpay_payment_id",
      "payment_reference",
      "payment_txn_id",
      "txnid",
      "txnId",
    ];

    if (value is Map) {
      for (final k in keys) {
        if (value.containsKey(k) && value[k] != null) {
          final v = value[k];
          if (v.toString().trim().isNotEmpty) return v.toString().trim();
        }
      }
      for (final entry in value.entries) {
        final found = _findTxnId(entry.value);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findTxnId(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  DateTime? _parseOrderDate(dynamic value) {
    final keys = [
      "created_at",
      "order_date",
      "date",
      "createdAt",
      "placed_at",
      "order_time",
    ];
    if (value is Map) {
      for (final k in keys) {
        final v = value[k];
        final parsed = _parseDateValue(v);
        if (parsed != null) return parsed;
      }
      for (final entry in value.entries) {
        final parsed = _parseOrderDate(entry.value);
        if (parsed != null) return parsed;
      }
    } else if (value is List) {
      for (final item in value) {
        final parsed = _parseOrderDate(item);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  DateTime? _parseDateValue(dynamic v) {
    if (v == null) return null;
    try {
      if (v is int) {
        return v > 1000000000000
            ? DateTime.fromMillisecondsSinceEpoch(v)
            : DateTime.fromMillisecondsSinceEpoch(v * 1000);
      }
      if (v is String) {
        return DateTime.tryParse(v);
      }
    } catch (_) {}
    return null;
  }

  // ================= AUTO CLOSE =================
  void _startAutoCloseTimer({int seconds = 3}) {
    autoCloseTimer?.cancel();
    _countdownSeconds = seconds;
    autoCloseTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdownSeconds <= 0) {
        timer.cancel();
        _navigateToWelcome();
      } else {
        setState(() => _countdownSeconds--);
      }
    });
  }

  void _navigateToWelcome() {
    _scheduleImageCacheClear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  void _scheduleImageCacheClear() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  }

  @override
  void dispose() {
    autoCloseTimer?.cancel();
    _pulseStopTimer?.cancel();
    if (_animationController.isAnimating) {
      _animationController.stop(canceled: true);
    }
    if (_receiptController.isAnimating) {
      _receiptController.stop(canceled: true);
    }
    if (_vibrateController.isAnimating) {
      _vibrateController.stop(canceled: true);
    }
    if (_pulseController.isAnimating) {
      _pulseController.stop(canceled: true);
    }
    _animationController.dispose();
    _receiptController.dispose();
    _vibrateController.dispose();
    _pulseController.dispose();
    _usbEvents.setMethodCallHandler(null);
    if (_maintenanceListener != null) {
      KioskMemoryService.instance.maintenanceTick.removeListener(
        _maintenanceListener!,
      );
    }
    super.dispose();
  }

  void _handleMaintenanceTick() {
    if (!mounted) return;
    if (_pulseController.isAnimating) {
      _pulseController.reset();
      _pulseController.repeat(reverse: true);
    }
    if (_vibrateController.isAnimating) {
      _vibrateController.reset();
      _vibrateController.repeat(reverse: true);
    }
  }

  Future<void> _loadRestaurantName() async {
    String? name = widget.restaurantName;
    if (name == null || name.trim().isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      name = prefs.getString("restaurant_name");
    }
    if (!mounted) return;
    setState(() {
      _restaurantName = (name == null || name.trim().isEmpty)
          ? _restaurantName
          : name!.trim();
    });
  }

  // ================= UI COMPONENTS =================
  @override
  Widget build(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        toolbarHeight: isTablet ? 100 : 80,
        backgroundColor: const Color(0xFF5BCB73),
        elevation: 0,
        centerTitle: true,
        leadingWidth: 140,
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
        title: Text(
          _restaurantName,
          style: const TextStyle(
            color: Color.fromARGB(221, 255, 255, 255),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Stack(
        children: [
          _buildBackground(),
          Center(
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: _buildMainCard(),
                ),
              ),
            ),
          ),
          if (_blockUi) _printingOverlay(),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF5BCB73), Color(0xFF4DBA63), Color(0xFF43B05A)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _glowCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  Widget _buildPrinterSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_enableSuccessAnimations)
          AnimatedBuilder(
            animation: _vibrateController,
            builder: (_, child) {
              final offset = isPrinting ? (Random().nextDouble() * 2 - 1) : 0.0;
              return Transform.translate(
                offset: Offset(offset, 0),
                child: child,
              );
            },
            child: Container(
              width: 240,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(10),
                ),
              ),
            ),
          )
        else
          Container(
            width: 240,
            height: 16,
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
            ),
          ),
        const SizedBox(height: 6),
        if (_enableSuccessAnimations)
          ClipRect(
            child: AnimatedBuilder(
              animation: _receiptController,
              builder: (_, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _receiptController.value,
                child: child,
              ),
              child: _buildPhysicalReceipt(),
            ),
          )
        else
          _buildPhysicalReceipt(),
      ],
    );
  }

  Widget _buildPhysicalReceipt() {
    return Container(
      width: 230,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "RECEIPT",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const Divider(),
          ...widget.cart.take(3).map(
                (i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          "${i["qty"]}x ${i["name"]}",
                          style: const TextStyle(fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        "₹${i["price"] * i["qty"]}",
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "TOTAL",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Text(
                "₹$totalAmount",
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text("*** THANK YOU ***", style: TextStyle(fontSize: 8)),
        ],
      ),
    );
  }

  Widget _buildMainCard() {
    return SizedBox(
      width: 520,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 24, 36, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.check, size: 46, color: kPrimary),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "Payment Successful!",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Your Receipt Is Printing. Kindly Do Not Pull Until Fully Printed.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Please show this receipt at the counter to get your order.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 20),
            const Text(
              "AMOUNT PAID",
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.4,
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "₹$totalAmount",
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 18),
            _buildPrinterSection(),
            if (printerStatus == PrinterStatus.error) ...[
              const SizedBox(height: 8),
              Text(
                printerStatusMessage ?? "Printer error",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kPrimary.withOpacity(0.12), kPrimary.withOpacity(0.04)],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: kPrimary.withOpacity(0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kPrimary.withOpacity(0.25)),
            ),
            child: const Text(
              "SUCCESS",
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: kPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _restaurantName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 16),
          if (_enableSuccessAnimations)
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, __) => Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kPrimary.withOpacity(0.12),
                  ),
                  child: const Icon(
                    Icons.check_circle,
                    color: kPrimary,
                    size: 74,
                  ),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kPrimary.withOpacity(0.12),
              ),
              child: const Icon(
                Icons.check_circle,
                color: kPrimary,
                size: 74,
              ),
            ),
          const SizedBox(height: 14),
          const Text(
            "Payment Successful",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.2,
            ),
          ),
          Text(
            "Order #${widget.orderNumber}",
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "₹$totalAmount",
            style: const TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.bold,
              color: kPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Total Amount",
            style: TextStyle(color: Colors.blueGrey, fontSize: 14),
          ),
          const SizedBox(height: 14),
          _printerStatusChip(),
        ],
      ),
    );
  }

  Widget _printerStatusChip() {
    if (printerStatus == PrinterStatus.success) {
      return const SizedBox.shrink();
    }
    String text;
    Color color;
    switch (printerStatus) {
      case PrinterStatus.printing:
        text = "Printing...";
        color = Colors.blue;
        break;
      case PrinterStatus.error:
        text = "Print Failed";
        color = Colors.red;
        break;
      default:
        text = "Ready";
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildOrderDetails() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FBF8),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kPrimary.withOpacity(0.08)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200),
        child: ListView(
          shrinkWrap: true,
          children: widget.cart
              .map(
                (i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        "${i["qty"]}x ",
                        style: const TextStyle(
                          color: kPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          i["name"],
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        "₹${i["price"] * i["qty"]}",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        if (isPrinting)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: LinearProgressIndicator(
              color: kPrimary,
              backgroundColor: Colors.transparent,
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: isPrinting ? null : _handlePrintingProcess,
            icon: const Icon(Icons.print_outlined),
            label: Text(
              isPrinting ? "Printing..." : "Reprint Receipt",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: kPrimary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _printingOverlay() {
    return Positioned.fill(
      child: AbsorbPointer(
        absorbing: true,
        child: Container(
          color: Colors.black.withOpacity(0.55),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.print, color: Colors.white, size: 64),
                const SizedBox(height: 16),
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  _printStatusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handlePrintStatus(String status, String message) {
    switch (status) {
      case "PRINT_STARTED":
      case "PRINTING":
        setState(() {
          isPrinting = true;
          _blockUi = true;
          printerStatus = PrinterStatus.printing;
          printerStatusMessage = "Printing receipt...";
          _printStatusText =
              message.isNotEmpty ? message : "Printing your receipt...";
        });
        break;
      case "PRINT_SUCCESS":
        setState(() {
          isPrinting = false;
          _blockUi = false;
          printerStatus = PrinterStatus.success;
          printerStatusMessage = "Printer Ready";
          _printStatusText = "Print successful";
        });
        _startAutoCloseTimer(seconds: 3);
        break;
      case "PRINT_ERROR":
        setState(() {
          isPrinting = false;
          _blockUi = false;
          printerStatus = PrinterStatus.error;
          printerStatusMessage = "Print Failed";
          _printStatusText = message.isNotEmpty ? message : "Print failed";
        });
        _startAutoCloseTimer(seconds: 3);
        break;
      default:
        break;
    }
  }
}
