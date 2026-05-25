import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmi_printer_plus/sunmi_printer_plus.dart';
import 'package:sunmi_printer_plus/enums.dart';
import 'package:sunmi_printer_plus/sunmi_style.dart';
import 'package:flutter/foundation.dart';

import '../api/kiosk_api.dart';
import '../core/receipt_print_mode.dart';
import 'epson_usb_printer_service.dart';

enum PrinterType { internal, usb, lan }

enum PrinterStatus { online, offline, notConfigured }

class PrinterService {
  final _usbService = EpsonUSBPrinterService();
  static const _usbPrinterConfigKey = "selected_usb_printer";

  bool _isTakeAwayOrder(String? orderType) {
    final v = orderType?.toLowerCase() ?? "";
    return v.contains("take") || v.contains("pickup");
  }

  num _parcelTotalFromCart(List<Map<String, dynamic>> cartItems) {
    num total = 0;
    for (final item in cartItems) {
      final qty = (item["qty"] as num?)?.toInt() ?? 0;
      final num charge = item["take_away_charge"] is num
          ? item["take_away_charge"] as num
          : num.tryParse(
                "${item["take_away_charge"] ?? item["parcel_charge"] ?? item["parcelCharge"] ?? item["takeaway_charge"]}",
              ) ??
              0;
      if (charge > 0) total += charge * qty;
    }
    return total;
  }

