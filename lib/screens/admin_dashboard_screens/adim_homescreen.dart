import 'dart:async';
import 'package:api_selfxo_project/screens/admin_dashboard_screens/categorie_screen.dart';
import 'package:flutter/material.dart';
import 'package:api_selfxo_project/core/order_utils.dart';
import 'package:api_selfxo_project/screens/admin_dashboard_screens/products_dashboard.dart';
// Import your category screen here
// import 'package:api_selfxo_project/screens/admin_dashboard_screens/categories_dashboard.dart';

import 'dashboard.dart';
import 'order_history.dart';
import 'settings.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  int index = 0;
  int badgeCount = 0;

  bool _badgeLoading = false;

  late final List<Widget?> _pages;

  @override
  void initState() {
    super.initState();
    _pages = List<Widget?>.filled(5, null);
    _pages[0] = const DashboardTab();
  }

  Widget _pageFor(int pageIndex) {
    final existing = _pages[pageIndex];
    if (existing != null) return existing;
    final created = switch (pageIndex) {
      0 => const DashboardTab(),
      1 => const CategoriesScreen(),
      2 => ProductsTab(onProductsUpdated: () {}),
      3 => const OrdersHistoryTab(),
      4 => const SettingsScreen(),
      _ => const SizedBox.shrink(),
    };
    _pages[pageIndex] = created;
    return created;
  }

  Future<void> _refreshBadge() async {
    if (_badgeLoading) return;
    _badgeLoading = true;
    try {
      // This uses OrderUtils which we updated to map 'uuid' to 'transaction_id'
      final count = await OrderUtils.getPendingOrderCount();
      if (mounted) setState(() => badgeCount = count);
    } catch (e) {
    } finally {
      _badgeLoading = false;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: List.generate(
          _pages.length,
          (pageIndex) => _pages[pageIndex] ?? const SizedBox.shrink(),
        ),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      height: 95,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: index,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: const Color(0xFF9F342C),
        unselectedItemColor: Colors.grey.shade500,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        selectedFontSize: 13,
        unselectedFontSize: 12,
        selectedIconTheme: const IconThemeData(size: 26),
        unselectedIconTheme: const IconThemeData(size: 24),
        onTap: (i) => setState(() {
          index = i;
          _pageFor(i);
        }),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            label: "Dashboard",
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.category_outlined),
            label: "Categories",
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2_outlined),
            label: "Products",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            label: "Orders",
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: "Settings",
          ),
        ],
      ),
    );
  }
}
