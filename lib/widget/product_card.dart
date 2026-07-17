import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';
import 'package:api_selfxo_project/widget/product_description_dialog.dart';

class ProductCardRef extends StatefulWidget {
  final int id;
  final String name;
  final String category;
  final int price;
  final String imagePath;
  final String description;
  final bool isVeg;
  final List<Map<String, dynamic>> variations;
  final List<Map<String, dynamic>> modifiers;
  final int qty;

  final Function(
    int id,
    String name,
    String category,
    int price,
    String image,
    int qty,
    Map<String, dynamic>? variation,
    List<Map<String, dynamic>> modifiers,
    Rect? imageRect,
  ) onAddToCart;

  final int? imageCacheWidth;
  final int? imageCacheHeight;

  const ProductCardRef({
    super.key,
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.imagePath,
    this.description = "",
    required this.isVeg,
    required this.qty,
    required this.onAddToCart,
    this.imageCacheWidth,
    this.imageCacheHeight,
    this.variations = const [],
    this.modifiers = const [],
  });

  @override
  State<ProductCardRef> createState() => _ProductCardRefState();
}

class _ProductCardRefState extends State<ProductCardRef> {
  late int qty;
  BuildContext? _imageContext;
  Map<String, dynamic>? _lastVariation;
  List<Map<String, dynamic>> _lastModifiers = [];

  @override
  void initState() {
    super.initState();
    qty = widget.qty;
  }

