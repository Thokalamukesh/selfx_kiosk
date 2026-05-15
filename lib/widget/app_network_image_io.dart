import 'package:flutter/material.dart';

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
    if (url.trim().isEmpty) return fallback;
    return Image.network(
      url,
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      gaplessPlayback: gaplessPlayback,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
