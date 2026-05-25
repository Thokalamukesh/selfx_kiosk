import 'package:api_selfxo_project/api/dio_client.dart';

String normalizeImageUrl(String? raw) {
  final trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) return '';

  final normalized = trimmed.replaceAll('\\', '/');

  if (normalized.startsWith('data:')) {
    return normalized;
  }
  if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
    return _encodeWebSafeUrl(normalized);
  }
  if (normalized.startsWith('//')) {
    return _encodeWebSafeUrl('https:$normalized');
  }
  if (RegExp(r'^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/|$)').hasMatch(normalized)) {
    return _encodeWebSafeUrl('https://$normalized');
  }

  var base = DioClient.baseUrl;
  if (base.contains('/api/')) {
    base = base.replaceFirst('/api/', '/');
  }
  if (!base.endsWith('/')) {
    base = '$base/';
  }

  final path =
      normalized.startsWith('/') ? normalized.substring(1) : normalized;
  return _encodeWebSafeUrl('$base$path');
}

String normalizeImageUrlValue(dynamic value) {
  return normalizeImageUrl(value?.toString());
}

bool isSupportedRasterImageUrl(String? raw) {
  final trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) return false;

  final lower = trimmed.toLowerCase();
  if (lower.startsWith('data:')) {
    return lower.startsWith('data:image/png') ||
        lower.startsWith('data:image/jpeg') ||
        lower.startsWith('data:image/jpg') ||
        lower.startsWith('data:image/gif') ||
        lower.startsWith('data:image/webp') ||
        lower.startsWith('data:image/bmp');
  }

  final path = Uri.tryParse(trimmed)?.path.toLowerCase() ?? lower;
  if (path.endsWith('.svg') ||
      path.endsWith('.svgz') ||
      path.endsWith('.avif') ||
      path.endsWith('.heic') ||
      path.endsWith('.heif') ||
      path.endsWith('.tif') ||
      path.endsWith('.tiff') ||
      path.endsWith('.pdf')) {
    return false;
  }

  return true;
}

String _encodeWebSafeUrl(String url) {
  try {
    return Uri.encodeFull(url);
  } catch (_) {
    return url;
  }
}
