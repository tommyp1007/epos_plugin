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
  // Instance of the iOS helper defined below
  final BluetoothPrintService _bleService = BluetoothPrintService();

  // --- GET PAIRED DEVICES ---
  Future<List<BluetoothInfo>> getBondedDevices() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.pairedBluetooths;
    } else if (Platform.isIOS) {
      final prefs = await SharedPreferences.getInstance();
      final String? savedListString = prefs.getString('ios_saved_printers');
      if (savedListString != null) {
        try {
          List<dynamic> jsonList = jsonDecode(savedListString);
          return jsonList.map((item) => BluetoothInfo(
              name: item['name'] ?? "Unknown",
              macAdress: item['macAdress'] ?? ""
          )).toList();
        } catch (e) {
          return [];
        }
      }
      return [];
    }
    return [];
  }

  // --- SAVE DEVICE (iOS) ---
  Future<void> saveDevice(String name, String macAddress) async {
    if (!Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    List<BluetoothInfo> currentList = await getBondedDevices();
    
    if (!currentList.any((d) => d.macAdress == macAddress)) {
      currentList.add(BluetoothInfo(name: name, macAdress: macAddress));
      List<Map<String, String>> jsonList = currentList.map((d) => {
        'name': d.name,
        'macAdress': d.macAdress
      }).toList();
      await prefs.setString('ios_saved_printers', jsonEncode(jsonList));
    }
  }

  // --- CONNECT ---
  Future<bool> connect(String macAddress) async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
    } else {
      try {
        BluetoothDevice device = BluetoothDevice(remoteId: DeviceIdentifier(macAddress));
        return await _bleService.connect(device);
      } catch (e) {
        debugPrint("iOS Connection Error: $e");
        return false;
      }
    }
  }

  // --- DISCONNECT ---
  Future<bool> disconnect() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.disconnect;
    } else {
      await _bleService.disconnect();
      return true;
    }
  }

  // --- SEND BYTES (Required for iOS Printing) ---
  Future<void> sendBytes(List<int> bytes) async {
    if (Platform.isAndroid) {
      // Android: Send via plugin
      await PrintBluetoothThermal.writeBytes(bytes);
    } else {
      // iOS: Send via our custom BLE service
      await _bleService.sendBytes(bytes);
    }
  }

  // --- CHECK CONNECTION STATUS ---
  Future<bool> isConnected() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.connectionStatus;
    } else {
      return _bleService.isConnected;
    }
  }
}

// ==========================================
// 2. IOS BLE HELPER CLASS
// ==========================================
class BluetoothPrintService {
  static final BluetoothPrintService _instance = BluetoothPrintService._internal();
  factory BluetoothPrintService() => _instance;
  BluetoothPrintService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  bool get isConnected => _connectedDevice != null && _connectedDevice!.isConnected;

  Future<bool> connect(BluetoothDevice device) async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
      
      // If already connected to this device, return true
      if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId && isConnected) {
        return true;
      }

      await device.connect(autoConnect: false);
      _connectedDevice = device;

      List<BluetoothService> services = await device.discoverServices();
      _writeCharacteristic = null;

      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.writeWithoutResponse || characteristic.properties.write) {
            _writeCharacteristic = characteristic;
            return true;
          }
        }
      }
      return _writeCharacteristic != null;
    } catch (e) {
      disconnect();
      return false;
    }
  }

  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _writeCharacteristic = null;
    }
  }

  Future<void> sendBytes(List<int> bytes) async {
    if (_connectedDevice == null || _writeCharacteristic == null) {
      throw Exception("Not connected (iOS BLE)");
    }
    
    // Chunking for BLE limits (iOS handles small chunks better)
    const int chunkSize = 150; 
    bool useWithoutResponse = _writeCharacteristic!.properties.writeWithoutResponse;

    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      await _writeCharacteristic!.write(chunk, withoutResponse: useWithoutResponse);
      await Future.delayed(const Duration(milliseconds: 20)); // Critical delay
    }
  }
}