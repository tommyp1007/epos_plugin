import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart'; // IMPORT PROVIDER

import '../services/bluetooth_print_service.dart';
import '../services/language_service.dart'; // IMPORT LANGUAGE SERVICE
import '../utils/raw_commands.dart';

class TestPrintPage extends StatefulWidget {
  const TestPrintPage({Key? key}) : super(key: key);

  @override
  _TestPrintPageState createState() => _TestPrintPageState();
}

class _TestPrintPageState extends State<TestPrintPage> {
  final _service = BluetoothPrintService();
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  String? _connectedDeviceName;

  // Stream subscription to manage memory usage
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initBluetooth() async {
    // 1. Setup Listeners
    _scanSubscription = _service.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          // Filter out devices with no name to keep UI clean
          _scanResults = results.where((r) => r.device.platformName.isNotEmpty).toList();
          // Sort by signal strength (closest first)
          _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
        });
      }
    });

    _stateSubscription = FlutterBluePlus.adapterState.listen((state) {
       // Optional: Handle Bluetooth turning off/on dynamically
    });

    FlutterBluePlus.isScanning.listen((state) {
      if (mounted) setState(() => _isScanning = state);
    });

    // 2. Check Permissions & Start
    await _checkPermissions();
    _startScan();
  }

  Future<void> _checkPermissions() async {
    final lang = Provider.of<LanguageService>(context, listen: false); // Provider for SnackBar

    if (Platform.isAndroid) {
      // Android 12+ (API 31+)
      if (await _isAndroid12OrHigher()) {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();
      } 
      // Android 11 or lower (Huawei/Older devices)
      else {
        await [
          Permission.bluetooth,
          Permission.location, // Critical for BLE on older Android
        ].request();
        
        // Optional: Check if Location Service (GPS) is actually on
        if (!await Permission.location.serviceStatus.isEnabled) {
           if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lang.translate('msg_enable_gps')))); // TRANSLATED
        }
      }
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
      ].request();
    }
  }

  // Helper to detect Android version
  Future<bool> _isAndroid12OrHigher() async {
    return true; // Simplified for this snippet
  }

  void _startScan() async {
    final lang = Provider.of<LanguageService>(context, listen: false);

    // Check if Bluetooth is On
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lang.translate('msg_bt_on')))); // REUSING KEY
      return;
    }

    try {
      _service.startScan();
    } catch (e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${lang.translate('msg_start_scan_error')} $e"))); // TRANSLATED
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    await _service.stopScan();
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${lang.translate('msg_connecting')} ${device.platformName}..."))); // REUSING KEY

    try {
      bool success = await _service.connect(device);
      
      if (success && mounted) {
        setState(() => _connectedDeviceName = device.platformName.isNotEmpty ? device.platformName : device.remoteId.str);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lang.translate('msg_connected_success')))); // TRANSLATED
      } else {
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lang.translate('msg_conn_fail')))); // REUSING KEY
      }
    } catch (e) {
       if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${lang.translate('msg_error_conn')} $e"))); // REUSING KEY
    }
  }

  void _disconnect() async {
    setState(() {
      _connectedDeviceName = null;
    });
  }

  void _printTest() async {
    if (_connectedDeviceName == null) return;
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    try {
      List<int> bytes = [];
      bytes.addAll(RawCommands.reset());
      bytes.addAll("e-Pos BLE Service Test\n".codeUnits);
      bytes.addAll("----------------\n".codeUnits);
      // TRANSLATED TEST CONTENT
      bytes.addAll(lang.translate('test_print_content').codeUnits); 
      bytes.addAll("Platform: ${Platform.isAndroid ? 'Android' : 'iOS'}\n\n\n".codeUnits);
      bytes.addAll(RawCommands.feed(3));

      await _service.sendBytes(bytes);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${lang.translate('msg_print_error')} $e"))); // TRANSLATED
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. LISTEN TO LANGUAGE CHANGES
    final lang = Provider.of<LanguageService>(context);

    return Scaffold(
      appBar: AppBar(title: Text(lang.translate('title_ble_manager'))), // TRANSLATED
      body: Column(
        children: [
          // Connection Status Area
          Container(
            padding: const EdgeInsets.all(16),
            color: _connectedDeviceName != null ? Colors.green[100] : Colors.grey[200],
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _connectedDeviceName != null 
                                ? lang.translate('status_connected')       // TRANSLATED
                                : lang.translate('status_not_connected'),  // TRANSLATED
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _connectedDeviceName != null ? Colors.green[800] : Colors.red,
                            ),
                          ),
                          if (_connectedDeviceName != null)
                            Text(_connectedDeviceName!, style: const TextStyle(fontSize: 12)),
                        ],
                      )
                    ),
                    if (_connectedDeviceName != null) 
                      Row(
                        children: [
                           ElevatedButton(
                            onPressed: _printTest, 
                            child: Text(lang.translate('btn_test_print')) // TRANSLATED
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.red),
                            onPressed: _disconnect,
                            tooltip: lang.translate('disconnect'), // REUSING KEY
                          )
                        ],
                      )
                  ],
                ),
              ],
            ),
          ),
          
          // Scanning Indicator
          if (_isScanning)
            const LinearProgressIndicator()
          else 
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh), 
                label: Text(lang.translate('btn_scan_again')), // TRANSLATED
                onPressed: _startScan
              ),
            ),

          // Device List
          Expanded(
            child: _scanResults.isEmpty
                ? Center(
                    child: Text(
                      _isScanning 
                          ? lang.translate('msg_scanning_ble')   // TRANSLATED
                          : lang.translate('msg_no_ble_found'),  // TRANSLATED
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    itemCount: _scanResults.length,
                    separatorBuilder: (c, i) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = _scanResults[index];
                      // Double check to hide empty names if stream didn't filter
                      if (result.device.platformName.isEmpty) return const SizedBox.shrink();
                      
                      return ListTile(
                        leading: const Icon(Icons.bluetooth, color: Colors.blue),
                        title: Text(result.device.platformName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(result.device.remoteId.str), // MAC on Android, UUID on iOS
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text("${result.rssi} dBm", style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                          ],
                        ),
                        onTap: () => _connectToDevice(result.device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}