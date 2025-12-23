import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/language_service.dart';

class AppInfoPage extends StatelessWidget {
  // We keep this parameter to avoid breaking the call in HomePage, 
  // even though it is not used in this page anymore.
  final String? connectedDeviceName;

  const AppInfoPage({Key? key, this.connectedDeviceName}) : super(key: key);

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
                    onChanged: (val) => lang.switchLanguage('en'),
                  ),
                  const Divider(height: 1, indent: 16),
                  RadioListTile<String>(
                    title: const Text("Bahasa Melayu"),
                    secondary: const Text("🇲🇾", style: TextStyle(fontSize: 20)),
                    value: 'ms',
                    groupValue: lang.currentLanguage,
                    onChanged: (val) => lang.switchLanguage('ms'),
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
                  // --- UPDATED: BIGGER CUSTOM ICON ---
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
                    "${lang.translate('lbl_version')} 1.0.2 (${lang.translate('lbl_build')} 24)", 
                    style: const TextStyle(color: Colors.grey)
                  ),
                  
                  const SizedBox(height: 5),
                  // --- TRANSLATED DEVELOPER TEAM ---
                  Text(
                    "${lang.translate('lbl_developer')}: ${lang.translate('val_lhdnm_team')}", 
                    style: const TextStyle(color: Colors.grey)
                  ),
                  
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