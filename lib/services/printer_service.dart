import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// IMPORTANT: Import the separate service file so we share the same connection
import 'bluetooth_print_service.dart'; 

class PrinterService {
  // Use the singleton instance from the separate file
  final BluetoothPrintService _bleService = BluetoothPrintService();
  
  // MANAGED QUEUE: Prevents Memory Leaks and OOM Crashes
  final List<List<int>> _queue = [];
  bool _isProcessing = false;

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

  Future<bool> connect(String macAddress) async {
    if (Platform.isAndroid) {
      // Force refresh connection for stability
      await PrintBluetoothThermal.disconnect;
      await Future.delayed(const Duration(milliseconds: 500));
      return await PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
    } else {
      // iOS: Reconstruct the device object using the UUID (macAddress)
      // This allows us to pass it to the shared service
      BluetoothDevice device = BluetoothDevice(remoteId: DeviceIdentifier(macAddress));
      return await _bleService.connect(device);
    }
  }

  Future<bool> disconnect() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.disconnect;
    } else {
      await _bleService.disconnect();
      return true;
    }
  }

  // --- UPDATED SEND METHOD WITH MEMORY PROTECTION ---
  Future<void> sendBytes(List<int> bytes) async {
    // Add to queue and trigger worker if idle
    _queue.add(bytes);
    if (!_isProcessing) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    _isProcessing = true;
    
    while (_queue.isNotEmpty) {
      final List<int> currentJob = _queue.removeAt(0);
      
      try {
        // --- WAKE UP SEQUENCE (Adapted from rawbt logic) ---
        // 1. Wake up bytes (NULL) -> Wakes printer CPU from sleep
        final List<int> wakeUp = [0x00, 0x00, 0x00];
        // 2. Init Command -> Clears buffer settings
        final List<int> resetCmd = [0x1B, 0x40]; 
        
        if (Platform.isAndroid) {
          // Send Wake Up
          await PrintBluetoothThermal.writeBytes(wakeUp);
          await Future.delayed(const Duration(milliseconds: 150));
          
          // Send Init
          await PrintBluetoothThermal.writeBytes(resetCmd);
          await Future.delayed(const Duration(milliseconds: 100));
          
          // CRITICAL FIX: Use chunking for Android to prevent Buffer Overflow
          await _sendSafeAndroid(currentJob);
        } else {
          // iOS / BLE Path
          // Send Wake Up + Init
          await _bleService.sendBytes([...wakeUp, ...resetCmd]);
          await Future.delayed(const Duration(milliseconds: 200));
          
          // Send Job (iOS BLE service handles chunking internally now)
          await _bleService.sendBytes(currentJob);
        }
        
        // HARDWARE RECOVERY DELAY: 1.5 seconds per job
        // Prevents thermal printer from overheating or crashing on large queues
        await Future.delayed(const Duration(milliseconds: 1500));
      } catch (e) {
        debugPrint("Queue Worker Error: $e");
      }
    }
    
    _isProcessing = false;
  }

  /// Helper to chunk large byte arrays on Android to prevent buffer overflow
  /// Prevents "alien text" on generic Chinese printers with small buffers (4KB)
  Future<void> _sendSafeAndroid(List<int> bytes) async {
    // 2048 bytes (2KB) is generally safe for SPP (Bluetooth Classic)
    const int chunkSize = 2048; 
    
    for (int i = 0; i < bytes.length; i += chunkSize) {
      int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      List<int> chunk = bytes.sublist(i, end);
      
      await PrintBluetoothThermal.writeBytes(chunk);
      
      // INCREASED DELAY: 50ms (was 30ms)
      // Matches the "mechanical delay" we added in Kotlin to be safer.
      await Future.delayed(const Duration(milliseconds: 50)); 
    }
  }

  Future<bool> isConnected() async {
    if (Platform.isAndroid) {
      return await PrintBluetoothThermal.connectionStatus;
    } else {
      return _bleService.isConnected;
    }
  }

  int get pendingJobs => _queue.length;
}