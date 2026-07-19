import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/admin_api.dart';
import '../screens/admin_dashboard_screens/adim_homescreen.dart';

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  bool loading = false;
  String error = "";
  String _pin = "";
  String? _terminalName;
  String? _restaurantName;
  Color _accent = const Color(0xFF9F342C);

  @override
  void initState() {
    super.initState();
    _loadDisplayMeta();
  }

  // =========================================================
  // VERIFY ADMIN PIN
  // =========================================================
  Future<void> _verifyPin([String? value]) async {
    final pin = (value ?? _pin).trim();

    if (pin.length != 6) {
      HapticFeedback.selectionClick();
      setState(() => error = "Enter the 6-digit kiosk PIN");
      return;
    }

    setState(() {
      loading = true;
      error = "";
    });

    try {
      final res = await AdminApi().login(deviceId: "", pin: pin);

      // ✅ SAFE TOKEN EXTRACTION
      final token = res.data?["token"];
      if (token == null || token.toString().isEmpty) {
        throw Exception("Admin token missing");
      }

      if (!mounted) return;
      final navigator = Navigator.of(context, rootNavigator: true);

      // ✅ CLOSE PIN DIALOG
      navigator.pop();

      // ✅ GO TO ADMIN HOME
      navigator.pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const AdminHomeScreen(),
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 160),
          transitionsBuilder: (_, animation, __, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.015),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        ),
      );
    } catch (e) {
      HapticFeedback.heavyImpact();
      setState(() {
        error = AdminApi.errorMessage(e);
        _pin = "";
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadDisplayMeta() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _terminalName = _firstText([
        prefs.getString("kiosk_name"),
        prefs.getString("terminal_name"),
        prefs.getString("device_uuid"),
      ]);
      _restaurantName = _firstText([
        prefs.getString("restaurant_name"),
        prefs.getString("branch_name"),
        "SELFX Kiosk",
      ]);
      _accent = _parseColor(
        _firstText([
          prefs.getString("restaurant_primary_color"),
          prefs.getString("primary_color"),
        ]),
      );
    });
  }

  void _appendDigit(String digit) {
    if (loading || _pin.length >= 6) return;
    HapticFeedback.selectionClick();
    final next = "$_pin$digit";
    setState(() {
      _pin = next;
      error = "";
    });
    if (next.length == 6) {
      Future.microtask(() => _verifyPin(next));
    }
  }

  void _deleteDigit() {
    if (loading || _pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      error = "";
    });
  }

  void _clearPin() {
    if (loading || _pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin = "";
      error = "";
    });
  }

  // =========================================================
  // UI
  // =========================================================
  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Material(
              color: const Color(0xFFF7F4EF),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                    child: _buildPanel(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 20, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border:
            Border(bottom: BorderSide(color: Colors.black.withOpacity(0.06))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              onPressed: loading
                  ? null
                  : () => Navigator.of(context, rootNavigator: true).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
              color: const Color(0xFF2D2623),
              tooltip: "Back",
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Staff mode",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF241F1C),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if ((_terminalName ?? "").isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _terminalName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _accent,
                  Color.lerp(_accent, Colors.black, 0.28) ?? _accent,
                ],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.admin_panel_settings_rounded,
              color: Colors.white,
              size: 38,
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            "Enter kiosk PIN",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF241F1C),
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            _restaurantName == null
                ? "Use the PIN set in admin for this device."
                : "Unlock ${_restaurantName!} admin controls.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 22),
          _buildPinBoxes(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: error.isEmpty
                ? const SizedBox(height: 18, key: ValueKey("empty-error"))
                : Padding(
                    key: ValueKey(error),
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Color(0xFFD32F2F),
                          size: 17,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            error,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFD32F2F),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 4),
          _buildKeypad(),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: loading || _pin.length != 6 ? null : _verifyPin,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.2,
                      ),
                    )
                  : const Icon(Icons.lock_open_rounded, size: 20),
              label: Text(
                loading ? "Unlocking" : "Unlock admin",
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                disabledForegroundColor: Colors.grey.shade600,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinBoxes() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final filled = index < _pin.length;
        final active = index == _pin.length && !loading;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 52,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: filled ? _accent.withOpacity(0.1) : const Color(0xFFF4F1EC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color:
                  filled || active ? _accent : Colors.black.withOpacity(0.08),
              width: filled || active ? 1.8 : 1,
            ),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 120),
              child: filled
                  ? Icon(
                      Icons.circle,
                      key: ValueKey("dot-$index"),
                      size: 13,
                      color: _accent,
                    )
                  : const SizedBox.shrink(key: ValueKey("blank")),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      "1",
      "2",
      "3",
      "4",
      "5",
      "6",
      "7",
      "8",
      "9",
      "clear",
      "0",
      "delete",
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 18),
      itemCount: keys.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.05,
      ),
      itemBuilder: (context, index) => _buildKey(keys[index]),
    );
  }

  Widget _buildKey(String value) {
    final isDelete = value == "delete";
    final isClear = value == "clear";
    final enabled = !loading && (!isDelete || _pin.isNotEmpty);
    return Material(
      color: isClear ? Colors.transparent : const Color(0xFFF4F1EC),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: !enabled
            ? null
            : isDelete
                ? _deleteDigit
                : isClear
                    ? _clearPin
                    : () => _appendDigit(value),
        borderRadius: BorderRadius.circular(14),
        child: Center(
          child: isDelete
              ? Icon(
                  Icons.backspace_outlined,
                  color: enabled ? const Color(0xFF332C28) : Colors.grey,
                  size: 22,
                )
              : Text(
                  isClear ? "Clear" : value,
                  style: TextStyle(
                    color: isClear
                        ? (_pin.isEmpty ? Colors.grey : _accent)
                        : const Color(0xFF241F1C),
                    fontSize: isClear ? 13 : 22,
                    fontWeight: isClear ? FontWeight.w800 : FontWeight.w900,
                  ),
                ),
        ),
      ),
    );
  }

  String? _firstText(Iterable<String?> values) {
    for (final value in values) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != "null") {
        return text;
      }
    }
    return null;
  }

  Color _parseColor(String? raw) {
    const fallback = Color(0xFF9F342C);
    if (raw == null || raw.trim().isEmpty) return fallback;
    var value = raw.trim().replaceAll("#", "");
    if (value.length == 6) value = "FF$value";
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return fallback;
    return Color(parsed);
  }
}
