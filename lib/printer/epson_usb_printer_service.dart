import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';

class EpsonUSBPrinterService {
  // MUST match PRINTER_CHANNEL in MainActivity.kt
  static const MethodChannel _channel = MethodChannel(
    'com.whimsicaldev/epson_usb',
  );

  static const Duration _defaultTimeout = Duration(seconds: 8);
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _printTimeout = Duration(seconds: 20);
  static const Duration _permissionTimeout = Duration(seconds: 15);

  Future<T?> _invoke<T>(
    String method, [
    dynamic arguments,
    Duration? timeout,
  ]) async {
    try {
      return await _channel
          .invokeMethod<T>(method, arguments)
          .timeout(timeout ?? _defaultTimeout);
    } on TimeoutException {
      throw Exception("USB method timeout: $method");
    }
  }

  // ================= GET PRINTER LIST =================
  Future<List<Map<String, dynamic>>> getPrinterList() async {

    try {
      final dynamic res = await _invoke<dynamic>('getPrinterList');

      List<dynamic> list;
      if (res is Map && res['printerList'] is List) {
        // Backward-compat for older native response
        list = List<dynamic>.from(res['printerList']);
      } else if (res is List) {
        list = res;
      } else {
        list = [];
      }


      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .map(_normalizePrinter)
          .toList();
    } catch (e, st) {
      return [];
    }
  }

  // ================= CONNECT + PRINT =================
  Future<void> setSelectedPrinter(Map<String, dynamic> printer) async {
    final int? deviceId = _toInt(printer['deviceId']);
    final int? vendorId = _toInt(printer['vendorId']);
    final int? productId = _toInt(printer['productId']);


    await _invoke<void>('setSelectedPrinter', {
      'deviceId': deviceId,
      'vendorId': vendorId,
      'productId': productId,
    }, _connectTimeout);
  }

  Future<void> scanAndConnect() async {
    await _invoke<void>('scanAndConnect', null, _connectTimeout);
  }

  Future<bool> requestUsbPermission(Map<String, dynamic> printer) async {
    final int? deviceId = _toInt(printer['deviceId']);
    final int? vendorId = _toInt(printer['vendorId']);
    final int? productId = _toInt(printer['productId']);


    final bool? requested = await _invoke<bool>(
      'requestUsbPermission',
      {'deviceId': deviceId, 'vendorId': vendorId, 'productId': productId},
      _permissionTimeout,
    );
    return requested ?? false;
  }

  Future<bool> requestUsbPermissionWithUi(
    Map<String, dynamic> printer, {
    int durationMs = 20000,
  }) async {
    final int? deviceId = _toInt(printer['deviceId']);
    final int? vendorId = _toInt(printer['vendorId']);
    final int? productId = _toInt(printer['productId']);


    final bool? requested = await _invoke<bool>(
      'requestUsbPermissionWithUi',
      {
        'deviceId': deviceId,
        'vendorId': vendorId,
        'productId': productId,
        'durationMs': durationMs,
      },
      Duration(milliseconds: durationMs + 5000),
    );
    return requested ?? false;
  }

  Future<List<String>> getNativeLogs() async {
    final List<dynamic>? res = await _invoke<List<dynamic>>('getNativeLogs');
    return res?.map((e) => e.toString()).toList() ?? [];
  }

  Future<void> clearNativeLogs() async {
    await _invoke<void>('clearNativeLogs');
  }

  

 

  Future<void> printData({
    required Map<String, dynamic> printer,
    required List<Map<String, dynamic>> printObject,
  }) async {

    await _ensureConnection(printer);

    try {

      final int? deviceId = _toInt(printer['deviceId']);
      final int? vendorId = _toInt(printer['vendorId']);
      final int? productId = _toInt(printer['productId']);

      await _invoke<void>('printData', {
        'printObject': jsonEncode(printObject),
        'lineFeed': 3,
        'deviceId': deviceId,
        'vendorId': vendorId,
        'productId': productId,
      }, _printTimeout);

    } catch (e, st) {
      rethrow;
    }
  }

