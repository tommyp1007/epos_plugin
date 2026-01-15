import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    // note: SharedPreferences in Flutter adds a "flutter." prefix to keys in the XML file
    // So 'language_code' here becomes 'flutter.language_code' in Android native.
    _currentLanguage = prefs.getString('language_code') ?? 'en';
    notifyListeners();
  }

  // Set the language and save it so Native Android can read it
  Future<void> setLanguage(String languageCode) async {
    _currentLanguage = languageCode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language_code', _currentLanguage);
    notifyListeners(); 
  }

  // Helper to get text easily within Flutter UI
  String translate(String key) {
    return AppTranslations.text(key, _currentLanguage); 
  }
}