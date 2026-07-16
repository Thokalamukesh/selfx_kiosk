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

  final base = _assetBaseUrl(DioClient.baseUrl);

  final path =
      normalized.startsWith('/') ? normalized.substring(1) : normalized;
  return _encodeWebSafeUrl('$base$path');
}

String normalizeImageUrlValue(dynamic value) {
  return normalizeImageUrl(value?.toString());
}

String firstImageUrlFromMap(
  Map? source, {
  List<String> keys = const [
    "item_photo_url",
    "category_image",
    "category_image_url",
    "image_url",
    "imageUrl",
    "image",
    "photo_url",
    "photoUrl",
    "photo",
    "item_image",
    "itemImage",
    "thumbnail",
    "thumb",
    "img",
  ],
}) {
  final raw = firstImageValueFromMap(source, keys: keys);
  return normalizeImageUrlValue(raw);
}

dynamic firstImageValueFromMap(
  Map? source, {
  List<String> keys = const [
    "item_photo_url",
    "category_image",
    "category_image_url",
    "image_url",
    "imageUrl",
    "image",
    "photo_url",
    "photoUrl",
    "photo",
    "item_image",
    "itemImage",
    "thumbnail",
    "thumb",
    "img",
  ],
}) {
  if (source == null) return null;

  for (final key in keys) {
    final value = source[key];
    if (_hasImageValue(value)) return value;
  }

  final wanted = keys.map(_normalizeKey).toSet();
  for (final entry in source.entries) {
    if (wanted.contains(_normalizeKey(entry.key.toString())) &&
        _hasImageValue(entry.value)) {
      return entry.value;
    }
  }

  for (final nestedKey in const ["item", "product", "menu_item", "menuItem"]) {
    final nested = source[nestedKey];
    if (nested is Map) {
      final value = firstImageValueFromMap(nested, keys: keys);
      if (_hasImageValue(value)) return value;
    }
  }

  return null;
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
      path.endsWith('.mp4') ||
      path.endsWith('.m4v') ||
      path.endsWith('.mov') ||
      path.endsWith('.webm') ||
      path.endsWith('.avi') ||
      path.endsWith('.mkv') ||
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

String _assetBaseUrl(String apiBaseUrl) {
  final uri = Uri.tryParse(apiBaseUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
  }
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port/';
}

bool _hasImageValue(dynamic value) {
  final text = value?.toString().trim();
  return text != null && text.isNotEmpty && text.toLowerCase() != "null";
}

String _normalizeKey(String value) {
  return value.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");
}
