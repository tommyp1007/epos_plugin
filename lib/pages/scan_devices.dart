import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // Required for iOS
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart'; // IMPORT PROVIDER

import '../services/printer_service.dart';
import '../services/language_service.dart'; // IMPORT LANGUAGE SERVICE

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

    // Helper to get lang inside async method without context issues
    // Note: We use listen: false here because we are in a logic function, not build
    final lang = Provider.of<LanguageService>(context, listen: false);

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
          _showSnackBar(lang.translate('msg_bt_on')); // TRANSLATED
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
      if (mounted) _showSnackBar("${lang.translate('msg_scan_error')} $e"); // TRANSLATED
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
    final lang = Provider.of<LanguageService>(context, listen: false); // Provider access

    _showSnackBar("${lang.translate('msg_connecting')} ${device.name}..."); // TRANSLATED

    try {
      bool success = false;

      if (Platform.isAndroid) {
        // Android: Needs explicit Bonding for Classic Bluetooth
        if (!device.isBonded) {
          bool? bonded = await FlutterBluetoothSerial.instance.bondDeviceAtAddress(device.address);
          if (bonded != true) {
            _showSnackBar(lang.translate('msg_pair_fail')); // TRANSLATED
            return;
          }
        }
        success = await _printerService.connect(device.address);
      } else if (Platform.isIOS) {
        // iOS: Connect directly (Bonding/Pairing is handled by OS dialogs if needed)
        success = await _printerService.connect(device.address);
      }

      if (mounted) {
        if (success) {
          Navigator.pop(context, device.address); // Return the ID/MAC
        } else {
          _showSnackBar(lang.translate('msg_conn_fail')); // TRANSLATED
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
    // 1. WATCH FOR LANGUAGE CHANGES
    final lang = Provider.of<LanguageService>(context);

    return Scaffold(
      appBar: AppBar(title: Text(lang.translate('title_scan'))), // TRANSLATED
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
                  OutlinedButton(
                      onPressed: _stopScan,
                      child: Text(lang.translate('btn_stop_scan')) // TRANSLATED
                  )
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(lang.translate('btn_start_scan')), // TRANSLATED
                        onPressed: _startScan
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                  Platform.isIOS
                      ? lang.translate('note_ios')     // TRANSLATED
                      : lang.translate('note_android'),// TRANSLATED
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                )
              ],
            ),
          ),
          Expanded(
            child: _scanResults.isEmpty
                ? Center(
              child: Text(_isScanning
                  ? lang.translate('status_scanning')   // TRANSLATED
                  : lang.translate('status_no_devices') // TRANSLATED
              ),
            )
                : ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final device = _scanResults[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.print, color: Colors.blueGrey),
                    title: Text(device.name),
                    subtitle: Text("${device.address}\n${lang.translate('signal')} ${device.rssi}"), // TRANSLATED
                    trailing: ElevatedButton(
                      // On iOS we just say "Connect", on Android we distinguish Pair vs Paired
                      onPressed: (Platform.isAndroid && device.isBonded)
                          ? null
                          : () => _pairAndConnect(device),
                      child: Text(
                          Platform.isAndroid
                              ? (device.isBonded
                                ? lang.translate('btn_paired') // TRANSLATED
                                : lang.translate('btn_pair'))  // TRANSLATED
                              : lang.translate('btn_connect')    // TRANSLATED
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