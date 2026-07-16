import 'package:flutter/foundation.dart';

void kioskLog(
  Object? message, {
  String tag = 'SELFX',
  Object? error,
  StackTrace? stackTrace,
}) {
  final text = message?.toString() ?? 'null';
  if (!kDebugMode) return;

  debugPrint('[$tag] $text');
  if (error != null) debugPrint('[$tag] error=$error');
  if (stackTrace != null) debugPrint(stackTrace.toString());
}

void kioskLogError(
  Object message, {
  String tag = 'SELFX',
  Object? error,
  StackTrace? stackTrace,
}) {
  kioskLog(
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
  );
}
