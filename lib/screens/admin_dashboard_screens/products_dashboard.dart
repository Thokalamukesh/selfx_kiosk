import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';

class ProductsTab extends StatefulWidget {
  final VoidCallback onProductsUpdated;

  const ProductsTab({super.key, required this.onProductsUpdated});

  @override
  State<ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<ProductsTab> {
  bool loading = true;
  Map<String, List<Map<String, dynamic>>> groupedProducts = {};
  Map<String, List<Map<String, dynamic>>> filteredProducts = {};
  final Map<int, Map<String, dynamic>> _localOverrides = {};
  static const String _overridesKey = "admin_product_overrides";

  final TextEditingController searchController = TextEditingController();
  String searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadOverrides().then((_) => _loadProducts());
    searchController.addListener(_applySearch);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  void _goToWelcome() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  Future<void> _loadOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_overridesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _localOverrides.clear();
      decoded.forEach((key, value) {
        final id = int.tryParse(key.toString());
        if (id == null) return;
        if (value is Map) {
          _localOverrides[id] = Map<String, dynamic>.from(value);
        }
      });
    } catch (_) {}
  }

  Future<void> _persistOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _localOverrides.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      await prefs.setString(_overridesKey, jsonEncode(encoded));
    } catch (_) {}
  }

  // ================= LOAD DATA =================
  Future<void> _loadProducts() async {
    if (!mounted) return;
    setState(() => loading = true);

    try {
      final dio = await DioClient.getAdminDio();
      final res = await dio.get("admin/items");

      final List items = res.data["items"] ?? res.data["data"] ?? [];
      groupedProducts.clear();

      for (final raw in items) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final nested = item["item"];
        final nestedMap =
            nested is Map ? Map<String, dynamic>.from(nested) : null;

        final directName = item["item_name"] ?? item["name"];
        if (directName == null || directName.toString().trim().isEmpty) {
          final nestedName = nestedMap?["item_name"] ?? nestedMap?["name"];
          if (nestedName != null && nestedName.toString().trim().isNotEmpty) {
            item["item_name"] = nestedName;
          }
        }

        final directPrice = item["price"] ?? item["item_price"];
        if (directPrice == null) {
          final nestedPrice = nestedMap?["price"] ?? nestedMap?["item_price"];
          if (nestedPrice != null) {
            item["price"] = nestedPrice;
          }
        }

        final directImage = item["item_photo_url"] ?? item["image"];
        if (directImage == null || directImage.toString().trim().isEmpty) {
          final nestedImage =
              nestedMap?["item_photo_url"] ?? nestedMap?["image"];
          if (nestedImage != null && nestedImage.toString().trim().isNotEmpty) {
            item["item_photo_url"] = nestedImage;
          }
        }

        if (item["type"] == null && nestedMap?["type"] != null) {
          item["type"] = nestedMap?["type"];
        }

        item["id"] ??= nestedMap?["id"] ?? nestedMap?["item_id"];
        item["item_id"] ??= nestedMap?["item_id"] ?? nestedMap?["id"];

        final directCategory =
            item["category_name"] ?? item["category"] ?? item["cat_name"];
        if (directCategory == null ||
            directCategory.toString().trim().isEmpty) {
          final nestedCategory =
              nestedMap?["category_name"] ?? nestedMap?["category"];
          if (nestedCategory != null &&
              nestedCategory.toString().trim().isNotEmpty) {
            item["category_name"] = nestedCategory;
          }
        }

        _applyLocalOverride(item);
        final category = item["category_name"] ?? "Uncategorized";
        groupedProducts.putIfAbsent(category, () => []);
        groupedProducts[category]!.add(item);
      }

      _applySearch();
    } catch (e) {}

    if (mounted) setState(() => loading = false);
  }

  Future<void> _attachBranchAndRestaurant(Map<String, dynamic> body) async {
    final prefs = await SharedPreferences.getInstance();
    int? branchId = prefs.getInt("branch_id");
    String? restaurantId = prefs.getString("restaurant_id");

    if (branchId == null || restaurantId == null) {
      try {
        final res = await KioskApi().getRestaurantData();
        final kiosk = res.data?["kiosk_settings"];
        if (kiosk != null) {
          branchId ??= kiosk["branch_id"] is int
              ? kiosk["branch_id"]
              : int.tryParse(kiosk["branch_id"].toString());
          restaurantId ??= kiosk["restaurant_id"]?.toString();
          if (branchId != null) {
            await prefs.setInt("branch_id", branchId!);
          }
          if (restaurantId != null && restaurantId.isNotEmpty) {
            await prefs.setString("restaurant_id", restaurantId);
          }
        }
      } catch (_) {
        // ignore - we'll just send without if not available
      }
    }

    if (branchId != null) body["branch_id"] = branchId;
    if (restaurantId != null && restaurantId.isNotEmpty) {
      body["restaurant_id"] = restaurantId;
    }
  }

  // ================= SEARCH LOGIC =================
  void _applySearch() {
    searchQuery = searchController.text.toLowerCase().trim();
    final Map<String, List<Map<String, dynamic>>> temp = {};

    groupedProducts.forEach((category, items) {
      final List<Map<String, dynamic>> matches = searchQuery.isEmpty
          ? List<Map<String, dynamic>>.from(items)
          : items.where((item) {
              final name = _displayName(item).toLowerCase();
              return name.contains(searchQuery);
            }).toList();

      if (matches.isNotEmpty) {
        temp[category] = matches;
      }
    });

    if (mounted) setState(() => filteredProducts = temp);
  }

  int? _categoryId(Map<String, dynamic> cat) {
    final dynamic raw = cat["category_id"] ?? cat["id"];
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  String _categoryName(Map<String, dynamic> cat) {
    return (cat["category_name"] ?? cat["name"] ?? "Category").toString();
  }

  int? _itemId(Map<String, dynamic> item) {
    final dynamic raw = item["id"] ?? item["item_id"] ?? item["itemId"];
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  int? _extractCreatedItemId(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      dynamic raw = data["id"] ??
          data["item_id"] ??
          data["itemId"] ??
          (data["item"] is Map ? data["item"]["id"] : null) ??
          (data["item"] is Map ? data["item"]["item_id"] : null) ??
          (data["data"] is Map ? data["data"]["id"] : null) ??
          (data["product"] is Map ? data["product"]["id"] : null);
      if (raw != null) {
        if (raw is int) return raw;
        return int.tryParse(raw.toString());
      }
    }
    return null;
  }

  Future<int?> _resolveCreatedItemId({
    required String name,
    required num price,
    int? categoryId,
    int? menuId,
  }) async {
    try {
      final res = await AdminApi().getItems();
      final List items = res.data["items"] ?? res.data["data"] ?? const [];
      for (final raw in items) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final nested = item["item"];
        final nestedMap =
            nested is Map ? Map<String, dynamic>.from(nested) : null;
        final id = _itemId(item) ?? _itemId(nestedMap ?? {});
        if (id == null) continue;
        final itemName = (item["item_name"] ??
                nestedMap?["item_name"] ??
                item["name"] ??
                nestedMap?["name"] ??
                "")
            .toString()
            .trim();
        final itemPrice = num.tryParse(
              "${item["price"] ?? item["item_price"] ?? nestedMap?["price"] ?? nestedMap?["item_price"] ?? ""}",
            ) ??
            0;
        final itemCategoryId =
            _categoryId(item) ?? _categoryId({"id": item["item_category_id"]});
        final itemMenuId = _menuId(item) ?? _menuId({"id": item["menu_id"]});
        if (itemName == name &&
            itemPrice == price &&
            (categoryId == null || itemCategoryId == categoryId) &&
            (menuId == null || itemMenuId == menuId)) {
          return id;
        }
      }
    } catch (_) {}
    return null;
  }

  String _displayName(Map<String, dynamic> item) {
    final direct = item["item_name"] ?? item["name"];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString();
    }
    final nested = item["item"];
    if (nested is Map) {
      final n = nested["item_name"] ?? nested["name"];
      if (n != null && n.toString().trim().isNotEmpty) {
        return n.toString();
      }
    }
    return "";
  }

  void _applyLocalOverride(Map<String, dynamic> item) {
    final id = _itemId(item);
    if (id == null) return;
    final override = _localOverrides[id];
    if (override == null) return;
    item.addAll(override);
    final nested = item["item"];
    if (nested is Map) {
      for (final entry in override.entries) {
        nested[entry.key] = entry.value;
      }
    }
  }

  int? _menuId(Map<String, dynamic> menu) {
    final dynamic raw = menu["menu_id"] ?? menu["id"];
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  String _menuName(Map<String, dynamic> menu) {
    return (menu["menu_name"] ?? menu["name"] ?? "Menu").toString();
  }

  Future<void> _showAddProductDialog() async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final parcelCtrl = TextEditingController();
    String type = "veg";
    bool hasVariations = false;
    final List<TextEditingController> variationNameCtrls = [];
    final List<TextEditingController> variationPriceCtrls = [];
    final List<int?> variationIds = [];
    int? selectedCategoryId;
    int? selectedMenuId;
    String error = "";
    bool saving = false;
    bool loadingCats = true;
    List<Map<String, dynamic>> categories = [];
    List<Map<String, dynamic>> menus = [];

    void addVariationRow({String? name, String? price, int? id}) {
      variationNameCtrls.add(TextEditingController(text: name ?? ""));
      variationPriceCtrls.add(TextEditingController(text: price ?? ""));
      variationIds.add(id);
    }

    void disposeVariationCtrls() {
      for (final c in variationNameCtrls) {
        c.dispose();
      }
      for (final c in variationPriceCtrls) {
        c.dispose();
      }
    }

    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) {
            Future<void> loadCats() async {
              try {
                final res = await AdminApi().getItems();
                final List rawMenus = res.data["menus"] ?? [];
                final List rawCats = res.data["categoryList"] ??
                    res.data["categories"] ??
                    res.data["data"] ??
                    [];

                menus = rawMenus
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((m) => _menuId(m) != null)
                    .toList();

                categories = rawCats
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((c) => _categoryId(c) != null)
                    .toList();
                // De-duplicate categories by ID to avoid Dropdown duplicate values
                final Map<int, Map<String, dynamic>> byId = {};
                for (final c in categories) {
                  final id = _categoryId(c);
                  if (id != null) byId[id] = c;
                }
                categories = byId.values.toList();
                if (categories.isNotEmpty) {
                  selectedCategoryId ??= _categoryId(categories.first);
                  final ids =
                      categories.map(_categoryId).whereType<int>().toSet();
                  if (selectedCategoryId != null &&
                      !ids.contains(selectedCategoryId)) {
                    selectedCategoryId = _categoryId(categories.first);
                  }
                }
                if (menus.isNotEmpty) {
                  selectedMenuId ??= _menuId(menus.first);
                  final ids = menus.map(_menuId).whereType<int>().toSet();
                  if (selectedMenuId != null && !ids.contains(selectedMenuId)) {
                    selectedMenuId = _menuId(menus.first);
                  }
                }
              } catch (_) {
                categories = [];
                menus = [];
              } finally {
                if (mounted) {
                  setState(() => loadingCats = false);
                }
              }
            }

            if (loadingCats) {
              loadCats();
            }
            if (hasVariations && variationNameCtrls.isEmpty) {
              addVariationRow();
            }

            final labelStyle = TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
              fontSize: 12,
            );

            InputDecoration inputDecoration(String hint) {
              return InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF9F342C)),
                ),
              );
            }

            Widget fieldBlock(String label, Widget child) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: labelStyle),
                  const SizedBox(height: 6),
                  child,
                ],
              );
            }

            Widget colorSquare(Color color) {
              return Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }

            Widget typeOption({
              required String value,
              required String label,
              required Widget leading,
            }) {
              final selected = type == value;
              return InkWell(
                onTap: () => setState(() => type = value),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 110,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF9F342C)
                          : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      leading,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Add Product",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.redAccent,
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: loadingCats
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            fieldBlock(
                              "Name",
                              TextField(
                                controller: nameCtrl,
                                decoration: inputDecoration("Product name"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Price",
                              TextField(
                                controller: priceCtrl,
                                keyboardType: TextInputType.number,
                                decoration: inputDecoration("0"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Parcel Charge",
                              TextField(
                                controller: parcelCtrl,
                                keyboardType: TextInputType.number,
                                decoration: inputDecoration("0"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Menu",
                              menus.isNotEmpty
                                  ? DropdownButtonFormField<int>(
                                      value: selectedMenuId,
                                      decoration:
                                          inputDecoration("Select menu"),
                                      isExpanded: true,
                                      items: [
                                        for (final m in menus)
                                          DropdownMenuItem<int>(
                                            value: _menuId(m),
                                            child: Text(_menuName(m)),
                                          ),
                                      ],
                                      onChanged: (val) => setState(() {
                                        selectedMenuId = val;
                                      }),
                                    )
                                  : const Text(
                                      "No menus available",
                                      style: TextStyle(color: Colors.red),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Category",
                              categories.isNotEmpty
                                  ? DropdownButtonFormField<int>(
                                      value: selectedCategoryId,
                                      decoration: inputDecoration(
                                        "Select category",
                                      ),
                                      isExpanded: true,
                                      items: [
                                        for (final c in categories)
                                          DropdownMenuItem<int>(
                                            value: _categoryId(c),
                                            child: Text(_categoryName(c)),
                                          ),
                                      ],
                                      onChanged: (val) => setState(() {
                                        selectedCategoryId = val;
                                      }),
                                    )
                                  : const Text(
                                      "No categories available",
                                      style: TextStyle(color: Colors.red),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Type", style: labelStyle),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    typeOption(
                                      value: "veg",
                                      label: "Veg",
                                      leading: colorSquare(Colors.green),
                                    ),
                                    typeOption(
                                      value: "non-veg",
                                      label: "Non Veg",
                                      leading: colorSquare(
                                        const Color(0xFF8D4B2A),
                                      ),
                                    ),
                                    typeOption(
                                      value: "egg",
                                      label: "Egg",
                                      leading: const Icon(
                                        Icons.egg_alt_outlined,
                                        size: 18,
                                        color: Colors.orange,
                                      ),
                                    ),
                                    typeOption(
                                      value: "drink",
                                      label: "Drink",
                                      leading: const Icon(
                                        Icons.local_drink_outlined,
                                        size: 18,
                                        color: Colors.blue,
                                      ),
                                    ),
                                    typeOption(
                                      value: "others",
                                      label: "Other",
                                      leading: const Icon(
                                        Icons.category_outlined,
                                        size: 18,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Switch.adaptive(
                                  value: hasVariations,
                                  onChanged: (val) => setState(() {
                                    hasVariations = val;
                                    if (hasVariations &&
                                        variationNameCtrls.isEmpty) {
                                      addVariationRow();
                                    }
                                  }),
                                  activeColor: const Color(0xFF9F342C),
                                ),
                                const SizedBox(width: 8),
                                Text("Is Variation Product", style: labelStyle),
                              ],
                            ),
                            if (hasVariations) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Text(
                                    "Variations",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => setState(() {
                                      addVariationRow();
                                    }),
                                    icon: const Icon(Icons.add),
                                    label: const Text("Add"),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Column(
                                children: List.generate(
                                  variationNameCtrls.length,
                                  (i) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: TextField(
                                            controller: variationNameCtrls[i],
                                            decoration: const InputDecoration(
                                              labelText: "Name",
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          flex: 2,
                                          child: TextField(
                                            controller: variationPriceCtrls[i],
                                            keyboardType: TextInputType.number,
                                            decoration: const InputDecoration(
                                              labelText: "Price",
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () => setState(() {
                                            variationNameCtrls.removeAt(i);
                                            variationPriceCtrls.removeAt(i);
                                          }),
                                          icon: const Icon(Icons.close_rounded),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.red.withOpacity(0.2),
                                  ),
                                ),
                                child: Text(
                                  error,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            SizedBox(
                                width: double.infinity,
                                height: 44,
                                child: ElevatedButton(
                                  onPressed: saving
                                      ? null
                                      : () async {
                                          final name = nameCtrl.text.trim();
                                          final price = num.tryParse(
                                              priceCtrl.text.trim());
                                          final parcel = num.tryParse(
                                              parcelCtrl.text.trim());

                                          // 🔹 Basic validation
                                          if (name.isEmpty || price == null) {
                                            setState(() {
                                              error =
                                                  "Enter valid name and price";
                                            });
                                            return;
                                          }

                                          if (selectedCategoryId == null) {
                                            setState(() {
                                              error =
                                                  "Please select a category";
                                            });
                                            return;
                                          }

                                          if (selectedMenuId == null) {
                                            setState(() {
                                              error = "Please select a menu";
                                            });
                                            return;
                                          }

                                          // 🔹 Prepare variations
                                          final List<Map<String, dynamic>>
                                              variations = [];

                                          if (hasVariations) {
                                            for (int i = 0;
                                                i < variationNameCtrls.length;
                                                i++) {
                                              final vName =
                                                  variationNameCtrls[i]
                                                      .text
                                                      .trim();
                                              final vPrice = num.tryParse(
                                                  variationPriceCtrls[i]
                                                      .text
                                                      .trim());

                                              if (vName.isEmpty ||
                                                  vPrice == null) continue;

                                              final Map<String, dynamic> v = {
                                                "variation": vName,
                                                "price": vPrice,
                                              };

                                              // ✅ FIXED NULL ERROR HERE
                                              final id = variationIds[i];
                                              if (id != null) {
                                                v["id"] =
                                                    id; // No more int? error
                                              }

                                              variations.add(v);
                                            }

                                            if (variations.isEmpty) {
                                              setState(() {
                                                error =
                                                    "Add at least one variation";
                                              });
                                              return;
                                            }
                                          }

                                          setState(() {
                                            saving = true;
                                            error = "";
                                          });

                                          try {
                                            final Map<String, dynamic> body = {
                                              "item_name": name,
                                              "price": price,
                                              "item_category_id":
                                                  selectedCategoryId!,
                                              "category_id":
                                                  selectedCategoryId!,
                                              "is_available": 1,
                                              "type": type,
                                              "menu_id": selectedMenuId!,
                                              "take_away_charge": parcel ?? 0,
                                              "has_variations":
                                                  hasVariations ? 1 : 0,
                                              "has_variation":
                                                  hasVariations ? 1 : 0,
                                              "variations": hasVariations
                                                  ? variations
                                                  : [],
                                            };

                                            await _attachBranchAndRestaurant(
                                                body);
                                            final res =
                                                await AdminApi().createItem(
                                              body,
                                            );
                                            int? createdId =
                                                _extractCreatedItemId(res.data);
                                            createdId ??=
                                                await _resolveCreatedItemId(
                                              name: name,
                                              price: price,
                                              categoryId: selectedCategoryId,
                                              menuId: selectedMenuId,
                                            );
                                            if (createdId != null) {
                                              String? catName;
                                              if (selectedCategoryId != null) {
                                                final found = categories
                                                    .where(
                                                      (c) =>
                                                          _categoryId(c) ==
                                                          selectedCategoryId,
                                                    )
                                                    .toList();
                                                if (found.isNotEmpty) {
                                                  catName = _categoryName(
                                                    found.first,
                                                  );
                                                }
                                              }
                                              _localOverrides[createdId] = {
                                                "item_name": name,
                                                "name": name,
                                                "price": price,
                                                "item_price": price,
                                                "take_away_charge": parcel ?? 0,
                                                "type": type,
                                                "menu_id": selectedMenuId,
                                                "item_category_id":
                                                    selectedCategoryId,
                                                "category_id":
                                                    selectedCategoryId,
                                                "category_name":
                                                    catName ?? "Uncategorized",
                                                "has_variations":
                                                    hasVariations ? 1 : 0,
                                                "has_variation":
                                                    hasVariations ? 1 : 0,
                                                "variations": hasVariations
                                                    ? variations
                                                    : [],
                                                "id": createdId,
                                                "item_id": createdId,
                                              };
                                              await _persistOverrides();
                                            }

                                            if (!mounted) return;

                                            Navigator.pop(dialogContext);
                                            await _loadProducts();

                                            KioskMemoryService.instance
                                                .mediaRefreshTick.value++;

                                            widget.onProductsUpdated();

                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    "Product added successfully"),
                                                backgroundColor: Colors.green,
                                                duration: Duration(seconds: 1),
                                              ),
                                            );
                                          } catch (e) {
                                            setState(() {
                                              error = "Failed to add product";
                                              saving = false;
                                            });
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF9F342C),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: saving
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          "Add Product",
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold),
                                        ),
                                )),
                          ],
                        ),
                      ),
              ),
            );
          },
        ),
      );
    } finally {
      nameCtrl.dispose();
      priceCtrl.dispose();
      parcelCtrl.dispose();
      disposeVariationCtrls();
    }
  }

  Future<void> _showEditProductDialog(Map<String, dynamic> product) async {
    final nameCtrl = TextEditingController(
      text: (product["item_name"] ?? "").toString(),
    );
    final priceCtrl = TextEditingController(
      text: (product["price"] ?? "").toString(),
    );
    final parcelCtrl = TextEditingController(
      text: (product["take_away_charge"] ?? "").toString(),
    );
    String type = (product["type"] ?? "veg").toString();
    bool hasVariations =
        (product["has_variations"] ?? product["has_variation"]) == 1;
    final List<TextEditingController> variationNameCtrls = [];
    final List<TextEditingController> variationPriceCtrls = [];
    final List<int?> variationIds = [];
    int? selectedCategoryId = _categoryId(product) ??
        _categoryId({"id": product["item_category_id"]});
    int? selectedMenuId =
        _menuId(product) ?? _menuId({"id": product["menu_id"]});
    String error = "";
    bool saving = false;
    bool loadingCats = true;
    List<Map<String, dynamic>> categories = [];
    List<Map<String, dynamic>> menus = [];
    final List variationsFromApi = (product["variations"] as List?) ?? const [];

    void addVariationRow({String? name, String? price, int? id}) {
      variationNameCtrls.add(TextEditingController(text: name ?? ""));
      variationPriceCtrls.add(TextEditingController(text: price ?? ""));
      variationIds.add(id);
    }

    if (hasVariations && variationNameCtrls.isEmpty) {
      for (final v in variationsFromApi) {
        if (v is Map) {
          addVariationRow(
            name: v["variation"]?.toString(),
            price: v["price"]?.toString(),
            id: v["id"] is int ? v["id"] as int : int.tryParse("${v["id"]}"),
          );
        }
      }
      if (variationNameCtrls.isEmpty) addVariationRow();
    }

    void disposeVariationCtrls() {
      for (final c in variationNameCtrls) {
        c.dispose();
      }
      for (final c in variationPriceCtrls) {
        c.dispose();
      }
    }

    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) {
            Future<void> loadCats() async {
              try {
                final res = await AdminApi().getItems();
                final List rawMenus = res.data["menus"] ?? [];
                final List rawCats = res.data["categoryList"] ??
                    res.data["categories"] ??
                    res.data["data"] ??
                    [];

                menus = rawMenus
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((m) => _menuId(m) != null)
                    .toList();

                categories = rawCats
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((c) => _categoryId(c) != null)
                    .toList();
                // De-duplicate categories by ID to avoid Dropdown duplicate values
                final Map<int, Map<String, dynamic>> byId = {};
                for (final c in categories) {
                  final id = _categoryId(c);
                  if (id != null) byId[id] = c;
                }
                categories = byId.values.toList();
                if (categories.isNotEmpty) {
                  selectedCategoryId ??= _categoryId(categories.first);
                  final ids =
                      categories.map(_categoryId).whereType<int>().toSet();
                  if (selectedCategoryId != null &&
                      !ids.contains(selectedCategoryId)) {
                    selectedCategoryId = _categoryId(categories.first);
                  }
                }
                if (menus.isNotEmpty) {
                  selectedMenuId ??= _menuId(menus.first);
                  final ids = menus.map(_menuId).whereType<int>().toSet();
                  if (selectedMenuId != null && !ids.contains(selectedMenuId)) {
                    selectedMenuId = _menuId(menus.first);
                  }
                }
              } catch (_) {
                categories = [];
                menus = [];
              } finally {
                if (mounted) {
                  setState(() => loadingCats = false);
                }
              }
            }

            if (loadingCats) {
              loadCats();
            }
            if (hasVariations && variationNameCtrls.isEmpty) {
              addVariationRow();
            }

            final labelStyle = TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
              fontSize: 12,
            );

            InputDecoration inputDecoration(String hint) {
              return InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF9F342C)),
                ),
              );
            }

            Widget fieldBlock(String label, Widget child) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: labelStyle),
                  const SizedBox(height: 6),
                  child,
                ],
              );
            }

            Widget colorSquare(Color color) {
              return Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }

            Widget typeOption({
              required String value,
              required String label,
              required Widget leading,
            }) {
              final selected = type == value;
              return InkWell(
                onTap: () => setState(() => type = value),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 110,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF9F342C)
                          : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      leading,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            final dialogTitle = nameCtrl.text.trim().isNotEmpty
                ? "Update Product ${nameCtrl.text.trim()}"
                : "Update Product";

            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      dialogTitle,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.redAccent,
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: loadingCats
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            fieldBlock(
                              "Name",
                              TextField(
                                controller: nameCtrl,
                                decoration: inputDecoration("Product name"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Price",
                              TextField(
                                controller: priceCtrl,
                                keyboardType: TextInputType.number,
                                decoration: inputDecoration("0"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Parcel Charge",
                              TextField(
                                controller: parcelCtrl,
                                keyboardType: TextInputType.number,
                                decoration: inputDecoration("0"),
                              ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Menu",
                              menus.isNotEmpty
                                  ? DropdownButtonFormField<int>(
                                      value: selectedMenuId,
                                      decoration:
                                          inputDecoration("Select menu"),
                                      isExpanded: true,
                                      items: [
                                        for (final m in menus)
                                          DropdownMenuItem<int>(
                                            value: _menuId(m),
                                            child: Text(_menuName(m)),
                                          ),
                                      ],
                                      onChanged: (val) => setState(() {
                                        selectedMenuId = val;
                                      }),
                                    )
                                  : const Text(
                                      "No menus available",
                                      style: TextStyle(color: Colors.red),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            fieldBlock(
                              "Category",
                              categories.isNotEmpty
                                  ? DropdownButtonFormField<int>(
                                      value: selectedCategoryId,
                                      decoration: inputDecoration(
                                        "Select category",
                                      ),
                                      isExpanded: true,
                                      items: [
                                        for (final c in categories)
                                          DropdownMenuItem<int>(
                                            value: _categoryId(c),
                                            child: Text(_categoryName(c)),
                                          ),
                                      ],
                                      onChanged: (val) => setState(() {
                                        selectedCategoryId = val;
                                      }),
                                    )
                                  : const Text(
                                      "No categories available",
                                      style: TextStyle(color: Colors.red),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Type", style: labelStyle),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    typeOption(
                                      value: "veg",
                                      label: "Veg",
                                      leading: colorSquare(Colors.green),
                                    ),
                                    typeOption(
                                      value: "non-veg",
                                      label: "Non Veg",
                                      leading: colorSquare(
                                        const Color(0xFF8D4B2A),
                                      ),
                                    ),
                                    typeOption(
                                      value: "egg",
                                      label: "Egg",
                                      leading: const Icon(
                                        Icons.egg_alt_outlined,
                                        size: 18,
                                        color: Colors.orange,
                                      ),
                                    ),
                                    typeOption(
                                      value: "drink",
                                      label: "Drink",
                                      leading: const Icon(
                                        Icons.local_drink_outlined,
                                        size: 18,
                                        color: Colors.blue,
                                      ),
                                    ),
                                    typeOption(
                                      value: "others",
                                      label: "Other",
                                      leading: const Icon(
                                        Icons.category_outlined,
                                        size: 18,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Switch.adaptive(
                                  value: hasVariations,
                                  onChanged: (val) => setState(() {
                                    hasVariations = val;
                                    if (hasVariations &&
                                        variationNameCtrls.isEmpty) {
                                      addVariationRow();
                                    }
                                  }),
                                  activeColor: const Color(0xFF9F342C),
                                ),
                                const SizedBox(width: 8),
                                Text("Is Variation Product", style: labelStyle),
                              ],
                            ),
                            if (hasVariations) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Text(
                                    "Variations",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => setState(() {
                                      addVariationRow();
                                    }),
                                    icon: const Icon(Icons.add),
                                    label: const Text("Add"),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Column(
                                children: List.generate(
                                  variationNameCtrls.length,
                                  (i) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: TextField(
                                            controller: variationNameCtrls[i],
                                            decoration: const InputDecoration(
                                              labelText: "Name",
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          flex: 2,
                                          child: TextField(
                                            controller: variationPriceCtrls[i],
                                            keyboardType: TextInputType.number,
                                            decoration: const InputDecoration(
                                              labelText: "Price",
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () => setState(() {
                                            variationNameCtrls.removeAt(i);
                                            variationPriceCtrls.removeAt(i);
                                            variationIds.removeAt(i);
                                          }),
                                          icon: const Icon(Icons.close_rounded),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.red.withOpacity(0.2),
                                  ),
                                ),
                                child: Text(
                                  error,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            SizedBox(
                                width: double.infinity,
                                height: 44,
                                child: ElevatedButton(
                                  onPressed: saving
                                      ? null
                                      : () async {
                                          final name = nameCtrl.text.trim();
                                          final price = num.tryParse(
                                              priceCtrl.text.trim());
                                          final parcel = num.tryParse(
                                              parcelCtrl.text.trim());

                                          if (name.isEmpty || price == null) {
                                            setState(() {
                                              error =
                                                  "Enter valid name and price";
                                            });
                                            return;
                                          }

                                          if (selectedCategoryId == null) {
                                            setState(() {
                                              error =
                                                  "Please select a category";
                                            });
                                            return;
                                          }

                                          if (selectedMenuId == null) {
                                            setState(() {
                                              error = "Please select a menu";
                                            });
                                            return;
                                          }

                                          final List<Map<String, dynamic>>
                                              variations = [];

                                          if (hasVariations) {
                                            for (int i = 0;
                                                i < variationNameCtrls.length;
                                                i++) {
                                              final vName =
                                                  variationNameCtrls[i]
                                                      .text
                                                      .trim();
                                              final vPrice = num.tryParse(
                                                  variationPriceCtrls[i]
                                                      .text
                                                      .trim());

                                              if (vName.isEmpty ||
                                                  vPrice == null) continue;

                                              final Map<String, dynamic> v = {
                                                "variation": vName,
                                                "price": vPrice,
                                              };

                                              // ✅ FIXED NULL SAFETY ISSUE HERE
                                              final id = variationIds[i];
                                              if (id != null) {
                                                v["id"] =
                                                    id; // No more int? error
                                              }

                                              variations.add(v);
                                            }

                                            if (variations.isEmpty) {
                                              setState(() {
                                                error =
                                                    "Add at least one variation";
                                              });
                                              return;
                                            }
                                          }

                                          setState(() {
                                            saving = true;
                                            error = "";
                                          });

                                          try {
                                            final itemId = _itemId(product);

                                            if (itemId == null) {
                                              setState(() {
                                                error = "Invalid product ID";
                                                saving = false;
                                              });
                                              return;
                                            }

                                            String? newCategoryName;
                                            if (selectedCategoryId != null) {
                                              final found = categories
                                                  .where(
                                                    (c) =>
                                                        _categoryId(c) ==
                                                        selectedCategoryId,
                                                  )
                                                  .toList();
                                              if (found.isNotEmpty) {
                                                newCategoryName =
                                                    _categoryName(found.first);
                                              }
                                            }

                                            final Map<String, dynamic> body = {
                                              "item_name": name,
                                              "price": price,
                                              "item_category_id":
                                                  selectedCategoryId!,
                                              "category_id":
                                                  selectedCategoryId!,
                                              "is_available":
                                                  product["is_available"] ?? 1,
                                              "type": type,
                                              "menu_id": selectedMenuId!,
                                              "item_id": itemId,
                                              "id": itemId,
                                              "take_away_charge": parcel ?? 0,
                                              "has_variations":
                                                  hasVariations ? 1 : 0,
                                              "has_variation":
                                                  hasVariations ? 1 : 0,
                                              "variations": hasVariations
                                                  ? variations
                                                  : [],
                                            };

                                            await _attachBranchAndRestaurant(
                                                body);

                                            await AdminApi().updateItem(
                                              itemId.toString(),
                                              body,
                                            );

                                            if (!mounted) return;

                                            _localOverrides[itemId] = {
                                              "item_name": name,
                                              "name": name,
                                              "price": price,
                                              "item_price": price,
                                              "take_away_charge": parcel ?? 0,
                                              "type": type,
                                              "menu_id": selectedMenuId,
                                              "item_category_id":
                                                  selectedCategoryId,
                                              "category_id": selectedCategoryId,
                                              "category_name":
                                                  newCategoryName ??
                                                      product["category_name"],
                                              "has_variations":
                                                  hasVariations ? 1 : 0,
                                              "has_variation":
                                                  hasVariations ? 1 : 0,
                                              "variations": hasVariations
                                                  ? variations
                                                  : [],
                                            };
                                            await _persistOverrides();

                                            if (mounted) {
                                              this.setState(() {
                                                groupedProducts.forEach((
                                                  _,
                                                  list,
                                                ) {
                                                  list.removeWhere(
                                                    (p) => _itemId(p) == itemId,
                                                  );
                                                });
                                                final updated =
                                                    <String, dynamic>{
                                                  ...product,
                                                  ..._localOverrides[itemId]!,
                                                  "id": itemId,
                                                  "item_id": itemId,
                                                };
                                                final catKey =
                                                    (updated["category_name"] ??
                                                            "Uncategorized")
                                                        .toString();
                                                groupedProducts.putIfAbsent(
                                                  catKey,
                                                  () => [],
                                                );
                                                groupedProducts[catKey]!
                                                    .add(updated);
                                                _applySearch();
                                              });
                                            }

                                            Navigator.pop(dialogContext);

                                            await _loadProducts();

                                            KioskMemoryService.instance
                                                .mediaRefreshTick.value++;

                                            widget.onProductsUpdated();

                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    "Product updated successfully"),
                                                backgroundColor: Colors.green,
                                                duration: Duration(seconds: 1),
                                              ),
                                            );
                                          } catch (e) {
                                            setState(() {
                                              error =
                                                  "Failed to update product";
                                              saving = false;
                                            });
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF9F342C),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: saving
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          "Update Product",
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold),
                                        ),
                                )),
                          ],
                        ),
                      ),
              ),
            );
          },
        ),
      );
    } finally {
      nameCtrl.dispose();
      priceCtrl.dispose();
      parcelCtrl.dispose();
      disposeVariationCtrls();
    }
  }

  // ================= UPDATE STATUS =================
  Future<void> _updateAvailability(int? id, bool available) async {
    if (id == null) return;
    final status = available ? 1 : 0;
    setState(() {
      groupedProducts.forEach((_, list) {
        final idx = list.indexWhere((p) => _itemId(p) == id);
        if (idx != -1) {
          list[idx]["is_available"] = status;
          list[idx]["isAvailable"] = status;
          list[idx]["available"] = status;
        }
      });
      _applySearch();
    });

    try {
      final dio = await DioClient.getAdminDio();
      await dio.put(
        "admin/item/update/$id",
        data: {"is_available": status},
      );
      _localOverrides[id] = {
        ...?_localOverrides[id],
        "id": id,
        "item_id": id,
        "is_available": status,
        "isAvailable": status,
        "available": status,
      };
      await _persistOverrides();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Product ${available ? 'Enabled' : 'Disabled'}"),
          backgroundColor: available ? Colors.green : Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
      KioskMemoryService.instance.mediaRefreshTick.value++;
      widget.onProductsUpdated();
    } catch (e) {
      _loadProducts();
    }
  }

  // ================= UI BUILD =================
  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    int crossAxisCount = 2;
    double aspectRatio = 0.76; // Matches CategoriesScreen exactly

    if (screenWidth > 900) {
      crossAxisCount = 4;
    } else if (screenWidth > 600) {
      crossAxisCount = 3;
    }

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 195, 196, 196),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C), // Matches Categories Header
        elevation: 0,
        leadingWidth: 120,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Image.asset(
              "assets/self.png",
              height: 36,
              fit: BoxFit.contain,
            ),
          ),
        ),
        title: const Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: Colors.white),
            SizedBox(width: 8),
            Text(
              "Manage Inventory",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _showAddProductDialog,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                "Add Product",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: _goToWelcome,
            icon: const Icon(Icons.logout_rounded),
            color: Colors.white,
            tooltip: "Exit",
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: "Search products...",
                prefixIcon: const Icon(Icons.search, color: Color(0xFF9F342C)),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: searchController.clear,
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF9F342C)),
            )
          : filteredProducts.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadProducts,
                  color: const Color(0xFF9F342C),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 100),
                    itemCount: filteredProducts.length,
                    itemBuilder: (context, index) {
                      String category = filteredProducts.keys.elementAt(index);
                      List<Map<String, dynamic>> items =
                          filteredProducts[category]!;
                      return _categorySection(
                        category,
                        items,
                        crossAxisCount,
                        aspectRatio,
                      );
                    },
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inventory_2_outlined, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          const Text(
            "No products found",
            style: TextStyle(color: Colors.grey, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _categorySection(
    String category,
    List<Map<String, dynamic>> items,
    int count,
    double ratio,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 16, 12),
          child: Text(
            category.toUpperCase(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Colors.blueGrey,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: ratio,
            ),
            itemBuilder: (_, i) => _productCard(items[i]),
          ),
        ),
      ],
    );
  }

  Widget _productCard(Map<String, dynamic> p) {
    final bool isActive = p["is_available"] == 1;
    final String? imageUrl = p["item_photo_url"];
    final String type = (p["type"] ?? "veg").toString();
    final num parcelCharge =
        num.tryParse((p["take_away_charge"] ?? "0").toString()) ?? 0;
    final bool hasVariations =
        (p["has_variations"] ?? p["has_variation"] ?? 0) == 1;
    final bool isWide = MediaQuery.of(context).size.width >= 900;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image Section
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: ColorFiltered(
                    colorFilter: isActive
                        ? const ColorFilter.mode(
                            Colors.transparent,
                            BlendMode.multiply,
                          )
                        : const ColorFilter.mode(
                            Colors.grey,
                            BlendMode.saturation,
                          ),
                    child: imageUrl != null && imageUrl.isNotEmpty
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              final dpr =
                                  MediaQuery.of(context).devicePixelRatio;
                              final cacheWidth = (constraints.maxWidth * dpr)
                                  .round()
                                  .clamp(1, 4096);
                              final cacheHeight = (constraints.maxHeight * dpr)
                                  .round()
                                  .clamp(1, 4096);
                              return Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                cacheWidth: cacheWidth,
                                cacheHeight: cacheHeight,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.grey[100],
                                  child: const Icon(
                                    Icons.dining_sharp,
                                    size: 110,
                                  ),
                                ),
                              );
                            },
                          )
                        : Container(
                            color: Colors.grey[50],
                            child: const Icon(
                              Icons.fastfood,
                              color: Colors.grey,
                            ),
                          ),
                  ),
                ),
                if (!isActive)
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(18),
                      ),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.visibility_off,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Info Section
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _displayName(p).isEmpty ? "-" : _displayName(p),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            "₹${p["price"] ?? 0}",
                            style: TextStyle(
                              fontSize: isWide ? 14 : 13,
                              color: const Color(0xFF9F342C),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            onPressed: () => _showEditProductDialog(p),
                            icon: const Icon(Icons.edit, size: 18),
                            color: const Color(0xFF9F342C),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: "Edit",
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _badge(
                            _typeLabel(type),
                            _typeIcon(type),
                            _typeColor(type),
                            compact: !isWide,
                          ),
                          if (parcelCharge > 0)
                            _badge(
                              "Parcel ₹${parcelCharge.toStringAsFixed(0)}",
                              Icons.local_shipping_outlined,
                              const Color(0xFF7C6B43),
                              compact: !isWide,
                            ),
                          if (hasVariations)
                            _badge(
                              "Variations",
                              Icons.tune_rounded,
                              const Color(0xFF2F6F9E),
                              compact: !isWide,
                            ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _statusPill(isActive, compact: !isWide),
                      SizedBox(
                        height: 24,
                        child: Transform.scale(
                          scale: 0.75,
                          child: Switch.adaptive(
                            value: isActive,
                            activeColor: const Color.fromARGB(255, 63, 159, 44),
                            onChanged: (val) =>
                                _updateAvailability(_itemId(p), val),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(
    String text,
    IconData icon,
    Color color, {
    bool compact = true,
  }) {
    final double fontSize = compact ? 10 : 11;
    final double iconSize = compact ? 12 : 14;
    final EdgeInsets padding = EdgeInsets.symmetric(
      horizontal: compact ? 8 : 10,
      vertical: compact ? 4 : 6,
    );
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(bool active, {bool compact = true}) {
    final color = active ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    final text = active ? "Active" : "Hidden";
    final double fontSize = compact ? 10 : 11;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case "non-veg":
        return "Non‑Veg";
      case "egg":
        return "Egg";
      case "drink":
        return "Drink";
      case "others":
        return "Others";
      default:
        return "Veg";
    }
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case "non-veg":
        return Icons.restaurant_rounded;
      case "egg":
        return Icons.egg_alt_outlined;
      case "drink":
        return Icons.local_cafe_outlined;
      case "others":
        return Icons.category_outlined;
      default:
        return Icons.eco_outlined;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case "non-veg":
        return const Color(0xFFD35454);
      case "egg":
        return const Color(0xFFE6A243);
      case "drink":
        return const Color(0xFF3C8DAD);
      case "others":
        return const Color(0xFF6D6D6D);
      default:
        return const Color(0xFF2E8B57);
    }
  }
}
