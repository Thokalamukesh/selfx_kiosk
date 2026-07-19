// ignore_for_file: avoid_web_libraries_in_flutter, undefined_prefixed_name

import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:flutter/material.dart';

int _nextNetworkImageId = 0;

class AppNetworkImage extends StatefulWidget {
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
  final String? debugLabel;

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
    this.preferPlatformView = true,
    this.debugLabel,
  });

  @override
  State<AppNetworkImage> createState() => _AppNetworkImageState();
}

class _AppNetworkImageState extends State<AppNetworkImage> {
  String? _viewType;
  html.ImageElement? _imageElement;
  StreamSubscription<html.Event>? _loadSub;
  StreamSubscription<html.Event>? _errorSub;
  bool _htmlError = false;
  bool _htmlLoaded = false;
  bool _disposed = false;
  bool _usePlatformView = false;
  String? _platformViewUrl;
  Timer? _loadTimeout;

  @override
  void initState() {
    super.initState();
    _usePlatformView = widget.preferPlatformView;
    if (_usePlatformView) {
      _ensurePlatformView();
    }
  }

  @override
  void didUpdateWidget(covariant AppNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _htmlError = false;
      _htmlLoaded = false;
      _platformViewUrl = null;
      if (!widget.preferPlatformView) {
        _usePlatformView = false;
      }
    }

    if (widget.preferPlatformView && !_usePlatformView) {
      _usePlatformView = true;
    }

    if (_usePlatformView &&
        (oldWidget.url != widget.url ||
            oldWidget.fit != widget.fit ||
            oldWidget.alignment != widget.alignment ||
            oldWidget.preferPlatformView != widget.preferPlatformView)) {
      _ensurePlatformView();
    }
  }

  void _bindEvents(html.ImageElement imageElement) {
    _loadSub?.cancel();
    _errorSub?.cancel();
    _loadTimeout?.cancel();
    _loadSub = imageElement.onLoad.listen((_) {
      if (!mounted || _disposed) return;
      _loadTimeout?.cancel();
      final width = imageElement.naturalWidth;
      final height = imageElement.naturalHeight;
      _log("loaded url=${_safeUrl(widget.url)} natural=${width}x$height");
      setState(() {
        _htmlError = false;
        _htmlLoaded = true;
      });
    });
    _errorSub = imageElement.onError.listen((_) {
      if (!mounted || _disposed) return;
      _loadTimeout?.cancel();
      _log("error url=${_safeUrl(widget.url)}");
      setState(() {
        _htmlError = true;
        _htmlLoaded = false;
      });
    });
  }

  void _ensurePlatformView() {
    if (_disposed) return;
    final url = widget.url.trim();
    if (url.isEmpty) {
      _htmlError = true;
      _htmlLoaded = false;
      _log("empty url");
      return;
    }

    if (_viewType == null) {
      _viewType = 'app-network-image-${_nextNetworkImageId++}';
      ui_web.platformViewRegistry.registerViewFactory(_viewType!, (int viewId) {
        return _imageElement ?? html.ImageElement();
      });
    }

    final imageElement = _imageElement ?? html.ImageElement();
    _imageElement = imageElement;
    _platformViewUrl = url;
    _htmlError = false;
    _htmlLoaded = false;
    _bindEvents(imageElement);
    _log("start platform_view url=${_safeUrl(url)} fit=${widget.fit.name}");

    imageElement
      ..src = url
      ..alt = ''
      ..draggable = false
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0'
      ..style.margin = '0'
      ..style.padding = '0'
      ..style.display = 'block'
      ..style.pointerEvents = 'none'
      ..style.userSelect = 'none'
      ..style.objectFit = _cssFit(widget.fit)
      ..style.objectPosition = _cssAlignment(widget.alignment);

    if (imageElement.complete == true && imageElement.naturalWidth > 0) {
      _loadTimeout?.cancel();
      _log(
        "loaded-from-cache url=${_safeUrl(url)} natural=${imageElement.naturalWidth}x${imageElement.naturalHeight}",
      );
      _htmlLoaded = true;
      _htmlError = false;
      return;
    }

    _loadTimeout = Timer(const Duration(seconds: 8), () {
      if (!mounted || _disposed || _platformViewUrl != url || _htmlLoaded) {
        return;
      }
      _log("timeout url=${_safeUrl(url)}");
      setState(() {
        _htmlError = true;
        _htmlLoaded = false;
      });
    });
  }

  void _switchToPlatformView() {
    if (_usePlatformView || _disposed || !mounted) return;
    setState(() {
      _usePlatformView = true;
      _htmlError = false;
    });
    _ensurePlatformView();
  }

  String _cssFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.contain:
        return 'contain';
      case BoxFit.fill:
        return 'fill';
      case BoxFit.none:
        return 'none';
      case BoxFit.scaleDown:
        return 'scale-down';
      case BoxFit.fitHeight:
      case BoxFit.fitWidth:
      case BoxFit.cover:
        return 'cover';
    }
  }

  String _cssAlignment(Alignment alignment) {
    final x = ((alignment.x + 1) / 2 * 100).clamp(0, 100).toStringAsFixed(0);
    final y = ((alignment.y + 1) / 2 * 100).clamp(0, 100).toStringAsFixed(0);
    return '$x% $y%';
  }

  @override
  void dispose() {
    _disposed = true;
    _loadSub?.cancel();
    _errorSub?.cancel();
    _loadTimeout?.cancel();
    _imageElement
      ?..src = ''
      ..remove();
    super.dispose();
  }

  void _log(String message) {
    final label = widget.debugLabel?.trim();
    if (label == null || label.isEmpty) return;
    kioskLog("$label $message", tag: "IMAGE");
  }

  String _safeUrl(String value) {
    final clean = value.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    return clean.length <= 160 ? clean : "${clean.substring(0, 160)}...";
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url.trim();
    if (url.isEmpty) {
      _log("fallback reason=empty");
      return widget.fallback;
    }

    if (_usePlatformView) {
      if (_htmlError || _viewType == null) {
        _log(
          "fallback reason=${_viewType == null ? 'no_view_type' : 'html_error'}",
        );
        return widget.fallback;
      }
      if (_platformViewUrl != url) {
        _ensurePlatformView();
      }
      final platformView = SizedBox(
        width: widget.width,
        height: widget.height,
        child: IgnorePointer(
          ignoring: true,
          child: HtmlElementView(viewType: _viewType!),
        ),
      );
      if (!_htmlLoaded) {
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.fallback,
            Opacity(opacity: 0, child: platformView),
          ],
        );
      }
      return platformView;
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Image.network(
        url,
        fit: widget.fit,
        alignment: widget.alignment,
        width: widget.width,
        height: widget.height,
        cacheWidth: widget.cacheWidth,
        cacheHeight: widget.cacheHeight,
        gaplessPlayback: widget.gaplessPlayback,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) {
          _log(
              "flutter-image error switching-to-platform-view url=${_safeUrl(url)}");
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _switchToPlatformView();
          });
          return widget.fallback;
        },
      ),
    );
  }
}
