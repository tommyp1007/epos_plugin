import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // Required for iOS
import 'package:permission_handler/permission_handler.dart';

import '../services/printer_service.dart';

/// A simple wrapper to unify Android (Classic) and iOS (BLE) results
class UniversalBluetoothDevice {
  final String name;
  final String address; // MAC for Android, UUID for iOS
  final int rssi;
  final bool isBonded; // Only relevant for Android

  UniversalBluetoothDevice({
    required this.name,
    required this.address,
    required this.rssi,
    this.isBonded = false,
  });
}

class ScanDevicesPage extends StatefulWidget {
  const ScanDevicesPage({Key? key}) : super(key: key);

  @override
  _ScanDevicesPageState createState() => _ScanDevicesPageState();
}

class _ScanDevicesPageState extends State<ScanDevicesPage> {
  final PrinterService _printerService = PrinterService();
  
  // Unified list for display
  List<UniversalBluetoothDevice> _scanResults = [];
  bool _isScanning = false;

  // Android specific subscription
  StreamSubscription<BluetoothDiscoveryResult>? _androidScanSubscription;
  
  // iOS specific subscription
  StreamSubscription<List<ScanResult>>? _iosScanSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      // Android 12+ requires specific bluetooth permissions
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Critical for detection on older Android/Huawei
      ].request();
    } else if (Platform.isIOS) {
      // iOS requires basic bluetooth permission
      await [
        Permission.bluetooth,
      ].request();
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    
    // Reset list and state
    setState(() {
      _scanResults = [];
      _isScanning = true;
    });

    try {
      if (Platform.isAndroid) {
        // --- ANDROID LOGIC (Classic Bluetooth) ---
        _androidScanSubscription = FlutterBluetoothSerial.instance.startDiscovery().listen((result) {
          if (mounted) {
            setState(() {
              // Filter out empty names for cleaner UI
              if (result.device.name != null && result.device.name!.isNotEmpty) {
                final device = UniversalBluetoothDevice(
                  name: result.device.name!,
                  address: result.device.address,
                  rssi: result.rssi,
                  isBonded: result.device.isBonded,
                );

                // Update or Add
                final index = _scanResults.indexWhere((r) => r.address == device.address);
                if (index >= 0) {
                  _scanResults[index] = device;
                } else {
                  _scanResults.add(device);
                }
                // Sort by signal strength
                _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
              }
            });
          }
        });

      } else if (Platform.isIOS) {
        // --- iOS LOGIC (BLE) ---
        // Check if Bluetooth is On
        if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
            _showSnackBar("Please turn on Bluetooth");
            _stopScan();
            return;
        }

        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

        _iosScanSubscription = FlutterBluePlus.scanResults.listen((results) {
          if (mounted) {
            setState(() {
              _scanResults = results
                  .where((r) => r.device.platformName.isNotEmpty) // BLE devices often have empty names
                  .map((r) => UniversalBluetoothDevice(
                        name: r.device.platformName,
                        address: r.device.remoteId.str, // iOS uses UUID, not MAC
                        rssi: r.rssi,
                        isBonded: false, // iOS handles bonding internally
                      ))
                  .toList();
               _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
            });
          }
        });
      }

      // Auto-stop after 15 seconds
      await Future.delayed(const Duration(seconds: 15));
      if (_isScanning) _stopScan();

    } catch (e) {
      if (mounted) _showSnackBar("Scan Error: $e");
      _stopScan();
    }
  }

  Future<void> _stopScan() async {
    if (Platform.isAndroid) {
      await _androidScanSubscription?.cancel();
      await FlutterBluetoothSerial.instance.cancelDiscovery();
    } else if (Platform.isIOS) {
      await _iosScanSubscription?.cancel();
      await FlutterBluePlus.stopScan();
    }
    
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _pairAndConnect(UniversalBluetoothDevice device) async {
    await _stopScan();
    
    _showSnackBar("Connecting to ${device.name}...");

    try {
      bool success = false;

      if (Platform.isAndroid) {
        // Android: Needs explicit Bonding for Classic Bluetooth
        if (!device.isBonded) {
          bool? bonded = await FlutterBluetoothSerial.instance.bondDeviceAtAddress(device.address);
          if (bonded != true) {
            _showSnackBar("Pairing failed.");
            return;
          }
        }
        success = await _printerService.connect(device.address);
      } else if (Platform.isIOS) {
        // iOS: Connect directly (Bonding/Pairing is handled by OS dialogs if needed)
        // Note: printerService must support connecting via UUID for iOS
        success = await _printerService.connect(device.address);
      }

      if (mounted) {
        if (success) {
          Navigator.pop(context, device.address); // Return the ID/MAC
        } else {
          _showSnackBar("Connection failed.");
        }
      }
    } catch (e) {
      if (mounted) _showSnackBar("Error: $e");
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan for Printers")),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Column(
              children: [
                if (_isScanning) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: _stopScan, child: const Text("STOP SCAN"))
                ] else ...[
                  SizedBox(
                    width: double.infinity, 
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.bluetooth_searching), 
                      label: const Text("SCAN DEVICES"), 
                      onPressed: _startScan
                    )
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                  Platform.isIOS 
                      ? "Note: iOS searches for BLE Printers." 
                      : "Note: Android searches for Classic Bluetooth.",
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                )
              ],
            ),
          ),
          Expanded(
            child: _scanResults.isEmpty
                ? Center(
                    child: Text(_isScanning ? "Scanning..." : "No devices found"),
                  )
                : ListView.builder(
                    itemCount: _scanResults.length,
                    itemBuilder: (context, index) {
                      final device = _scanResults[index];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.print, color: Colors.blueGrey),
                          title: Text(device.name),
                          subtitle: Text("${device.address}\nSignal: ${device.rssi}"),
                          trailing: ElevatedButton(
                            // On iOS we just say "Connect", on Android we distinguish Pair vs Paired
                            onPressed: (Platform.isAndroid && device.isBonded) 
                                ? null 
                                : () => _pairAndConnect(device),
                            child: Text(
                              Platform.isAndroid 
                                  ? (device.isBonded ? "PAIRED" : "PAIR") 
                                  : "CONNECT"
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}