  bool _hasParcelLine(List<dynamic> printObject) {
    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString().toLowerCase() ?? '';
        if (text.contains('parcel') && text.contains('charge')) {
          return true;
        }
      }
    }
    return false;
  }

  List<dynamic> _injectParcelLine(
    List<dynamic> printObject,
    num parcelTotal,
  ) {
    if (parcelTotal <= 0 || _hasParcelLine(printObject)) return printObject;
    final line =
        "Parcel Charges".padRight(22) + "Rs ${parcelTotal.toStringAsFixed(2)}";
    final entry = {
      'type': 'text',
      'text': line,
      'options': {'align': 0},
    };
    final out = List<dynamic>.from(printObject);
    int insertAt = out.length;
    for (int i = 0; i < out.length; i++) {
      final e = out[i];
      if (e is Map && e['type'] == 'text') {
        final t = e['text']?.toString().toLowerCase() ?? '';
        if (t.contains('total')) {
          insertAt = i;
          break;
        }
      }
    }
    out.insert(insertAt, entry);
    out.insert(insertAt + 1, {'type': 'feedLine'});
    return out;
  }

  List<dynamic> _clonePrintObject(List<dynamic> printObject) {
    try {
      final encoded = jsonEncode(printObject);
      final decoded = jsonDecode(encoded);
      if (decoded is List) return List<dynamic>.from(decoded);
    } catch (_) {}
    return List<dynamic>.from(printObject);
  }

  List<dynamic> _withCounterCopyHeader(
    List<dynamic> printObject, {
    required bool showParcel,
  }) {
    final cloned = _clonePrintObject(printObject);
    final header = <Map<String, dynamic>>[];
    if (showParcel) {
      header.add({
        'type': 'text',
        'text': 'PARCEL',
        'options': {'align': 1, 'bold': true},
      });
      header.add({'type': 'feedLine'});
    }
    header.add({
      'type': 'text',
      'text': 'COUNTER COPY',
      'options': {'align': 1, 'bold': true},
    });
    header.add({'type': 'feedLine'});
    return [...header, ...cloned];
  }

  bool _hasCounterLabel(List<dynamic> printObject) {
    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString().toLowerCase() ?? '';
        if (text.contains('counter copy')) return true;
      }
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> getUsbPrinters() async {
    final printers = await _usbService.getPrinterList();
    final onlyPrinters = printers.where((p) => p['isPrinter'] == true).toList();
    return onlyPrinters.isNotEmpty ? onlyPrinters : printers;
  }

  Future<Map<String, dynamic>?> getSelectedUsbPrinter() async {
    return _getSelectedUsbPrinter();
  }

  // ================= STATUS =================
  Future<PrinterStatus> getPrinterStatus() async {
    final type = await _getPrinterType();
    if (type == null) return PrinterStatus.notConfigured;

    switch (type) {
      case PrinterType.internal:
        try {
          final bind = await SunmiPrinter.bindingPrinter();
          return bind == true ? PrinterStatus.online : PrinterStatus.offline;
        } catch (_) {
          return PrinterStatus.offline;
        }

      case PrinterType.usb:
        try {
          final selected = await _getSelectedUsbPrinter();
          if (selected == null) return PrinterStatus.notConfigured;

          final status = await _usbService.queryStatus(printer: selected);
          return status == 'PRINT_NORMAL'
              ? PrinterStatus.online
              : PrinterStatus.offline;
        } catch (_) {
          return PrinterStatus.offline;
        }

      case PrinterType.lan:
        try {
          await KioskApi().pingDevice();
          return PrinterStatus.online;
        } catch (_) {
          return PrinterStatus.offline;
        }
    }
  }

  // ================= TEST PRINT =================
  Future<void> testPrint({
    required String restaurantName,
    String? address,
  }) async {
    final type = await _getPrinterType();
    if (type == PrinterType.lan) {
      throw Exception("Test print not supported for LAN printer");
    }

    final testData = _buildCompactTestPrintObject(
      restaurantName: restaurantName,
      address: address,
    );

    if (type == PrinterType.internal) {
      await _printWithSunmi(testData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) {
        throw Exception("No USB printer selected");
      }
      final usbData = testData.map(_mapForUsb).toList();
      await _usbService.printData(
        printer: printer,
        printObject: usbData,
      );
      return;
    }
  }

  // ================= RECEIPT PRINT =================
  Future<void> printOrder({
    required int orderId,
    required List<Map<String, dynamic>> cartItems,
    String? restaurantName,
    String? address,
    String? taxId,
    String? paymentMode,
    String? transactionId,
    DateTime? orderDate,
    num? taxAmount,
    num? discountAmount,
    List<String>? footerLines,
    String? orderType,
    bool forceLocal = false,
    bool requireBothCopies = false,
    bool counterCopyLabel = false,
    bool removeTaxLines = false,
    num? parcelTotalOverride,
  }) async {
    final type = await _getPrinterType();
    final receiptMode = await ReceiptPrintMode.getStoredMode();
    final bool shouldForceLocal = forceLocal;
    final num parcelTotal =
        parcelTotalOverride ?? _parcelTotalFromCart(cartItems);

    // ================= INTERNAL (Sunmi) =================
    if (type == PrinterType.internal) {
      if (!shouldForceLocal && orderId > 0) {
        try {
          final res = await KioskApi().printReceipt(orderId);
          final data = res.data;
          var printObjects = _extractBackendPrintObjects(data);
          if (requireBothCopies) {
            if (printObjects.length == 1) {
              final clone = counterCopyLabel
                  ? _withCounterCopyHeader(
                      printObjects.first,
                      showParcel: _isTakeAwayOrder(orderType),
                    )
                  : _clonePrintObject(printObjects.first);
              printObjects.add(clone);
            } else if (counterCopyLabel && printObjects.length >= 2) {
              if (!_hasCounterLabel(printObjects[1])) {
                printObjects[1] = _withCounterCopyHeader(
                  printObjects[1],
                  showParcel: _isTakeAwayOrder(orderType),
                );
              }
            }
          }
          if (removeTaxLines) {
            printObjects = printObjects.map(_removeTaxLines).toList();
          }
          if (parcelTotal > 0) {
            printObjects = printObjects
                .map((p) => _injectParcelLine(p, parcelTotal))
                .toList();
          }
          if (printObjects.isNotEmpty) {
            for (final obj in printObjects) {
              await _printWithSunmiRaw(obj);
            }
            return;
          }
        } catch (_) {
          // Silent fallback to local builder
        }
      }

      final receiptData = await compute(_buildReceiptIsolate, {
        "orderId": orderId,
        "cartItems": cartItems,
        "restaurantName": restaurantName ?? "SELFX",
        "address": address,
        "taxId": taxId,
        "paymentMode": paymentMode ?? "PAID",
        "transactionId": transactionId,
        "orderDate": orderDate?.millisecondsSinceEpoch,
        "taxAmount": taxAmount,
        "discountAmount": discountAmount,
        "footerLines": footerLines,
        "orderType": orderType,
        "receiptMode": receiptMode,
        "removeTaxLines": removeTaxLines,
      });

      await _printWithSunmi(receiptData);
      return;
    }

    // ================= USB PRINTER =================
    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      // ---- Prefer backend (Angular behavior) ----
      if (!shouldForceLocal && orderId > 0) {
        try {
          final res = await KioskApi().printReceipt(orderId);
          final data = res.data;

          var printObjects = _extractBackendPrintObjects(data);
          if (requireBothCopies) {
            if (printObjects.length == 1) {
              final clone = counterCopyLabel
                  ? _withCounterCopyHeader(
                      printObjects.first,
                      showParcel: _isTakeAwayOrder(orderType),
                    )
                  : _clonePrintObject(printObjects.first);
              printObjects.add(clone);
            } else if (counterCopyLabel && printObjects.length >= 2) {
              if (!_hasCounterLabel(printObjects[1])) {
                printObjects[1] = _withCounterCopyHeader(
                  printObjects[1],
                  showParcel: _isTakeAwayOrder(orderType),
                );
              }
            }
          }
          if (removeTaxLines) {
            printObjects = printObjects.map(_removeTaxLines).toList();
          }
          if (parcelTotal > 0) {
            printObjects = printObjects
                .map((p) => _injectParcelLine(p, parcelTotal))
                .toList();
          }
          if (printObjects.isNotEmpty) {
            for (final obj in printObjects) {
              await _usbService.printRawPrintObject(
                printer: printer,
                printObject: obj,
              );
            }
            return;
          }
        } catch (e) {
          // Silent fallback to local builder
        }
      }

      // ---- Fallback (offline / API failed) ----
      final fallbackData = await compute(_buildUsbReceiptIsolate, {
        "restaurantName": restaurantName ?? "SELFX",
        "address": address,
        "taxId": taxId,
        "orderId": orderId,
        "orderDate": orderDate?.millisecondsSinceEpoch,
        "transactionId": transactionId,
        "paymentMode": paymentMode ?? "PAID",
        "cartItems": cartItems,
        "taxAmount": taxAmount,
        "discountAmount": discountAmount,
        "footerLines": footerLines,
        "orderType": orderType,
        "receiptMode": receiptMode,
        "removeTaxLines": removeTaxLines,
      });

      await _usbService.printData(printer: printer, printObject: fallbackData);
      return;
    }

    // ================= LAN PRINTER =================
    if (type == PrinterType.lan) {
      // Angular behavior: backend handles printing
      if (orderId > 0) {
        await KioskApi().printReceipt(orderId);
      }
      return;
    }
  }

  // ================= DAILY SUMMARY PRINT =================
  Future<void> printDailySummary({
    required String title,
    required String fromDate,
    required String toDate,
    required int totalOrders,
    required num totalRevenue,
    String? restaurantName,
    String? address,
  }) async {
    final type = await _getPrinterType();

    final receiptData = await compute(_buildSummaryReceiptIsolate, {
      "title": title,
      "fromDate": fromDate,
      "toDate": toDate,
      "totalOrders": totalOrders,
      "totalRevenue": totalRevenue,
      "restaurantName": restaurantName ?? "SELFX",
      "address": address,
    });

    if (type == PrinterType.internal) {
      await _printWithSunmi(receiptData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      final usbData = receiptData.map(_mapForUsb).toList();

      await _usbService.printData(printer: printer, printObject: usbData);
      return;
    }
  }

  // ================= ITEM SALES REPORT (PER ITEM LINES) =================
  Future<void> printItemSalesReport({
    required String title,
    required String fromDate,
    required String toDate,
    required List<Map<String, dynamic>> items,
    required int totalItems,
    required num totalAmount,
    String? restaurantName,
    String? address,
    String? taxId,
  }) async {
    final type = await _getPrinterType();

    final receiptData = await compute(_buildItemSalesReportIsolate, {
      "title": title,
      "fromDate": fromDate,
      "toDate": toDate,
      "items": items,
      "totalItems": totalItems,
      "totalAmount": totalAmount,
      "restaurantName": restaurantName ?? "SELFX",
      "address": address,
      "taxId": taxId,
    });

    if (type == PrinterType.internal) {
      await _printWithSunmi(receiptData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      final usbData = receiptData.map(_mapForUsb).toList();

      await _usbService.printData(printer: printer, printObject: usbData);
      return;
    }
  }

  // ================= CATEGORY SUMMARY REPORT =================
  Future<void> printCategorySalesReport({
    required String title,
    required String fromDate,
    required String toDate,
    required Map<String, List<Map<String, dynamic>>> itemsByCategory,
    required int totalItems,
    required num totalAmount,
    String? restaurantName,
    String? address,
    String? taxId,
  }) async {
    final type = await _getPrinterType();

    final receiptData = await compute(_buildCategorySalesReportIsolate, {
      "title": title,
      "fromDate": fromDate,
      "toDate": toDate,
      "itemsByCategory": itemsByCategory,
      "totalItems": totalItems,
      "totalAmount": totalAmount,
      "restaurantName": restaurantName ?? "SELFX",
      "address": address,
      "taxId": taxId,
    });

    if (type == PrinterType.internal) {
      await _printWithSunmi(receiptData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      final usbData = receiptData.map(_mapForUsb).toList();

      await _usbService.printData(printer: printer, printObject: usbData);
      return;
    }
  }

  // ================= CATEGORY TOTALS ONLY REPORT =================
  Future<void> printCategoryTotalsReport({
    required String title,
    required String fromDate,
    required String toDate,
    required List<Map<String, dynamic>> categoryTotals,
    Map<String, List<Map<String, dynamic>>>? itemsByCategory,
    required int totalItems,
    required num totalAmount,
    String? restaurantName,
    String? address,
    String? taxId,
  }) async {
    final type = await _getPrinterType();

    final receiptData = await compute(_buildCategoryTotalsReportIsolate, {
      "title": title,
      "fromDate": fromDate,
      "toDate": toDate,
      "categoryTotals": categoryTotals,
      "itemsByCategory": itemsByCategory,
      "totalItems": totalItems,
      "totalAmount": totalAmount,
      "restaurantName": restaurantName ?? "SELFX",
      "address": address,
      "taxId": taxId,
    });

    if (type == PrinterType.internal) {
      await _printWithSunmi(receiptData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      final usbData = receiptData.map(_mapForUsb).toList();

      await _usbService.printData(printer: printer, printObject: usbData);
      return;
    }
  }

  // ================= CATEGORY SUMMARY (SINGLE DAY) =================
  Future<void> printCategoryDaySummaryReport({
    required String dateLabel,
    required List<Map<String, dynamic>> categoryTotals,
    required int totalItems,
    required num totalAmount,
    required String restaurantName,
    String? address,
    String? taxId,
  }) async {
    final type = await _getPrinterType();

    final receiptData = await compute(_buildCategoryDaySummaryReportIsolate, {
      "dateLabel": dateLabel,
      "categoryTotals": categoryTotals,
      "totalItems": totalItems,
      "totalAmount": totalAmount,
      "restaurantName": restaurantName,
      "address": address,
      "taxId": taxId,
    });

    if (type == PrinterType.internal) {
      await _printWithSunmi(receiptData);
      return;
    }

    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) return;

      final usbData = receiptData.map(_mapForUsb).toList();
      await _usbService.printData(printer: printer, printObject: usbData);
      return;
    }
  }

  // ================= HELPERS =================
  Future<PrinterType?> _getPrinterType() async {
    final prefs = await SharedPreferences.getInstance();
    final type = prefs.getString("printer_type");
    if (type == null) return null;

    return PrinterType.values.firstWhere(
      (e) => e.name == type,
      orElse: () => PrinterType.internal,
    );
  }

  // ===== MAP COMMON FORMAT → USB FORMAT =====
  Map<String, dynamic> _mapForUsb(Map<String, dynamic> item) {
    if (item['type'] != 'text') return item;

    final options = item['options'] ?? {};
    return {
      ...item,
      'options': {
        'align': options['align'] ?? 0,
        'fontStyle': options['bold'] == true ? 1 : 0,
        'widthTimes': options['size'] == 'lg' ? 1 : 0,
        'heightTimes': options['size'] == 'lg' ? 1 : 0,
      },
    };
  }

  Future<Map<String, dynamic>?> _getSelectedUsbPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_usbPrinterConfigKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveSelectedUsbPrinter(Map<String, dynamic> printer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usbPrinterConfigKey, jsonEncode(printer));
    await _usbService.setSelectedPrinter(printer);
    await _usbService.scanAndConnect();
  }

  Future<Map<String, dynamic>?> _resolveUsbPrinter({
    required bool allowAutoSelect,
  }) async {
    final saved = await _getSelectedUsbPrinter();
    if (saved != null) return saved;
    if (!allowAutoSelect) return null;

    final printers = await _usbService.getPrinterList();
    if (printers.isEmpty) return null;

    if (printers.length == 1) {
      await saveSelectedUsbPrinter(printers.first);
      return printers.first;
    }
    return null;
  }

  // ================= SUNMI =================
  List<Map<String, dynamic>> _buildCompactTestPrintObject({
    required String restaurantName,
    String? address,
  }) {
    const int width = 32;
    final now = DateTime.now();
    final printedAt =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";
    final lines = <Map<String, dynamic>>[];

    void add(String text, {int align = 0, bool bold = false}) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': 'md'},
      });
      lines.add({'type': 'feedLine'});
    }

    String center(String text) {
      if (text.length >= width) return text;
      final left = ((width - text.length) / 2).floor();
      final right = width - text.length - left;
      return (" " * left) + text + (" " * right);
    }

    String divider() => "-" * width;

    final name =
        restaurantName.trim().isEmpty ? "Restaurant" : restaurantName.trim();
    for (final part in _wrap(name, width)) {
      add(center(part), align: 1, bold: true);
    }
    if (address != null && address.trim().isNotEmpty) {
      for (final part in _wrap(address.trim(), width).take(2)) {
        add(center(part), align: 1);
      }
    }
    add(divider());
    add(center("TEST PRINT"), align: 1, bold: true);
    add(center("Printer configured"), align: 1);
    add(center(printedAt), align: 1);
    add(divider());

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});
    return lines;
  }

  Future<void> _printWithSunmi(List<Map<String, dynamic>> printObject) async {
    await SunmiPrinter.bindingPrinter();
    await SunmiPrinter.initPrinter();

    for (final item in printObject) {
      if (item['type'] == 'text') {
        final options = item['options'] is Map
            ? Map<String, dynamic>.from(item['options'])
            : {};
        final align = _toInt(options['align']) ?? 0;
        final bold =
            options['bold'] == true || (_toInt(options['fontStyle']) ?? 0) > 0;
        final size = options['size']?.toString();
        final large = size == 'lg' ||
            (_toInt(options['widthTimes']) ?? 0) > 0 ||
            (_toInt(options['heightTimes']) ?? 0) > 0;
        await _sunmiPrintText(
          (item['text'] ?? '').toString(),
          align: align,
          bold: bold,
          large: large,
        );
      } else if (item['type'] == 'dottedLine') {
        await _sunmiPrintText("--------------------------------", align: 0);
      } else if (item['type'] == 'feedLine') {
        await SunmiPrinter.lineWrap(1);
      } else if (item['type'] == 'halfCutPaper' ||
          item['type'] == 'fullCutPaper') {
        await SunmiPrinter.lineWrap(2);
        try {
          await SunmiPrinter.cut();
        } catch (_) {}
      }
    }
    await SunmiPrinter.lineWrap(3);
  }

  Future<void> _printWithSunmiRaw(List<dynamic> printObject) async {
    await SunmiPrinter.bindingPrinter();
    await SunmiPrinter.initPrinter();

    const int width = 32;
    final maxNOrgx = _maxNOrgx(printObject);

    List<String> buffer = List.filled(width, ' ');
    bool hasContent = false;
    bool lineLarge = false;
    bool lineBold = false;

    void resetBuffer() {
      buffer = List.filled(width, ' ');
      hasContent = false;
      lineLarge = false;
      lineBold = false;
    }

    Future<void> flushLine({bool forceLine = false}) async {
      if (!hasContent && !forceLine) return;
      if (!hasContent && forceLine) {
        await SunmiPrinter.lineWrap(1);
        resetBuffer();
        return;
      }
      final raw = buffer.join();
      final line = raw.replaceFirst(RegExp(r'\s+$'), '');
      await _sunmiPrintText(
        line,
        align: 0,
        bold: lineBold,
        large: lineLarge,
      );
      resetBuffer();
    }

    void insertAt(int pos, String text) {
      if (text.isEmpty) return;
      final clampedPos = pos.clamp(0, width - 1);
      final maxLen = width - clampedPos;
      final slice = text.length > maxLen ? text.substring(0, maxLen) : text;
      for (int i = 0; i < slice.length; i++) {
        buffer[clampedPos + i] = slice[i];
      }
      hasContent = true;
    }

    for (final entry in printObject) {
      if (entry is! Map) continue;
      final type = entry['type'];

      if (type == 'text') {
        final options = entry['options'] is Map
            ? Map<String, dynamic>.from(entry['options'])
            : <String, dynamic>{};
        final align = _toInt(options['align']) ?? 0;
        final nOrgx = _toInt(options['nOrgx']) ?? 0;
        final widthTimes = _toInt(options['widthTimes']) ?? 0;
        final heightTimes = _toInt(options['heightTimes']) ?? 0;
        final fontStyle = _toInt(options['fontStyle']) ?? 0;
        final bold = fontStyle > 0 || options['bold'] == true;
        final large = widthTimes > 0 ||
            heightTimes > 0 ||
            options['size']?.toString() == 'lg';
        final text = (entry['text'] ?? '').toString();

        if (align != 0) {
          await flushLine();
          final parts = text.split(RegExp(r'\r?\n'));
          for (final part in parts) {
            await _sunmiPrintText(
              part,
              align: align,
              bold: bold,
              large: large,
            );
          }
          continue;
        }

        final parts = text.split(RegExp(r'\r?\n'));
        for (int i = 0; i < parts.length; i++) {
          final part = parts[i];
          if (part.isNotEmpty) {
            final pos = _mapOrgxToChar(nOrgx, maxNOrgx, width);
            insertAt(pos, part);
          }
          lineLarge = lineLarge || large;
          lineBold = lineBold || bold;
          if (i < parts.length - 1) {
            await flushLine(forceLine: true);
          }
        }
      } else if (type == 'dottedLine') {
        await flushLine();
        await _sunmiPrintText('-' * width, align: 0);
      } else if (type == 'feedLine') {
        await flushLine();
        await SunmiPrinter.lineWrap(1);
      } else if (type == 'halfCutPaper' || type == 'fullCutPaper') {
        await flushLine();
        await SunmiPrinter.lineWrap(2);
        try {
          await SunmiPrinter.cut();
        } catch (_) {}
      }
    }

    await flushLine();
    await SunmiPrinter.lineWrap(1);
  }

  Future<void> _sunmiTestPrint(String restaurantName) async {
    await SunmiPrinter.bindingPrinter();
    await SunmiPrinter.initPrinter();

    await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
    await SunmiPrinter.printText(
      "$restaurantName\n",
      style: SunmiStyle(bold: true, fontSize: SunmiFontSize.LG),
    );
    await SunmiPrinter.printText("SUNMI TEST PRINT SUCCESS\n");
    await SunmiPrinter.lineWrap(3);
  }

  List<Map<String, dynamic>> _buildReceipt({
    required int orderId,
    required List<Map<String, dynamic>> cartItems,
    required String restaurantName,
    String? address,
    String? taxId,
    String? paymentMode,
    String? transactionId,
    DateTime? orderDate,
    num? taxAmount,
    num? discountAmount,
    List<String>? footerLines,
  }) {
    const int width = 32;
    final dt = orderDate ?? DateTime.now();
    final dateTime =
        "${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}";

    final List<Map<String, dynamic>> lines = [];

    void add(
      String text, {
      int align = 0,
      bool bold = false,
      String size = 'md',
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': size},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => '-' * width;

    String center(String t) => t.length >= width
        ? t
        : t.padLeft((width + t.length) ~/ 2).padRight(width);

    String lr(String l, String r) =>
        l.padRight(width - r.length).substring(0, width - r.length) + r;

    String money(num v) => "Rs ${v.toStringAsFixed(2)}";

    String itemRow(String n, String q, String p, String t) {
      return _truncate(n, 16).padRight(16) +
          q.padLeft(4) +
          p.padLeft(6) +
          t.padLeft(6);
    }

    // ================= HEADER =================
    add(center(restaurantName), align: 1, bold: true, size: 'lg');

    if (address?.isNotEmpty == true) {
      for (final l in _wrap(address!, width)) {
        add(center(l), align: 1);
      }
    }

    if (taxId?.isNotEmpty == true) {
      add(center("GST: $taxId"), align: 1);
    }

    add(center("SELFX ORDER #$orderId"), align: 1, bold: true);
    add(divider());

    add(lr("Order No", orderId.toString()));
    add(lr("Date", dateTime));

    if (transactionId?.isNotEmpty == true) {
      final txn = transactionId!;
      final shortTxn = txn.length > 16 ? txn.substring(txn.length - 16) : txn;
      add(lr("Txn ID", shortTxn));
      ;
    }

    if (paymentMode?.isNotEmpty == true) {
      add(lr("Payment", paymentMode!));
    }

    add(divider());
    add(itemRow("ITEM", "QTY", "RATE", "AMT"), bold: true);
    add(divider());

    // ================= ITEMS =================
    String? currentCategory;
    num categoryTotal = 0;
    num grandTotal = 0;

    for (final item in cartItems) {
      final category = item['category']?.toString();
      final qty = (item['qty'] ?? 0).toInt();
      final price = (item['price'] ?? 0);
      final total = qty * price;

      if (category != null && category != currentCategory) {
        if (currentCategory != null) {
          add(lr("Category Total", money(categoryTotal)), bold: true);
          add(divider());
          grandTotal += categoryTotal;
        }

        currentCategory = category;
        categoryTotal = 0;

        add(category.toUpperCase(), bold: true);
        add(divider());
      }

      categoryTotal += total;
      add(
        itemRow(
          item['name'] ?? 'Item',
          qty.toString(),
          price.toStringAsFixed(2),
          total.toStringAsFixed(2),
        ),
      );
    }

    if (currentCategory != null) {
      add(lr("Category Total", money(categoryTotal)), bold: true);
      add(divider());
      grandTotal += categoryTotal;
    }

    // ================= TOTALS =================
    final tax = taxAmount ?? 0;
    final discount = discountAmount ?? 0;
    final payable = grandTotal + tax - discount;

    if (tax > 0) add(lr("Tax", money(tax)));
    if (discount > 0) add(lr("Discount", money(discount)));
    add(lr("GRAND TOTAL", money(payable)), bold: true);

    add(divider());

    // ================= FOOTER =================
    final footer = footerLines ?? ["Thank you for your order!"];
    for (final f in footer) {
      add(center(f), align: 1);
    }

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  List<Map<String, dynamic>> _buildSummaryReceipt({
    required String title,
    required String fromDate,
    required String toDate,
    required int totalOrders,
    required num totalRevenue,
    required String restaurantName,
    String? address,
  }) {
    const int width = 32;
    final now = DateTime.now();
    final printedAt =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";

    final List<Map<String, dynamic>> lines = [];

    void addLine(
      String text, {
      int align = 0,
      bool bold = false,
      bool large = false,
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => "-" * width;
    String center(String text) {
      if (text.length >= width) return text;
      final left = ((width - text.length) / 2).floor();
      final right = width - text.length - left;
      return (" " * left) + text + (" " * right);
    }

    String lineLR(String left, String right) {
      final maxLeft = width - right.length;
      final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
      return l.padRight(width - right.length) + right;
    }

    String money(num value) {
      return "Rs ${value.toStringAsFixed(2)}";
    }

    final titleText = restaurantName.trim();
    if (titleText.length <= 16) {
      addLine(center(titleText), align: 1, bold: true, large: true);
    } else {
      for (final part in _wrap(titleText, width)) {
        addLine(center(part), align: 1, bold: true);
      }
    }

    if (address != null && address.trim().isNotEmpty) {
      for (final part in _wrap(address.trim(), width)) {
        addLine(center(part), align: 1);
      }
    }

    addLine(divider());
    addLine(center("DAILY SUMMARY"), align: 1, bold: true);
    addLine(center(title.toUpperCase()), align: 1);
    addLine(divider());
    addLine(lineLR("From", fromDate));
    addLine(lineLR("To", toDate));
    addLine(lineLR("Printed", printedAt));
    addLine(divider());
    addLine(lineLR("Orders (Bills)", totalOrders.toString()), bold: true);
    addLine(lineLR("Total Revenue", money(totalRevenue)), bold: true);
    addLine(divider());
    addLine(center("Thank you for your order!"), align: 1);

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  List<Map<String, dynamic>> _buildItemSalesReport({
    required String title,
    required String fromDate,
    required String toDate,
    required List<Map<String, dynamic>> items,
    required int totalItems,
    required num totalAmount,
    required String restaurantName,
    String? address,
    String? taxId,
  }) {
    const int width = 32;
    final now = DateTime.now();
    final printedAt =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";

    final List<Map<String, dynamic>> lines = [];

    void addLine(
      String text, {
      int align = 0,
      bool bold = false,
      bool large = false,
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => "-" * width;
    String center(String text) {
      if (text.length >= width) return text;
      final left = ((width - text.length) / 2).floor();
      final right = width - text.length - left;
      return (" " * left) + text + (" " * right);
    }

    String lineLR(String left, String right) {
      final maxLeft = width - right.length;
      final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
      return l.padRight(width - right.length) + right;
    }

    String money(num value) {
      return "Rs ${value.toStringAsFixed(2)}";
    }

    final titleText = restaurantName.trim();
    if (titleText.length <= 16) {
      addLine(center(titleText), align: 1, bold: true, large: true);
    } else {
      for (final part in _wrap(titleText, width)) {
        addLine(center(part), align: 1, bold: true);
      }
    }

    if (address != null && address.trim().isNotEmpty) {
      for (final part in _wrap(address.trim(), width)) {
        addLine(center(part), align: 1);
      }
    }
    if (taxId != null && taxId.trim().isNotEmpty) {
      addLine(center("GST: $taxId"), align: 1);
    }

    addLine(divider());
    addLine(center("ITEM SALES REPORT"), align: 1, bold: true);
    addLine(center(title.toUpperCase()), align: 1);
    addLine(divider());
    addLine(lineLR("From", fromDate));
    addLine(lineLR("To", toDate));
    addLine(lineLR("Printed", printedAt));
    addLine(divider());
    addLine(lineLR("ITEM", "PRICE"), bold: true);

    for (final item in items) {
      final name = item["name"]?.toString() ?? "Item";
      final price = item["price"] is num
          ? item["price"] as num
          : num.tryParse("${item["price"]}") ?? 0;
      addLine(lineLR(_truncate(name, width - 10), money(price)));
    }

    addLine(divider());
    addLine(lineLR("ITEMS SOLD (QTY)", totalItems.toString()), bold: true);
    addLine(lineLR("TOTAL AMOUNT", money(totalAmount)), bold: true);
    addLine(lineLR("TOTAL REVENUE", money(totalAmount)), bold: true);
    addLine(divider());
    addLine(center("Thank you for your order!"), align: 1);

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'feedLine'});
    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  List<Map<String, dynamic>> _buildCategorySalesReport({
    required String title,
    required String fromDate,
    required String toDate,
    required Map<String, List<Map<String, dynamic>>> itemsByCategory,
    required int totalItems,
    required num totalAmount,
    required String restaurantName,
    String? address,
    String? taxId,
  }) {
    const int width = 32;
    final now = DateTime.now();
    final printedAt =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";

    final List<Map<String, dynamic>> lines = [];

    void add(
      String text, {
      int align = 0,
      bool bold = false,
      String size = 'md',
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': size},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => '-' * width;

    String center(String t) => t.length >= width
        ? t
        : t.padLeft((width + t.length) ~/ 2).padRight(width);

    String lr(String l, String r) =>
        l.padRight(width - r.length).substring(0, width - r.length) + r;

    String money(num v) => v.toStringAsFixed(2);

    String categoryRow(String name, String qty, String amount) {
      return _truncate(name, 16).padRight(16) +
          qty.padLeft(6) +
          amount.padLeft(10);
    }

    // ================= HEADER =================
    add(center(restaurantName), align: 1, bold: true, size: 'lg');

    if (address?.isNotEmpty == true) {
      for (final l in _wrap(address!, width)) {
        add(center(l), align: 1);
      }
    }

    if (taxId?.isNotEmpty == true) {
      add(center("GST: $taxId"), align: 1);
    }

    add(divider());
    add(center("CATEGORY SALES REPORT"), align: 1, bold: true);
    add(center(title.toUpperCase()), align: 1);
    add(divider());

    add(lr("From", fromDate));
    add(lr("To", toDate));
    add(lr("Printed", printedAt));
    add(divider());

    // ================= TABLE HEADER =================
    add(categoryRow("CATEGORY", "ITEMS", "AMOUNT"), bold: true);
    add(divider());

    // ================= CATEGORY SUMMARY =================
    for (final entry in itemsByCategory.entries) {
      final category = entry.key;
      final items = entry.value;

      int qty = 0;
      num amount = 0;

      for (final item in items) {
        qty += (item['qty'] ?? 0) as int;
        amount += (item['total'] ?? 0) as num;
      }

      add(categoryRow(category.toUpperCase(), qty.toString(), money(amount)));
    }

    add(divider());

    // ================= TOTALS =================
    add(lr("ORDERS (BILLS)", totalItems.toString()), bold: true);
    add(lr("TOTAL AMOUNT", "Rs ${money(totalAmount)}"), bold: true);
    add(divider());

    add(center("Thank you!"), align: 1);

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  List<Map<String, dynamic>> _buildCategoryTotalsReport({
    required String title,
    required String fromDate,
    required String toDate,
    required List<Map<String, dynamic>> categoryTotals,
    Map<String, List<Map<String, dynamic>>>? itemsByCategory,
    required int totalItems,
    required num totalAmount,
    required String restaurantName,
    String? address,
    String? taxId,
  }) {
    const int width = 32;
    final now = DateTime.now();
    final printedAt =
        "${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}";

    final List<Map<String, dynamic>> lines = [];

    void addLine(
      String text, {
      int align = 0,
      bool bold = false,
      bool large = false,
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => "-" * width;
    String center(String text) {
      if (text.length >= width) return text;
      final left = ((width - text.length) / 2).floor();
      final right = width - text.length - left;
      return (" " * left) + text + (" " * right);
    }

    String lineLR(String left, String right) {
      final maxLeft = width - right.length;
      final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
      return l.padRight(width - right.length) + right;
    }

    String money(num value) => "Rs ${value.toStringAsFixed(2)}";
    String moneyShort(num value) => value.toStringAsFixed(2);

    String row(String name, String qty, String total) {
      const nameW = 18;
      const qtyW = 4;
      const totalW = 10;
      final n = _truncate(name, nameW).padRight(nameW);
      final q = qty.padLeft(qtyW);
      final t = total.padLeft(totalW);
      return "$n$q$t";
    }

    String itemRow(String name, String qty, String amount) {
      const nameW = 18;
      const qtyW = 4;
      const totalW = 10;
      final n = _truncate(" $name", nameW).padRight(nameW);
      final q = qty.padLeft(qtyW);
      final t = amount.padLeft(totalW);
      return "$n$q$t";
    }

    final titleText = restaurantName.trim();
    if (titleText.length <= 16) {
      addLine(center(titleText), align: 1, bold: true, large: true);
    } else {
      for (final part in _wrap(titleText, width)) {
        addLine(center(part), align: 1, bold: true);
      }
    }

    if (address != null && address.trim().isNotEmpty) {
      final parts = _wrap(address.trim(), width);
      for (final part in parts.take(2)) {
        addLine(center(part), align: 1);
      }
    }
    if (taxId != null && taxId.trim().isNotEmpty) {
      addLine(center("GST: $taxId"), align: 1);
    }

    addLine(divider());
    addLine(center("CATEGORY TOTALS"), align: 1, bold: true);
    addLine(center(title.toUpperCase()), align: 1);
    addLine(divider());
    addLine(lineLR("From", fromDate));
    addLine(lineLR("To", toDate));
    addLine(lineLR("Printed", printedAt));
    addLine(divider());
    addLine(row("CATEGORY", "QTY", "TOTAL"), bold: true);

    for (final entry in categoryTotals) {
      final name = entry["category"]?.toString() ?? "Category";
      final qty = (entry["qty"] as num?)?.toInt() ?? 0;
      final total = entry["total"] is num ? entry["total"] as num : 0;
      addLine(row(name.toUpperCase(), qty.toString(), money(total)));

      final items = itemsByCategory?[name];
      if (items != null && items.isNotEmpty) {
        final hasItemTotals = items.any((item) {
          if (item is! Map) return false;
          return item.containsKey("total") ||
              item.containsKey("amount") ||
              item.containsKey("total_price") ||
              item.containsKey("price") ||
              item.containsKey("unit_price") ||
              item.containsKey("unitPrice");
        });
        if (hasItemTotals) {
          addLine(itemRow("ITEM", "QTY", "AMOUNT"), bold: true);
        }
        for (final item in items) {
          if (item is! Map) continue;
          final itemName = item["name"]?.toString() ?? "Item";
          final itemQty = (item["qty"] as num?)?.toInt() ?? 0;
          if (!hasItemTotals) {
            addLine("  ${itemQty} x $itemName");
            continue;
          }
          final totalRaw = item["total"] ??
              item["amount"] ??
              item["total_price"] ??
              item["totalAmount"];
          final priceRaw = item["price"] ??
              item["unit_price"] ??
              item["unitPrice"] ??
              item["item_price"];
          num totalValue =
              totalRaw is num ? totalRaw : num.tryParse("$totalRaw") ?? 0;
          if (totalValue == 0 && itemQty > 0) {
            final num price =
                priceRaw is num ? priceRaw : num.tryParse("$priceRaw") ?? 0;
            totalValue = price * itemQty;
          }
          addLine(
            itemRow(
              itemName,
              itemQty.toString(),
              moneyShort(totalValue),
            ),
          );
        }
      }
    }

    addLine(divider());
    addLine(lineLR("TOTAL QTY", totalItems.toString()), bold: true);
    addLine(lineLR("TOTAL AMOUNT", money(totalAmount)), bold: true);
    addLine(divider());
    addLine(center("Thank you for your order!"), align: 1);

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

  List<Map<String, dynamic>> _buildCategoryDaySummaryReport({
    required String dateLabel,
    required List<Map<String, dynamic>> categoryTotals,
    required int totalItems,
    required num totalAmount,
    required String restaurantName,
    String? address,
    String? taxId,
  }) {
    const int width = 32;
    final List<Map<String, dynamic>> lines = [];

    void addLine(
      String text, {
      int align = 0,
      bool bold = false,
      String size = 'md',
    }) {
      lines.add({
        'type': 'text',
        'text': text,
        'options': {'align': align, 'bold': bold, 'size': size},
      });
      lines.add({'type': 'feedLine'});
    }

    String divider() => "-" * width;
    String center(String text) {
      if (text.length >= width) return text;
      final left = ((width - text.length) / 2).floor();
      final right = width - text.length - left;
      return (" " * left) + text + (" " * right);
    }

    String money(num value) => "₹${value.toStringAsFixed(2)}";

    final titleText = restaurantName.trim();
    if (titleText.length <= width) {
      addLine(center(titleText), align: 1, bold: true, size: 'lg');
    } else {
      for (final part in _wrap(titleText, width)) {
        addLine(center(part), align: 1, bold: true);
      }
    }

    if (address != null && address.trim().isNotEmpty) {
      final parts = _wrap(address.trim(), width);
      for (final part in parts.take(2)) {
        addLine(center(part), align: 1);
      }
    }
    if (taxId != null && taxId.trim().isNotEmpty) {
      addLine(center("GST: $taxId"), align: 1);
    }

    addLine(divider());
    addLine(center("CATEGORY SUMMARY"), align: 1, bold: true);
    addLine("Date: $dateLabel");
    addLine(divider());

    for (final entry in categoryTotals) {
      final name = entry["category"]?.toString() ?? "Category";
      final qty = (entry["qty"] as num?)?.toInt() ?? 0;
      final total = entry["total"] is num ? entry["total"] as num : 0;

      addLine(name, bold: true);
      addLine("Items: $qty");
      addLine("Amount: ${money(total)}");
      addLine("");
    }

    addLine(divider());
    addLine("Final Total: ${money(totalAmount)}", bold: true);
    addLine(divider());

    lines.add({'type': 'feedLine'});
    lines.add({'type': 'feedLine'});
    lines.add({'type': 'fullCutPaper'});

    return lines;
  }

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

  String _two(int value) => value.toString().padLeft(2, '0');

  List<dynamic> _removeTaxLines(List<dynamic> printObject) {
    return printObject.where((entry) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString().toLowerCase() ?? '';
        final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (normalized.startsWith('gst') ||
            normalized.startsWith('tax') ||
            text.contains('sgst') ||
            text.contains('cgst') ||
            text.contains('igst')) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  List<List<dynamic>> _extractBackendPrintObjects(dynamic data) {
    if (data is! Map) return [];

    final List<List<dynamic>> result = [];

    final rawList = data['printObjects'];
    if (rawList is List && rawList.isNotEmpty) {
      if (rawList.first is List) {
        for (final obj in rawList) {
          if (obj is List) {
            result.add(List<dynamic>.from(obj));
          }
        }
        return result;
      }
      if (rawList.first is Map) {
        result.add(List<dynamic>.from(rawList));
        return result;
      }
    }

    final raw = data['printObject'];
    if (raw is List) {
      result.add(List<dynamic>.from(raw));
    }

    final rawCounter = data['printObjectCounter'];
    if (rawCounter is List) {
      result.add(List<dynamic>.from(rawCounter));
    }

    return result;
  }

  dynamic _sanitizeNullTokens(dynamic value) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.toLowerCase() == "null") return "Parcel Charges";
      if (RegExp(r'\bnull\b', caseSensitive: false).hasMatch(value)) {
        return value.replaceAll(
          RegExp(r'\bnull\b', caseSensitive: false),
          "Parcel Charges",
        );
      }
      return value;
    }
    if (value is List) {
      return value.map(_sanitizeNullTokens).toList();
    }
    if (value is Map) {
      final out = <dynamic, dynamic>{};
      value.forEach((k, v) {
        out[k] = _sanitizeNullTokens(v);
      });
      return out;
    }
    return value;
  }

  List<dynamic> _sanitizePrintObject(List<dynamic> printObject) {
    final List<dynamic> sanitized = [];
    bool isCounterCopy = false;
    bool hasParcelHeader = false;
    bool hasPaymentSuccess = false;
    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final t = entry['text']?.toString().trim().toLowerCase() ?? '';
        if (t.contains('counter copy') ||
            t.endsWith('counter') ||
            t == 'counter') {
          isCounterCopy = true;
        }
        if (t == 'parcel' || (t.contains('parcel') && !t.contains('charge'))) {
          hasParcelHeader = true;
        }
        if (t.contains('payment successful')) {
          hasPaymentSuccess = true;
        }
      }
    }

    if (isCounterCopy) {
      if (!hasParcelHeader) {
        sanitized.add({
          'type': 'text',
          'text': 'PARCEL',
          'options': {'align': 1, 'bold': true, 'size': 'lg'},
        });
        sanitized.add({'type': 'feedLine'});
      }
      if (!hasPaymentSuccess) {
        sanitized.add({
          'type': 'text',
          'text': 'PAYMENT SUCCESSFUL',
          'options': {'align': 1, 'bold': true},
        });
        sanitized.add({'type': 'feedLine'});
      }
    }

    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final raw = entry['text'];
        final rawText = raw?.toString() ?? '';
        final lower = rawText.trim().toLowerCase();
        if (lower == 'parcel' ||
            (lower.contains('parcel') && !lower.contains('charge'))) {
          final cleaned = _sanitizeNullTokens(entry);
          if (cleaned is Map) {
            final options = cleaned['options'];
            if (options is Map) {
              options['bold'] = true;
              options['size'] = options['size'] ?? 'lg';
              options['align'] = options['align'] ?? 1;
            } else {
              cleaned['options'] = {'align': 1, 'bold': true, 'size': 'lg'};
            }
          }
          sanitized.add(cleaned);
          continue;
        }
        if (lower.contains('payment successful')) {
          final cleaned = _sanitizeNullTokens(entry);
          if (cleaned is Map) {
            final options = cleaned['options'];
            if (options is Map) {
              options['bold'] = true;
              options['align'] = options['align'] ?? 1;
            } else {
              cleaned['options'] = {'align': 1, 'bold': true};
            }
          }
          sanitized.add(cleaned);
          continue;
        }
        if (lower.contains('sgst') || lower.contains('igst')) {
          continue;
        }
        final cleaned = _sanitizeNullTokens(entry);
        if (cleaned is Map && cleaned['type'] == 'text') {
          final text = cleaned['text'];
          if (text == null || text.toString().trim().isEmpty) {
            cleaned['text'] = "Parcel Charges";
          }
        }
        sanitized.add(cleaned);
        continue;
      }
      sanitized.add(_sanitizeNullTokens(entry));
    }
    return sanitized;
  }

  int _maxNOrgx(List<dynamic> printObject) {
    int maxX = 0;
    for (final entry in printObject) {
      if (entry is Map) {
        final options = entry['options'];
        if (options is Map) {
          final nOrgx = _toInt(options['nOrgx']) ?? 0;
          if (nOrgx > maxX) maxX = nOrgx;
        }
      }
    }
    return maxX;
  }

  int _mapOrgxToChar(int nOrgx, int maxNOrgx, int width) {
    if (maxNOrgx <= 0 || width <= 1) return 0;
    final scaled = (nOrgx * (width - 1) / maxNOrgx).round();
    if (scaled < 0) return 0;
    if (scaled > width - 1) return width - 1;
    return scaled;
  }

  Future<void> _sunmiPrintText(
    String text, {
    required int align,
    bool bold = false,
    bool large = false,
  }) async {
    await SunmiPrinter.setAlignment(_toSunmiAlign(align));
    final style = (bold || large)
        ? SunmiStyle(
            bold: bold ? true : null,
            fontSize: large ? SunmiFontSize.LG : null,
          )
        : null;
    await SunmiPrinter.printText(text, style: style);
  }

  SunmiPrintAlign _toSunmiAlign(int align) {
    switch (align) {
      case 1:
        return SunmiPrintAlign.CENTER;
      case 2:
        return SunmiPrintAlign.RIGHT;
      default:
        return SunmiPrintAlign.LEFT;
    }
  }

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
}

List<Map<String, dynamic>> _buildReceiptIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final int? millis = args["orderDate"] as int?;
  final dt = millis != null
      ? DateTime.fromMillisecondsSinceEpoch(millis)
      : DateTime.now();
  final dateTime = "${dt.year}-${_twoIsolate(dt.month)}-${_twoIsolate(dt.day)} "
      "${_twoIsolate(dt.hour)}:${_twoIsolate(dt.minute)}";

  final List<Map<String, dynamic>> lines = [];

  void add(
    String text, {
    int align = 0,
    bool bold = false,
    String size = 'md',
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': size},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => '-' * width;

  String center(String t) => t.length >= width
      ? t
      : t.padLeft((width + t.length) ~/ 2).padRight(width);

  String lr(String l, String r) =>
      l.padRight(width - r.length).substring(0, width - r.length) + r;

  String money(num v) => "Rs ${v.toStringAsFixed(2)}";

  String itemRow(String n, String q, String p, String t) {
    return _truncateIsolate(n, 16).padRight(16) +
        q.padLeft(4) +
        p.padLeft(6) +
        t.padLeft(6);
  }

  final String restaurantName = (args["restaurantName"] ?? "SELFX").toString();
  final String? address = args["address"]?.toString();
  final String? taxId = args["taxId"]?.toString();
  final String paymentMode = (args["paymentMode"] ?? "PAID").toString();
  final String? transactionId = args["transactionId"]?.toString();
  final int orderId = (args["orderId"] as num?)?.toInt() ?? 0;
  final List cartItems = args["cartItems"] as List? ?? const [];
  final num tax = (args["taxAmount"] as num?) ?? 0;
  final num discount = (args["discountAmount"] as num?) ?? 0;
  final List footerLines =
      args["footerLines"] as List? ?? const ["Thank you for your order!"];
  final String? orderTypeRaw = args["orderType"]?.toString();
  final String? receiptModeRaw = args["receiptMode"]?.toString();
  final bool removeTaxLines = args["removeTaxLines"] == true;

  bool isTakeAway() {
    final v = orderTypeRaw?.toLowerCase() ?? "";
    return v.contains("take") || v.contains("pickup");
  }

  String? receiptMode() {
    if (receiptModeRaw == null || receiptModeRaw!.trim().isEmpty) return null;
    final v = receiptModeRaw!.toLowerCase().trim();
    if (v == "1") return "customer";
    if (v == "2") return "counter";
    if (v == "3") return "both";
    if (v.contains("both") || v.contains("all")) return "both";
    if (v.contains("customer")) return "customer";
    if (v.contains("counter")) return "counter";
    return null;
  }

  final String? mode = receiptMode();
  final bool allowCustomerCopy = mode != "counter";
  final bool allowCounterCopy = mode != "customer";

  String? orderTypeLabel() {
    if (orderTypeRaw == null || orderTypeRaw!.trim().isEmpty) return null;
    final v = orderTypeRaw!.toLowerCase();
    if (v.contains("dine")) return "Dine In";
    if (v.contains("take") || v.contains("pickup")) return "Take Away";
    if (v.contains("deliver")) return "Delivery";
    return orderTypeRaw;
  }

  void buildReceipt({required bool parcelCopy}) {
    // ================= HEADER =================
    if (parcelCopy) {
      if (isTakeAway()) {
        add(center("PARCEL"), align: 1, bold: true, size: 'lg');
      }
      add(center("PAYMENT SUCCESSFUL"), align: 1, bold: true);
      add(center("COUNTER COPY"), align: 1, bold: true);
    }

    add(center(restaurantName), align: 1, bold: true, size: 'lg');

    if (address?.isNotEmpty == true) {
      for (final l in _wrapIsolate(address!, width)) {
        add(center(l), align: 1);
      }
    }

    if (!removeTaxLines && taxId?.isNotEmpty == true) {
      add(center("GST: $taxId"), align: 1);
    }

    add(center("SELFX ORDER #$orderId"), align: 1, bold: true);
    add(divider());

    add(lr("Order No", orderId.toString()));
    add(lr("Date", dateTime));
    final orderLabel = orderTypeLabel();
    if (orderLabel != null && orderLabel.trim().isNotEmpty) {
      add(lr("Order Type", orderLabel));
    }
    if (!parcelCopy && isTakeAway()) {
      add(center("PARCEL"), align: 1, bold: true);
    }

    if (transactionId?.isNotEmpty == true) {
      final txn = transactionId!;
      final shortTxn = txn.length > 16 ? txn.substring(txn.length - 16) : txn;
      add(lr("Txn ID", shortTxn));
    }

    if (paymentMode.isNotEmpty) {
      add(lr("Payment", paymentMode));
    }

    add(divider());
    add(itemRow("ITEM", "QTY", "RATE", "AMT"), bold: true);
    add(divider());

    // ================= ITEMS =================
    String? currentCategory;
    num categoryTotal = 0;
    num grandTotal = 0;
    num parcelTotal = 0;

    for (final item in cartItems) {
      if (item is! Map) continue;
      final category = item['category']?.toString();
      final qty = (item['qty'] as num?)?.toInt() ?? 0;
      num price = item['price'] is num
          ? item['price'] as num
          : num.tryParse("${item['price']}") ?? 0;
      final num parcelCharge = item['take_away_charge'] is num
          ? item['take_away_charge'] as num
          : num.tryParse(
                  "${item['take_away_charge'] ?? item['parcel_charge'] ?? item['parcelCharge'] ?? item['takeaway_charge']}") ??
              0;
      if (parcelCharge > 0) {
        parcelTotal += parcelCharge * qty;
      }
      String name = (item['name'] ?? item['item_name'] ?? '').toString().trim();
      if (name.isEmpty || name.toLowerCase() == "null") {
        name = "Parcel Charges";
        if (price == 0) {
          if (parcelCharge > 0) {
            price = parcelCharge;
          } else {
            final amount = item['amount'] ?? item['total'] ?? item['value'];
            final amtNum = num.tryParse("$amount") ?? 0;
            if (amtNum > 0 && qty > 0) {
              price = amtNum / qty;
            }
          }
        }
      }
      final num total = qty * price;

      if (category != null && category != currentCategory) {
        if (currentCategory != null) {
          add(lr("Category Total", money(categoryTotal)), bold: true);
          add(divider());
          grandTotal += categoryTotal;
        }

        currentCategory = category;
        categoryTotal = 0;

        add(category.toUpperCase(), bold: true);
        add(divider());
      }

      categoryTotal += total;
      add(
        itemRow(
          name,
          qty.toString(),
          price.toStringAsFixed(2),
          total.toStringAsFixed(2),
        ),
      );
    }

    if (currentCategory != null) {
      add(lr("Category Total", money(categoryTotal)), bold: true);
      add(divider());
      grandTotal += categoryTotal;
    }

    // ================= TOTALS =================
    final payable = grandTotal + parcelTotal + tax - discount;

    if (!parcelCopy) {
      if (!removeTaxLines && tax > 0) add(lr("Tax", money(tax)));
      if (parcelTotal > 0) add(lr("Parcel Charges", money(parcelTotal)));
      if (!removeTaxLines && discount > 0) add(lr("Discount", money(discount)));
    } else {
      if (parcelTotal > 0) add(lr("Parcel Charges", money(parcelTotal)));
    }
    add(lr("GRAND TOTAL", money(payable)), bold: true);

    add(divider());

    // ================= FOOTER =================
    if (parcelCopy) {
      add(center("South Indian Counter"), align: 1);
    } else {
      for (final f in footerLines) {
        add(center(f.toString()), align: 1);
      }
    }
  }

  if (allowCustomerCopy) {
    buildReceipt(parcelCopy: false);
  }
  if (allowCounterCopy && (isTakeAway() || mode == "counter")) {
    lines.add({'type': 'feedLine'});
    buildReceipt(parcelCopy: true);
  }

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildSummaryReceiptIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final now = DateTime.now();
  final printedAt =
      "${now.year}-${_twoIsolate(now.month)}-${_twoIsolate(now.day)} "
      "${_twoIsolate(now.hour)}:${_twoIsolate(now.minute)}";

  final List<Map<String, dynamic>> lines = [];

  void addLine(
    String text, {
    int align = 0,
    bool bold = false,
    bool large = false,
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => "-" * width;
  String center(String text) {
    if (text.length >= width) return text;
    final left = ((width - text.length) / 2).floor();
    final right = width - text.length - left;
    return (" " * left) + text + (" " * right);
  }

  String lineLR(String left, String right) {
    final maxLeft = width - right.length;
    final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
    return l.padRight(width - right.length) + right;
  }

  String money(num value) => "Rs ${value.toStringAsFixed(2)}";

  final titleText = (args["restaurantName"] ?? "SELFX").toString().trim();
  if (titleText.length <= 16) {
    addLine(center(titleText), align: 1, bold: true, large: true);
  } else {
    for (final part in _wrapIsolate(titleText, width)) {
      addLine(center(part), align: 1, bold: true);
    }
  }

  final String? address = args["address"]?.toString();
  if (address != null && address.trim().isNotEmpty) {
    for (final part in _wrapIsolate(address.trim(), width)) {
      addLine(center(part), align: 1);
    }
  }

  addLine(divider());
  addLine(center("DAILY SUMMARY"), align: 1, bold: true);
  addLine(center(args["title"].toString().toUpperCase()), align: 1);
  addLine(divider());
  addLine(lineLR("From", args["fromDate"].toString()));
  addLine(lineLR("To", args["toDate"].toString()));
  addLine(lineLR("Printed", printedAt));
  addLine(divider());
  addLine(
    lineLR("Orders (Bills)", args["totalOrders"].toString()),
    bold: true,
  );
  addLine(
    lineLR("Total Revenue", money((args["totalRevenue"] as num?) ?? 0)),
    bold: true,
  );
  addLine(divider());
  addLine(center("Thank you for your order!"), align: 1);

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildItemSalesReportIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final now = DateTime.now();
  final printedAt =
      "${now.year}-${_twoIsolate(now.month)}-${_twoIsolate(now.day)} "
      "${_twoIsolate(now.hour)}:${_twoIsolate(now.minute)}";

  final List<Map<String, dynamic>> lines = [];

  void addLine(
    String text, {
    int align = 0,
    bool bold = false,
    bool large = false,
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => "-" * width;
  String center(String text) {
    if (text.length >= width) return text;
    final left = ((width - text.length) / 2).floor();
    final right = width - text.length - left;
    return (" " * left) + text + (" " * right);
  }

  String lineLR(String left, String right) {
    final maxLeft = width - right.length;
    final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
    return l.padRight(width - right.length) + right;
  }

  String money(num value) => "Rs ${value.toStringAsFixed(2)}";

  final titleText = (args["restaurantName"] ?? "SELFX").toString().trim();
  if (titleText.length <= 16) {
    addLine(center(titleText), align: 1, bold: true, large: true);
  } else {
    for (final part in _wrapIsolate(titleText, width)) {
      addLine(center(part), align: 1, bold: true);
    }
  }

  final String? address = args["address"]?.toString();
  if (address != null && address.trim().isNotEmpty) {
    for (final part in _wrapIsolate(address.trim(), width)) {
      addLine(center(part), align: 1);
    }
  }
  final String? taxId = args["taxId"]?.toString();
  if (taxId != null && taxId.trim().isNotEmpty) {
    addLine(center("GST: $taxId"), align: 1);
  }

  addLine(divider());
  addLine(center("ITEM SALES REPORT"), align: 1, bold: true);
  addLine(center(args["title"].toString().toUpperCase()), align: 1);
  addLine(divider());
  addLine(lineLR("From", args["fromDate"].toString()));
  addLine(lineLR("To", args["toDate"].toString()));
  addLine(lineLR("Printed", printedAt));
  addLine(divider());
  addLine(lineLR("ITEM", "PRICE"), bold: true);

  final items = args["items"] as List? ?? const [];
  for (final item in items) {
    if (item is! Map) continue;
    final name = item["name"]?.toString() ?? "Item";
    final price = item["price"] is num
        ? item["price"] as num
        : num.tryParse("${item["price"]}") ?? 0;
    addLine(lineLR(_truncateIsolate(name, width - 10), money(price)));
  }

  addLine(divider());
  addLine(
    lineLR("ITEMS SOLD (QTY)", args["totalItems"].toString()),
    bold: true,
  );
  addLine(
    lineLR(
      "TOTAL AMOUNT",
      money((args["totalAmount"] as num?) ?? 0),
    ),
    bold: true,
  );
  addLine(divider());
  addLine(center("Thank you for your order!"), align: 1);

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'feedLine'});
  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildCategorySalesReportIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final now = DateTime.now();
  final printedAt =
      "${now.year}-${_twoIsolate(now.month)}-${_twoIsolate(now.day)} "
      "${_twoIsolate(now.hour)}:${_twoIsolate(now.minute)}";

  final List<Map<String, dynamic>> lines = [];

  void add(
    String text, {
    int align = 0,
    bool bold = false,
    String size = 'md',
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': size},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => '-' * width;

  String center(String t) => t.length >= width
      ? t
      : t.padLeft((width + t.length) ~/ 2).padRight(width);

  String lr(String l, String r) =>
      l.padRight(width - r.length).substring(0, width - r.length) + r;

  String money(num v) => v.toStringAsFixed(2);

  String categoryRow(String name, String qty, String amount) {
    return _truncateIsolate(name, 16).padRight(16) +
        qty.padLeft(6) +
        amount.padLeft(10);
  }

  final String restaurantName = (args["restaurantName"] ?? "SELFX").toString();
  final String? address = args["address"]?.toString();
  final String? taxId = args["taxId"]?.toString();

  // ================= HEADER =================
  add(center(restaurantName), align: 1, bold: true, size: 'lg');

  if (address?.isNotEmpty == true) {
    for (final l in _wrapIsolate(address!, width)) {
      add(center(l), align: 1);
    }
  }

  if (taxId?.isNotEmpty == true) {
    add(center("GST: $taxId"), align: 1);
  }

  add(divider());
  add(center("CATEGORY SALES REPORT"), align: 1, bold: true);
  add(center(args["title"].toString().toUpperCase()), align: 1);
  add(divider());

  add(lr("From", args["fromDate"].toString()));
  add(lr("To", args["toDate"].toString()));
  add(lr("Printed", printedAt));
  add(divider());

  // ================= TABLE HEADER =================
  add(categoryRow("CATEGORY", "ITEMS", "AMOUNT"), bold: true);
  add(divider());

  // ================= CATEGORY SUMMARY =================
  final itemsByCategory =
      args["itemsByCategory"] as Map? ?? const <String, dynamic>{};
  for (final entry in itemsByCategory.entries) {
    final category = entry.key.toString();
    final items = entry.value is List ? entry.value as List : const [];

    int qty = 0;
    num amount = 0;

    for (final item in items) {
      if (item is! Map) continue;
      qty += (item['qty'] as num?)?.toInt() ?? 0;
      amount += item['total'] is num
          ? item['total'] as num
          : num.tryParse("${item['total']}") ?? 0;
    }

    add(categoryRow(category.toUpperCase(), qty.toString(), money(amount)));
  }

  add(divider());

  // ================= TOTALS =================
  add(lr("ORDERS (BILLS)", args["totalItems"].toString()), bold: true);
  add(
    lr("TOTAL AMOUNT", "Rs ${money((args["totalAmount"] as num?) ?? 0)}"),
    bold: true,
  );
  add(divider());

  add(center("Thank you!"), align: 1);

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildCategoryTotalsReportIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final now = DateTime.now();
  final printedAt =
      "${now.year}-${_twoIsolate(now.month)}-${_twoIsolate(now.day)} "
      "${_twoIsolate(now.hour)}:${_twoIsolate(now.minute)}";

  final List<Map<String, dynamic>> lines = [];

  void addLine(
    String text, {
    int align = 0,
    bool bold = false,
    bool large = false,
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': large ? 'lg' : 'md'},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => "-" * width;
  String center(String text) {
    if (text.length >= width) return text;
    final left = ((width - text.length) / 2).floor();
    final right = width - text.length - left;
    return (" " * left) + text + (" " * right);
  }

  String lineLR(String left, String right) {
    final maxLeft = width - right.length;
    final l = left.length > maxLeft ? left.substring(0, maxLeft) : left;
    return l.padRight(width - right.length) + right;
  }

  String money(num value) => "Rs ${value.toStringAsFixed(2)}";
  String moneyShort(num value) => value.toStringAsFixed(2);

  String row(String name, String qty, String total) {
    const nameW = 18;
    const qtyW = 4;
    const totalW = 10;
    final n = _truncateIsolate(name, nameW).padRight(nameW);
    final q = qty.padLeft(qtyW);
    final t = total.padLeft(totalW);
    return "$n$q$t";
  }

  String itemRow(String name, String qty, String amount) {
    const nameW = 18;
    const qtyW = 4;
    const totalW = 10;
    final n = _truncateIsolate(" $name", nameW).padRight(nameW);
    final q = qty.padLeft(qtyW);
    final t = amount.padLeft(totalW);
    return "$n$q$t";
  }

  final titleText = (args["restaurantName"] ?? "SELFX").toString().trim();
  if (titleText.length <= 16) {
    addLine(center(titleText), align: 1, bold: true, large: true);
  } else {
    for (final part in _wrapIsolate(titleText, width)) {
      addLine(center(part), align: 1, bold: true);
    }
  }

  final String? address = args["address"]?.toString();
  if (address != null && address.trim().isNotEmpty) {
    final parts = _wrapIsolate(address.trim(), width);
    for (final part in parts.take(2)) {
      addLine(center(part), align: 1);
    }
  }
  final String? taxId = args["taxId"]?.toString();
  if (taxId != null && taxId.trim().isNotEmpty) {
    addLine(center("GST: $taxId"), align: 1);
  }

  addLine(divider());
  addLine(center("CATEGORY TOTALS"), align: 1, bold: true);
  addLine(center(args["title"].toString().toUpperCase()), align: 1);
  addLine(divider());
  addLine(lineLR("From", args["fromDate"].toString()));
  addLine(lineLR("To", args["toDate"].toString()));
  addLine(lineLR("Printed", printedAt));
  addLine(divider());
  addLine(row("CATEGORY", "QTY", "TOTAL"), bold: true);

  final totals = args["categoryTotals"] as List? ?? const [];
  final itemsByCategory = args["itemsByCategory"] as Map?;
  for (final entry in totals) {
    if (entry is! Map) continue;
    final name = entry["category"]?.toString() ?? "Category";
    final qty = (entry["qty"] as num?)?.toInt() ?? 0;
    final total = entry["total"] is num ? entry["total"] as num : 0;
    addLine(row(name.toUpperCase(), qty.toString(), money(total)));

    final items = itemsByCategory?[name];
    if (items is List && items.isNotEmpty) {
      final hasItemTotals = items.any((item) {
        if (item is! Map) return false;
        return item.containsKey("price") ||
            item.containsKey("unit_price") ||
            item.containsKey("total") ||
            item.containsKey("amount") ||
            item.containsKey("total_price");
      });
      if (hasItemTotals) {
        addLine(itemRow("ITEM", "QTY", "AMOUNT"), bold: true);
      }
      for (final item in items) {
        if (item is! Map) continue;
        final itemName = item["name"]?.toString() ?? "Item";
        final itemQty = (item["qty"] as num?)?.toInt() ?? 0;
        if (!hasItemTotals) {
          addLine("  ${itemQty} x $itemName");
          continue;
        }
        final totalRaw = item["total"] ??
            item["amount"] ??
            item["total_price"] ??
            item["totalAmount"];
        num totalValue =
            totalRaw is num ? totalRaw : num.tryParse("$totalRaw") ?? 0;
        if (totalValue == 0 && itemQty > 0) {
          final priceRaw = item["price"] ??
              item["unit_price"] ??
              item["unitPrice"] ??
              item["item_price"];
          final num price =
              priceRaw is num ? priceRaw : num.tryParse("$priceRaw") ?? 0;
          totalValue = price * itemQty;
        }
        addLine(
          itemRow(
            itemName,
            itemQty.toString(),
            moneyShort(totalValue),
          ),
        );
      }
    }
  }

  addLine(divider());
  addLine(lineLR("TOTAL QTY", args["totalItems"].toString()), bold: true);
  addLine(
    lineLR("TOTAL AMOUNT", money((args["totalAmount"] as num?) ?? 0)),
    bold: true,
  );
  addLine(divider());
  addLine(center("Thank you for your order!"), align: 1);

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildCategoryDaySummaryReportIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final List<Map<String, dynamic>> lines = [];

  void addLine(
    String text, {
    int align = 0,
    bool bold = false,
    String size = 'md',
  }) {
    lines.add({
      'type': 'text',
      'text': text,
      'options': {'align': align, 'bold': bold, 'size': size},
    });
    lines.add({'type': 'feedLine'});
  }

  String divider() => "-" * width;
  String center(String text) {
    if (text.length >= width) return text;
    final left = ((width - text.length) / 2).floor();
    final right = width - text.length - left;
    return (" " * left) + text + (" " * right);
  }

  String money(num value) => "₹${value.toStringAsFixed(2)}";

  final titleText = (args["restaurantName"] ?? "SELFX").toString().trim();
  if (titleText.length <= width) {
    addLine(center(titleText), align: 1, bold: true, size: 'lg');
  } else {
    for (final part in _wrapIsolate(titleText, width)) {
      addLine(center(part), align: 1, bold: true);
    }
  }

  final String? address = args["address"]?.toString();
  if (address != null && address.trim().isNotEmpty) {
    final parts = _wrapIsolate(address.trim(), width);
    for (final part in parts.take(2)) {
      addLine(center(part), align: 1);
    }
  }
  final String? taxId = args["taxId"]?.toString();
  if (taxId != null && taxId.trim().isNotEmpty) {
    addLine(center("GST: $taxId"), align: 1);
  }

  addLine(divider());
  addLine(center("CATEGORY SUMMARY"), align: 1, bold: true);
  addLine("Date: ${args["dateLabel"]}");
  addLine(divider());

  final totals = args["categoryTotals"] as List? ?? const [];
  for (final entry in totals) {
    if (entry is! Map) continue;
    final name = entry["category"]?.toString() ?? "Category";
    final qty = (entry["qty"] as num?)?.toInt() ?? 0;
    final total = entry["total"] is num ? entry["total"] as num : 0;

    addLine(name, bold: true);
    addLine("Items: $qty");
    addLine("Amount: ${money(total)}");
    addLine("");
  }

  addLine(divider());
  addLine("Final Total: ${money((args["totalAmount"] as num?) ?? 0)}",
      bold: true);
  addLine(divider());

  lines.add({'type': 'feedLine'});
  lines.add({'type': 'feedLine'});
  lines.add({'type': 'fullCutPaper'});

  return lines;
}

List<Map<String, dynamic>> _buildUsbReceiptIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final int? millis = args["orderDate"] as int?;
  final dt = millis != null
      ? DateTime.fromMillisecondsSinceEpoch(millis)
      : DateTime.now();
  final dateTime = "${dt.year}-${_twoIsolate(dt.month)}-${_twoIsolate(dt.day)} "
      "${_twoIsolate(dt.hour)}:${_twoIsolate(dt.minute)}";

  final List<Map<String, dynamic>> lines = [];

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
        'fontStyle': bold ? 1 : 0,
        'widthTimes': large ? 1 : 0,
        'heightTimes': large ? 1 : 0,
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

  String money(num v) => v.toStringAsFixed(2);

  String itemRow(String name, String qty, String price, String total) {
    return _truncateIsolate(name, 16).padRight(16) +
        qty.padLeft(4) +
        price.padLeft(6) +
        total.padLeft(6);
  }

  final String restaurantName = (args["restaurantName"] ?? "SELFX").toString();
  final String? address = args["address"]?.toString();
  final String? taxId = args["taxId"]?.toString();
  final int orderId = (args["orderId"] as num?)?.toInt() ?? 0;
  final String paymentMode = (args["paymentMode"] ?? "PAID").toString();
  final String? transactionId = args["transactionId"]?.toString();
  final List cartItems = args["cartItems"] as List? ?? const [];
  final num tax = (args["taxAmount"] as num?) ?? 0;
  final num discount = (args["discountAmount"] as num?) ?? 0;
  final List footerLines =
      args["footerLines"] as List? ?? const ["Thank you for your order!"];
  final String? orderTypeRaw = args["orderType"]?.toString();
  final String? receiptModeRaw = args["receiptMode"]?.toString();
  final bool removeTaxLines = args["removeTaxLines"] == true;

  bool isTakeAway() {
    final v = orderTypeRaw?.toLowerCase() ?? "";
    return v.contains("take") || v.contains("pickup");
  }

  String? receiptMode() {
    if (receiptModeRaw == null || receiptModeRaw!.trim().isEmpty) return null;
    final v = receiptModeRaw!.toLowerCase().trim();
    if (v == "1") return "customer";
    if (v == "2") return "counter";
    if (v == "3") return "both";
    if (v.contains("both") || v.contains("all")) return "both";
    if (v.contains("customer")) return "customer";
    if (v.contains("counter")) return "counter";
    return null;
  }

  final String? mode = receiptMode();
  final bool allowCustomerCopy = mode != "counter";
  final bool allowCounterCopy = mode != "customer";

  String? orderTypeLabel() {
    if (orderTypeRaw == null || orderTypeRaw!.trim().isEmpty) return null;
    final v = orderTypeRaw!.toLowerCase();
    if (v.contains("dine")) return "Dine In";
    if (v.contains("take") || v.contains("pickup")) return "Take Away";
    if (v.contains("deliver")) return "Delivery";
    return orderTypeRaw;
  }

  void buildReceipt({required bool parcelCopy}) {
    if (parcelCopy) {
      if (isTakeAway()) {
        text(center("PARCEL"), align: 1, bold: true, large: true);
      }
      text(center("PAYMENT SUCCESSFUL"), align: 1, bold: true);
      text(center("COUNTER COPY"), align: 1, bold: true);
    }

    text(center(restaurantName), align: 1, bold: true, large: true);

    if (address?.isNotEmpty == true) {
      for (final l in _wrapIsolate(address!, width)) {
        text(center(l), align: 1);
      }
    }

    if (!removeTaxLines && taxId?.isNotEmpty == true) {
      text(center("GST: $taxId"), align: 1);
    }

    text(center("SELFX ORDER #$orderId"), align: 1, bold: true);
    dotted();

    text(lr("Order #", orderId.toString()));
    text(lr("DATE", dateTime));
    final orderLabel = orderTypeLabel();
    if (orderLabel != null && orderLabel.trim().isNotEmpty) {
      text(lr("Order Type", orderLabel));
    }
    if (!parcelCopy && isTakeAway()) {
      text(center("PARCEL"), align: 1, bold: true);
    }

    if (transactionId?.isNotEmpty == true) {
      final t = transactionId!;
      final shortTxn = t.length > 16 ? t.substring(t.length - 16) : t;
      text(lr("TXN ID", shortTxn));
    }

    if (paymentMode.isNotEmpty) {
      text(lr("Payment", paymentMode));
    }

    dotted();

    text(itemRow("ITEM", "QTY", "PRICE", "VALUE"), bold: true);
    dotted();

    String? currentCategory;
    num categoryTotal = 0;
    num grandTotal = 0;
    num parcelTotal = 0;

    for (final item in cartItems) {
      if (item is! Map) continue;
      final qty = (item['qty'] as num?)?.toInt() ?? 0;
      num price = item['price'] is num
          ? item['price'] as num
          : num.tryParse("${item['price']}") ?? 0;
      final category = item['category']?.toString();
      final num parcelCharge = item['take_away_charge'] is num
          ? item['take_away_charge'] as num
          : num.tryParse(
                  "${item['take_away_charge'] ?? item['parcel_charge'] ?? item['parcelCharge'] ?? item['takeaway_charge']}") ??
              0;
      if (parcelCharge > 0) {
        parcelTotal += parcelCharge * qty;
      }
      String name = (item['name'] ?? item['item_name'] ?? '').toString().trim();
      if (name.isEmpty || name.toLowerCase() == "null") {
        name = "Parcel Charges";
        if (price == 0) {
          if (parcelCharge > 0) {
            price = parcelCharge;
          } else {
            final amount = item['amount'] ?? item['total'] ?? item['value'];
            final amtNum = num.tryParse("$amount") ?? 0;
            if (amtNum > 0 && qty > 0) {
              price = amtNum / qty;
            }
          }
        }
      }
      final num total = qty * price;

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

    final payable = grandTotal + parcelTotal + tax - discount;

    if (!parcelCopy) {
      if (!removeTaxLines && tax > 0) text(lr("Tax", "Rs ${money(tax)}"));
      if (parcelTotal > 0) {
        text(lr("Parcel Charges", "Rs ${money(parcelTotal)}"));
      }
      if (!removeTaxLines && discount > 0) {
        text(lr("Discount", "-Rs ${money(discount)}"));
      }
    } else {
      if (parcelTotal > 0) {
        text(lr("Parcel Charges", "Rs ${money(parcelTotal)}"));
      }
    }
    text(lr("GRAND TOTAL", "Rs ${money(payable)}"), bold: true);
    dotted();

    if (parcelCopy) {
      text(center("South Indian Counter"), align: 1);
    } else {
      for (final f in footerLines) {
        if (f.toString().trim().isNotEmpty) {
          text(center(f.toString().trim()), align: 1);
        }
      }
    }
  }

  if (allowCustomerCopy) {
    buildReceipt(parcelCopy: false);
  }
  if (allowCounterCopy && (isTakeAway() || mode == "counter")) {
    lines.add({'type': 'feedLine'});
    buildReceipt(parcelCopy: true);
  }

  lines.add({'type': 'fullCutPaper'});
  return lines;
}

List<String> _wrapIsolate(String text, int width) {
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

String _truncateIsolate(String text, int width) {
  return text.length > width ? text.substring(0, width) : text;
}

String _twoIsolate(int value) => value.toString().padLeft(2, '0');
