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
  BluetoothCharacteristic? _notifyCharacteristic; // For Input Draining

  /// Check connection status
  bool get isConnected {
    if (_connectedDevice == null) return false;
    return _connectedDevice!.isConnected; 
  }

  // --- 1. Request Permissions ---
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      bool scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      bool connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      bool locationGranted = statuses[Permission.location]?.isGranted ?? false;

      return (scanGranted && connectGranted) || locationGranted;
    } else if (Platform.isIOS) {
      PermissionStatus status = await Permission.bluetooth.request();
      return status.isGranted;
    }
    return false;
  }

  // --- 2. Scan for Devices (BLE) ---
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Future<void> startScan() async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      throw Exception("Bluetooth is off");
    }
    return FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  Future<void> stopScan() async {
    return FlutterBluePlus.stopScan();
  }

  // --- 3. Connect to a specific printer ---
  Future<bool> connect(BluetoothDevice device) async {
    try {
      await stopScan();

      if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId) {
        return true; 
      }

      // Connect without autoConnect for faster response
      await device.connect(autoConnect: false, mtu: null);
      _connectedDevice = device;

      // 4. Discover Services
      List<BluetoothService> services = await device.discoverServices();
      _writeCharacteristic = null;
      _notifyCharacteristic = null;

      for (var service in services) {
        for (var characteristic in service.characteristics) {
          // Find Write
          if (characteristic.properties.writeWithoutResponse || characteristic.properties.write) {
            _writeCharacteristic = characteristic;
          }
          // Find Notify (for input draining)
          if (characteristic.properties.notify || characteristic.properties.indicate) {
             _notifyCharacteristic = characteristic;
          }
        }
      }
      
      if (_writeCharacteristic != null) {
          // Start draining input if available (keeps connection alive on some devices)
          if (_notifyCharacteristic != null) {
              try {
                  await _notifyCharacteristic!.setNotifyValue(true);
                  _notifyCharacteristic!.lastValueStream.listen((value) {});
              } catch (e) { /* Ignore notification errors */ }
          }
          return true;
      }
      
      throw Exception("No writable characteristic found.");
    } catch (e) {
      print("Connection failed: $e");
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
      _notifyCharacteristic = null;
    }
  }

  // --- 6. Send Bytes (Optimized for iOS BLE) ---
  Future<void> sendBytes(List<int> bytes) async {
    if (_connectedDevice == null || _writeCharacteristic == null) {
      throw Exception("Not connected or Write Characteristic not found");
    }

    final bool canWriteNoResponse = _writeCharacteristic!.properties.writeWithoutResponse;
    
    // REDUCED CHUNK SIZE: 80 bytes is safer for generic thermal printers via BLE on iOS
    const int chunkSize = 80; 

    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      
      try {
        await _writeCharacteristic!.write(chunk, withoutResponse: canWriteNoResponse);
        
        // Increased delay for iOS stability (prevents data loss)
        int delay = Platform.isAndroid ? 15 : 45; 
        await Future.delayed(Duration(milliseconds: delay)); 
      } catch (e) {
        print("Error writing chunk: $e");
        throw e;
      }
    }
  }
}