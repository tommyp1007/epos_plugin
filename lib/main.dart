import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart'; 

import 'services/language_service.dart';
import 'utils/api_urls.dart'; // Import this to access ApiUrls
import 'pages/home_page.dart';
import 'pages/login_page.dart'; 

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
  // Navigator Key allows us to navigate even from outside the build context (e.g. async file sharing)
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  
  StreamSubscription<List<SharedFile>>? _intentDataStreamSubscription;
  String? _sharedFilePath;
  
  // Auth State
  bool _isAuthChecked = false;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth(); // 1. Check Login Status first
    _initShareListener();
    _checkDeviceAndConfigureSettings();
    _requestRuntimePermissions(); 
  }

  /// 1. Check if the user has an active session from LoginPage
  Future<void> _checkAuth() async {
    final prefs = await SharedPreferences.getInstance();
    bool loggedIn = prefs.getBool('is_logged_in') ?? false;
    
    if (mounted) {
      setState(() {
        _isLoggedIn = loggedIn;
        _isAuthChecked = true;
      });
    }
  }

  /// Request Notification and Bluetooth permissions at runtime.
  Future<void> _requestRuntimePermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.notification,      
        Permission.bluetoothConnect,  
        Permission.bluetoothScan,     
      ].request();

      if (statuses[Permission.notification]!.isDenied) {
        debugPrint("Notification permission denied. Background status won't show.");
      }
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    }
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
            detectedMode = is80mm ? "80" : "58";
            
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
    // 1. App Background / Hot Start 
    _intentDataStreamSubscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (List<SharedFile> value) {
        _processShareResult(value, "Background Stream");
      },
      onError: (err) {
        debugPrint("getMediaStream error: $err");
      }
    );

    // 2. App Cold Start 
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
      String? path = firstFile.value; 

      if (path != null && path.isNotEmpty) {
        // CHECK 1: Is it a Website Link?
        if (path.toLowerCase().startsWith("http")) {
            debugPrint("Detected Web Link: $path");
        }
        // CHECK 2: Is it a Local File?
        else {
            if (Platform.isIOS && path.startsWith("file://")) {
              path = path.replaceFirst("file://", "");
            }
            try {
              path = Uri.decodeFull(path!);
            } catch (e) {
              debugPrint("Error decoding path: $e");
            }
        }

        debugPrint("Received content via Share ($source): $path");

        if (mounted) {
          setState(() {
            _sharedFilePath = path;
          });
          
          // CRITICAL: If the user is already logged in and using the app,
          // simply updating state might not refresh the current route if it's pushed on stack.
          // We force a navigation to HomePage with the new file.
          if (_isLoggedIn && _isAuthChecked) {
             _navigatorKey.currentState?.pushReplacement(
               MaterialPageRoute(
                 builder: (context) => HomePage(
                   key: ValueKey(path), // Force rebuild
                   sharedFilePath: path
                 )
               )
             );
          }
        }
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

    // 1. Show Loading until Auth Check is done
    if (!_isAuthChecked) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      navigatorKey: _navigatorKey, // Attach the key to handle nav from async methods
      title: lang.translate('app_title'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: false,
      ),
      // 2. Define Routes for Navigation from Login Page
      routes: {
        // FIX: Ensure this matches your testing environment!
        // Changed to preProd to match your logic in the prompt.
        '/login': (context) => const LoginPage(url: ApiUrls.preProd),
        
        '/home': (context) => HomePage(
           // If accessing home via route, pass the current shared file state
           key: _sharedFilePath != null ? ValueKey(_sharedFilePath) : null,
           sharedFilePath: _sharedFilePath,
        ),
      },
      // 3. Logic: If Logged In -> Home, Else -> Login
      home: _isLoggedIn 
          ? HomePage(
              key: _sharedFilePath != null ? ValueKey(_sharedFilePath) : null,
              sharedFilePath: _sharedFilePath
            )
          : const LoginPage(url: ApiUrls.preProd), // FIX: Consistent URL
    );
  }
}