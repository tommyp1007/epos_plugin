import 'dart:async';
import 'dart:io'; // Required for Platform checks

import 'package:flutter/material.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart'; // NEW IMPORT
import 'package:flutter_sharing_intent/model/sharing_file.dart'; // NEW MODEL IMPORT
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:provider/provider.dart';

import 'services/language_service.dart';
import 'pages/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  runApp(
    ChangeNotifierProvider(
      create: (context) => LanguageService(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // UPDATED: StreamSubscription now listens to List<SharedFile>
  StreamSubscription<List<SharedFile>>? _intentDataStreamSubscription;
  
  // We only need to store the path of the single file we want to print
  String? _sharedFilePath;

  @override
  void initState() {
    super.initState();
    _initShareListener();
    _checkDeviceAndConfigureSettings(); // Run auto-detection on startup
  }

  /// --- SMART STARTUP CONFIGURATION ---
  /// Checks if the device is a known POS model (Sunmi V3, T2, etc.)
  /// and pre-configures the settings to match the Native Print Service.
  Future<void> _checkDeviceAndConfigureSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      String? currentWidthMode = prefs.getString('printer_width_mode');

      if (currentWidthMode == null) {
        String detectedMode = "58"; // Default fallback

        // --- ANDROID DETECTION LOGIC ---
        if (Platform.isAndroid) {
          final deviceInfo = DeviceInfoPlugin();
          AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
          
          String manufacturer = androidInfo.manufacturer.toUpperCase();
          String model = androidInfo.model.toUpperCase();

          if (manufacturer.contains("SUNMI")) {
            List<String> models80mm = ["V3", "V3 MIX", "T2", "T2S", "T1", "K2", "T5711"];
            
            bool is80mm = false;
            for (var m in models80mm) {
              if (model.contains(m)) {
                is80mm = true;
                break;
              }
            }

            if (is80mm) {
              detectedMode = "80";
              print("Auto-Config: Detected Sunmi 80mm Device ($model). Setting mode to 80.");
            } else {
              detectedMode = "58"; // V2, P2, etc.
              print("Auto-Config: Detected Sunmi 58mm Device ($model). Setting mode to 58.");
            }

            if (prefs.getString('selected_printer_mac') == null) {
               await prefs.setString('selected_printer_mac', "INNER");
            }
          } 
        } 
        // --- IOS DETECTION LOGIC ---
        else if (Platform.isIOS) {
            detectedMode = "58";
            print("Auto-Config: iOS Device detected. Defaulting to 58mm.");
        }

        await prefs.setString('printer_width_mode', detectedMode);
      }
    } catch (e) {
      print("Error during startup device detection: $e");
    }
  }

  /// --- UPDATED SHARE LISTENER LOGIC ---
  void _initShareListener() {
    // 1. Listen for files shared while the app is ALREADY OPEN (Background / Hot Start)
    _intentDataStreamSubscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (List<SharedFile> value) {
        _processShareResult(value, "Background Stream");
      }, 
      onError: (err) {
        print("getMediaStream error: $err");
      }
    );

    // 2. Listen for files shared when the app is CLOSED (Cold Start)
    FlutterSharingIntent.instance.getInitialSharing().then((List<SharedFile> value) {
      if (value.isNotEmpty) {
        _processShareResult(value, "Cold Start");
        
        // Note: FlutterSharingIntent usually handles resetting automatically, 
        // but if you find issues with persistent intents, check their docs.
      }
    });
  }

  void _processShareResult(List<SharedFile> files, String source) {
    if (files.isNotEmpty) {
      // We take the first file shared
      final firstFile = files.first;
      
      // In flutter_sharing_intent, the path is stored in the 'value' property
      final path = firstFile.value;

      if (path != null && path.isNotEmpty) {
        setState(() {
          _sharedFilePath = path;
        });
        print("Received file via Share ($source): $path");
        print("File Type: ${firstFile.type}"); // Optional: Log type for debug
      }
    }
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);

    return MaterialApp(
      title: lang.translate('app_title'), 
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: false, 
      ),
      home: HomePage(
        // The 'key' forces the HomePage to reload if a new file comes in
        key: _sharedFilePath != null ? ValueKey(_sharedFilePath) : null,
        sharedFilePath: _sharedFilePath
      ),
    );
  }
}