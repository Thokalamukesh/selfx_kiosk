import 'package:flutter/material.dart';
import 'package:api_selfxo_project/core/image_url.dart';

class AppNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final Alignment alignment;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;
  final Widget fallback;
  final bool gaplessPlayback;
  final bool preferPlatformView;

  const AppNetworkImage({
    super.key,
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.gaplessPlayback = false,
    this.preferPlatformView = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isSupportedRasterImageUrl(url)) return fallback;
    return Image.network(
      url,
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      gaplessPlayback: gaplessPlayback,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