  @override
  void didUpdateWidget(covariant ProductCardRef oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.qty != widget.qty) qty = widget.qty;
  }

  bool get _needsCustomization =>
      widget.variations.isNotEmpty || widget.modifiers.isNotEmpty;

  String get _description => cleanProductDescription(widget.description);

  void _addDirect() {
    final newQty = qty + 1;
    setState(() => qty = newQty);
    widget.onAddToCart(
      widget.id,
      widget.name,
      widget.category,
      widget.price,
      widget.imagePath,
      newQty,
      null,
      const [],
      _imageRect(),
    );
  }

  void _remove() {
    final newQty = qty - 1;
    final updatedQty = newQty < 0 ? 0 : newQty;
    if (updatedQty == 0) {
      _lastVariation = null;
      _lastModifiers = [];
    }
    setState(() => qty = updatedQty);

    final variation = _needsCustomization ? _lastVariation : null;
    final modifiers =
        _needsCustomization ? _lastModifiers : const <Map<String, dynamic>>[];
    widget.onAddToCart(
      widget.id,
      widget.name,
      widget.category,
      widget.price,
      widget.imagePath,
      updatedQty,
      variation,
      modifiers,
      _imageRect(),
    );
  }

  Rect? _imageRect() {
    final ctx = _imageContext;
    if (ctx == null) return null;
    final render = ctx.findRenderObject();
    if (render is! RenderBox || !render.attached) return null;
    final topLeft = render.localToGlobal(Offset.zero);
    return topLeft & render.size;
  }

  void _showDescription() {
    if (_description.isEmpty) return;
    showProductDescriptionDialog(
      context: context,
      name: widget.name,
      description: _description,
      imagePath: widget.imagePath,
      isVeg: widget.isVeg,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final bool isCompactWebCard = kIsWeb && !isTablet;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: isCompactWebCard ? 1.42 : 1.2,
              child: _imageSection(),
            ),
            Expanded(child: _infoSection()),
            Padding(
              padding: EdgeInsets.fromLTRB(
                isCompactWebCard ? 8 : 10,
                0,
                isCompactWebCard ? 8 : 10,
                isCompactWebCard ? 6 : 8,
              ),
              child: qty == 0 ? _addButton() : _counter(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageSection() {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = widget.imageCacheWidth ?? (220 * dpr).round();
    final cacheHeight = widget.imageCacheHeight ?? (220 * dpr).round();
    final imageUrl = normalizeImageUrl(widget.imagePath);

    return Builder(
      builder: (ctx) {
        _imageContext = ctx;
        return Stack(
          children: [
            Positioned.fill(
              child: Container(
                key: ValueKey("product-image-${widget.id}"),
                color: Colors.grey.shade100,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _description.isEmpty ? null : _showDescription,
                    child: imageUrl.isNotEmpty
                        ? AppNetworkImage(
                            url: imageUrl,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            gaplessPlayback: true,
                            cacheWidth: cacheWidth,
                            cacheHeight: cacheHeight,
                            fallback: const Center(
                              child: Icon(Icons.fastfood, size: 30),
                            ),
                          )
                        : const Center(child: Icon(Icons.fastfood, size: 30)),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: widget.isVeg ? Colors.green : Colors.red,
                    width: 1.2,
                  ),
                ),
                child: Icon(
                  Icons.circle,
                  size: 6,
                  color: widget.isVeg ? Colors.green : Colors.red,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _infoSection() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = MediaQuery.of(context).size.width > 600;
        final isCompactWebCard = kIsWeb && !isTablet;
        final tightHeight =
            constraints.hasBoundedHeight && constraints.maxHeight < 70;
        final compact = isCompactWebCard || tightHeight;

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: tightHeight ? 0 : (isCompactWebCard ? 1 : 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                widget.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize:
                      tightHeight ? 13 : (isTablet ? 16 : (compact ? 12 : 13)),
                  fontWeight: FontWeight.w600,
                  height: compact ? 1.08 : null,
                ),
              ),
              Text(
                "₹${widget.price}",
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(
                  fontSize:
                      tightHeight ? 14 : (isTablet ? 16 : (compact ? 13 : 14)),
                  fontWeight: FontWeight.bold,
                  color: const Color.fromARGB(255, 0, 0, 0),
                  height: compact ? 1.05 : null,
                ),
              ),
              if (_needsCustomization)
                Padding(
                  padding: EdgeInsets.only(top: compact ? 2 : 4),
                  child: Container(
                    constraints:
                        BoxConstraints(maxWidth: tightHeight ? 116 : 132),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 6 : 8,
                      vertical: compact ? 2 : 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF5E3),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFE9BE72)),
                      boxShadow: tightHeight
                          ? const []
                          : [
                              BoxShadow(
                                color: const Color(0xFF9F342C)
                                    .withValues(alpha: 0.08),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          size: compact ? 9 : 11,
                          color: const Color(0xFF9F342C),
                        ),
                        SizedBox(width: compact ? 3 : 4),
                        Flexible(
                          child: Text(
                            "Variants",
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? 8.5 : 10,
                              color: const Color(0xFF7A2B22),
                              fontWeight: FontWeight.w800,
                              height: 1.0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SizedBox(
                    height: isTablet && !tightHeight ? 12 : (compact ? 0 : 2)),
            ],
          ),
        );
      },
    );
  }

  Widget _addButton() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final bool isCompactWebCard = kIsWeb && !isTablet;
    return SizedBox(
      height: isCompactWebCard ? 28 : 32,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFFF4C66A),
          foregroundColor: const Color(0xFF1F1F1F),
          side: const BorderSide(color: Color(0xFFE2B85E), width: 1),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () =>
            _needsCustomization ? _openCustomizationSheet() : _addDirect(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              size: isCompactWebCard ? 15 : 18,
              color: const Color(0xFF1F1F1F),
            ),
            SizedBox(width: isCompactWebCard ? 4 : 6),
            Text(
              "Add",
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF1F1F1F),
                fontSize: isCompactWebCard ? 12 : 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _counter() {
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final bool isCompactWebCard = kIsWeb && !isTablet;
    final double buttonHeight = isCompactWebCard ? 28 : 32;
    return SizedBox(
      height: buttonHeight,
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: _qtyInnerButton(
                label: "-",
                onTap: _remove,
                isTablet: isTablet,
                backgroundColor: Colors.red,
                textColor: Colors.white,
                height: buttonHeight,
              ),
            ),
            Expanded(
              flex: 3,
              child: Container(
                alignment: Alignment.center,
                child: Text(
                  "$qty",
                  style: TextStyle(
                    fontSize: isTablet ? 16 : (isCompactWebCard ? 12 : 14),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _qtyInnerButton(
                label: "+",
                onTap:
                    _needsCustomization ? _openCustomizationSheet : _addDirect,
                isTablet: isTablet,
                isPrimary: true,
                height: buttonHeight,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyInnerButton({
    required String label,
    required VoidCallback onTap,
    required bool isTablet,
    bool isPrimary = false,
    Color? textColor,
    Color? backgroundColor,
    double? height,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: height ?? (isTablet ? 32 : 28),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: backgroundColor ??
              (isPrimary ? const Color(0xFF1B8E3E) : Colors.white),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isPrimary ? Colors.white : (textColor ?? Colors.black87),
            fontSize: isTablet ? 18 : (kIsWeb ? 14 : 16),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Future<void> _openCustomizationSheet() async {
    final Map<String, dynamic>? result =
        await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _CustomizationSheet(
          name: widget.name,
          imageUrl: widget.imagePath,
          variations: widget.variations,
          modifiers: widget.modifiers,
          onCancel: () => Navigator.pop(context),
          onAdd: (data) => Navigator.pop(context, data),
        ),
      ),
    );

    if (result != null) {
      final int addedQty = (result["qty"] as num?)?.toInt() ?? 1;
      final int newTotalQty = qty + addedQty;
      final variation = result["variation"] as Map<String, dynamic>?;
      final modifiers = List<Map<String, dynamic>>.from(
        result["modifiers"] ?? [],
      );

      setState(() {
        qty = newTotalQty;
        _lastVariation = variation;
        _lastModifiers = modifiers;
      });

      widget.onAddToCart(
        widget.id,
        widget.name,
        widget.category,
        widget.price,
        widget.imagePath,
        newTotalQty,
        variation,
        modifiers,
        _imageRect(),
      );
    }
  }
}

class _CustomizationSheet extends StatefulWidget {
  final String name;
  final String imageUrl;
  final List<Map<String, dynamic>> variations;
  final List<Map<String, dynamic>> modifiers;
  final VoidCallback onCancel;
  final Function(Map<String, dynamic>) onAdd;

  const _CustomizationSheet({
    required this.name,
    required this.imageUrl,
    required this.variations,
    required this.modifiers,
    required this.onCancel,
    required this.onAdd,
  });

  @override
  State<_CustomizationSheet> createState() => _CustomizationSheetState();
}

class _CustomizationSheetState extends State<_CustomizationSheet> {
  int? selectedVariation;
  final Set<int> selectedModifiers = {};
  int quantity = 1;

  String _safeText(dynamic value) {
    if (value == null) return "";
    if (value is String) return value;
    if (value is Map) return value["name"] ?? value["label"] ?? "Option";
    return value.toString();
  }

  bool get canAdd => widget.variations.isEmpty || selectedVariation != null;

  int? _optionId(Map<String, dynamic> value) {
    return int.tryParse(value["id"]?.toString() ?? "");
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width > 600;
    final hasVariants = widget.variations.isNotEmpty;
    final hasModifiers = widget.modifiers.isNotEmpty;
    final hasBoth = hasVariants && hasModifiers;
    final sheetHeightFactor = hasBoth ? (isTablet ? 0.68 : 0.74) : 0.52;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.infinity,
          minHeight: MediaQuery.of(context).size.height * sheetHeightFactor,
          maxHeight: MediaQuery.of(context).size.height * sheetHeightFactor,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFCF7),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: const Color(0xFFE2B85E).withValues(alpha: 0.65),
                width: 1.2,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 30,
                offset: const Offset(0, -10),
              ),
            ],
          ),
          padding: EdgeInsets.fromLTRB(
            0,
            12,
            0,
            MediaQuery.of(context).viewInsets.bottom + 12,
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                Center(
                  child: Container(
                    width: 46,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD6AE63),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFFF0E2CA),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF7A2B22)
                                    .withValues(alpha: 0.08),
                                blurRadius: 18,
                                offset: const Offset(0, 7),
                              ),
                            ],
                          ),
                          child: _buildHeader(),
                        ),
                        const SizedBox(height: 12),
                        if (hasBoth) ...[
                          _customizationNotice(),
                          const SizedBox(height: 12),
                        ],
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (hasVariants) ...[
                                  _sectionTitle(
                                    "Choose Size",
                                    Icons.straighten_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  _animatedOptionRow(
                                    index: 0,
                                    children: widget.variations
                                        .map((v) =>
                                            _buildVariationTile(v, isTablet))
                                        .toList(),
                                  ),
                                  const SizedBox(height: 14),
                                ],
                                if (hasModifiers) ...[
                                  _sectionTitle(
                                    "Add Toppings",
                                    Icons.tune_rounded,
                                  ),
                                  const SizedBox(height: 8),
                                  _animatedOptionRow(
                                    index: hasVariants ? 1 : 0,
                                    children: widget.modifiers
                                        .map((m) =>
                                            _buildModifierTile(m, isTablet))
                                        .toList(),
                                  ),
                                  const SizedBox(height: 14),
                                ],
                              ],
                            ),
                          ),
                        ),
                        _buildActions(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFEBD8B9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              color: Color(0xFFFFF4EA),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 15, color: const Color(0xFF9F342C)),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2A211C),
            ),
          ),
        ],
      ),
    );
  }

  Widget _customizationNotice() {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7FFF8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFBDE5C2)),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 18,
              color: Color(0xFF1B8E3E),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "Size and toppings are available for this item",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xFF175D2D),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animatedOptionRow({
    required int index,
    required List<Widget> children,
  }) {
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 260 + (index * 80)),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        );
      },
      child: SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(right: 4),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, itemIndex) => children[itemIndex],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final int cache = (80 * dpr).round().clamp(1, 512);
    final imageUrl = normalizeImageUrl(widget.imageUrl);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: imageUrl.isNotEmpty
              ? AppNetworkImage(
                  url: imageUrl,
                  width: 80, // Slightly smaller for header
                  height: 80,
                  fit: BoxFit.cover,
                  cacheWidth: cache,
                  cacheHeight: cache,
                  fallback: const Icon(Icons.fastfood, size: 50),
                )
              : const Icon(Icons.fastfood, size: 50),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (widget.variations.isNotEmpty || widget.modifiers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF5E3),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFE9BE72)),
                    ),
                    child: const Text(
                      "Customize your item",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(0xFF7A2B22),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _qtyButton(
                    Icons.remove,
                    quantity > 1 ? () => setState(() => quantity--) : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      "$quantity",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _qtyButton(Icons.add, () => setState(() => quantity++)),
                ],
              ),
            ],
          ),
        ),
        IconButton(onPressed: widget.onCancel, icon: const Icon(Icons.close)),
      ],
    );
  }

  Widget _buildVariationTile(Map<String, dynamic> v, bool isTablet) {
    final optionId = _optionId(v);
    final bool selected = selectedVariation == optionId;
    final String label = _safeText(v["variation"] ?? v["name"]);
    final String priceText = "₹${v["price"] ?? 0}";

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() {
        selectedVariation = optionId;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: isTablet ? 192 : 158,
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF4EA) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? const Color(0xFF9F342C) : Colors.grey.shade200,
            width: selected ? 1.8 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: selected
                  ? const Color(0xFF9F342C).withValues(alpha: 0.16)
                  : Colors.black.withValues(alpha: 0.045),
              blurRadius: selected ? 14 : 8,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: 0,
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color:
                    selected ? const Color(0xFF9F342C) : Colors.grey.shade400,
                size: 19,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: isTablet ? 15 : 14,
                      color: selected
                          ? const Color(0xFF7A2B22)
                          : const Color(0xFF1D1D1F),
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    priceText,
                    style: TextStyle(
                      fontSize: isTablet ? 17 : 16,
                      fontWeight: FontWeight.w900,
                      color: selected
                          ? const Color(0xFF9F342C)
                          : const Color(0xFF2E2E2E),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModifierTile(Map<String, dynamic> m, bool isTablet) {
    final id = _optionId(m);
    final selected = selectedModifiers.contains(id);
    final String label = _safeText(m["name"]);
    final String priceText = m["price"] != null ? "₹${m["price"]}" : "₹0";

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        if (id == null) return;
        setState(() {
          selected ? selectedModifiers.remove(id) : selectedModifiers.add(id);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: isTablet ? 192 : 158,
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF7E8) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? const Color(0xFFD78A19) : Colors.grey.shade200,
            width: selected ? 1.8 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: selected
                  ? const Color(0xFFD78A19).withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.045),
              blurRadius: selected ? 14 : 8,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: 0,
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.add_circle_outline_rounded,
                color:
                    selected ? const Color(0xFFD78A19) : Colors.grey.shade400,
                size: 19,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: isTablet ? 15 : 14,
                      color: selected
                          ? const Color(0xFF7A4A11)
                          : const Color(0xFF1D1D1F),
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    priceText,
                    style: TextStyle(
                      fontSize: isTablet ? 16 : 15,
                      fontWeight: FontWeight.w900,
                      color: selected
                          ? const Color(0xFFD78A19)
                          : const Color(0xFF2E2E2E),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0E2CA)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7A2B22).withValues(alpha: 0.09),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF7A2B22),
                side: const BorderSide(color: Color(0xFFE2B85E), width: 1.2),
                backgroundColor: const Color(0xFFFFFCF7),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 18),
              label: const Text(
                "CANCEL",
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                shadowColor: Colors.green.withValues(alpha: 0.3),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 6,
              ),
              onPressed: canAdd
                  ? () {
                      widget.onAdd({
                        "variation": selectedVariation == null
                            ? null
                            : widget.variations.firstWhere(
                                (v) => _optionId(v) == selectedVariation,
                              ),
                        "modifiers": widget.modifiers
                            .where(
                              (m) => selectedModifiers.contains(_optionId(m)),
                            )
                            .map(
                              (m) => {
                                "id": m["id"],
                                "name": m["name"],
                                "price": m["price"] ?? 0,
                              },
                            )
                            .toList(),
                        "qty": quantity,
                      });
                    }
                  : null,
              icon: const Icon(
                Icons.shopping_cart_rounded,
                size: 18,
                color: Colors.white,
              ),
              label: const FittedBox(
                child: Text(
                  "ADD TO CART",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qtyButton(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null ? Colors.grey : Colors.black,
        ),
      ),
    );
  }
}

///
///
///
/// cz\ategori
