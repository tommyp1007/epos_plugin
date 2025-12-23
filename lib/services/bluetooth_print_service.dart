import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BluetoothPrintService {
  static final BluetoothPrintService _instance = BluetoothPrintService._internal();
  factory BluetoothPrintService() => _instance;
  BluetoothPrintService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  bool get isConnected => _connectedDevice != null && _connectedDevice!.isConnected;

  // 1. Request Permissions
  Future<bool> requestPermissions() async {
    // Android 12+ requires specific scan/connect permissions
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Required for BLE on older Androids
      ].request();
      return statuses.values.every((status) => status.isGranted);
    }
    return true; // iOS handles permissions via Info.plist mostly
  }

  // 2. Scan for Devices (BLE)
  // We return the stream of list results provided by the library
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Future<void> startScan() async {
    // Timeout ensures we don't drain battery
    return FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
  }

  Future<void> stopScan() async {
    return FlutterBluePlus.stopScan();
  }

  // 3. Connect to a specific printer
  Future<bool> connect(BluetoothDevice device) async {
    try {
      if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId) {
        return true; // Already connected
      }

      await disconnect(); // Clean up old connection

      // Connect with auto-reconnect disabled for printers usually
      await device.connect(autoConnect: false);
      _connectedDevice = device;

      // 4. Discover Services & Find Write Characteristic
      // BLE devices have "Services", inside services are "Characteristics".
      // We need to find the one allowed to "Write".
      List<BluetoothService> services = await device.discoverServices();
      
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
            _writeCharacteristic = characteristic;
            return true;
          }
        }
      }
      
      return true;
    } catch (e) {
      print("Connection failed: $e");
      return false;
    }
  }

  // 5. Disconnect
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _writeCharacteristic = null;
    }
  }

  // 6. Send Bytes (With Chunking for BLE)
  Future<void> sendBytes(List<int> bytes) async {
    if (_connectedDevice == null || _writeCharacteristic == null) {
      throw Exception("Not connected or Write Characteristic not found");
    }

    // BLE has a limit (MTU). We must split data into chunks (e.g., 100 bytes)
    // or the printer will drop the data.
    const int chunkSize = 100; 
    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      
      // writeWithoutResponse is faster and usually preferred for thermal printers
      await _writeCharacteristic!.write(chunk, withoutResponse: true);
      
      // Small delay to prevent flooding the buffer
      await Future.delayed(const Duration(milliseconds: 10)); 
    }
  }
}