  // ================= PRINT RAW JSON (SERVER) =================
  Future<void> printRawPrintObject({
    required Map<String, dynamic> printer,
    required List<dynamic> printObject,
  }) async {

    await _ensureConnection(printer);

    try {
      final int? deviceId = _toInt(printer['deviceId']);
      final int? vendorId = _toInt(printer['vendorId']);
      final int? productId = _toInt(printer['productId']);
      await _invoke<void>('printData', {
        'printObject': jsonEncode(printObject),
        'lineFeed': 0, // IMPORTANT: backend already includes feedLine/cut
        'deviceId': deviceId,
        'vendorId': vendorId,
        'productId': productId,
      }, _printTimeout);
    } catch (e, st) {
      rethrow;
    }
  }

  // ================= QUERY PRINTER STATUS =================
  Future<String> queryStatus({Map<String, dynamic>? printer}) async {

    try {
      final Map? res = await _invoke<Map>('queryStatus', {
        'deviceId': _toInt(printer?['deviceId']),
        'vendorId': _toInt(printer?['vendorId']),
        'productId': _toInt(printer?['productId']),
      }, _defaultTimeout);
      return res?['status'] ?? 'UNKNOWN_STATUS';
    } catch (e, st) {
      return 'ERROR';
    }
  }

  // ================= USB CONNECTION =================
  Future<void> _ensureConnection(Map<String, dynamic> printer) async {

    final int? deviceId = _toInt(printer['deviceId']);
    final int? vendorId = _toInt(printer['vendorId']);
    final int? productId = _toInt(printer['productId']);

    if (deviceId == null && vendorId == null && productId == null) {
      throw Exception("Invalid USB printer");
    }

    try {

      await _invoke<void>('connectToPrinter', {
        'deviceId': deviceId,
        'vendorId': vendorId,
        'productId': productId,
      }, _connectTimeout);

    } catch (e, st) {
      rethrow;
    }
  }

  // ================= SAMPLE / TEST PRINT =================
  List<Map<String, dynamic>> samplePrintObject({
    required String restaurantName,
    required String address,
  }) {

    final now = DateTime.now();
    final dateTime =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";

    return [
      {
        'type': 'text',
        'text': restaurantName,
        'options': {
          'align': 1,
          'fontStyle': 1, // bold
          'widthTimes': 1,
          'heightTimes': 1,
        },
      },
      {'type': 'feedLine'},
      {
        'type': 'text',
        'text': address,
        'options': {'align': 1},
      },
      {
        'type': 'text',
        'text': dateTime,
        'options': {'align': 1},
      },
      {'type': 'feedLine'},
      {'type': 'dottedLine'},
      {
        'type': 'text',
        'text': 'USB TEST PRINT SUCCESSFUL',
        'options': {'align': 1},
      },
      {'type': 'feedLine'},
      {
        'type': 'text',
        'text': 'Thank you for your order!',
        'options': {'align': 1},
      },
      {
        'type': 'text',
        'text': 'Please visit again',
        'options': {'align': 1},
      },
      // Add extra feed lines before cut to avoid mid-receipt cuts on some models
      {'type': 'feedLine'},
      {'type': 'feedLine'},
      {'type': 'feedLine'},
      {'type': 'feedLine'},
      {'type': 'feedLine'},
      {'type': 'fullCutPaper'},
    ];
  }

