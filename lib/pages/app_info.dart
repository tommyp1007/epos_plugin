import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/language_service.dart';
import '../utils/api_urls.dart';
import 'login_page.dart'; 

class AppInfoPage extends StatelessWidget {
  final String? connectedDeviceName;

  const AppInfoPage({Key? key, this.connectedDeviceName}) : super(key: key);

  // --- ANDROID SPECIFIC: Battery Optimization ---
  Future<void> _requestBatteryOptimizationManual() async {
    // We wrap this in a check to ensure it never runs on iOS
    if (!Platform.isAndroid) return;

    var status = await Permission.ignoreBatteryOptimizations.status;

    if (status.isGranted) {
      await openAppSettings();
    } else {
      var result = await Permission.ignoreBatteryOptimizations.request();
      if (result.isDenied || result.isPermanentlyDenied) {
        await openAppSettings();
      }
    }
  }

  // --- LOGOUT HANDLER (iOS & Android Compatible) ---
  Future<void> _handleLogout(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Get current base URL so we don't accidentally switch environments
      // If null, fallback to PreProd (since you are likely testing on PreProd)
      String currentBaseUrl = prefs.getString('env_url') ?? ApiUrls.preProd;

      // 2. Clear Local Session Flag
      await prefs.setBool('is_logged_in', false);

      // 3. Clear WebView Cookies 
      // This is crucial for iOS. If you don't do this, the WebView 
      // might remember the previous session (Odoo session_id) even after the app restarts.
      final cookieManager = WebViewCookieManager();
      await cookieManager.clearCookies();

      // 4. Navigate to LoginPage in "Logout Mode"
      // We use pushAndRemoveUntil to clear the navigation stack, 
      // so the user cannot click "Back" to return to the settings.
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => LoginPage(
              url: currentBaseUrl, 
              isLogout: true, // Triggers the /session/logout logic in LoginPage
            ),
          ),
          (route) => false, // Remove all previous routes
        );
      }
    } catch (e) {
      debugPrint("Logout error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);

    return Scaffold(
      appBar: AppBar(title: Text(lang.translate('title_settings'))),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ============================
            // 1. LANGUAGE SECTION
            // ============================
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                lang.translate('sec_language').toUpperCase(),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Container(
              color: Colors.white,
              child: Column(
                children: [
                  RadioListTile<String>(
                    title: const Text("English"),
                    secondary: const Text("🇬🇧", style: TextStyle(fontSize: 20)),
                    value: 'en',
                    groupValue: lang.currentLanguage,
                    onChanged: (val) => lang.setLanguage('en'),
                  ),
                  const Divider(height: 1, indent: 16),
                  RadioListTile<String>(
                    title: const Text("Bahasa Melayu"),
                    secondary: const Text("🇲🇾", style: TextStyle(fontSize: 20)),
                    value: 'ms',
                    groupValue: lang.currentLanguage,
                    onChanged: (val) => lang.setLanguage('ms'),
                  ),
                ],
              ),
            ),

            // ============================
            // 2. APP INFO SECTION
            // ============================
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 25, 16, 8),
              child: Text(
                lang.translate('sec_about').toUpperCase(),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Container(
              color: Colors.white,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  // --- ICON ---
                  Image.asset(
                    'assets/images/menu_icon.png',
                    width: 150,
                    height: 150,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 10),

                  // --- APP NAME ---
                  Text(
                    lang.translate('app_plugin_name'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),

                  const SizedBox(height: 5),
                  // --- VERSION ---
                  Text(
                    "${lang.translate('lbl_version')} 1.0.0 (${lang.translate('lbl_build')} 1)",
                    style: const TextStyle(color: Colors.grey)
                  ),

                  const SizedBox(height: 5),
                  // --- DEVELOPER TEAM ---
                  Text(
                    "${lang.translate('lbl_developer')}: ${lang.translate('val_lhdnm_team')}",
                    style: const TextStyle(color: Colors.grey)
                  ),

                  // --- MANUAL BATTERY OPTIMIZATION FIX (Android Only) ---
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 15),
                    TextButton.icon(
                      icon: const Icon(Icons.battery_alert, size: 18, color: Colors.orange),
                      label: Text(
                        lang.translate('btn_fix_background'),
                        style: const TextStyle(color: Colors.orange),
                      ),
                      onPressed: _requestBatteryOptimizationManual,
                    ),
                  ],

                  // --- LOGOUT BUTTON ---
                  const SizedBox(height: 10),
                  const Divider(indent: 40, endIndent: 40),
                  TextButton.icon(
                    icon: const Icon(Icons.logout, color: Colors.red),
                    label: Text(
                      lang.translate('btn_logout'),
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _handleLogout(context),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),

            const SizedBox(height: 40),

            // --- COPYRIGHT ---
            Center(
              child: Text(
                lang.translate('txt_copyright'),
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
      backgroundColor: Colors.grey[100],
    );
  }
}