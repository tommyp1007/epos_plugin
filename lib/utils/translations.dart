import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// TRANSLATIONS & LANGUAGE SERVICE
// ==========================================

class AppTranslations {
  static final Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'app_title': 'MyInvois e-Pos Printer',
      'title_login': 'MyInvois e-Pos Login',
      'lang_button': 'BM',

      // Section 1
      'sec_connection': '1. Connection Manager',
      'select_hint': 'Please click "Search to Devices" button',
      'unknown_device': 'Unknown Device',
      'working': 'Working...',
      'disconnect': 'Disconnect',
      'connect_selected': 'Connect Selected',
      'connected_to': 'Connected to',
      'connected_other': 'Connected to another device',
      'search_devices': 'Search for Devices',

      // Section 2
      'sec_native': '2. Print Test',
      'native_desc': 'Uses Android/iOS System Print Service.\nPreview matches configured paper width.',
      'test_system_button': 'TEST PRINT',

      // Section 3
      'sec_config': '3. Configuration',
      'width_dpi': 'Width Settings',
      'width_desc': 'Set 58mm or 80mm paper size',

      // Section 4 (Manual Print)
      'sec_manual_print': '4. Manual Print / PDF Viewer',
      'btn_select_doc': 'Select Document',
      'desc_select_doc': 'Pick a PDF or Image to print',

      // Section 5 (PDF Preview & Queue)
      'preview_title': 'MyInvois Receipt Preview',
      'lbl_queue': 'Queue',
      'status_queue_full': 'QUEUE FULL - PLEASE WAIT',
      'status_printing': 'PRINTING IN PROGRESS',
      'status_left': 'LEFT', // e.g., "(3 LEFT)"
      'btn_wait': 'PLEASE WAIT...',
      'btn_queueing': 'QUEUEING...',
      'btn_print_receipt': 'PRINT RECEIPT',
      'msg_queue_full_wait': 'Print queue is full. Please wait.',
      'msg_added_queue': 'Added to queue',
      'err_file_not_found': 'File not found at path:',
      'err_decode': 'Could not decode content.',
      'err_download': 'Download Failed:',

      // Snackbars / Status
      'msg_disconnected': 'Disconnected.',
      'msg_connected': 'Connected to',
      'msg_failed': 'Connection failed. Is the printer ON?',
      'msg_error_conn': 'Error during connection:',
      'msg_error_launch': 'Error launching Native Print:',
      'msg_reset_defaults': 'Reset to Default Settings',
      'msg_error_prefix': 'Error:',

      // Bluetooth Scan Page
      'title_scan': 'Scan for Printers',
      'btn_stop_scan': 'STOP SCAN',
      'btn_start_scan': 'SCAN DEVICES',
      'note_ios': 'Note: iOS searches for BLE Printers.',
      'note_android': 'Note: Android searches for Classic Bluetooth.',
      'status_scanning': 'Scanning...',
      'status_no_devices': 'No devices found',
      'btn_paired': 'PAIRED',
      'btn_pair': 'PAIR',
      'btn_connect': 'CONNECT',
      'msg_connecting': 'Connecting to',
      'msg_pair_fail': 'Pairing failed.',
      'msg_conn_fail': 'Connection failed.',
      'msg_bt_on': 'Please turn on Bluetooth',
      'msg_scan_error': 'Scan Error:',
      'signal': 'Signal:',

      // BLE Manager Page
      'title_ble_manager': 'BLE Printer Manager',
      'status_connected': 'Connected',
      'status_not_connected': 'Not Connected',
      'btn_test_print': 'TEST PRINT',
      'btn_scan_again': 'Scan Again',
      'msg_scanning_ble': 'Scanning for BLE devices...',
      'msg_no_ble_found': 'No BLE devices found.\nMake sure printer is ON and supports BLE.',
      'msg_enable_gps': 'Please enable Location/GPS for Bluetooth scanning.',
      'msg_start_scan_error': 'Start Scan Error:',
      'msg_connected_success': 'Connected successfully!',
      'msg_print_error': 'Print Error:',
      'test_print_content': 'Works on iOS & Android!\n\n',

