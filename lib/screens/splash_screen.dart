import 'package:api_selfxo_project/background_image/background_image.dart';
import 'package:api_selfxo_project/core/kiosk_bootstrap.dart';
import 'package:api_selfxo_project/printer/register_kiosk.dart';
import 'package:api_selfxo_project/screens/register_screen.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _initStarted = false;
  bool _didNavigate = false;
  bool _skipVisualSplash = false;
  @override
  void initState() {
    super.initState();
    _skipVisualSplash = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _init();
    });
  }

  Future<void> _init() async {
    if (_initStarted) return;
    _initStarted = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final authToken = prefs.getString("auth_token")?.trim() ?? "";
      final setupDone = prefs.getBool("kiosk_setup_done") ?? false;
      final printerConfigured =
          (prefs.getString("printer_type")?.trim().isNotEmpty ?? false);
      final readyForWelcome = setupDone && printerConfigured;
      if (!mounted) return;

      if (_didNavigate) return;
      if (authToken.isEmpty) {
        _didNavigate = true;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const UserIdScreen()),
        );
        return;
      }

      try {
        await DeviceBootstrap.ensureDeviceReady();
      } catch (e) {
        // Bootstrap will retry from the destination screen.
      }

      if (!mounted) return;
      if (_didNavigate) return;
      _didNavigate = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => readyForWelcome
              ? const WelcomeScreen()
              : const RegisterKioskScreen(),
        ),
      );
    } catch (e) {
      if (!mounted || _didNavigate) return;
      _didNavigate = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const UserIdScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_skipVisualSplash) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            "assets/spalsh.jpeg",
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}
