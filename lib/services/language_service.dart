import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Helper for translations import
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

  // Method renamed to 'setLanguage' to match your AppInfoPage usage
  Future<void> setLanguage(String languageCode) async {
    _currentLanguage = languageCode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', _currentLanguage);
    notifyListeners(); // This tells the UI to rebuild
  }

  // Helper to get text easily
  String translate(String key) {
    // Uses the AppTranslations class from your utils
    return AppTranslations.text(key, _currentLanguage); 
  }
}