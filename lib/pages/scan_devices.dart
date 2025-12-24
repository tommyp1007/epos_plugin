import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
// 1. PREFIXES TO RESOLVE CONFLICT
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as fbs;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp; 

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart'; // Required for BluetoothInfo
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart'; 

import '../services/printer_service.dart';
import '../services/language_service.dart'; 

/// A simple wrapper to unify Android (Classic) and iOS (BLE) results
class UniversalBluetoothDevice {
  final String name;
  final String address; // MAC for Android, UUID for iOS
  final int rssi;
  final bool isBonded; // Relevant for Android
  final bool isSystemConnected; // Relevant for iOS (already connected in settings)

  UniversalBluetoothDevice({
    required this.name,
    required this.address,
    required this.rssi,
    this.isBonded = false,
    this.isSystemConnected = false,
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

  // Android specific subscription (Using Prefix fbs)
  StreamSubscription<fbs.BluetoothDiscoveryResult>? _androidScanSubscription;

  // iOS specific subscription (Using Prefix fbp)
  StreamSubscription<List<fbp.ScanResult>>? _iosScanSubscription;

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
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, 
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
      ].request();
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    final lang = Provider.of<LanguageService>(context, listen: false);

    setState(() {
      _scanResults = [];
      _isScanning = true;
    });

    try {
      if (Platform.isAndroid) {
        // --- ANDROID LOGIC (Classic Bluetooth via fbs) ---
        _androidScanSubscription = fbs.FlutterBluetoothSerial.instance.startDiscovery().listen((result) {
          if (mounted) {
            setState(() {
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
                _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
              }
            });
          }
        });

      } else if (Platform.isIOS) {
        // --- iOS LOGIC (BLE via fbp) ---
        
        // 1. Check Adapter State
        if (await fbp.FlutterBluePlus.adapterState.first != fbp.BluetoothAdapterState.on) {
          _showSnackBar(lang.translate('msg_bt_on'));
          _stopScan();
          return;
        }

        // 2. Fetch System Devices (Already connected in iOS Settings)
        try {
          // FIX: Call as a function with empty list []
          // Note: On iOS, this requires specific Service UUIDs to work perfectly, 
          // but passing [] satisfies the compiler.
          List<fbp.BluetoothDevice> systemDevices = await fbp.FlutterBluePlus.systemDevices([]);
          
          for (var d in systemDevices) {
            if (d.platformName.isNotEmpty) {
              _addIosDevice(d, rssi: 0, isSystemConnected: true);
            }
          }
        } catch (e) {
          debugPrint("Error fetching system devices: $e");
        }

        // 3. Start Active Scan
        await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

        _iosScanSubscription = fbp.FlutterBluePlus.scanResults.listen((results) {
          if (mounted) {
             for (var r in results) {
               if (r.device.platformName.isNotEmpty) {
                 _addIosDevice(r.device, rssi: r.rssi, isSystemConnected: false);
               }
             }
          }
        });
      }

      // Auto-stop after 15 seconds
      await Future.delayed(const Duration(seconds: 15));
      if (_isScanning) _stopScan();

    } catch (e) {
      if (mounted) _showSnackBar("${lang.translate('msg_scan_error')} $e");
      _stopScan();
    }
  }

  // Helper to add iOS devices safely (Uses fbp.BluetoothDevice)
  void _addIosDevice(fbp.BluetoothDevice d, {required int rssi, required bool isSystemConnected}) {
    setState(() {
      final device = UniversalBluetoothDevice(
        name: d.platformName,
        address: d.remoteId.str, // UUID
        rssi: rssi,
        isBonded: false,
        isSystemConnected: isSystemConnected, 
      );

      final index = _scanResults.indexWhere((r) => r.address == device.address);
      if (index >= 0) {
        bool wasConnected = _scanResults[index].isSystemConnected;
        if (wasConnected) {
           _scanResults[index] = UniversalBluetoothDevice(
             name: device.name, 
             address: device.address, 
             rssi: rssi != 0 ? rssi : _scanResults[index].rssi,
             isSystemConnected: true
           );
        } else {
           _scanResults[index] = device;
        }
      } else {
        _scanResults.add(device);
      }
      
      _scanResults.sort((a, b) {
        if (a.isSystemConnected && !b.isSystemConnected) return -1;
        if (!a.isSystemConnected && b.isSystemConnected) return 1;
        return b.rssi.compareTo(a.rssi);
      });
    });
  }

  Future<void> _stopScan() async {
    if (Platform.isAndroid) {
      await _androidScanSubscription?.cancel();
      await fbs.FlutterBluetoothSerial.instance.cancelDiscovery();
    } else if (Platform.isIOS) {
      await _iosScanSubscription?.cancel();
      await fbp.FlutterBluePlus.stopScan();
    }

    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _pairAndConnect(UniversalBluetoothDevice device) async {
    await _stopScan();
    final lang = Provider.of<LanguageService>(context, listen: false);

    _showSnackBar("${lang.translate('msg_connecting')} ${device.name}...");

    try {
      bool success = false;

      if (Platform.isAndroid) {
        // Android: Needs explicit Bonding via fbs
        if (!device.isBonded) {
          bool? bonded = await fbs.FlutterBluetoothSerial.instance.bondDeviceAtAddress(device.address);
          if (bonded != true) {
            _showSnackBar(lang.translate('msg_pair_fail'));
            return;
          }
        }
        success = await _printerService.connect(device.address);
      } else if (Platform.isIOS) {
        // iOS: Connect directly
        success = await _printerService.connect(device.address);
      }

      if (mounted) {
        if (success) {
          // Return the Full BluetoothInfo Object (from print_bluetooth_thermal package)
          BluetoothInfo info = BluetoothInfo(
            name: device.name, 
            macAdress: device.address
          );
          Navigator.pop(context, info); 
        } else {
          _showSnackBar(lang.translate('msg_conn_fail'));
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
    final lang = Provider.of<LanguageService>(context);

    return Scaffold(
      appBar: AppBar(title: Text(lang.translate('title_scan'))),
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
                      child: Text(lang.translate('btn_stop_scan'))
                  )
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(lang.translate('btn_start_scan')),
                        onPressed: _startScan
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                  Platform.isIOS
                      ? lang.translate('note_ios')
                      : lang.translate('note_android'),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                )
              ],
            ),
          ),
          Expanded(
            child: _scanResults.isEmpty
                ? Center(
              child: Text(_isScanning
                  ? lang.translate('status_scanning')
                  : lang.translate('status_no_devices')
              ),
            )
                : ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final device = _scanResults[index];
                
                String subtitle = device.address;
                if (device.isSystemConnected) {
                   subtitle += "\n(System Connected)";
                } else if (device.rssi != 0) {
                   subtitle += "\n${lang.translate('signal')} ${device.rssi}";
                }

                return Card(
                  child: ListTile(
                    leading: Icon(Icons.print, color: device.isSystemConnected ? Colors.green : Colors.blueGrey),
                    title: Text(device.name, style: TextStyle(fontWeight: device.isSystemConnected ? FontWeight.bold : FontWeight.normal)),
                    subtitle: Text(subtitle),
                    trailing: ElevatedButton(
                      onPressed: (Platform.isAndroid && device.isBonded)
                          ? null
                          : () => _pairAndConnect(device),
                      child: Text(
                          Platform.isAndroid
                              ? (device.isBonded
                                ? lang.translate('btn_paired')
                                : lang.translate('btn_pair'))
                              : (device.isSystemConnected 
                                  ? lang.translate('btn_select')
                                  : lang.translate('btn_connect'))
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