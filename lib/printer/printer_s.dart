import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List, compute;
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunmi_printer_plus/sunmi_printer_plus.dart';
import 'package:sunmi_printer_plus/enums.dart';
import 'package:sunmi_printer_plus/sunmi_style.dart';

import '../api/kiosk_api.dart';
import '../core/india_time.dart';
import '../core/kiosk_log.dart';
import 'epson_usb_printer_service.dart';

enum PrinterType { internal, usb, lan }

enum PrinterStatus { online, offline, notConfigured }

const String _poweredBySelfxLabel = "Powered By";
const String _poweredBySelfxBrand = "SELFX";

String _printDateTime(DateTime value) {
  return "${value.year}-${_twoIsolate(value.month)}-${_twoIsolate(value.day)} "
      "${_twoIsolate(value.hour)}:${_twoIsolate(value.minute)}";
}

DateTime _receiptWallTime(DateTime? value) {
  if (value == null) return IndiaTime.now();
  return value.isUtc ? IndiaTime.toWallTime(value) : value;
}

List<String> _receiptFooterLines(dynamic raw) {
  if (raw is List) {
    final lines = raw
        .map((value) => value?.toString().trim() ?? "")
        .where((value) => value.isNotEmpty)
        .toList();
    if (lines.isNotEmpty) return lines;
  }
  return const ["Thank you for your order!"];
}

class PrinterService {
  final _usbService = EpsonUSBPrinterService();
  final Map<String, Uint8List> _printImageCache = {};
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

  List<List<dynamic>> _dedupeRawPrintObjects(List<List<dynamic>> objects) {
    final seen = <String>{};
    final out = <List<dynamic>>[];
    for (final object in objects) {
      String key;
      try {
        key = jsonEncode(object);
      } catch (_) {
        key = object.toString();
      }
      if (seen.add(key)) {
        out.add(object);
      }
    }
    return out;
  }

  bool _backendPrintObjectAlreadyHasBothCopies(List<List<dynamic>> objects) {
    if (objects.length != 1) return false;
    final object = objects.first;
    var cutCount = 0;
    var duplicateMarkers = 0;
    var printableAfterFirstCut = false;
    var sawCut = false;
    var sawCounterMarker = false;
    var printableBeforeCounterMarker = false;
    var printableAfterCounterMarker = false;

    for (final entry in object) {
      if (entry is! Map) continue;
      final type = entry['type']?.toString().trim().toLowerCase() ?? '';
      if (_isCutEntry(entry)) {
        cutCount++;
        sawCut = true;
        continue;
      }
      if (type == 'text') {
        final text = entry['text']?.toString() ?? '';
        final isCounterMarker = _isCounterCopyText(text);
        if (_isDuplicateCopyText(text) || isCounterMarker) {
          duplicateMarkers++;
        }
        if (isCounterMarker) {
          sawCounterMarker = true;
          continue;
        }
        if (sawCut && text.trim().isNotEmpty) {
          printableAfterFirstCut = true;
        }
      } else if (sawCut && _isPrintablePrintEntry(entry)) {
        printableAfterFirstCut = true;
      }
      if (_isPrintablePrintEntry(entry)) {
        if (sawCounterMarker) {
          printableAfterCounterMarker = true;
        } else {
          printableBeforeCounterMarker = true;
        }
      }
    }

    return cutCount > 1 ||
        (cutCount >= 1 && printableAfterFirstCut) ||
        (sawCounterMarker &&
            printableBeforeCounterMarker &&
            printableAfterCounterMarker) ||
        duplicateMarkers > 1;
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
    header.add({'type': 'dottedLine'});
    return [...header, ...cloned];
  }

  List<dynamic> _withoutQrCommands(List<dynamic> printObject) {
    final out = <dynamic>[];
    for (final entry in printObject) {
      if (entry is Map) {
        final type = entry['type']?.toString().trim().toLowerCase() ?? '';
        if (type == 'qr' || type == 'qrcode' || type == 'qr_code') {
          continue;
        }
      }
      out.add(entry);
    }
    return out;
  }

