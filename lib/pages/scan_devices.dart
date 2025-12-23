import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/printer_service.dart';

class ScanDevicesPage extends StatefulWidget {
  const ScanDevicesPage({Key? key}) : super(key: key);

  @override
  _ScanDevicesPageState createState() => _ScanDevicesPageState();
}

class _ScanDevicesPageState extends State<ScanDevicesPage> {
  final PrinterService _printerService = PrinterService();
  List<BluetoothDiscoveryResult> _scanResults = [];
  bool _isScanning = false;
  StreamSubscription<BluetoothDiscoveryResult>? _scanSubscription;

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
      await [Permission.bluetooth, Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) return;
    setState(() { _scanResults = []; _isScanning = true; });

    try {
      _scanSubscription = FlutterBluetoothSerial.instance.startDiscovery().listen((result) {
        if (mounted) {
          setState(() {
            if (result.device.name != null && result.device.name!.isNotEmpty) {
              final existingIndex = _scanResults.indexWhere((r) => r.device.address == result.device.address);
              if (existingIndex >= 0) {
                _scanResults[existingIndex] = result; 
              } else {
                _scanResults.add(result);
              }
              _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
            }
          });
        }
      });
      await Future.delayed(const Duration(seconds: 15));
      if (_isScanning) _stopScan();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Scan Error: $e")));
    }
  }

  Future<void> _stopScan() async {
    await _scanSubscription?.cancel();
    await FlutterBluetoothSerial.instance.cancelDiscovery();
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _pairAndConnect(BluetoothDiscoveryResult result) async {
    await _stopScan();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Pairing with ${result.device.name}...")));
    try {
      bool paired = await FlutterBluetoothSerial.instance.bondDeviceAtAddress(result.device.address) ?? false;
      if (!paired) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Pairing failed.")));
         return;
      }
      bool success = await _printerService.connect(result.device.address);
      if (mounted) {
        if (success) {
          Navigator.pop(context, result.device.address); 
        } else {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
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
                  SizedBox(width: double.infinity, child: ElevatedButton.icon(icon: const Icon(Icons.bluetooth_searching), label: const Text("SCAN DEVICES"), onPressed: _startScan)),
                ],
              ],
            ),
          ),
          Expanded(
            child: _scanResults.isEmpty
                ? Center(child: Text(_isScanning ? "Scanning..." : "No devices found"))
                : ListView.builder(
                    itemCount: _scanResults.length,
                    itemBuilder: (context, index) {
                      final result = _scanResults[index];
                      final device = result.device;
                      return Card(
                        child: ListTile(
                          leading: Icon(Icons.print, color: Colors.blueGrey),
                          title: Text(device.name ?? "Unknown"),
                          subtitle: Text("${device.address}\nRSSI: ${result.rssi}"),
                          trailing: ElevatedButton(
                            onPressed: device.isBonded ? null : () => _pairAndConnect(result),
                            child: Text(device.isBonded ? "PAIRED" : "PAIR"),
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