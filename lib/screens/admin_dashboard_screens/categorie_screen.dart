import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/api/dio_client.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  bool isLoading = true;
  List<Map<String, dynamic>> allCategories = [];
  List<Map<String, dynamic>> filteredCategories = [];
  final Map<int, Map<String, dynamic>> _localOverrides = {};
  static const String _categoryOverridesKey = "admin_category_overrides";

  final TextEditingController searchController = TextEditingController();
  String searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadOverrides().then((_) => _fetchCategories());
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

  // ================= LOAD DATA =================
  Future<void> _loadOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_categoryOverridesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _localOverrides
        ..clear()
        ..addAll(
          decoded.map(
            (k, v) => MapEntry(
              int.tryParse(k.toString()) ?? 0,
              v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{},
            ),
          )..removeWhere((key, value) => key == 0),
        );
    } catch (_) {}
  }

  Future<void> _persistOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _localOverrides.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      await prefs.setString(_categoryOverridesKey, jsonEncode(encoded));
    } catch (_) {}
  }

  void _applyLocalOverride(Map<String, dynamic> category) {
    final id = _categoryId(category);
    if (id == null) return;
    final override = _localOverrides[id];
    if (override == null) return;
    category.addAll(override);
  }

  Future<void> _fetchCategories() async {
    if (!mounted) return;
    setState(() => isLoading = true);

    try {
      final res = await AdminApi().getCategories();
      final List rawData = res.data["categories"] ?? res.data["data"] ?? [];
      final categories = rawData.whereType<Map>().map((raw) {
        final category = Map<String, dynamic>.from(raw);
        _applyLocalOverride(category);
        return category;
      }).toList();

      if (mounted) {
        allCategories = categories;
        _applySearch();
      }
    } catch (e) {}

    if (mounted) setState(() => isLoading = false);
  }

  // ================= SEARCH LOGIC =================
  void _applySearch() {
    searchQuery = searchController.text.toLowerCase().trim();
    if (mounted) {
      setState(() {
        filteredCategories = searchQuery.isEmpty
            ? List<Map<String, dynamic>>.from(allCategories)
            : allCategories.where((cat) {
                final name =
                    (cat["category_name"] ?? "").toString().toLowerCase();
                return name.contains(searchQuery);
              }).toList();
      });
    }
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

  Future<void> _showEditCategoryDialog(Map<String, dynamic> category) async {
    final nameCtrl = TextEditingController(text: _categoryName(category));
    String type = (category["type"] ?? "veg").toString();
    String error = "";
    bool saving = false;
    final catId = _categoryId(category);

    if (catId == null) return;

    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Edit Category",
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
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: "Category Name",
                        prefixIcon: Icon(Icons.category_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: Colors.red.withOpacity(0.2)),
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
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  height: 42,
                  child: OutlinedButton(
                    onPressed:
                        saving ? null : () => Navigator.pop(dialogContext),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text("Cancel"),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: saving
                        ? null
                        : () async {
                            final name = nameCtrl.text.trim();
                            if (name.isEmpty) {
                              setState(() {
                                error = "Enter category name";
                              });
                              return;
                            }
                            setState(() {
                              saving = true;
                              error = "";
                            });
                            try {
                              final body = {
                                "category_name": name,
                                "type": type,
                                "is_active": category["is_active"] ?? 1,
                              };
                              await AdminApi().updateCategory(
                                catId.toString(),
                                body,
                              );
                              _localOverrides[catId] = {
                                ...?_localOverrides[catId],
                                "category_id": catId,
                                "id": catId,
                                "category_name": name,
                                "name": name,
                                "type": type,
                                "is_active": category["is_active"] ?? 1,
                                "isActive": category["is_active"] ?? 1,
                                "active": category["is_active"] ?? 1,
                              };
                              await _persistOverrides();
                              if (!mounted) return;
                              Navigator.pop(dialogContext);
                              _fetchCategories();
                              KioskMemoryService
                                  .instance.mediaRefreshTick.value++;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text("Category updated successfully"),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            } catch (e) {
                              setState(() {
                                error = "Failed to update category";
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
                            "Update",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      nameCtrl.dispose();
    }
  }

  Future<void> _showAddCategoryDialog() async {
    final nameCtrl = TextEditingController();
    String type = "veg";
    String error = "";
    bool saving = false;

    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF9F342C).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.add_box_rounded,
                          color: Color(0xFF9F342C),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        "Create Category",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Enter a category name to add it.",
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: "Category Name",
                        prefixIcon: Icon(Icons.category_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: Colors.red.withOpacity(0.2)),
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
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  height: 42,
                  child: OutlinedButton(
                    onPressed:
                        saving ? null : () => Navigator.pop(dialogContext),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text("Cancel"),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: saving
                        ? null
                        : () async {
                            final name = nameCtrl.text.trim();
                            if (name.isEmpty) {
                              setState(() {
                                error = "Enter category name";
                              });
                              return;
                            }
                            setState(() {
                              saving = true;
                              error = "";
                            });
                            try {
                              final body = {
                                "category_name": name,
                                "type": type,
                                "is_active": 1,
                              };
                              await AdminApi().createCategory(body);
                              if (!mounted) return;
                              Navigator.pop(dialogContext);
                              _fetchCategories();
                              KioskMemoryService
                                  .instance.mediaRefreshTick.value++;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("Category added successfully"),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            } catch (e) {
                              setState(() {
                                error = "Failed to add category";
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
                            "Save",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      nameCtrl.dispose();
    }
  }

  // ================= UPDATE STATUS =================
  Future<void> _toggleCategoryVisibility(int index, bool newValue) async {
    final catId = _categoryId(filteredCategories[index]);
    if (catId == null) return;
    final status = newValue ? 1 : 0;

    // Optimistic Update
    setState(() {
      for (final cat in allCategories) {
        if (_categoryId(cat) == catId) {
          cat["is_active"] = status;
          cat["isActive"] = status;
          cat["active"] = status;
        }
      }
      filteredCategories[index]["is_active"] = status;
      filteredCategories[index]["isActive"] = status;
      filteredCategories[index]["active"] = status;
    });

    try {
      final dio = await DioClient.getAdminDio();
      // Adjust this endpoint to match your actual Category Update API
      await dio.put(
        "admin/category/update/$catId",
        data: {"is_active": status},
      );
      final category = filteredCategories[index];
      _localOverrides[catId] = {
        ...?_localOverrides[catId],
        "category_id": catId,
        "id": catId,
        "category_name": _categoryName(category),
        "name": _categoryName(category),
        "type": category["type"],
        "is_active": status,
        "isActive": status,
        "active": status,
      };
      await _persistOverrides();
      KioskMemoryService.instance.mediaRefreshTick.value++;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Category ${newValue ? 'Enabled' : 'Disabled'}"),
          backgroundColor: newValue ? Colors.green : Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      _fetchCategories(); // Revert on failure
    }
  }

  // ================= UI BUILD =================
  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    // Responsive Grid Logic (Matching ProductsTab)
    int crossAxisCount = 2;
    double aspectRatio = 0.72;

    if (screenWidth > 900) {
      crossAxisCount = 4;
    } else if (screenWidth > 600) {
      crossAxisCount = 3;
    }

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 195, 196, 196),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
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
            Icon(Icons.category_outlined, color: Colors.white),
            SizedBox(width: 8),
            Text(
              "Menu Categories",
              style: TextStyle(
                color: Color.fromARGB(255, 255, 255, 255),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          // 🔥 Top Right Add Product Button
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _showAddCategoryDialog,
              icon: const Icon(
                Icons.add,
                color: Color.fromARGB(255, 255, 255, 255),
              ),
              label: const Text(
                "Add Category",
                style: TextStyle(
                  color: Color.fromARGB(255, 255, 255, 255),
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
                hintText: "Search categories...",
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
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF9F342C)),
            )
          : filteredCategories.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _fetchCategories,
                  color: const Color(0xFF9F342C),
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 100),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 16, 12),
                        child: Text(
                          "CATEGORIES",
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
                          itemCount: filteredCategories.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 16,
                            childAspectRatio: aspectRatio,
                          ),
                          itemBuilder: (context, index) => _categoryCard(index),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _categoryCard(int index) {
    final cat = filteredCategories[index];
    final bool isActive = (cat["is_active"] ?? 1) == 1;
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final String imageUrl =
        cat["category_image"] ?? cat["item_photo_url"] ?? "";
    final String type = (cat["type"] ?? "veg").toString();

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
            flex: 4,
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
                    child: imageUrl.isNotEmpty
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
                                  child:
                                      const Icon(Icons.dinner_dining_rounded),
                                ),
                              );
                            },
                          )
                        : Container(
                            color: Colors.grey[50],
                            child: const Icon(Icons.category),
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
                      child: Icon(Icons.visibility_off, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),

          // Info Section
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          cat["category_name"] ?? "Unknown",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isActive ? Colors.black : Colors.grey,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _showEditCategoryDialog(cat),
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
                    spacing: isTablet ? 12 : 8,
                    runSpacing: isTablet ? 10 : 6,
                    children: [
                      _badge(
                        _typeLabel(type),
                        _typeIcon(type),
                        _typeColor(type),
                      ),
                      _badge(
                        isActive ? "Active" : "Hidden",
                        isActive
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        isActive ? Colors.green : Colors.red,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      height: 24,
                      child: Transform.scale(
                        scale: 0.75,
                        child: Switch.adaptive(
                          value: isActive,
                          activeColor: const Color.fromARGB(255, 44, 159, 48),
                          onChanged: (val) =>
                              _toggleCategoryVisibility(index, val),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.category_outlined, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          const Text(
            "No categories found",
            style: TextStyle(color: Colors.grey, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
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
