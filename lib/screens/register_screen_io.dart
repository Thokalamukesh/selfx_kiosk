import 'package:api_selfxo_project/api/kiosk_api.dart';
import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/connectivity_service.dart';
import 'package:api_selfxo_project/core/kiosk_log.dart';
import 'package:api_selfxo_project/printer/register_kiosk.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_service.dart';

class UserIdScreen extends StatefulWidget {
  const UserIdScreen({super.key});

  @override
  State<UserIdScreen> createState() => _UserIdScreenState();
}

class _UserIdScreenState extends State<UserIdScreen> {
  bool loading = false;
  bool hasError = false;
  String? _pairingCode;
  String? _pairingDeviceUuid;
  String? _pairingExpiresAt;
  bool _pairingApproved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _submit();
    });
  }

  Future<void> _submit() async {
    if (loading) return;

    final prefs = await SharedPreferences.getInstance();
    final deviceName = _resolveDeviceName(prefs);
    await prefs.setString("pending_kiosk_device_name", deviceName);

    if (!ConnectivityService.instance.isOnline.value) {
      _showError("No internet connection");
      return;
    }

    setState(() {
      loading = true;
      hasError = false;
      _pairingCode = null;
      _pairingDeviceUuid = null;
      _pairingExpiresAt = null;
      _pairingApproved = false;
    });

    try {
      final existingToken = prefs.getString("auth_token")?.trim() ?? "";
      if (existingToken.isNotEmpty) {
        await prefs.remove("pending_kiosk_device_name");
        await _loadBootstrapForSetup();
        final setupDone = prefs.getBool("kiosk_setup_done") ?? false;
        final printerConfigured =
            (prefs.getString("printer_type")?.trim().isNotEmpty ?? false);
        final readyForWelcome = setupDone && printerConfigured;
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => readyForWelcome
                ? const WelcomeScreen()
                : const RegisterKioskScreen(),
          ),
        );
        return;
      }

      final auth = AuthService();
      await prefs.setBool("kiosk_setup_done", false);
      final session = await auth.startPairing(force: true);
      if (!mounted) return;
      setState(() {
        _pairingCode = session.pairingCode;
        _pairingDeviceUuid = session.deviceUuid;
        _pairingExpiresAt = session.expiresAt;
      });

      final ok = await auth.waitForPairing(
        session,
        onPairingCompleted: () {
          if (!mounted) return;
          setState(() => _pairingApproved = true);
        },
      );
      if (!ok) throw Exception("Registration failed");

      await prefs.remove("pending_kiosk_device_name");
      await prefs.setBool("kiosk_setup_done", false);
      await _loadBootstrapForSetup();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const RegisterKioskScreen()),
      );
    } catch (e) {
      await prefs.remove("pending_kiosk_device_name");
      setState(() => hasError = true);
      final message = e.toString().replaceFirst("Exception: ", "").trim();
      _showError(
        message.isEmpty
            ? "Registration failed. Check ID and Internet."
            : message,
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _resolveDeviceName(SharedPreferences prefs) {
    final pending = prefs.getString("pending_kiosk_device_name")?.trim();
    if (pending != null && pending.isNotEmpty) return pending;

    final saved = prefs.getString("kiosk_name")?.trim();
    if (saved != null && saved.isNotEmpty) return saved;

    return "Kiosk";
  }

  Future<void> _loadBootstrapForSetup() async {
    try {
      await KioskApi().getRestaurantData();
    } catch (e) {
      kioskLogError("Bootstrap after pairing failed: $e", tag: "AUTH");
      if (KioskApi.isBootstrapForbiddenError(e)) {
        throw Exception(KioskApi.bootstrapDisabledHelpMessage(e));
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade800),
    );
  }

  Widget _buildPairingStatus() {
    final code = _pairingCode?.trim();
    final deviceUuid = _pairingDeviceUuid?.trim();
    if (!loading) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6F4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7B7B2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            "Pairing Code",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF7A221B),
            ),
          ),
          if (code != null && code.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildPairingCodeDigits(code),
            const SizedBox(height: 12),
            const Text(
              "Enter this code in the restaurant admin panel.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              deviceUuid == null || deviceUuid.isEmpty
                  ? "Starting pairing..."
                  : "Pairing started. Waiting for code...",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
          if (_pairingExpiresAt != null &&
              _pairingExpiresAt!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              "Expires at ${_pairingExpiresAt!.trim()}",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ],
          const SizedBox(height: 12),
          LinearProgressIndicator(
            minHeight: 3,
            backgroundColor: const Color(0xFFF1D7D4),
            color: _pairingApproved
                ? const Color(0xFF1B8E3E)
                : const Color(0xFF9F342C),
          ),
          const SizedBox(height: 8),
          Text(
            _pairingApproved
                ? "Approved. Opening kiosk..."
                : "Waiting for approval...",
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildPairingCodeDigits(String code) {
    final digits = code.split("");
    return Semantics(
      label: "Pairing code $code",
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < digits.length; i++) ...[
            Expanded(
              child: Container(
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF9F342C),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Text(
                  digits[i],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF9F342C),
                  ),
                ),
              ),
            ),
            if (i != digits.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width > 700;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        backgroundColor: const Color(0xFF9F342C),
        elevation: 0,
        centerTitle: true,
        leadingWidth: isTablet ? 0 : 120,
        leading: isTablet
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Image.asset(
                    "assets/self.png",
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
        title: const Text(
          "Kiosk",
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 28,
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              padding: const EdgeInsets.all(26),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isTablet) ...[
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          "assets/selfxfavicon.jpg",
                          width: 108,
                          height: 108,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  const Text(
                    "Approve this kiosk",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Enter the pairing code in your restaurant admin panel.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildPairingStatus(),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9F342C),
                        foregroundColor: Colors.white,
                      ),
                      child: loading
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _pairingApproved
                                      ? "Opening kiosk"
                                      : "Waiting for approval",
                                ),
                              ],
                            )
                          : const Text("Retry pairing"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
