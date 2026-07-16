import 'package:flutter/material.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';

String cleanProductDescription(dynamic value) {
  final raw = value?.toString().trim() ?? "";
  final text = raw
      .replaceAll(RegExp(r"<br\s*/?>", caseSensitive: false), "\n")
      .replaceAll(RegExp(r"</p\s*>", caseSensitive: false), "\n")
      .replaceAll(RegExp(r"<[^>]+>"), "")
      .replaceAll("&nbsp;", " ")
      .replaceAll("&amp;", "&")
      .replaceAll("&quot;", '"')
      .replaceAll("&#39;", "'")
      .replaceAll(RegExp(r"[ \t]+\n"), "\n")
      .replaceAll(RegExp(r"\n{3,}"), "\n\n")
      .trim();
  if (text.isEmpty || text.toLowerCase() == "null") return "";
  return text;
}

Future<void> showProductDescriptionDialog({
  required BuildContext context,
  required String name,
  required String description,
  required String imagePath,
  required bool isVeg,
}) {
  final cleanDescription = cleanProductDescription(description);
  if (cleanDescription.isEmpty) return Future.value();

  final accent = isVeg ? const Color(0xFF1B8E3E) : const Color(0xFFC62828);
  final imageUrl = normalizeImageUrl(imagePath);
  final dpr = MediaQuery.of(context).devicePixelRatio;
  final cacheWidth = (420 * dpr).round().clamp(1, 2048);
  final cacheHeight = (240 * dpr).round().clamp(1, 2048);

  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      final maxWidth =
          media.size.width >= 700 ? 460.0 : media.size.width * 0.90;

      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: media.size.height < 520 ? 150 : 190,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (imageUrl.isNotEmpty)
                          AppNetworkImage(
                            url: imageUrl,
                            fit: BoxFit.cover,
                            cacheWidth: cacheWidth,
                            cacheHeight: cacheHeight,
                            fallback: _DescriptionImageFallback(
                              accent: accent,
                            ),
                          )
                        else
                          _DescriptionImageFallback(accent: accent),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0.02),
                                Colors.black.withOpacity(0.52),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Material(
                            color: Colors.white.withOpacity(0.92),
                            shape: const CircleBorder(),
                            child: IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded),
                              color: const Color(0xFF1F1F1F),
                              onPressed: () => Navigator.pop(dialogContext),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 18,
                          right: 18,
                          bottom: 16,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: accent,
                                    width: 1.4,
                                  ),
                                ),
                                child: Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    height: 1.05,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.notes_rounded, size: 18, color: accent),
                            const SizedBox(width: 8),
                            Text(
                              "Description",
                              style: TextStyle(
                                color: accent,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: media.size.height * 0.32,
                          ),
                          child: SingleChildScrollView(
                            child: Text(
                              cleanDescription,
                              style: const TextStyle(
                                color: Color(0xFF2D2D2D),
                                fontSize: 15.5,
                                height: 1.42,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DescriptionImageFallback extends StatelessWidget {
  final Color accent;

  const _DescriptionImageFallback({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: accent.withOpacity(0.10),
      alignment: Alignment.center,
      child: Icon(Icons.fastfood_rounded, size: 52, color: accent),
    );
  }
}