      // Configuration Page-width settings
      'title_config': 'Printer Configuration',
      'lbl_paper_size': 'Paper Size (Width)',
      'btn_58mm': '58mm',
      'lbl_standard': 'Standard',
      'btn_80mm': '80mm',
      'lbl_large': 'Large/POS',
      'lbl_advanced': 'Advanced Settings:',
      'hint_dots': '384 = 58mm, 576 = 80mm',
      'btn_auto_detect': 'AUTO\nDETECT',
      'lbl_visual': 'Visual Preview:',
      'btn_save_settings': 'SAVE SETTINGS',
      'lbl_active_area': 'Active Area',

      // Messages & Status
      'msg_saved': 'Settings Saved:',
      'msg_internal_detect': 'Internal Printer detected. Auto-detect available.',
      'msg_ios_manual': 'iOS Device: Please select paper size manually.',
      'msg_no_printer': 'No printer connected. Auto-detect disabled.',
      'msg_external_printer': 'External Bluetooth Printer',
      'msg_manual_select': 'Please select size manually.',
      'msg_scanned': 'Scanned Hardware:',
      'msg_detect_sunmi_80': 'Detected Sunmi 80mm',
      'msg_detect_sunmi_58': 'Detected Sunmi 58mm',
      'msg_detect_huawei': 'Detected Huawei Device. Defaulting to 58mm.',
      'msg_unknown_internal': 'Unknown Internal Device. Defaulting to 58mm.',
      'msg_detect_error': 'Detection Error. Defaulting to 58mm.',
      
      // Cache & Reload
      'msg_cache_cleared': 'Cache Cleared. Reloading...',
      'msg_reloading': 'Page is Reloading...',

      // Native Service Messages (For reference/future use)
      'msg_login_required': 'MyInvois e-Pos: Login Required',
      'msg_login_desc': 'Please login to the MyInvois e-Pos app to enable printing.',

      // Settings page
      'title_settings': 'Settings & Info',
      'sec_language': 'Language',
      'sec_about': 'About',
      'lbl_version': 'Version',
      'lbl_developer': 'Developer',
      'txt_copyright': '© 2025 LHDNM Copyrights',
      'app_plugin_name': 'MyInvois e-Pos Printer',
      'val_lhdnm_team': 'LHDNM Team',
      'lbl_build': 'Build',
      'btn_fix_background': 'Fix Background Printing',
      'btn_logout': 'Logout',

