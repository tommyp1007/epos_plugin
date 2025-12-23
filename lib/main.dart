import 'dart:async';
import 'package:flutter/material.dart';
import 'package:share_handler/share_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'pages/home_page.dart';

void main() {
  // Required for platform channels (ShareHandler, SharedPreferences, DeviceInfo)
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<SharedMedia>? _streamSubscription;
  
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
      
      // 1. Check if width is already configured
      // Note: We use 'printer_width_mode' to match the Native Service (values: "58" or "80")
      String? currentWidthMode = prefs.getString('printer_width_mode');

      if (currentWidthMode == null) {
        // 2. No setting found. Let's auto-detect the device.
        final deviceInfo = DeviceInfoPlugin();
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        
        String manufacturer = androidInfo.manufacturer.toUpperCase();
        String model = androidInfo.model.toUpperCase();

        String detectedMode = "58"; // Default to 58mm

        // 3. Logic for Sunmi Devices
        if (manufacturer.contains("SUNMI")) {
          // List of known 80mm models
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

          // 4. Save Settings for Native Service
          // The native service listens for 'flutter.printer_width_mode'
          await prefs.setString('printer_width_mode', detectedMode);
          
          // Set default printer to INNER so native service picks it up immediately
          if (prefs.getString('selected_printer_mac') == null) {
             // If detected as Sunmi, assume Inner Printer (using "INNER" or "sunmi_virtual" logic)
             // Using "INNER" allows your Connection Manager to map it correctly.
             await prefs.setString('selected_printer_mac', "INNER");
          }
        } else {
           // Non-Sunmi Device (Generic Android)
           await prefs.setString('printer_width_mode', "58");
        }
      }
    } catch (e) {
      print("Error during startup device detection: $e");
    }
  }

  void _initShareListener() async {
    final handler = ShareHandler.instance;

    // 1. Listen for files shared when the app is CLOSED (Cold Start)
    try {
      final SharedMedia? initialMedia = await handler.getInitialSharedMedia();
      if (initialMedia != null) {
        _processShareResult(initialMedia, "Cold Start");
      }
    } catch (e) {
      print("Error fetching initial share: $e");
    }

    // 2. Listen for files shared while the app is ALREADY OPEN (Background)
    _streamSubscription = handler.sharedMediaStream.listen((SharedMedia media) {
      _processShareResult(media, "Background Stream");
    });
  }

  void _processShareResult(SharedMedia media, String source) {
    // FIX: Safely access the attachments list
    final attachments = media.attachments;

    if (attachments != null && attachments.isNotEmpty) {
      // FIX: Access the first attachment safely using '?'
      final firstAttachment = attachments.first;
      
      // FIX: Only access .path if firstAttachment is not null
      final path = firstAttachment?.path;

      if (path != null && path.isNotEmpty) {
        setState(() {
          _sharedFilePath = path;
        });
        print("Received file via Share ($source): $path");
      }
    } 
    // Check if it's just text (e.g. sharing a link or plain text)
    else if (media.content != null && media.content!.isNotEmpty) {
      print("Received Text ($source): ${media.content}");
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'e-Pos Printer Services',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: false, 
      ),
      // We pass the captured file path to HomePage
      home: HomePage(
        // The 'key' forces the HomePage to reload if a new file comes in
        key: _sharedFilePath != null ? ValueKey(_sharedFilePath) : null,
        sharedFilePath: _sharedFilePath
      ),
    );
  }
}