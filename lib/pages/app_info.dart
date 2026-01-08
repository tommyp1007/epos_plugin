import 'dart:io'; // Required to check Platform.isAndroid
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart'; // Required for the fix button
import '../services/language_service.dart';

class AppInfoPage extends StatelessWidget {
  // We keep this parameter to avoid breaking the call in HomePage
  final String? connectedDeviceName;

  const AppInfoPage({Key? key, this.connectedDeviceName}) : super(key: key);

  // Updated function to handle "Deny" and "Already Allowed" scenarios
  Future<void> _requestBatteryOptimizationManual() async {
    // 1. Check the current status first
    var status = await Permission.ignoreBatteryOptimizations.status;

    if (status.isGranted) {
      // Case A: Permission is ALREADY allowed.
      // The user clicked the button to check/verify, so we open the settings.
      await openAppSettings();
    } else {
      // Case B: Not allowed yet. Try to show the "Allow/Deny" dialog.
      var result = await Permission.ignoreBatteryOptimizations.request();

      // Case C: The user clicked "Deny" in the dialog OR the dialog was blocked.
      // We force open the settings so they can enable it manually.
      if (result.isDenied || result.isPermanentlyDenied) {
        await openAppSettings();
      }
      
      // Case D: If result.isGranted, the user just clicked "Allow" successfully. 
      // We don't need to do anything else.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access the LanguageService
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
                  // --- BIGGER CUSTOM ICON ---
                  Image.asset(
                    'assets/images/menu_icon.png', 
                    width: 150, // Bigger size
                    height: 150,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 10),
                  
                  // --- TRANSLATED APP NAME ---
                  Text(
                    lang.translate('app_plugin_name'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  
                  const SizedBox(height: 5),
                  // --- TRANSLATED VERSION & BUILD ---
                  Text(
                    "${lang.translate('lbl_version')} 1.0.5 (${lang.translate('lbl_build')} 24)", 
                    style: const TextStyle(color: Colors.grey)
                  ),
                  
                  const SizedBox(height: 5),
                  // --- TRANSLATED DEVELOPER TEAM ---
                  Text(
                    "${lang.translate('lbl_developer')}: ${lang.translate('val_lhdnm_team')}", 
                    style: const TextStyle(color: Colors.grey)
                  ),

                  // --- MANUAL BATTERY OPTIMIZATION FIX BUTTON ---
                  // Only show this on Android (covers Huawei/Samsung/etc.)
                  // Hide completely on iOS
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
                  
                  const SizedBox(height: 20),
                ],
              ),
            ),
            
            const SizedBox(height: 40),
            
            // --- TRANSLATED COPYRIGHT ---
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