  bool _hasCounterLabel(List<dynamic> printObject) {
    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString() ?? '';
        if (_isCounterCopyText(text)) return true;
      }
    }
    return false;
  }

  bool _isCutEntry(dynamic entry) {
    if (entry is! Map) return false;
    final type = entry['type']?.toString().trim().toLowerCase() ?? '';
    return type == 'cut' ||
        type == 'fullcutpaper' ||
        type == 'halfcutpaper' ||
        type == 'partialcutpaper' ||
        type == 'full_cut_paper' ||
        type == 'half_cut_paper' ||
        type == 'partial_cut_paper';
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
    final type = await _resolvePrinterTypeForTestPrint();
    if (type == null) {
      throw Exception("Printer not configured");
    }
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
      kioskLog("USB test print sent", tag: "PRINT");
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
    String? orderNumber,
    bool forceLocal = false,
    bool backendOnly = false,
    bool preserveBackendPrintFormat = false,
    bool requireBothCopies = false,
    bool counterCopyLabel = false,
    bool removeTaxLines = false,
    num? parcelTotalOverride,
  }) async {
    final type = await _getPrinterType();
    if (type == null) {
      throw Exception("Printer not configured");
    }
    final orderRef = _backendOrderRef(orderId, orderNumber);
    kioskLog(
      "printOrder start order=$orderRef type=${type.name} forceLocal=$forceLocal backendOnly=$backendOnly items=${cartItems.length}",
      tag: "PRINT",
    );
    final num parcelTotal =
        parcelTotalOverride ?? _parcelTotalFromCart(cartItems);

    if (forceLocal) {
      throw Exception(
          "Local receipt print disabled; backend print API required");
    }
    if (orderRef == null) {
      throw Exception("Order number missing for backend receipt print");
    }

    // ================= INTERNAL (Sunmi) =================
    if (type == PrinterType.internal) {
      try {
        final printObjects = await _loadBackendPrintObjects(
          orderId: orderId,
          orderNumber: orderNumber,
          type: type,
          restaurantName: restaurantName,
          orderType: orderType,
          requireBothCopies: requireBothCopies,
          counterCopyLabel: counterCopyLabel,
          removeTaxLines: removeTaxLines,
          parcelTotal: parcelTotal,
          preserveBackendPrintFormat: preserveBackendPrintFormat,
          backendTimeout: null,
        );
        if (printObjects.isEmpty) {
          throw Exception("Backend print object missing");
        }
        for (final obj in printObjects) {
          await _printWithSunmiRaw(obj);
        }
        kioskLog("backend Sunmi print complete order=$orderRef", tag: "PRINT");
        return;
      } catch (e, stackTrace) {
        kioskLogError(
          "backend Sunmi print failed order=$orderRef",
          tag: "PRINT",
          error: e,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    // ================= USB PRINTER =================
    if (type == PrinterType.usb) {
      final printer = await _resolveUsbPrinter(allowAutoSelect: true);
      if (printer == null) {
        throw Exception("No USB printer selected");
      }

      try {
        final printObjects = await _loadBackendPrintObjects(
          orderId: orderId,
          orderNumber: orderNumber,
          type: type,
          restaurantName: restaurantName,
          orderType: orderType,
          requireBothCopies: requireBothCopies,
          counterCopyLabel: counterCopyLabel,
          removeTaxLines: removeTaxLines,
          parcelTotal: parcelTotal,
          preserveBackendPrintFormat: preserveBackendPrintFormat,
          backendTimeout: null,
        );
        if (printObjects.isEmpty) {
          throw Exception("Backend print object missing");
        }
        for (final obj in printObjects) {
          await _usbService.printRawPrintObject(
            printer: printer,
            printObject: obj,
          );
        }
        kioskLog("backend USB print complete order=$orderRef", tag: "PRINT");
        return;
      } catch (e, stackTrace) {
        kioskLogError(
          "backend USB print failed order=$orderRef",
          tag: "PRINT",
          error: e,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    // ================= LAN PRINTER =================
    if (type == PrinterType.lan) {
      await _fetchBackendPrintResponse(
          orderId: orderId, orderNumber: orderNumber);
      kioskLog("LAN/backend print complete order=$orderRef", tag: "PRINT");
      return;
    }
  }

  String? _backendOrderRef(int orderId, String? orderNumber) {
    final normalized = orderNumber?.trim();
    if (normalized != null &&
        normalized.isNotEmpty &&
        normalized.toLowerCase() != "null") {
      return normalized;
    }
    return orderId > 0 ? orderId.toString() : null;
  }

  Future<dynamic> _fetchBackendPrintResponse({
    required int orderId,
    String? orderNumber,
    Duration? timeout,
  }) async {
    final normalized = orderNumber?.trim();
    Future<dynamic> request;
    if (normalized != null &&
        normalized.isNotEmpty &&
        normalized.toLowerCase() != "null") {
      request = KioskApi().printReceiptByOrderNumber(normalized);
    } else {
      request = KioskApi().printReceipt(orderId);
    }
    if (timeout == null) return request;
    return request.timeout(timeout);
  }

  Future<List<List<dynamic>>> _loadBackendPrintObjects({
    required int orderId,
    required PrinterType type,
    String? orderNumber,
    String? restaurantName,
    String? orderType,
    required bool requireBothCopies,
    required bool counterCopyLabel,
    required bool removeTaxLines,
    required num parcelTotal,
    required bool preserveBackendPrintFormat,
    Duration? backendTimeout,
  }) async {
    final res = await _fetchBackendPrintResponse(
      orderId: orderId,
      orderNumber: orderNumber,
      timeout: backendTimeout,
    );
    final data = res.data;
    final orderRef = _backendOrderRef(orderId, orderNumber) ?? orderId;
    final lineWidth = _backendLineWidth(data);
    var rawPrintObjects = _extractBackendPrintObjects(data);
    if (rawPrintObjects.isEmpty) {
      rawPrintObjects = _buildOrderReceiptFromBackendResponse(
        data,
        lineWidth: lineWidth,
      );
    }
    rawPrintObjects = _dedupeRawPrintObjects(rawPrintObjects);
    if (rawPrintObjects.isEmpty) return const [];
    final rawCustomerCopies = rawPrintObjects
        .where((object) => !_isRawCounterPrintObject(object))
        .toList();
    final rawCounterCopies =
        rawPrintObjects.where(_isRawCounterPrintObject).toList();
    final selectedRawPrintObjects = <List<dynamic>>[];
    final generatedCounterCopyIndexes = <int>{};
    final backendAlreadyHasBothCopies = requireBothCopies &&
        _backendPrintObjectAlreadyHasBothCopies(
          rawPrintObjects,
        );
    final backendHasDuplicateCopy = rawPrintObjects.any(
      _isRawDuplicatePrintObject,
    );
    if (backendAlreadyHasBothCopies ||
        (requireBothCopies &&
            backendHasDuplicateCopy &&
            rawPrintObjects.length == 1)) {
      selectedRawPrintObjects.add(rawPrintObjects.first);
    } else if (requireBothCopies) {
      final customer = rawCustomerCopies.isNotEmpty
          ? rawCustomerCopies.first
          : rawPrintObjects.first;
      final counter =
          rawCounterCopies.isNotEmpty ? rawCounterCopies.first : customer;
      selectedRawPrintObjects
        ..add(customer)
        ..add(counter);
      if (rawCounterCopies.isEmpty) {
        generatedCounterCopyIndexes.add(1);
      }
    } else {
      selectedRawPrintObjects.addAll(rawPrintObjects);
    }

    var printObjects = selectedRawPrintObjects
        .map((object) => _normalizeBackendPrintObject(
              object,
              lineWidth: lineWidth,
            ))
        .where((object) => object.isNotEmpty)
        .toList();
    if (generatedCounterCopyIndexes.isNotEmpty) {
      for (final index in generatedCounterCopyIndexes) {
        if (index >= 0 && index < printObjects.length) {
          printObjects[index] = _withoutQrCommands(printObjects[index]);
        }
      }
    }
    if (type == PrinterType.usb) {
      final withImages = <List<dynamic>>[];
      for (final object in printObjects) {
        withImages.add(await _embedUsbImageBytes(object));
      }
      printObjects = withImages;
    }
    if (requireBothCopies &&
        (backendAlreadyHasBothCopies || backendHasDuplicateCopy)) {
      printObjects = printObjects.map(_withInterCopyHalfCuts).toList();
    }
    if (!backendAlreadyHasBothCopies &&
        !backendHasDuplicateCopy &&
        requireBothCopies &&
        counterCopyLabel &&
        printObjects.length >= 2) {
      if (!_hasCounterLabel(printObjects[1])) {
        printObjects[1] = _withCounterCopyHeader(
          printObjects[1],
          showParcel: _isTakeAwayOrder(orderType),
        );
      }
    }
    if (!backendAlreadyHasBothCopies &&
        requireBothCopies &&
        printObjects.length >= 2) {
      printObjects[0] = _withTrailingCut(printObjects[0], halfCut: true);
      printObjects[1] = _withTrailingCut(printObjects[1], halfCut: false);
    }
    kioskLog(
      "backend print objects order=$orderRef type=${type.name} ${_describePrintPayload(data)} count=${printObjects.length}",
      tag: "PRINT",
    );

    if (preserveBackendPrintFormat) {
      return printObjects;
    }

    printObjects = printObjects
        .map((p) => _withReceiptHeaderName(p, restaurantName))
        .toList();
    if (!backendAlreadyHasBothCopies &&
        !backendHasDuplicateCopy &&
        requireBothCopies) {
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
      printObjects =
          printObjects.map((p) => _injectParcelLine(p, parcelTotal)).toList();
    }
    if (!backendAlreadyHasBothCopies &&
        requireBothCopies &&
        printObjects.length >= 2) {
      printObjects[0] = _withTrailingCut(printObjects[0], halfCut: true);
      printObjects[1] = _withTrailingCut(printObjects[1], halfCut: false);
    }
    return printObjects;
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

  Future<PrinterType?> _resolvePrinterTypeForTestPrint() async {
    final configured = await _getPrinterType();
    if (configured != null) return configured;

    final selectedUsb = await _getSelectedUsbPrinter();
    if (selectedUsb != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("printer_type", PrinterType.usb.name);
      return PrinterType.usb;
    }

    final usbPrinters = await _usbService.getPrinterList();
    if (usbPrinters.length == 1) {
      await saveSelectedUsbPrinter(usbPrinters.first);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("printer_type", PrinterType.usb.name);
      return PrinterType.usb;
    }

    return null;
  }

  // ===== MAP COMMON FORMAT → USB FORMAT =====
  Map<String, dynamic> _mapForUsb(Map<String, dynamic> item) {
    if (item['type'] != 'text') return item;

    final options = item['options'] ?? {};
    return {
      ...item,
      'text': _printerSafeText((item['text'] ?? '').toString()),
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
    final printedAt = _printDateTime(IndiaTime.now());
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
      } else if (item['type'] == 'image') {
        final options = item['options'] is Map
            ? Map<String, dynamic>.from(item['options'])
            : <String, dynamic>{};
        await _printSunmiImage(
          item,
          align: _toInt(options['align']) ?? 1,
        );
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
        final text = _printerSafeText((entry['text'] ?? '').toString());

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
      } else if (type == 'image') {
        await flushLine();
        final options = entry['options'] is Map
            ? Map<String, dynamic>.from(entry['options'])
            : <String, dynamic>{};
        await _printSunmiImage(
          entry,
          align: _toInt(options['align']) ?? 1,
        );
      } else if (type == 'qr') {
        await flushLine();
        final data = entry['data']?.toString().trim() ?? '';
        if (data.isNotEmpty) {
          await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
          try {
            await SunmiPrinter.printQRCode(data, size: 5);
          } catch (_) {
            await _sunmiPrintText(data, align: 1);
          }
          await SunmiPrinter.lineWrap(1);
        }
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
    final dateTime = _printDateTime(_receiptWallTime(orderDate));

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

    String center(String t) => t.trim();

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
    final footer = _receiptFooterLines(footerLines);
    for (final f in footer) {
      add(center(f), align: 1);
    }
    add(center(_poweredBySelfxLabel), align: 1);
    add(center(_poweredBySelfxBrand), align: 1, bold: true);

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
    final printedAt = _printDateTime(IndiaTime.now());

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
    final printedAt = _printDateTime(IndiaTime.now());

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
    final printedAt = _printDateTime(IndiaTime.now());

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

    String center(String t) => t.trim();

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
    final printedAt = _printDateTime(IndiaTime.now());

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

    String money(num value) => "Rs ${value.toStringAsFixed(2)}";

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

  List<dynamic> _withReceiptHeaderName(
    List<dynamic> printObject,
    String? restaurantName,
  ) {
    final name = restaurantName?.trim();
    if (name == null || name.isEmpty) return printObject;

    final out = _clonePrintObject(printObject);
    for (var i = 0; i < out.length; i++) {
      final entry = out[i];
      if (entry is! Map || entry['type'] != 'text') continue;

      final text = entry['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;

      final lower = text.toLowerCase();
      if (lower.contains('counter copy') ||
          lower == 'counter' ||
          lower == 'parcel') {
        continue;
      }

      final updated = Map<dynamic, dynamic>.from(entry);
      updated['text'] = name;
      out[i] = updated;
      return out;
    }

    return [
      {
        'type': 'text',
        'text': name,
        'options': {
          'align': 1,
          'bold': true,
          'widthTimes': 1,
          'heightTimes': 1
        },
      },
      {'type': 'feedLine'},
      ...out,
    ];
  }

  List<List<dynamic>> _extractBackendPrintObjects(dynamic data) {
    final List<List<dynamic>> result = [];

    void collectObject(dynamic value) {
      if (value is! List || value.isEmpty) return;
      final mapEntries = value.whereType<Map>().toList();
      if (mapEntries.isNotEmpty) {
        final hasPrintCommand = mapEntries.any((entry) {
          final type = entry['type']?.toString().trim();
          return type != null && type.isNotEmpty;
        });
        if (hasPrintCommand) {
          result.add(List<dynamic>.from(value));
          return;
        }
      }
      if (value.first is List) {
        for (final obj in value) {
          collectObject(obj);
        }
        return;
      }
      if (value.first is Map) {
        result.add(List<dynamic>.from(value));
        return;
      }
      if (value.every((entry) => entry is String)) {
        final lines = value
            .map((entry) => entry.toString())
            .where((entry) => entry.trim().isNotEmpty)
            .map<dynamic>(
              (entry) => {
                'type': 'text',
                'text': entry,
                'options': {'align': 0},
              },
            )
            .toList();
        if (lines.isNotEmpty) {
          lines.add({'type': 'feedLine'});
          lines.add({'type': 'fullCutPaper'});
          result.add(lines);
        }
      }
    }

    void collectFromMap(Map map, {int depth = 3}) {
      if (depth <= 0) return;
      for (final key in const [
        'printObjects',
        'print_objects',
        'printObject',
        'print_object',
        'printObjectCustomer',
        'print_object_customer',
        'printObjectCounter',
        'print_object_counter',
        'customerPrintObject',
        'customer_print_object',
        'counterPrintObject',
        'counter_print_object',
      ]) {
        collectObject(map[key]);
      }

      for (final key in const [
        'data',
        'receipt',
        'print',
        'payload',
        'order',
        'result',
      ]) {
        final nested = map[key];
        if (nested is Map) {
          collectFromMap(nested, depth: depth - 1);
        }
      }
    }

    if (data is Map) {
      collectFromMap(data);
    } else {
      collectObject(data);
    }
    return result;
  }

  List<List<dynamic>> _buildOrderReceiptFromBackendResponse(
    dynamic data, {
    required int lineWidth,
  }) {
    if (data is! Map) return const [];
    final root = Map<dynamic, dynamic>.from(data);
    final body = root['data'] is Map
        ? Map<dynamic, dynamic>.from(root['data'] as Map)
        : root;
    final order = _firstBackendMap([
      body['order'],
      root['order'],
      body['receipt'] is Map ? (body['receipt'] as Map)['order'] : null,
    ]);
    if (order == null || order.isEmpty) return const [];

    final restaurant = _firstBackendMap([
      body['restaurant'],
      root['restaurant'],
      order['restaurant'],
    ]);
    final branch = _firstBackendMap([
      body['branch'],
      root['branch'],
      order['branch'],
    ]);
    final settings = _firstBackendMap([
      body['settings'],
      body['receipt_settings'],
      root['settings'],
      root['receipt_settings'],
    ]);

    final width = lineWidth.clamp(28, 48);
    final out = <dynamic>[];

    void text(
      String? value, {
      int align = 0,
      bool bold = false,
      String? style,
    }) {
      final raw = value?.trim() ?? '';
      if (raw.isEmpty || raw.toLowerCase() == 'null') return;
      final options = {
        'align': align,
        'nOrgx': 0,
        'widthTimes': 0,
        'heightTimes': 0,
        if (bold || style == 'title' || style == 'large_bold') 'bold': true,
        if (bold || style == 'title' || style == 'large_bold') 'fontStyle': 1,
      };
      for (final line in _backendTextLines(raw, options, lineWidth: width)) {
        out.add({'type': 'text', 'text': line, 'options': options});
        out.add({'type': 'feedLine'});
      }
    }

    void row(String label, String value, {bool bold = false}) {
      final right = value.trim();
      if (right.isEmpty || right.toLowerCase() == 'null') return;
      for (final line
          in _formatBackendRow(label, right, lineWidth: width).split('\n')) {
        text(line, bold: bold);
      }
    }

    void divider() {
      if (_hasPrintableBackendContent(out)) {
        out.add({'type': 'dottedLine'});
      }
    }

    final restaurantName = _firstBackendText([
      restaurant?['name'],
      restaurant?['restaurant_name'],
      body['restaurant_name'],
      body['restaurant'],
    ]);
    final branchName = _firstBackendText([
      branch?['name'],
      branch?['branch_name'],
      order['branch_name'],
      body['branch_name'],
    ]);
    final address = _firstBackendText([
      branch?['address'],
      restaurant?['address'],
      body['address'],
    ]);
    final taxId = _firstBackendText([
      restaurant?['tax_id'],
      restaurant?['gstin'],
      restaurant?['gst_number'],
      branch?['tax_id'],
      branch?['gstin'],
      order['tax_id'],
    ]);
    final token = _firstBackendText([order['token'], order['token_number']]);
    final orderNumber = _firstBackendText([
      order['order_number'],
      order['number'],
      order['order_no'],
    ]);
    final orderType = _formatBackendOrderType(order['type']);
    final createdAt = _firstBackendText([
      order['created_at'],
      order['createdAt'],
      order['date'],
    ]);
    final table = _firstBackendText([order['table_name'], order['table']]);
    final customer = _firstBackendText([
      order['customer_name'],
      order['customer'],
    ]);
    final notes = _firstBackendText([order['notes'], order['note']]);
    final currency = _firstBackendText([
          order['currency_symbol'],
          body['currency_symbol'],
          restaurant?['currency_symbol'],
        ]) ??
        'Rs';

    text(restaurantName, align: 1, bold: true, style: 'title');
    text(branchName, align: 1);
    text(address, align: 1);
    if (taxId != null) text('GSTIN: $taxId', align: 1);
    if (token != null) text('TOKEN #$token', align: 1, bold: true);
    if (orderNumber != null) text('Order:$orderNumber', align: 1, bold: true);
    final typeDate = [
      if (orderType != null) orderType,
      if (createdAt != null) _shortBackendDate(createdAt),
    ].where((value) => value.trim().isNotEmpty).join(' - ');
    text(typeDate, align: 1);
    if (table != null) text('Table:$table');
    if (customer != null) text('Customer:$customer');
    if (notes != null) text('Note:$notes');
    divider();

    final items = order['items'];
    if (items is List) {
      for (final itemRaw in items) {
        if (itemRaw is! Map) continue;
        final item = Map<dynamic, dynamic>.from(itemRaw);
        final qty = _toNum(item['quantity'] ?? item['qty']) ?? 1;
        final name = _firstBackendText([
              item['name'],
              item['item_name'],
              item['product_name'],
            ]) ??
            'Item';
        final total =
            _toNum(item['total'] ?? item['line_total'] ?? item['amount']) ??
                ((_toNum(item['unit_price'] ?? item['price']) ?? 0) * qty);
        row('${_formatQty(qty)}x $name', _backendMoney(total, currency),
            bold: true);
        final variant = _firstBackendText([
          item['variant_name'],
          item['variant'],
        ]);
        if (variant != null) text('($variant)');
        final unit = _toNum(item['unit_price'] ?? item['price']);
        if (unit != null) text('@ ${_backendMoney(unit, currency)} each');
        final modifiers = item['modifiers'];
        if (modifiers is List) {
          for (final modRaw in modifiers) {
            if (modRaw is! Map) continue;
            final mod = Map<dynamic, dynamic>.from(modRaw);
            final modName = _firstBackendText([
              mod['option_name'],
              mod['name'],
              mod['label'],
            ]);
            if (modName == null) continue;
            final amount = _toNum(mod['price_adjustment'] ?? mod['amount']);
            if (amount != null && amount != 0) {
              row('  + $modName', _backendMoney(amount, currency));
            } else {
              text('  + $modName');
            }
          }
        }
      }
    }
    divider();

    row('Subtotal', _backendMoney(_toNum(order['subtotal']) ?? 0, currency));
    final discount = _toNum(order['discount_total']);
    if (discount != null && discount > 0) {
      row('Discount', '-${_backendMoney(discount, currency)}');
    }
    final extraCharges = order['extra_charges'];
    if (extraCharges is List) {
      for (final chargeRaw in extraCharges) {
        if (chargeRaw is! Map) continue;
        final charge = Map<dynamic, dynamic>.from(chargeRaw);
        final amount = _toNum(charge['amount']);
        if (amount == null || amount == 0) continue;
        row(
            _firstBackendText([charge['label'], charge['name']]) ??
                'Extra Charge',
            _backendMoney(amount, currency));
      }
    }
    final serviceCharge = _toNum(order['service_charge']);
    if (serviceCharge != null && serviceCharge > 0) {
      row(
        _firstBackendText([order['service_charge_label']]) ?? 'Service charge',
        _backendMoney(serviceCharge, currency),
      );
    }
    final taxBreakdown = order['tax_breakdown'];
    if (taxBreakdown is List) {
      for (final taxRaw in taxBreakdown) {
        if (taxRaw is! Map) continue;
        final tax = Map<dynamic, dynamic>.from(taxRaw);
        final amount = _toNum(tax['amount']);
        if (amount == null || amount == 0) continue;
        final name = _firstBackendText([tax['name']]) ?? 'Tax';
        final rate = _toNum(tax['rate']);
        row(rate == null ? name : '$name (${_formatQty(rate)}%)',
            _backendMoney(amount, currency));
      }
    }
    divider();
    row('TOTAL', _backendMoney(_toNum(order['total']) ?? 0, currency),
        bold: true);

    final status = _firstBackendText([order['payment_status']]);
    if (status != null) {
      text(_titleBackend(status), align: 1, bold: true);
    }
    final method = _firstBackendText([order['payment_method']]);
    if (method != null) text('Method: ${_titleBackend(method)}', align: 1);
    final transaction = _firstBackendText([order['transaction_id']]);
    if (transaction != null) text('Transaction: $transaction', align: 1);

    final qr = _firstBackendText([
      order['tracking_url'],
      order['payment_url'],
      order['qr_data'],
      order['upi_url'],
    ]);
    if (qr != null) {
      out.add({
        'type': 'qr',
        'data': _cleanBackendQrData(qr),
        'size': 4,
        'errorLevel': 1,
        'options': {'align': 1, 'nOrgx': 0},
      });
    }

    text(
      _firstBackendText([settings?['footer_line'], body['footer_line']]) ??
          'Thank you for your order!',
      align: 1,
    );
    divider();
    text(_poweredBySelfxLabel, align: 1);
    text(_poweredBySelfxBrand, align: 1, bold: true);

    return out.isEmpty ? const [] : [out];
  }

  Map<dynamic, dynamic>? _firstBackendMap(Iterable<dynamic> values) {
    for (final value in values) {
      if (value is Map && value.isNotEmpty) {
        return Map<dynamic, dynamic>.from(value);
      }
    }
    return null;
  }

  String? _firstBackendText(Iterable<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      if (value is Map || value is List) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
    }
    return null;
  }

  num? _toNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    return num.tryParse(value.toString().replaceAll(',', '').trim());
  }

  String _backendMoney(num value, String currency) {
    final prefix = _printerSafeCurrency(currency);
    return '$prefix ${value.toStringAsFixed(2)}';
  }

  String _formatQty(num value) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String? _formatBackendOrderType(dynamic raw) {
    final value = raw?.toString().trim();
    if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
      return null;
    }
    final normalized = value.toLowerCase().replaceAll('_', ' ');
    if (normalized.contains('dine')) return 'Dine in';
    if (normalized.contains('take') || normalized.contains('pick')) {
      return 'Take away';
    }
    return _titleBackend(value.replaceAll('_', ' '));
  }

  String _titleBackend(String value) {
    return value
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1).toLowerCase())
        .join(' ');
  }

  String _shortBackendDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final wall = _receiptWallTime(parsed);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour12 = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
    final ampm = wall.hour >= 12 ? 'PM' : 'AM';
    return '${wall.day} ${months[wall.month - 1]} ${wall.year} '
        '${hour12.toString().padLeft(2, '0')}:'
        '${wall.minute.toString().padLeft(2, '0')} $ampm';
  }

  String _describePrintPayload(dynamic data) {
    Map? payload;
    if (data is Map) {
      payload = data['data'] is Map ? data['data'] as Map : data;
    }
    if (payload == null) return "payload=unknown";
    final paper = payload['paper']?.toString();
    final version = payload['version']?.toString();
    final fontSize = payload['font_size']?.toString();
    final rawObject = payload['print_object'] ??
        payload['printObject'] ??
        payload['print_objects'] ??
        payload['printObjects'];
    final length = rawObject is List ? rawObject.length : 0;
    return "payload version=${version ?? '-'} paper=${paper ?? '-'} font=${fontSize ?? '-'} rawItems=$length";
  }

  int _backendLineWidth(dynamic data) {
    Map? payload;
    if (data is Map) {
      payload = data['data'] is Map ? data['data'] as Map : data;
    }
    final paper = payload?['paper']?.toString().trim().toLowerCase() ?? '';
    switch (paper) {
      case '112mm':
        return 67;
      case '80mm':
        return 48;
      case '56mm':
      default:
        return 32;
    }
  }

  List<dynamic> _normalizeBackendPrintObject(
    List<dynamic> printObject, {
    required int lineWidth,
  }) {
    final normalized = <dynamic>[];
    var footerStarted = false;

    void addTextLine(String text, Map<String, dynamic> options) {
      final trimmed = text.trimRight();
      if (trimmed.trim().isEmpty) return;
      final printOptions = {
        ...options,
        'align': _backendAlign(options['align']),
        'nLan': _toInt(options['nLan']) ?? 0,
        'nOrgx': _toInt(options['nOrgx']) ?? 0,
        'paperWidthChars': lineWidth,
      };
      normalized.add({
        'type': 'text',
        'text': trimmed,
        'options': printOptions,
      });
      normalized.add({'type': 'feedLine'});
    }

    void addText(String text, Map<String, dynamic> options) {
      final lines = _backendTextLines(text, options, lineWidth: lineWidth);
      for (final line in lines) {
        addTextLine(line, options);
      }
    }

    bool addImage(Map entry) {
      final image = _backendImageCommand(entry, lineWidth: lineWidth);
      if (image == null) return false;
      normalized.add(image);
      normalized.add({'type': 'feedLine'});
      return true;
    }

    for (final entry in printObject) {
      if (entry is! Map) continue;
      final type = entry['type']?.toString().trim().toLowerCase() ?? '';

      if (type == 'init') {
        continue;
      }

      if (type == 'powered_by' || type == 'poweredby' || type == 'powered-by') {
        if (addImage(entry)) {
          footerStarted = true;
          continue;
        }
        addText(_poweredBySelfxLabel, {'align': 1});
        addText(_poweredBySelfxBrand, {'align': 1, 'bold': true});
        footerStarted = true;
        continue;
      }

      if (type == 'logo') {
        if (addImage(entry)) {
          if (footerStarted || _isFooterImage(entry)) {
            footerStarted = true;
          }
          continue;
        }
        if (footerStarted || _isFooterImage(entry)) {
          footerStarted = true;
        }
        continue;
      }

      if (type == 'image') {
        if (addImage(entry)) {
          if (footerStarted || _isFooterImage(entry)) {
            footerStarted = true;
          }
          continue;
        }
        if (footerStarted || _isFooterImage(entry)) {
          footerStarted = true;
        }
        continue;
      }

      if (type == 'text') {
        final text = entry['text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        addText(text, _backendTextOptions(entry, text: text));
        if (_isReceiptFooterText(text)) {
          footerStarted = true;
        }
        continue;
      }

      if (type == 'row') {
        final left = entry['left']?.toString() ?? '';
        final right = entry['right']?.toString() ?? '';
        final line = _formatBackendRow(left, right, lineWidth: lineWidth);
        if (line.trim().isEmpty) continue;
        for (final part in line.split('\n')) {
          addText(part, _backendTextOptions(entry));
        }
        continue;
      }

      if (type == 'divider' || type == 'line' || type == 'dottedline') {
        normalized.add({'type': 'dottedLine'});
        continue;
      }

      if (type == 'feed' || type == 'feedline') {
        final lines = (_toInt(entry['lines']) ?? 1).clamp(1, 8);
        for (var i = 0; i < lines; i++) {
          normalized.add({'type': 'feedLine'});
        }
        continue;
      }

      if (type == 'cut' ||
          type == 'fullcutpaper' ||
          type == 'halfcutpaper' ||
          type == 'partialcutpaper' ||
          type == 'full_cut_paper' ||
          type == 'half_cut_paper' ||
          type == 'partial_cut_paper') {
        final mode = entry['mode']?.toString().toLowerCase() ?? '';
        normalized.add({
          'type': mode == 'half' ||
                  mode == 'partial' ||
                  type == 'halfcutpaper' ||
                  type == 'partialcutpaper' ||
                  type == 'half_cut_paper' ||
                  type == 'partial_cut_paper'
              ? 'halfCutPaper'
              : 'fullCutPaper',
        });
        continue;
      }

      if (type == 'qr' || type == 'qrcode' || type == 'qr_code') {
        final qrOptions = entry['options'] is Map
            ? Map<dynamic, dynamic>.from(entry['options'] as Map)
            : const <dynamic, dynamic>{};
        final data = _cleanBackendQrData(_firstNonEmptyString([
              entry['data'],
              entry['text'],
              entry['value'],
              entry['payload'],
              entry['content'],
              entry['url'],
              entry['qr_url'],
              entry['qrUrl'],
              entry['tracking_url'],
              entry['trackingUrl'],
              entry['payment_url'],
              entry['paymentUrl'],
              entry['checkout_url'],
              entry['checkoutUrl'],
              entry['qr_data'],
              entry['qrData'],
              entry['qr_code'],
              entry['qrCode'],
              entry['upi_qr'],
              entry['upiQr'],
              entry['upi_url'],
              entry['upiUrl'],
            ]) ??
            '');
        if (data.isEmpty) continue;
        normalized.add({
          'type': 'qr',
          'data': data,
          'size': (_toInt(entry['size'] ??
                      entry['module_size'] ??
                      entry['moduleSize']) ??
                  4)
              .clamp(3, 6),
          'max_width_dots': lineWidth <= 32 ? 320 : 360,
          'paper_width_dots': _paperWidthDotsForBackend(lineWidth),
          'errorLevel': _qrErrorLevel(entry['error_level'] ??
              entry['errorLevel'] ??
              qrOptions['error_level'] ??
              qrOptions['errorLevel'] ??
              entry['correction'] ??
              entry['ecc']),
          'options': {
            'align': _backendAlign(entry['align'] ?? qrOptions['align'])
          },
        });
        continue;
      }

      normalized.add(_sanitizeNullTokens(entry));
    }
    return normalized;
  }

  bool _isDuplicatePrintObject(List<dynamic> printObject) {
    for (final entry in printObject) {
      if (entry is Map && entry['type'] == 'text') {
        final text = entry['text']?.toString() ?? '';
        if (_isDuplicateCopyText(text)) return true;
      }
    }
    return false;
  }

  bool _isRawDuplicatePrintObject(List<dynamic> printObject) {
    return _isDuplicatePrintObject(printObject);
  }

  bool _isRawCounterPrintObject(List<dynamic> printObject) {
    return _isDuplicatePrintObject(printObject) ||
        printObject.any((entry) =>
            entry is Map &&
            entry['type'] == 'text' &&
            _isCounterCopyText(entry['text']?.toString() ?? ''));
  }

  bool _isDuplicateCopyText(String text) {
    final value = text.trim().toLowerCase();
    return value == 'duplicate' ||
        value == 'duplicat' ||
        value == 'duplicate copy' ||
        value.contains('duplicate copy');
  }

  bool _isCounterCopyText(String text) {
    final value = text.trim().toLowerCase();
    return value == 'counter' ||
        value == 'counter copy' ||
        value.contains('counter copy');
  }

  bool _hasPrintableBackendContent(List<dynamic> entries) {
    for (final entry in entries) {
      if (entry is! Map) continue;
      final type = entry['type'];
      if (type == 'text') {
        final text = entry['text']?.toString().trim() ?? '';
        if (text.isNotEmpty) return true;
      }
      if (type == 'image' || type == 'qr') return true;
    }
    return false;
  }

  bool _isReceiptFooterText(String text) {
    final value = text.trim().toLowerCase();
    if (value.isEmpty) return false;
    return value.contains('thank you') ||
        value.contains('thanks for your order') ||
        value.contains('visit again');
  }

  List<dynamic> _withTrailingCut(
    List<dynamic> printObject, {
    required bool halfCut,
  }) {
    final out = _clonePrintObject(printObject);
    while (out.isNotEmpty) {
      final last = out.last;
      if (last is Map && (last['type'] == 'feedLine' || _isCutEntry(last))) {
        out.removeLast();
        continue;
      }
      break;
    }
    out.add({'type': 'feedLine'});
    out.add({'type': 'feedLine'});
    out.add({'type': halfCut ? 'halfCutPaper' : 'fullCutPaper'});
    return out;
  }

  List<dynamic> _withInterCopyHalfCuts(List<dynamic> printObject) {
    final cloned = _clonePrintObject(printObject);
    if (!cloned.any(_isCutEntry)) {
      final markerIndex = cloned.indexWhere(_isInterCopyMarker);
      if (markerIndex <= 0) return cloned;
      final out = <dynamic>[
        ...cloned.take(markerIndex),
        {'type': 'feedLine'},
        {'type': 'feedLine'},
        {'type': 'halfCutPaper'},
        ...cloned.skip(markerIndex),
      ];
      return _withTrailingCut(out, halfCut: false);
    }

    final out = <dynamic>[];
    var convertedBoundaryCut = false;
    for (var i = 0; i < cloned.length; i++) {
      final entry = cloned[i];
      if (!_isCutEntry(entry)) {
        out.add(entry);
        continue;
      }
      final hasPrintableAfter = cloned
          .skip(i + 1)
          .any((candidate) => _isPrintablePrintEntry(candidate));
      if (hasPrintableAfter) {
        convertedBoundaryCut = true;
        out.add({'type': 'halfCutPaper'});
      } else {
        out.add({'type': 'fullCutPaper'});
      }
    }

    return convertedBoundaryCut ? _withTrailingCut(out, halfCut: false) : out;
  }

  bool _isPrintablePrintEntry(dynamic entry) {
    if (entry is! Map) return false;
    final type = entry['type']?.toString().trim().toLowerCase() ?? '';
    if (type == 'text') {
      return (entry['text']?.toString().trim() ?? '').isNotEmpty;
    }
    return type == 'image' ||
        type == 'logo' ||
        type == 'qr' ||
        type == 'qrcode' ||
        type == 'qr_code' ||
        type == 'row';
  }

  bool _isInterCopyMarker(dynamic entry) {
    if (entry is! Map) return false;
    final type = entry['type']?.toString().trim().toLowerCase() ?? '';
    if (type != 'text') return false;
    return _isCounterCopyText(entry['text']?.toString() ?? '');
  }

  bool _isFooterImage(Map entry) {
    final source = [
      entry['label'],
      entry['name'],
      entry['bind'],
      entry['toggle'],
      entry['alt'],
      entry['purpose'],
      entry['role'],
    ].map((value) => value?.toString().trim().toLowerCase() ?? '').join(' ');
    return source.contains('powered') ||
        source.contains('powered_by') ||
        source.contains('logo') ||
        source.contains('footer');
  }

  Map<String, dynamic>? _backendImageCommand(
    Map entry, {
    required int lineWidth,
  }) {
    final options = entry['options'] is Map
        ? Map<dynamic, dynamic>.from(entry['options'] as Map)
        : const <dynamic, dynamic>{};
    final url = _firstNonEmptyString([
      entry['url'],
      entry['src'],
      entry['image_url'],
      entry['imageUrl'],
      entry['logo_url'],
      entry['logoUrl'],
      entry['powered_by_url'],
      entry['poweredByUrl'],
    ]);
    final base64 = _firstNonEmptyString([
      entry['base64'],
      entry['image_base64'],
      entry['imageBase64'],
      entry['logo_base64'],
      entry['logoBase64'],
      entry['data_uri'],
      entry['dataUri'],
    ]);
    if (url == null && base64 == null) return null;

    final maxWidth = _toInt(entry['max_width_dots'] ??
            entry['maxWidthDots'] ??
            entry['width']) ??
        (_isFooterImage(entry) ? 220 : 192);
    return {
      'type': 'image',
      if (url != null) 'url': url,
      if (base64 != null) 'base64': base64,
      'max_width_dots': maxWidth.clamp(96, 384),
      'paper_width_dots': _paperWidthDotsForBackend(lineWidth),
      'options': {'align': _backendAlign(entry['align'] ?? options['align'])},
    };
  }

  int _paperWidthDotsForBackend(int lineWidth) {
    if (lineWidth <= 32) return 384;
    if (lineWidth <= 48) return 576;
    return 832;
  }

  String? _firstNonEmptyString(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != 'null') {
        return text;
      }
    }
    return null;
  }

  String _cleanBackendQrData(String value) {
    var text = value.trim().replaceAll(r'\/', '/');
    text = text.replaceAll(RegExp(r'[\r\n\t]'), '');
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  int _qrErrorLevel(dynamic raw) {
    if (raw is num) return raw.toInt().clamp(0, 3);
    final value = raw?.toString().trim().toLowerCase() ?? '';
    switch (value) {
      case 'l':
      case 'low':
        return 0;
      case 'q':
        return 2;
      case 'h':
      case 'high':
        return 3;
      case 'm':
      case 'medium':
      default:
        return _toInt(value)?.clamp(0, 3) ?? 1;
    }
  }

  Map<String, dynamic> _backendTextOptions(Map entry, {String? text}) {
    final existing = entry['options'] is Map
        ? Map<String, dynamic>.from(entry['options'])
        : <String, dynamic>{};
    final style = entry['style']?.toString().toLowerCase() ?? '';
    final rawText = text?.trim() ?? '';
    final bold = style.contains('bold') ||
        style.contains('title') ||
        existing['bold'] == true ||
        (_toInt(existing['fontStyle']) ?? 0) > 0;
    final large = (style.contains('large') || style.contains('title')) &&
        _allowBackendLargeText(rawText);
    final align = _shouldCenterBackendText(rawText, style)
        ? 1
        : _backendAlign(entry['align'] ?? existing['align']);
    return {
      ...existing,
      'align': align,
      'nOrgx': 0,
      if (bold) 'bold': true,
      if (bold) 'fontStyle': 1,
      'widthTimes': large ? 1 : 0,
      'heightTimes': large ? 1 : 0,
      if (large) 'size': 'lg',
    };
  }

  bool _allowBackendLargeText(String text) {
    final value = text.trim();
    if (value.isEmpty) return false;
    if (value.length > 24) return false;
    final lower = value.toLowerCase();
    if (lower.startsWith('order:') ||
        lower.startsWith('transaction:') ||
        lower.contains('http')) {
      return false;
    }
    return true;
  }

  bool _shouldCenterBackendText(String text, String style) {
    final value = text.trim().toLowerCase();
    if (value.isEmpty) return false;
    if (style.contains('title') || style.contains('center')) return true;
    if (value.startsWith('token')) return true;
    if (value == 'paid' ||
        value == 'payment pending' ||
        value.startsWith('method:') ||
        value.startsWith('transaction:')) {
      return true;
    }
    if (_isReceiptFooterText(text)) return true;
    if (value == 'main') return true;
    if (!value.contains(':') &&
        !value.contains(r'$') &&
        !RegExp(r'^\d+\s*x\b').hasMatch(value) &&
        !value.contains('dine') &&
        !value.contains('order') &&
        value.length <= 24) {
      return true;
    }
    return false;
  }

  List<String> _backendTextLines(
    String text,
    Map<String, dynamic> options, {
    required int lineWidth,
  }) {
    final width = lineWidth.clamp(24, 48);
    final align = _toInt(options['align']) ?? 0;
    final out = <String>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final trimmedRaw = align == 0 ? raw.trim() : raw.trimRight();
      if (trimmedRaw.trim().isEmpty) continue;

      final dashMatch = RegExp(r'-{3,}').firstMatch(trimmedRaw);
      if (dashMatch != null) {
        final prefix =
            _cleanBackendText(trimmedRaw.substring(0, dashMatch.start));
        if (prefix.trim().isEmpty) {
          out.add('-' * width);
          continue;
        }
        if (_looksLikeBackendItemLine(prefix)) {
          out.addAll(_wrap(prefix, width));
          continue;
        }
        if (prefix.length >= width) {
          out.addAll(_wrap(prefix, width));
        } else {
          out.add(prefix + ('-' * (width - prefix.length)));
        }
        continue;
      }

      final value = align == 0
          ? _cleanBackendText(trimmedRaw).trimLeft()
          : _cleanBackendText(trimmedRaw);
      final lines = value.length <= width ? [value] : _wrap(value, width);
      if (align == 0) {
        out.addAll(lines.map((line) => line.trimLeft()));
      } else {
        out.addAll(lines.map((line) => line.trim()));
      }
    }
    return out;
  }

  bool _looksLikeBackendItemLine(String value) {
    return RegExp(r'^\s*\d+\s*x\b', caseSensitive: false).hasMatch(value);
  }

  String _cleanBackendText(String value) {
    var out = _printerSafeText(value).trimRight();
    if (out.trim().toLowerCase().startsWith('thank you')) {
      return 'Thank you for your order!';
    }
    out = out.replaceAllMapped(
      RegExp(r'\b(Customer|Order|Subtotal|Total):(?=\S)', caseSensitive: false),
      (match) => '${match.group(1)}: ',
    );
    if (RegExp(r'^\s*\d+\s*x-', caseSensitive: false).hasMatch(out)) {
      out = out.replaceFirstMapped(
        RegExp(r'^(\s*\d+\s*)x-', caseSensitive: false),
        (match) => '${match.group(1)}x ',
      );
      out = out.replaceAll('-', ' ');
      out = out.replaceAll(RegExp(r'\s{2,}'), ' ');
    }
    return out;
  }

  int _backendAlign(dynamic raw) {
    if (raw is num) return raw.toInt().clamp(0, 2);
    final value = raw?.toString().trim().toLowerCase() ?? '';
    if (value == 'center' || value == 'centre') return 1;
    if (value == 'right' || value == 'end') return 2;
    return 0;
  }

  String _formatBackendRow(
    String left,
    String right, {
    required int lineWidth,
  }) {
    final width = lineWidth.clamp(24, 80);
    final l = left.trim();
    final r = _formatBackendRowRight(right);
    if (r.isEmpty) return l;
    if (l.isEmpty) return r.padLeft(width);
    final rightWidth = r.length.clamp(6, 12).toInt();
    final leftWidth = width - rightWidth;
    final wrappedLeft = _wrap(l, leftWidth);
    final leftLines = wrappedLeft.isEmpty ? [''] : wrappedLeft;
    final lines = <String>[];
    for (var i = 0; i < leftLines.length; i++) {
      final line = leftLines[i];
      if (i == 0) {
        lines.add(line.padRight(leftWidth) + r.padLeft(rightWidth));
      } else {
        lines.add(line);
      }
    }
    return lines.join('\n');
  }

  String _formatBackendRowRight(String right) {
    // Backend/admin controls row amount text. Only sanitize unsupported glyphs.
    final value = _printerSafeText(right).trim();
    return value;
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

  Future<List<dynamic>> _embedUsbImageBytes(List<dynamic> printObject) async {
    final out = <dynamic>[];
    for (final entry in printObject) {
      if (entry is Map && _isQrEntry(entry)) {
        final imageEntry = _qrEntryAsImage(entry);
        if (imageEntry != null) {
          out.add(imageEntry);
          continue;
        }
      }
      if (entry is Map && entry['type'] == 'image') {
        try {
          final bytes = await _loadPrintImageBytes(entry);
          if (bytes != null && bytes.isNotEmpty) {
            out.add({
              ...entry,
              'base64': base64Encode(bytes),
            });
            continue;
          }
        } catch (e, stackTrace) {
          kioskLogError(
            "USB image embed skipped source=${_printImageSource(entry)}",
            tag: "PRINT",
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
      out.add(entry);
    }
    return out;
  }

  bool _isQrEntry(Map entry) {
    final type = entry['type']?.toString().trim().toLowerCase() ?? '';
    return type == 'qr' || type == 'qrcode' || type == 'qr_code';
  }

  Map<String, dynamic>? _qrEntryAsImage(Map entry) {
    final data = _cleanBackendQrData(_firstNonEmptyString([
          entry['data'],
          entry['text'],
          entry['value'],
          entry['payload'],
          entry['content'],
          entry['url'],
          entry['qr_url'],
          entry['qrUrl'],
          entry['tracking_url'],
          entry['trackingUrl'],
          entry['payment_url'],
          entry['paymentUrl'],
          entry['checkout_url'],
          entry['checkoutUrl'],
          entry['qr_data'],
          entry['qrData'],
          entry['qr_code'],
          entry['qrCode'],
          entry['upi_qr'],
          entry['upiQr'],
          entry['upi_url'],
          entry['upiUrl'],
        ]) ??
        '');
    if (data.isEmpty) return null;

    final paperWidth = _toInt(entry['paper_width_dots']) ?? 384;
    final maxWidth =
        (_toInt(entry['max_width_dots'] ?? entry['maxWidthDots']) ??
                (paperWidth <= 384 ? 320 : 360))
            .clamp(220, paperWidth);
    final png = _buildQrPng(data, maxWidth);
    return {
      'type': 'image',
      'base64': base64Encode(png),
      'max_width_dots': maxWidth,
      'paper_width_dots': paperWidth,
      'options': {'align': 1},
    };
  }

  Uint8List _buildQrPng(String data, int targetPixels) {
    QrImage? qrImage;
    for (final level in const [
      QrErrorCorrectLevel.H,
      QrErrorCorrectLevel.Q,
      QrErrorCorrectLevel.M,
    ]) {
      try {
        qrImage = QrImage(QrCode.fromData(
          data: data,
          errorCorrectLevel: level,
        ));
        break;
      } catch (_) {}
    }
    if (qrImage == null) {
      qrImage = QrImage(QrCode.fromData(
        data: data,
        errorCorrectLevel: QrErrorCorrectLevel.L,
      ));
    }

    const quietModules = 4;
    final totalModules = qrImage.moduleCount + quietModules * 2;
    final modulePixels = (targetPixels ~/ totalModules).clamp(3, 12);
    final imageSize = totalModules * modulePixels;
    final output = img.Image(imageSize, imageSize);
    img.fill(output, img.getColor(255, 255, 255));
    final black = img.getColor(0, 0, 0);

    for (var row = 0; row < qrImage.moduleCount; row++) {
      for (var col = 0; col < qrImage.moduleCount; col++) {
        if (!qrImage.isDark(row, col)) continue;
        final startX = (col + quietModules) * modulePixels;
        final startY = (row + quietModules) * modulePixels;
        for (var y = 0; y < modulePixels; y++) {
          for (var x = 0; x < modulePixels; x++) {
            output.setPixel(startX + x, startY + y, black);
          }
        }
      }
    }

    return Uint8List.fromList(img.encodePng(output));
  }

  Future<void> _printSunmiImage(Map entry, {required int align}) async {
    try {
      final bytes = await _loadPrintImageBytes(entry);
      if (bytes == null || bytes.isEmpty) return;
      await SunmiPrinter.setAlignment(_toSunmiAlign(align));
      await SunmiPrinter.printImage(bytes);
      await SunmiPrinter.lineWrap(1);
    } catch (e, stackTrace) {
      kioskLogError(
        "Sunmi image print skipped source=${_printImageSource(entry)}",
        tag: "PRINT",
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  String _printImageSource(Map entry) {
    final url = entry['url']?.toString().trim() ?? '';
    if (url.isNotEmpty) return url;
    final base64 = entry['base64']?.toString().trim() ?? '';
    return base64.isNotEmpty ? 'base64-image' : '';
  }

  Future<Uint8List?> _loadPrintImageBytes(Map entry) async {
    var base64 = entry['base64']?.toString().trim() ?? '';
    if (base64.isNotEmpty) {
      final dataUriIndex = base64.indexOf('base64,');
      if (dataUriIndex >= 0) {
        base64 = base64.substring(dataUriIndex + 'base64,'.length);
      }
      return Uint8List.fromList(base64Decode(base64));
    }

    final url = entry['url']?.toString().trim() ?? '';
    if (url.isEmpty) return null;
    return _downloadPrintImage(url);
  }

  Future<Uint8List?> _downloadPrintImage(String url) async {
    final cached = _printImageCache[url];
    if (cached != null) return cached;
    final res = await Dio().get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 4),
      ),
    );
    final data = res.data;
    if (data == null || data.isEmpty) return null;
    final bytes = Uint8List.fromList(data);
    _printImageCache[url] = bytes;
    return bytes;
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
    await SunmiPrinter.printText(_printerSafeText(text), style: style);
  }

  String _printerSafeText(String value) {
    return value
        .replaceAll('₹', 'Rs ')
        .replaceAll('₨', 'Rs ')
        .replaceAll(RegExp(r'\bINR(?=\d)', caseSensitive: false), 'Rs ')
        .replaceAll(RegExp(r'\bRs(?=\d)', caseSensitive: false), 'Rs ')
        .replaceAll(RegExp(r'\bINR\s+', caseSensitive: false), 'Rs ')
        .replaceAll(RegExp(r'Rs\s+'), 'Rs ');
  }

  String _printerSafeCurrency(String value) {
    final safe = _printerSafeText(value).trim();
    if (safe.isEmpty) return 'Rs';
    if (safe.toLowerCase() == 'inr') return 'Rs';
    return safe;
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

List<Map<String, dynamic>> _buildSummaryReceiptIsolate(
  Map<String, dynamic> args,
) {
  const int width = 32;
  final printedAt = _printDateTime(IndiaTime.now());

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
  final printedAt = _printDateTime(IndiaTime.now());

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
  final printedAt = _printDateTime(IndiaTime.now());

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

  String center(String t) => t.trim();

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
  final printedAt = _printDateTime(IndiaTime.now());

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

  String money(num value) => "Rs ${value.toStringAsFixed(2)}";

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