  // ================= RECEIPT PRINT OBJECT (ANGULAR FORMAT) =================
  List<Map<String, dynamic>> buildReceiptPrintObject({
    required String restaurantName,
    String? address,
    String? taxId,
    required int orderId,
    DateTime? orderDate,
    String? transactionId,
    String? paymentMode,
    required List<Map<String, dynamic>> cartItems,
    num? taxAmount,
    num? discountAmount,
    List<String>? footerLines,
  }) {
    const int width = 32;
    final dt = orderDate ?? DateTime.now();
    final dateTime =
        "${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}";

    final List<Map<String, dynamic>> lines = [];

    // ================= LOW-LEVEL HELPERS =================
    void text(
      String value, {
      int align = 0,
      bool bold = false,
      bool large = false,
    }) {
      lines.add({
        'type': 'text',
        'text': value,
        'options': {
          'align': align,
          'fontStyle': bold ? 1 : 0, // ✅ native supported
          'widthTimes': large ? 1 : 0, // ✅ native supported
          'heightTimes': large ? 1 : 0, // ✅ native supported
        },
      });
      lines.add({'type': 'feedLine'});
    }

    void dotted() => lines.add({'type': 'dottedLine'});

    String center(String t) => t.length >= width
        ? t
        : t.padLeft((width + t.length) ~/ 2).padRight(width);

    String lr(String l, String r) =>
        l.padRight(width - r.length).substring(0, width - r.length) + r;

    String money(num v) => v.toStringAsFixed(2); // ✅ NO "Rs" here

    String itemRow(String name, String qty, String price, String total) {
      return _truncate(name, 16).padRight(16) +
          qty.padLeft(4) +
          price.padLeft(6) +
          total.padLeft(6);
    }

    // ================= HEADER =================
    text(center(restaurantName), align: 1, bold: true, large: true);

    if (address?.isNotEmpty == true) {
      for (final l in _wrap(address!, width)) {
        text(center(l), align: 1);
      }
    }

    if (taxId?.isNotEmpty == true) {
      text(center("GST: $taxId"), align: 1);
    }

    text(center("SELFX ORDER #$orderId"), align: 1, bold: true);
    dotted();

    text(lr("Order #", orderId.toString()));

    text(lr("DATE", dateTime));

    if (transactionId?.isNotEmpty == true) {
      final t = transactionId!;
      final shortTxn = t.length > 16 ? t.substring(t.length - 16) : t;
      text(lr("TXN ID", shortTxn));
    }

    if (paymentMode?.isNotEmpty == true) {
      text(lr("Payment", paymentMode!));
    }

    dotted();

    // ================= ITEMS =================
    text(itemRow("ITEM", "QTY", "PRICE", "VALUE"), bold: true);
    dotted();

    String? currentCategory;
    num categoryTotal = 0;
    num grandTotal = 0;

    for (final item in cartItems) {
      final name = item['name']?.toString() ?? 'Item';
      final qty = (item['qty'] ?? 0).toInt();
      final price = (item['price'] ?? 0) as num;
      final total = qty * price;
      final category = item['category']?.toString();

      if (category != null && category != currentCategory) {
        if (currentCategory != null) {
          text(lr("Category Total", "Rs ${money(categoryTotal)}"), bold: true);
          dotted();
          grandTotal += categoryTotal;
        }
        currentCategory = category;
        categoryTotal = 0;
        text(category.toUpperCase(), bold: true);
        dotted();
      }

      categoryTotal += total;
      text(itemRow(name, qty.toString(), money(price), money(total)));
    }

    if (currentCategory != null) {
      text(lr("Category Total", "Rs ${money(categoryTotal)}"), bold: true);
      dotted();
      grandTotal += categoryTotal;
    }

    // ================= TOTALS =================
    final tax = taxAmount ?? 0;
    final discount = discountAmount ?? 0;
    final payable = grandTotal + tax - discount;

    if (tax > 0) text(lr("Tax", "Rs ${money(tax)}"));
    if (discount > 0) text(lr("Discount", "-Rs ${money(discount)}"));
    text(lr("GRAND TOTAL", "Rs ${money(payable)}"), bold: true);
    dotted();

    // ================= FOOTER =================
    final footer = footerLines ?? ["Thank you for your order!"];

    for (final f in footer) {
      if (f.trim().isNotEmpty) {
        text(center(f.trim()), align: 1);
      }
    }

    // 🔴 IMPORTANT: NO EXTRA FEED LINES
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  Map<String, dynamic> _normalizePrinter(Map<String, dynamic> printer) {
    final normalized = Map<String, dynamic>.from(printer);
    normalized['name'] ??=
        printer['productName'] ?? printer['manufacturerName'] ?? 'USB Printer';
    return normalized;
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  List<String> _wrap(String text, int width) {
    final words = text.split(RegExp(r"\s+"));
    final List<String> lines = [];
    var current = "";
    for (final word in words) {
      if ((current + " " + word).trim().length <= width) {
        current = (current + " " + word).trim();
      } else {
        if (current.isNotEmpty) lines.add(current);
        current = word;
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  String _truncate(String text, int width) {
    return text.length > width ? text.substring(0, width) : text;
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
}
