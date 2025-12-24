import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ==========================================
// 1. MAIN PRINTER SERVICE (Android + iOS Unified)
// ==========================================
class PrinterService {
  // Create an instance of the iOS helper class defined at the bottom of this file
  final BluetoothPrintService _bleService = BluetoothPrintService();

  // --- GET PAIRED DEVICES (Unified) ---
  Future<List<BluetoothInfo>> getBondedDevices() async {
    if (Platform.isAndroid) {
      // Android: Use the native plugin to get system bonded devices
      return await PrintBluetoothThermal.pairedBluetooths;
    } else if (Platform.isIOS) {
      // iOS: Load "Saved" devices from SharedPreferences manually
      final prefs = await SharedPreferences.getInstance();
      final String? savedListString = prefs.getString('ios_saved_printers');

      if (savedListString != null) {
        try {
          List<dynamic> jsonList = jsonDecode(savedListString);
          return jsonList.map((item) {
            return BluetoothInfo(
                name: item['name'] ?? "Unknown",
                macAdress: item['macAdress'] ?? "" // On iOS this is the UUID
            );
          }).toList();
        } catch (e) {
          debugPrint("Error parsing iOS saved printers: $e");
          return [];
        }
      }
      return [];
    }
    return [];
  }

  // --- SAVE DEVICE (iOS Only) ---
  // Helper to simulate "Bonding" on iOS by saving the UUID
  Future<void> saveDevice(String name, String macAddress) async {
    if (!Platform.isIOS) return;

    final prefs = await SharedPreferences.getInstance();
    List<BluetoothInfo> currentList = await getBondedDevices();

    // Check if already exists to avoid duplicates
    bool exists = currentList.any((d) => d.macAdress == macAddress);
    if (!exists) {
      currentList.add(BluetoothInfo(name: name, macAdress: macAddress));

      // Convert to JSON for storage
      List<Map<String, String>> jsonList = currentList.map((d) => {
        'name': d.name,
        'macAdress': d.macAdress
      }).toList();

      await prefs.setString('ios_saved_printers', jsonEncode(jsonList));
    }
  }

  // --- CONNECT (Unified) ---
  Future<bool> connect(String macAddress) async {
    if (Platform.isAndroid) {
      // Android Connection (Classic Bluetooth)
      return await PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
    } else {
      // iOS Connection (BLE)
      try {
        // We recreate the BluetoothDevice object using the saved UUID (macAddress)
        BluetoothDevice device = BluetoothDevice(remoteId: DeviceIdentifier(macAddress));
        return await _bleService.connect(device);
      } catch (e) {
        debugPrint("iOS Connection Error: $e");
        return false;
      }
    }
  }

  // --- DISCONNECT (Unified) ---
  Future<bool> disconnect() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.disconnect;
    } else {
      await _bleService.disconnect();
      return true;
    }
  }
}

// ==========================================
// 2. IOS BLE HELPER CLASS (BluetoothPrintService)
// ==========================================
class BluetoothPrintService {
  static final BluetoothPrintService _instance = BluetoothPrintService._internal();
  factory BluetoothPrintService() => _instance;
  BluetoothPrintService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  // Check connection status
  bool get isConnected {
    if (_connectedDevice == null) return false;
    return _connectedDevice!.isConnected;
  }

  // --- Connect to a specific printer (BLE) ---
  Future<bool> connect(BluetoothDevice device) async {
    try {
      // Always stop scanning before connecting to improve stability
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      // Check if already connected to this specific device
      if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId) {
        if (isConnected) return true;
      }

      // Connect
      // Note: 'mtu: null' lets the OS negotiate the size.
      await device.connect(autoConnect: false);

      _connectedDevice = device;

      // Discover Services to find the Write Characteristic
      List<BluetoothService> services = await device.discoverServices();

      _writeCharacteristic = null;

      // Loop through services to find a writable characteristic
      // Most thermal printers use specific UUIDs, but searching for 'write' property is generic and usually works.
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.writeWithoutResponse || characteristic.properties.write) {
            _writeCharacteristic = characteristic;
            return true;
          }
        }
      }

      if (_writeCharacteristic == null) {
        debugPrint("No writable characteristic found on this device.");
        // Optional: Disconnect if we can't write to it
        await device.disconnect(); 
        return false;
      }

      return true;
    } catch (e) {
      debugPrint("BLE Connection failed: $e");
      disconnect();
      return false;
    }
  }

  // --- Disconnect ---
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _writeCharacteristic = null;
    }
  }

  // --- Send Bytes (Chunked for BLE) ---
  Future<void> sendBytes(List<int> bytes) async {
    if (_connectedDevice == null || _writeCharacteristic == null) {
      throw Exception("Not connected or Write Characteristic not found");
    }

    // Determine write type
    final bool canWriteNoResponse = _writeCharacteristic!.properties.writeWithoutResponse;
    final bool canWriteResponse = _writeCharacteristic!.properties.write;
    
    // Prefer WriteWithoutResponse for speed, unless only WriteResponse is available
    bool useWithoutResponse = canWriteNoResponse;
    if (!canWriteNoResponse && canWriteResponse) {
      useWithoutResponse = false;
    }

    // BLE MTU is limited (often 20-512 bytes). We split large data into chunks (e.g., 150 bytes).
    const int chunkSize = 150; 

    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      
      try {
        await _writeCharacteristic!.write(chunk, withoutResponse: useWithoutResponse);
        
        // Small delay to prevent buffer overflow on the printer side
        int delay = Platform.isAndroid ? 10 : 5; 
        await Future.delayed(Duration(milliseconds: delay)); 
      } catch (e) {
        debugPrint("Error writing BLE chunk: $e");
        throw e;
      }
    }
  }
}