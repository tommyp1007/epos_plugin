import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
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
  StreamSubscription<List<SharedFile>>? _intentDataStreamSubscription;
  String? _sharedFilePath;

  @override
  void initState() {
    super.initState();
    _initShareListener();
    _checkDeviceAndConfigureSettings();
  }

  Future<void> _checkDeviceAndConfigureSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? currentWidthMode = prefs.getString('printer_width_mode');

      if (currentWidthMode == null) {
        String detectedMode = "58";

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
            } else {
              detectedMode = "58";
            }
            if (prefs.getString('selected_printer_mac') == null) {
               await prefs.setString('selected_printer_mac', "INNER");
            }
          }
        }
        else if (Platform.isIOS) {
            detectedMode = "58";
        }

        await prefs.setString('printer_width_mode', detectedMode);
      }
    } catch (e) {
      debugPrint("Error during startup device detection: $e");
    }
  }

  void _initShareListener() {
    // 1. App Background / Hot Start (App is already running)
    _intentDataStreamSubscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (List<SharedFile> value) {
        _processShareResult(value, "Background Stream");
      },
      onError: (err) {
        debugPrint("getMediaStream error: $err");
      }
    );

    // 2. App Cold Start (App was closed)
    FlutterSharingIntent.instance.getInitialSharing().then((List<SharedFile> value) {
      if (value.isNotEmpty) {
        _processShareResult(value, "Cold Start");
      }
    });
  }

  // --- SMART PROCESSING (URL vs FILE) ---
  void _processShareResult(List<SharedFile> files, String source) {
    if (files.isNotEmpty) {
      final firstFile = files.first;
      String? path = firstFile.value; // value contains the Text (URL) or Path

      if (path != null && path.isNotEmpty) {
        // CHECK 1: Is it a Website Link? (http/https)
        if (path.toLowerCase().startsWith("http")) {
            debugPrint("Detected Web Link: $path");
        }
        // CHECK 2: Is it a Local File?
        else {
            // iOS Fix: Remove file:// prefix if present
            if (Platform.isIOS && path.startsWith("file://")) {
              path = path.replaceFirst("file://", "");
            }

            // General Fix: Decode URI chars (e.g. %20 -> space)
            try {
              path = Uri.decodeFull(path!);
            } catch (e) {
              debugPrint("Error decoding path: $e");
            }
        }

        setState(() {
          _sharedFilePath = path;
        });
        debugPrint("Received content via Share ($source): $path");
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
        // Forces reload if file path changes
        key: _sharedFilePath != null ? ValueKey(_sharedFilePath) : null,
        sharedFilePath: _sharedFilePath
      ),
    );
  }
}