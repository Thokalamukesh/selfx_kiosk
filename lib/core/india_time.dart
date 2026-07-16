import 'package:intl/intl.dart';

class IndiaTime {
  static const Duration offset = Duration(hours: 5, minutes: 30);

  static DateTime now() => toWallTime(DateTime.now().toUtc());

  static DateTime toWallTime(DateTime value) {
    final utc = value.isUtc ? value : value.toUtc();
    final shifted = utc.add(offset);
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  static DateTime? parseDateValue(dynamic value) {
    if (value == null) return null;
    try {
      if (value is DateTime) return toWallTime(value);
      if (value is int) return fromEpoch(value);
      if (value is double) return fromEpoch(value.toInt());
      if (value is String) return parseDateString(value);
    } catch (_) {}
    return null;
  }

  static DateTime fromEpoch(int value) {
    final millis = value > 1000000000000 ? value : value * 1000;
    return toWallTime(DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true));
  }

  static DateTime? parseDateString(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final formatted = parseRestaurantFormattedDate(trimmed);
    if (formatted != null) return formatted;

    final direct = DateTime.tryParse(trimmed);
    if (direct != null) {
      if (hasExplicitTimezone(trimmed)) return toWallTime(direct);
      return toWallTime(_asUtcInstant(direct));
    }

    for (final pattern in const [
      'yyyy-MM-dd HH:mm:ss.SSS',
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd hh:mm a',
      'dd MMM yyyy, hh:mm a',
      'dd MMM yyyy, HH:mm',
      'dd/MM/yyyy HH:mm',
      'MMM dd, yyyy hh:mm a',
      'MMMM dd, yyyy hh:mm a',
      'yyyy-MM-dd',
    ]) {
      try {
        return toWallTime(DateFormat(pattern).parse(trimmed, true));
      } catch (_) {}
    }

    if (trimmed.contains(' ') && !trimmed.contains('T')) {
      final parsed = DateTime.tryParse(trimmed.replaceFirst(' ', 'T'));
      if (parsed != null) {
        if (hasExplicitTimezone(trimmed)) return toWallTime(parsed);
        return toWallTime(_asUtcInstant(parsed));
      }
    }

    return null;
  }

  static DateTime? parseRestaurantFormattedDate(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final cleaned = raw
        .replaceAll(RegExp(r"\s+"), " ")
        .replaceAll(RegExp(r"\s*-\s*"), " ")
        .trim();
    for (final pattern in const [
      "d MMM y h:mm a",
      "d MMM y hh:mm a",
      "dd MMM y h:mm a",
      "dd MMM y hh:mm a",
      "d MMMM y h:mm a",
      "d MMMM y hh:mm a",
      "dd MMMM y h:mm a",
      "dd MMMM y hh:mm a",
      "d MMM y HH:mm",
      "dd MMM y HH:mm",
    ]) {
      try {
        return DateFormat(pattern).parseStrict(cleaned);
      } catch (_) {}
    }
    return null;
  }

  static String formatWall(DateTime value, String pattern) {
    return DateFormat(pattern).format(value);
  }

  static bool hasExplicitTimezone(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith("Z") ||
        RegExp(r"[+-]\d{2}:?\d{2}$").hasMatch(trimmed);
  }

  static DateTime _asUtcInstant(DateTime value) {
    return DateTime.utc(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }
}
