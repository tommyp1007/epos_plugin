import 'dart:async';
import 'package:flutter/services.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

class PrinterService {
  
  /// Get list of paired devices
  /// Returns a list of [BluetoothInfo] which contains name and macAddress
  Future<List<BluetoothInfo>> getBondedDevices() async {
    try {
      final List<BluetoothInfo> result = await PrintBluetoothThermal.pairedBluetooths;
      return result;
    } on PlatformException catch (e) {
      print("Failed to get paired devices: $e");
      return [];
    }
  }

  /// Connect to a specific printer using its MAC Address
  Future<bool> connect(String macAddress) async {
    try {
      final bool result = await PrintBluetoothThermal.connect(
        macPrinterAddress: macAddress
      );
      return result;
    } on PlatformException catch (e) {
      print("Error connecting: $e");
      return false;
    }
  }

  /// Disconnect
  Future<bool> disconnect() async {
    try {
      final bool result = await PrintBluetoothThermal.disconnect;
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Check connection status
  Future<bool> get isConnected async {
    try {
      return await PrintBluetoothThermal.connectionStatus;
    } catch (e) {
      return false;
    }
  }

  /// Send raw bytes to the printer
  Future<bool> sendRawCommands(List<int> commands) async {
    try {
      bool connected = await isConnected;
      if (connected) {
        // print_bluetooth_thermal handles the chunking and types internally
        final bool result = await PrintBluetoothThermal.writeBytes(commands);
        return result;
      } else {
        print("Printer not connected");
        return false;
      }
    } catch (e) {
      print("Error sending commands: $e");
      return false;
    }
  }
}