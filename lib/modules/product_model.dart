class ProductModel {
  final int id;
  final String name;
  final String category;
  final int price;
  final String image;
  final String description;
  bool? isBestSeller;
  final String type;

  // 🔥 ADD THESE TWO FIELDS
  final List<Map<String, dynamic>> variations;
  final List<Map<String, dynamic>> modifiers;

  ProductModel({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.image,
    this.description = "",
    this.type = "veg",
    this.isBestSeller = false,
    this.variations = const [], // Default empty
    this.modifiers = const [], // Default empty
  });

  static dynamic _firstNonEmptyType(List<dynamic> values) {
    for (final v in values) {
      if (v == null) continue;
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) continue;
        return s;
      }
      return v;
    }
    return null;
  }

  static String normalizeType(dynamic value) {
    if (value == null) return "veg";
    if (value is bool) return value ? "veg" : "non-veg";
    if (value is num) {
      if (value == 1) return "veg";
      if (value == 0) return "non-veg";
    }
    final s = value.toString().toLowerCase().trim();
    if (s.isEmpty) return "veg";
    if (s == "1" || s == "v" || s == "veg" || s == "vegetarian") {
      return "veg";
    }
    if (s == "0" ||
        s == "n" ||
        s == "nv" ||
        s == "nonveg" ||
        s == "non-veg" ||
        s == "non_veg" ||
        s == "non veg" ||
        s == "nonvegetarian" ||
        s == "non-vegetarian" ||
        s == "egg") {
      return "non-veg";
    }
    if (s == "drink" ||
        s == "drinks" ||
        s == "beverage" ||
        s == "beverages" ||
        s == "other" ||
        s == "others") {
      return "veg";
    }
    if (s.contains("non") && s.contains("veg")) return "non-veg";
    if (s.contains("veg")) return "veg";
    return s;
  }

  bool get isVeg => normalizeType(type) == "veg";

  factory ProductModel.fromJson(Map<String, dynamic> json) {
    final preferredType = _firstNonEmptyType([
      json["type"],
      json["veg_type"],
      json["vegType"],
      json["food_type"],
      json["foodType"],
      json["item_type"],
      json["itemType"],
    ]);
    final fallbackType = _firstNonEmptyType([
      json["is_veg"],
      json["isVeg"],
      json["is_vegetarian"],
      json["isVegetarian"],
      json["vegetarian"],
    ]);
    final rawType = preferredType ?? fallbackType;
    return ProductModel(
      id: json["id"] ?? json["item_id"] ?? 0,
      name: json["item_name"] ?? "",
      category: json["category_name"] ?? "",
      price: int.tryParse(json["price"].toString()) ?? 0,
      image: json["item_photo_url"] ??
          json["image_url"] ??
          json["image"] ??
          json["photo_url"] ??
          "",
      description: (json["description"] ??
              json["item_description"] ??
              json["itemDescription"] ??
              json["short_description"] ??
              json["shortDescription"] ??
              "")
          .toString(),
      type: normalizeType(rawType),
      isBestSeller: json["is_best_seller"] == 1 || json["best_selling"] == 1,
      // ✅ Map from API keys
      variations: json["variations"] != null
          ? List<Map<String, dynamic>>.from(json["variations"])
          : [],
      modifiers: json["modifiers"] != null
          ? List<Map<String, dynamic>>.from(json["modifiers"])
          : [],
    );
  }
}
