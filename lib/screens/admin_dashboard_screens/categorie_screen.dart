import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:api_selfxo_project/api/admin_api.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/image_url.dart';
import 'package:api_selfxo_project/core/kiosk_memory_service.dart';
import 'package:api_selfxo_project/widget/app_network_image.dart';
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
      if (_localOverrides.isEmpty) {
        await prefs.remove(_categoryOverridesKey);
        return;
      }
      final encoded = _localOverrides.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      await prefs.setString(_categoryOverridesKey, jsonEncode(encoded));
    } catch (_) {}
  }

  Future<void> _fetchCategories() async {
    if (!mounted) return;
    setState(() => isLoading = true);

    try {
      final res = await AdminApi().getCategories();
      final List rawData = res.data["categories"] ?? res.data["data"] ?? [];
      final categories = rawData
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .toList();

      if (_localOverrides.isNotEmpty) {
        _localOverrides.clear();
        await _persistOverrides();
      }

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

  String _normalizedKey(String key) =>
      key.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");

  dynamic _readCategoryValue(Map<String, dynamic> category, List<String> keys) {
    for (final key in keys) {
      if (category.containsKey(key)) return category[key];
    }

    final wanted = keys.map(_normalizedKey).toSet();
    for (final entry in category.entries) {
      if (wanted.contains(_normalizedKey(entry.key.toString()))) {
        return entry.value;
      }
    }
    return null;
  }

  bool? _truthyStatus(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final normalized = value.toString().toLowerCase().trim();
    if (normalized.isEmpty) return null;
    if (normalized == "0" ||
        normalized == "false" ||
        normalized == "no" ||
        normalized == "n" ||
        normalized == "off" ||
        normalized == "inactive" ||
        normalized == "disabled" ||
        normalized == "hidden" ||
        normalized == "unavailable" ||
        normalized == "not_available") {
      return false;
    }
    if (normalized == "1" ||
        normalized == "true" ||
        normalized == "yes" ||
        normalized == "y" ||
        normalized == "on" ||
        normalized == "active" ||
        normalized == "enabled" ||
        normalized == "available") {
      return true;
    }
    return null;
  }

  bool _isCategoryActive(Map<String, dynamic> category) {
    final raw = _readCategoryValue(category, const [
      "is_active",
      "isActive",
      "active",
      "is_available",
      "isAvailable",
      "available",
      "enabled",
      "status",
      "category_status",
      "categoryStatus",
    ]);
    return _truthyStatus(raw) ?? true;
  }

  String _categoryType(Map<String, dynamic> category) {
    return (_readCategoryValue(category, const [
              "type",
              "category_type",
              "categoryType",
            ]) ??
            "veg")
        .toString();
  }

  void _setCategoryStatus(Map<String, dynamic> category, int status) {
    category["is_active"] = status;
    category["isActive"] = status;
    category["active"] = status;
    category["is_available"] = status;
    category["isAvailable"] = status;
    category["available"] = status;
    category["enabled"] = status;
    category["status"] = status;
    category["category_status"] = status;
    category["categoryStatus"] = status;
  }

  Future<Map<String, dynamic>?> _fetchBackendCategory(int catId) async {
    final res = await AdminApi().getCategories();
    _throwIfBackendFailed(res);
    final List rawData = res.data["categories"] ?? res.data["data"] ?? [];
    for (final raw in rawData.whereType<Map>()) {
      final category = Map<String, dynamic>.from(raw);
      if (_categoryId(category) == catId) return category;
    }
    return null;
  }

  List<Map<String, dynamic>> _categoryStatusPayloads(
    Map<String, dynamic> category,
    int status,
  ) {
    final name = _categoryName(category);
    final type = _categoryType(category);
    final full = {
      "category_name": name,
      "name": name,
      "type": type,
      "is_active": status,
      "isActive": status,
      "active": status,
      "is_available": status,
      "isAvailable": status,
      "available": status,
      "enabled": status,
      "status": status,
      "category_status": status,
      "categoryStatus": status,
    };

    return [
      full,
      {"category_name": name, "type": type, "is_active": status},
      {"category_name": name, "type": type, "status": status},
      {"category_name": name, "type": type, "active": status},
      {"category_name": name, "type": type, "is_available": status},
      {"category_name": name, "type": type, "category_status": status},
      {"is_active": status},
      {"status": status},
      {"active": status},
      {"is_available": status},
      {"category_status": status},
    ];
  }

  Future<Map<String, dynamic>?> _updateCategoryStatusOnBackend(
    int catId,
    Map<String, dynamic> category,
    int status,
  ) async {
    Exception? lastError;
    final expectedActive = status == 1;
    final seenPayloads = <String>{};

    for (final body in _categoryStatusPayloads(category, status)) {
      final signature = jsonEncode(body);
      if (!seenPayloads.add(signature)) continue;

      try {
        final res = await AdminApi().updateCategory(catId.toString(), body);
        _throwIfBackendFailed(res);
        final backendCategory = await _fetchBackendCategory(catId);
        if (backendCategory == null ||
            _isCategoryActive(backendCategory) == expectedActive) {
          return backendCategory;
        }
        lastError = Exception("Backend did not save the category status");
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }

    throw lastError ?? Exception("Failed to update category status");
  }

  String _responseMessage(dynamic data) {
    if (data is Map) {
      final message = data["message"] ?? data["error"] ?? data["errors"];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString().trim();
      }
    }
    return "Backend rejected the category update";
  }

  void _throwIfBackendFailed(dynamic response) {
    final code = response.statusCode as int?;
    if (code != null && code >= 400) {
      throw Exception(_responseMessage(response.data));
    }
  }

  Future<void> _showEditCategoryDialog(Map<String, dynamic> category) async {
    final nameCtrl = TextEditingController(text: _categoryName(category));
    String type = _categoryType(category);
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
                                "is_active":
                                    _isCategoryActive(category) ? 1 : 0,
                                "status": _isCategoryActive(category) ? 1 : 0,
                                "is_available":
                                    _isCategoryActive(category) ? 1 : 0,
                              };
                              final res = await AdminApi().updateCategory(
                                catId.toString(),
                                body,
                              );
                              _throwIfBackendFailed(res);
                              _localOverrides.remove(catId);
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
                                "status": 1,
                                "is_available": 1,
                              };
                              final res = await AdminApi().createCategory(body);
                              _throwIfBackendFailed(res);
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
    final category = Map<String, dynamic>.from(filteredCategories[index]);
    final catId = _categoryId(category);
    if (catId == null) return;
    final status = newValue ? 1 : 0;

    // Optimistic Update
    setState(() {
      for (final cat in allCategories) {
        if (_categoryId(cat) == catId) {
          _setCategoryStatus(cat, status);
        }
      }
      _setCategoryStatus(filteredCategories[index], status);
    });

    try {
      await _updateCategoryStatusOnBackend(catId, category, status);
      _localOverrides.remove(catId);
      await _persistOverrides();
      await _fetchCategories();
      if (!mounted) return;
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst("Exception: ", "")),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
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
    final bool isActive = _isCategoryActive(cat);
    final bool isTablet = MediaQuery.of(context).size.width > 600;
    final String imageUrl = firstImageUrlFromMap(
      cat,
      keys: const [
        "category_image",
        "category_image_url",
        "image_url",
        "imageUrl",
        "image",
        "photo_url",
        "photoUrl",
        "photo",
        "thumbnail",
        "thumb",
        "img",
      ],
    );
    final String type = _categoryType(cat);

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
                              return AppNetworkImage(
                                url: imageUrl,
                                fit: BoxFit.cover,
                                cacheWidth: cacheWidth,
                                cacheHeight: cacheHeight,
                                fallback: Container(
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
