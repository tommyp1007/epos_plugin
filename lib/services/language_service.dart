import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Helper for Step 2 import (put this at top of file)
import '../utils/translations.dart';

class LanguageService with ChangeNotifier {
  // Default to English
  String _currentLanguage = 'en';

  String get currentLanguage => _currentLanguage;

  LanguageService() {
    _loadLanguage();
  }

  // Load saved language from phone storage
  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    _currentLanguage = prefs.getString('language_code') ?? 'en';
    notifyListeners();
  }

  // Switch Language and Save to Storage
  Future<void> switchLanguage(String languageCode) async {
    _currentLanguage = languageCode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', _currentLanguage);
    notifyListeners(); // This tells the UI to rebuild
  }

  // Helper to get text easily
  String translate(String key) {
    // Import your translations file here
    // Assuming you implemented Step 2
    return AppTranslations.text(key, _currentLanguage); 
  }
}
