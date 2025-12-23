import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/bluetooth_print_service.dart';
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
    // Note: We use the direct stream from FlutterBluePlus for the UI list 
    // to ensure we get the latest raw data, or you can stick to _service.scanResults 
    // if your service does special filtering.
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
           if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enable Location/GPS for Bluetooth scanning.")));
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
    // In Dart 2.18+ / Flutter 3.3+, standard libraries don't expose SDK_INT easily without device_info_plus.
    // If you don't have device_info_plus, we assume permission_handler handles the fallback, 
    // but requesting 'bluetoothScan' on old Android simply returns granted/restricted instantly.
    // So simply requesting both sets (as done above) is usually safe or you can use device_info_plus.
    return true; // Simplified for this snippet; permission_handler handles version checks internally mostly.
  }

  void _startScan() async {
    // Check if Bluetooth is On
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please turn on Bluetooth")));
      return;
    }

    try {
      // Use the service start scan
      _service.startScan();
    } catch (e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Start Scan Error: $e")));
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    await _service.stopScan();
    
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connecting to ${device.platformName}...")));

    try {
      // Note: iOS uses UUIDs, Android uses MAC addresses. 
      // flutter_blue_plus handles this via remoteId.
      bool success = await _service.connect(device);
      
      if (success && mounted) {
        setState(() => _connectedDeviceName = device.platformName.isNotEmpty ? device.platformName : device.remoteId.str);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connected successfully!")));
      } else {
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connection failed.")));
      }
    } catch (e) {
       if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connection Error: $e")));
    }
  }

  void _disconnect() async {
    // Assuming your service has a disconnect method, or you access the device directly
    // If _service doesn't expose disconnect, you might need to add it or store the 'device' object globally.
    // For now, we just clear the UI state as a visual representation.
    setState(() {
      _connectedDeviceName = null;
    });
  }

  void _printTest() async {
    if (_connectedDeviceName == null) return;
    
    try {
      List<int> bytes = [];
      bytes.addAll(RawCommands.reset());
      bytes.addAll("e-Pos BLE Service Test\n".codeUnits);
      bytes.addAll("----------------\n".codeUnits);
      bytes.addAll("Works on iOS & Android!\n\n".codeUnits);
      bytes.addAll("Platform: ${Platform.isAndroid ? 'Android' : 'iOS'}\n\n\n".codeUnits);
      bytes.addAll(RawCommands.feed(3));

      await _service.sendBytes(bytes);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Print Error: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("BLE Printer Manager")),
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
                            _connectedDeviceName != null ? "Connected" : "Not Connected",
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
                            child: const Text("TEST PRINT")
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.red),
                            onPressed: _disconnect,
                            tooltip: "Disconnect",
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
                label: const Text("Scan Again"), 
                onPressed: _startScan
              ),
            ),

          // Device List
          Expanded(
            child: _scanResults.isEmpty
                ? Center(
                    child: Text(
                      _isScanning ? "Scanning for BLE devices..." : "No BLE devices found.\nMake sure printer is ON and supports BLE.",
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