      // PDF Test Print
      'test_print_title': 'MyInvois e-Pos Test Print',
      'test_print_config': 'Config: ',
      'test_print_left': '<< Left',
      'test_print_center': 'Center',
      'test_print_right': 'Right >>',
      'test_print_instruction': "If 'Left' and 'Right' are cut off, reduce dots (e.g., 370). If there is whitespace, increase dots.",
    },
    'ms': {
      'app_title': 'Pencetak MyInvois e-Pos',
      'title_login': 'Log Masuk MyInvois e-Pos',
      'lang_button': 'ENG',

      // Section 1
      'sec_connection': '1. Pengurus Sambungan',
      'select_hint': 'Sila tekan butang "Carian Peranti"',
      'unknown_device': 'Peranti Tidak Diketahui',
      'working': 'Sedang proses...',
      'disconnect': 'Putus Sambungan',
      'connect_selected': 'Pilih Sambungan',
      'connected_to': 'Disambungkan ke',
      'connected_other': 'Disambungkan ke peranti lain',
      'search_devices': 'Carian Peranti',

      // Section 2
      'sec_native': '2. Ujian Cetakan',
      'native_desc': 'Menggunakan Servis Cetak Android/iOS.\nMenyemak paparan mengikut lebar kertas yang ditetapkan.',
      'test_system_button': 'UJI CETAKAN',

      // Section 3
      'sec_config': '3. Konfigurasi',
      'width_dpi': 'Tetapan Lebar',
      'width_desc': 'Tetapkan saiz kertas 58mm atau 80mm',

      // Section 4 (Manual Print)
      'sec_manual_print': '4. Cetakan Manual / Paparan PDF',
      'btn_select_doc': 'Pilih Dokumen',
      'desc_select_doc': 'Pilih PDF atau Imej untuk dicetak',

      // Section 5 (PDF Preview & Queue)
      'preview_title': 'Pratonton Resit MyInvois',
      'lbl_queue': 'Giliran',
      'status_queue_full': 'GILIRAN PENUH - TUNGGU SEBENTAR',
      'status_printing': 'SEDANG MENCETAK',
      'status_left': 'BAKI', // e.g., "(3 BAKI)"
      'btn_wait': 'SILA TUNGGU...',
      'btn_queueing': 'MENYUSUN...',
      'btn_print_receipt': 'CETAK RESIT',
      'msg_queue_full_wait': 'Giliran cetak penuh. Sila tunggu.',
      'msg_added_queue': 'Ditambah ke giliran',
      'err_file_not_found': 'Fail tidak dijumpai di laluan:',
      'err_decode': 'Tidak dapat menyahkod kandungan.',
      'err_download': 'Muat Turun Gagal:',

      // Snackbars / Status
      'msg_disconnected': 'Terputus.',
      'msg_connected': 'Berjaya sambung ke',
      'msg_failed': 'Gagal menyambung. Adakah pencetak ON?',
      'msg_error_conn': 'Ralat semasa menyambung:',
      'msg_error_launch': 'Ralat melancarkan Cetakan Asli:',
      'msg_reset_defaults': 'Tetapan Semula ke Asal',
      'msg_error_prefix': 'Ralat:',

      // Bluetooth Scan Page
      'title_scan': 'Cari Pencetak',
      'btn_stop_scan': 'BERHENTI IMBAS',
      'btn_start_scan': 'IMBAS PERANTI',
      'note_ios': 'Nota: iOS mencari Pencetak BLE.',
      'note_android': 'Nota: Android mencari Bluetooth Klasik.',
      'status_scanning': 'Sedang mengimbas...',
      'status_no_devices': 'Tiada peranti dijumpai',
      'btn_paired': 'DISAMBUNG',
      'btn_pair': 'SAMBUNG',
      'btn_connect': 'SAMBUNG',
      'msg_connecting': 'Menyambung ke',
      'msg_pair_fail': 'Gagal berpasangan.',
      'msg_conn_fail': 'Gagal menyambung.',
      'msg_bt_on': 'Sila hidupkan Bluetooth',
      'msg_scan_error': 'Ralat Imbasan:',
      'signal': 'Isyarat:',

      // BLE Manager Page
      'title_ble_manager': 'Pengurus Pencetak BLE',
      'status_connected': 'Disambungkan',
      'status_not_connected': 'Tidak Disambung',
      'btn_test_print': 'CETAKAN UJIAN',
      'btn_scan_again': 'Imbas Semula',
      'msg_scanning_ble': 'Mengimbas peranti BLE...',
      'msg_no_ble_found': 'Tiada peranti BLE dijumpai.\nPastikan pencetak ON dan menyokong BLE.',
      'msg_enable_gps': 'Sila aktifkan Lokasi/GPS untuk imbasan Bluetooth.',
      'msg_start_scan_error': 'Ralat Mula Imbas:',
      'msg_connected_success': 'Berjaya disambungkan!',
      'msg_print_error': 'Ralat Cetakan:',
      'test_print_content': 'Berfungsi di iOS & Android!\n\n',

      // Configuration Page-width settings
      'title_config': 'Konfigurasi Pencetak',
      'lbl_paper_size': 'Saiz Kertas (Lebar)',
      'btn_58mm': '58mm',
      'lbl_standard': 'Standard',
      'btn_80mm': '80mm',
      'lbl_large': 'Besar/POS',
      'lbl_advanced': 'Tetapan Lanjutan:',
      'hint_dots': '384 = 58mm, 576 = 80mm',
      'btn_auto_detect': 'AUTO\nKESAN',
      'lbl_visual': 'Semakan Paparan:',
      'btn_save_settings': 'SIMPAN TETAPAN',
      'lbl_active_area': 'Kawasan Aktif',

      // Messages & Status
      'msg_saved': 'Tetapan Disimpan:',
      'msg_internal_detect': 'Pencetak Dalaman dikesan. Auto-kesan tersedia.',
      'msg_ios_manual': 'Peranti iOS: Sila pilih saiz kertas secara manual.',
      'msg_no_printer': 'Tiada pencetak disambung. Auto-kesan dimatikan.',
      'msg_external_printer': 'Pencetak Bluetooth Luaran',
      'msg_manual_select': 'Sila pilih saiz manual.',
      'msg_scanned': 'Perkakasan Dikesan:',
      'msg_detect_sunmi_80': 'Dikesan Sunmi 80mm',
      'msg_detect_sunmi_58': 'Dikesan Sunmi 58mm',
      'msg_detect_huawei': 'Dikesan Peranti Huawei. Tetapan asal 58mm.',
      'msg_unknown_internal': 'Peranti Dalaman Tidak Diketahui. Tetapan asal 58mm.',
      'msg_detect_error': 'Ralat Pengesanan. Tetapan asal 58mm.',
      
      // Cache & Reload
      'msg_cache_cleared': 'Cache Dibersihkan. Memuat semula...',
      'msg_reloading': 'Halaman sedang dimuat semula...',

      // Native Service Messages (For reference/future use)
      'msg_login_required': 'MyInvois e-Pos: Log Masuk Diperlukan',
      'msg_login_desc': 'Sila log masuk ke aplikasi MyInvois e-Pos untuk mengaktifkan cetakan.',

      // Settings page
      'title_settings': 'Tetapan & Info',
      'sec_language': 'Bahasa',
      'sec_about': 'Perihal',
      'lbl_version': 'Versi',
      'lbl_developer': 'Pembangun',
      'txt_copyright': '© 2025 Hak Cipta LHDNM',
      'app_plugin_name': 'Pencetak MyInvois e-Pos',
      'val_lhdnm_team': 'Pasukan LHDNM',
      'lbl_build': 'Binaan',
      'btn_fix_background': 'Baiki Cetakan Latar Belakang',
      'btn_logout': 'Log Keluar',

      // PDF Test Print
      'test_print_title': 'Cetakan Ujian MyInvois e-Pos',
      'test_print_config': 'Konfig: ',
      'test_print_left': '<< Kiri',
      'test_print_center': 'Tengah',
      'test_print_right': 'Kanan >>',
      'test_print_instruction': "Jika 'Kiri' dan 'Kanan' terpotong, kurangkan titik (cth: 370). Jika ada ruang kosong, tambah titik.",
    },
  };

  static String text(String key, String languageCode) {
    return _localizedValues[languageCode]?[key] ?? key;
  }
}

class LanguageService with ChangeNotifier {
  Locale _currentLocale = const Locale('en');

  Locale get currentLocale => _currentLocale;
  String get currentLanguage => _currentLocale.languageCode; 

  LanguageService() {
    _loadLanguage();
  }

  void _loadLanguage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? langCode = prefs.getString('language_code');
    if (langCode != null) {
      _currentLocale = Locale(langCode);
      notifyListeners();
    }
  }

  void setLanguage(String code) async {
    if (code == 'en' || code == 'ms') {
      _currentLocale = Locale(code);
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('language_code', code);
      notifyListeners();
    }
  }

  void switchLanguage() async {
    if (_currentLocale.languageCode == 'en') {
      setLanguage('ms');
    } else {
      setLanguage('en');
    }
  }

  String translate(String key) {
    return AppTranslations.text(key, _currentLocale.languageCode);
  }
}