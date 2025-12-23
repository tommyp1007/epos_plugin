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

  /// Check connection status using the device's current state stream
  bool get isConnected {
    if (_connectedDevice == null) return false;
    return _connectedDevice!.isConnected; 
  }

  // --- 1. Request Permissions (Updated for Android 12+ & iOS) ---
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      // Android 12+ (SDK 31+) permissions
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Critical for detection on older Android (Huawei/Samsung)
      ].request();

      bool scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      bool connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      bool locationGranted = statuses[Permission.location]?.isGranted ?? false;

      // Simplistic check: generally if we have location (old) or scan+connect (new), we are good.
      return (scanGranted && connectGranted) || locationGranted;
    } else if (Platform.isIOS) {
      // iOS 13+ requires Bluetooth permission
      PermissionStatus status = await Permission.bluetooth.request();
      return status.isGranted;
    }
    return false;
  }

  // --- 2. Scan for Devices (BLE) ---
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Future<void> startScan() async {
    // Check if Bluetooth is actually On before scanning to avoid errors
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      throw Exception("Bluetooth is off");
    }
    // Timeout ensures we don't drain battery
    return FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  Future<void> stopScan() async {
    return FlutterBluePlus.stopScan();
  }

  // --- 3. Connect to a specific printer ---
  Future<bool> connect(BluetoothDevice device) async {
    try {
      // Crucial for Android: Always stop scanning before connecting
      await stopScan();

      if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId) {
        return true; // Already connected
      }

      // --- FIX APPLIED HERE ---
      // We added 'license: License.free'. 
      // If you are a commercial entity with >15 employees, use License.commercial.
      await device.connect(
        license: License.free, // Required in flutter_blue_plus v2.0+
        autoConnect: false, 
        mtu: null
      );
      
      _connectedDevice = device;

      // 4. Discover Services & Find Write Characteristic
      List<BluetoothService> services = await device.discoverServices();
      
      // Reset characteristic
      _writeCharacteristic = null;

      for (var service in services) {
        for (var characteristic in service.characteristics) {
          // We look for a characteristic that allows writing.
          // Printers usually have one specific characteristic for data.
          if (characteristic.properties.writeWithoutResponse || characteristic.properties.write) {
            _writeCharacteristic = characteristic;
            return true;
          }
        }
      }
      
      if (_writeCharacteristic == null) {
        throw Exception("No writable characteristic found on this device.");
      }
      
      return true;
    } catch (e) {
      print("Connection failed: $e");
      // Cleanup if connection failed
      disconnect();
      return false;
    }
  }

  // --- 5. Disconnect ---
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _writeCharacteristic = null;
    }
  }

  // --- 6. Send Bytes (With Chunking for BLE) ---
  Future<void> sendBytes(List<int> bytes) async {
    if (_connectedDevice == null || _writeCharacteristic == null) {
      throw Exception("Not connected or Write Characteristic not found");
    }

    // Determine the type of write (With Response is slower but more reliable, Without Response is faster)
    final bool canWriteNoResponse = _writeCharacteristic!.properties.writeWithoutResponse;
    final bool canWriteResponse = _writeCharacteristic!.properties.write;
    
    // Preference: NoResponse > Response
    bool useWithoutResponse = canWriteNoResponse;
    if (!canWriteNoResponse && canWriteResponse) {
      useWithoutResponse = false;
    }

    // BLE has a limit (MTU). We must split data into chunks.
    const int chunkSize = 150; 

    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      
      try {
        await _writeCharacteristic!.write(chunk, withoutResponse: useWithoutResponse);
        
        // Small delay is CRITICAL for Android to prevent buffer overflow
        int delay = Platform.isAndroid ? 15 : 5; 
        await Future.delayed(Duration(milliseconds: delay)); 
      } catch (e) {
        print("Error writing chunk: $e");
        throw e;
      }
    }
  }
}