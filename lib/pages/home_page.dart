import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../services/printer_service.dart';
import 'width_settings.dart';
import 'scan_devices.dart';

class HomePage extends StatefulWidget {
  final String? sharedFilePath;
  const HomePage({Key? key, this.sharedFilePath}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final PrinterService _printerService = PrinterService();

  List<BluetoothInfo> _pairedDevices = [];
  BluetoothInfo? _selectedPairedDevice;
  String? _connectedMac;
  bool _isLoadingPaired = false;
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    // 1. Android & Huawei (Android-based) Permissions
    if (Platform.isAndroid) {
      // requesting all relevant permissions for both old (Location) 
      // and new (Scan/Connect) Android versions.
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Critical for scanning on older Android & Huawei
      ].request();
    } 
    // 2. Apple iOS Permissions
    else if (Platform.isIOS) {
      // iOS requires Bluetooth permission explicitly
      await [
        Permission.bluetooth,
      ].request();
    }
    
    // After permissions are handled, load devices
    _loadBondedDevices();
  }

  Future<void> _loadBondedDevices({String? autoSelectMac}) async {
    setState(() => _isLoadingPaired = true);
    try {
      // Note: "Bonded" devices are primarily an Android concept. 
      // On iOS, this list might be empty, requiring the user to use "Search for Devices".
      List<BluetoothInfo> devices = await _printerService.getBondedDevices();
      
      if (mounted) {
        setState(() {
          _pairedDevices = devices;
          if (devices.isNotEmpty) {
            if (autoSelectMac != null) {
              try {
                _selectedPairedDevice = devices.firstWhere((d) => d.macAdress == autoSelectMac);
              } catch (e) {
                _selectedPairedDevice = devices.first;
              }
            } else {
              if (_selectedPairedDevice == null) {
                _selectedPairedDevice = devices.first;
              }
            }
          }
        });
      }
    } catch (e) {
      // On iOS, getBondedDevices might throw an UnimplementedError or PlatformException.
      // We catch it silently here so the app doesn't crash, allowing the user to use "Search".
      debugPrint("Error loading bonded devices (Normal on iOS): $e");
    } finally {
      if (mounted) {
        setState(() => _isLoadingPaired = false);
      }
    }
  }

  Future<void> _toggleConnection() async {
    if (_selectedPairedDevice == null) return;
    
    setState(() => _isConnecting = true);

    String selectedMac = _selectedPairedDevice!.macAdress;
    bool isCurrentlyConnectedToSelection = (_connectedMac == selectedMac);
    final prefs = await SharedPreferences.getInstance();

    try {
      if (isCurrentlyConnectedToSelection) {
        await _printerService.disconnect();
        // Remove the preference so Native Service stops filtering for this specific device
        await prefs.remove('selected_printer_mac'); 

        if (mounted) {
          setState(() {
            _connectedMac = null;
            _isConnecting = false;
          });
          _showSnackBar("Disconnected.");
        }
      } else {
        if (_connectedMac != null) {
           await _printerService.disconnect();
           await Future.delayed(const Duration(milliseconds: 500)); 
        }

        bool success = await _printerService.connect(selectedMac);
        
        if (success) {
           // SAVE MAC ADDRESS: This allows Kotlin/Native to know which printer to select by default
           await prefs.setString('selected_printer_mac', selectedMac); 
           
           if (mounted) {
             setState(() {
               _connectedMac = selectedMac;
               _isConnecting = false;
             });
             _showSnackBar("Connected to ${_selectedPairedDevice!.name}");
           }
        } else {
           await prefs.remove('selected_printer_mac');
           if (mounted) {
             setState(() {
               _connectedMac = null; 
               _isConnecting = false;
             });
             _showSnackBar("Connection failed. Is the printer ON?");
           }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        _showSnackBar("Error during connection: $e");
      }
    }
  }

  Future<void> _navigateToScanPage() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ScanDevicesPage()),
    );
    if (result is String) {
      _loadBondedDevices(autoSelectMac: result);
    } else if (result == true) {
      _loadBondedDevices();
    }
  }

  // --- 3. Native Print Logic (Updated) ---
  Future<void> _testNativePrintService() async {
    try {
      // Fetch current configuration for display on receipt
      final prefs = await SharedPreferences.getInstance();
      final int inputDots = prefs.getInt('printer_width_dots') ?? 384; // Default to 384 (58mm standard)
      const int _selectedDpi = 203; // Standard Thermal DPI

      // We force 80mm layout here so the Android Preview is never cropped.
      // The Service (Kotlin) will scale it down if the user settings = 58mm.
      const double paperWidthMm = 79.0;

      // Define page format
      final receiptFormat = PdfPageFormat(
         paperWidthMm * PdfPageFormat.mm, 
         double.infinity, // Continuous roll
         marginAll: 0 
      );

      await Printing.layoutPdf(
        format: receiptFormat, 
        dynamicLayout: false, 

        onLayout: (PdfPageFormat format) async {
          final doc = pw.Document();
          
          doc.addPage(pw.Page(
            pageFormat: receiptFormat,
            build: (pw.Context context) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text("e-Pos System Test Print", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                  pw.SizedBox(height: 5),
                  pw.Text("DPI: $_selectedDpi"),
                  pw.Text("Config: $inputDots dots (58mm)"),
                  pw.SizedBox(height: 10),
                  pw.Container(width: double.infinity, height: 2, color: PdfColors.black),
                  pw.SizedBox(height: 5),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text("<< Left"),
                      pw.Text("Center"),
                      pw.Text("Right >>"),
                    ]
                  ),
                  pw.SizedBox(height: 5),
                  pw.Container(width: double.infinity, height: 2, color: PdfColors.black),
                   pw.SizedBox(height: 10),
                   pw.BarcodeWidget(
                     barcode: pw.Barcode.qrCode(),
                     data: 'e-Pos System Test',
                     width: 100,
                     height: 100,
                   ),
                   pw.SizedBox(height: 10),
                   pw.Text("If 'Left' and 'Right' are cut off, reduce dots (e.g., 370). If there is whitespace, increase dots."),
                ]
              );
            }
          ));
          return doc.save();
        },
        name: 'ePos_Receipt_Test',
      );
    } catch (e) {
      _showSnackBar("Error launching Native Print: $e");
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openSettings() {
    String deviceName = "";
    if (_connectedMac != null && _selectedPairedDevice != null) {
      if (_selectedPairedDevice!.macAdress == _connectedMac) {
          deviceName = _selectedPairedDevice!.name;
      }
    }
    Navigator.push(
      context, 
      MaterialPageRoute(
        builder: (_) => WidthSettings(connectedDeviceName: deviceName)
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isSelectedDeviceConnected = (_selectedPairedDevice != null && _selectedPairedDevice!.macAdress == _connectedMac);

    return Scaffold(
      appBar: AppBar(
        title: const Text("My-Invois e-Pos Printer"),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _loadBondedDevices())
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text("1. Connection Manager", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      DropdownButton<BluetoothInfo>(
                        isExpanded: true,
                        hint: const Text("Select a paired printer"),
                        // Ensure the value matches exactly the object in the list
                        value: (_pairedDevices.isNotEmpty && _selectedPairedDevice != null && _pairedDevices.contains(_selectedPairedDevice)) 
                            ? _selectedPairedDevice 
                            : null,
                        items: _pairedDevices.map((device) {
                          return DropdownMenuItem(value: device, child: Text(device.name.isEmpty ? "Unknown Device" : device.name));
                        }).toList(),
                        onChanged: (device) {
                          setState(() { 
                            _selectedPairedDevice = device; 
                          });
                        },
                      ),
                      const SizedBox(height: 5),
                      ElevatedButton.icon(
                        icon: _isConnecting 
                           ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                           : Icon(isSelectedDeviceConnected ? Icons.link_off : Icons.link),
                        label: Text(_isConnecting 
                            ? "Working..." 
                            : (isSelectedDeviceConnected ? "Disconnect" : "Connect Selected")),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isSelectedDeviceConnected ? Colors.redAccent : Colors.green, 
                          foregroundColor: Colors.white
                        ),
                        onPressed: (_selectedPairedDevice == null || _isConnecting) ? null : _toggleConnection,
                      ),
                      if (_connectedMac != null) 
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            isSelectedDeviceConnected 
                                ? "Connected to ${_selectedPairedDevice?.name}" 
                                : "Connected to another device",
                            style: TextStyle(
                              color: isSelectedDeviceConnected ? Colors.green : Colors.orange, 
                              fontWeight: FontWeight.bold
                            ),
                          ),
                        ),
                      const Divider(),
                      OutlinedButton.icon(icon: const Icon(Icons.search), label: const Text("Search for Devices"), onPressed: _navigateToScanPage),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              const Text("2. Native / System Print", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Card(
                color: Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      const Text("Uses Android/iOS System Print Service.\nPreview matches configured paper width.", textAlign: TextAlign.center),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.print),
                          label: const Text("TEST SYSTEM PRINT"),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                          onPressed: _testNativePrintService,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
               const SizedBox(height: 20),
               
               const Text("3. Configuration", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
               Card(
                 child: ListTile(
                   leading: const Icon(Icons.settings_applications, size: 40, color: Colors.blueGrey),
                   title: const Text("Width & DPI Settings"),
                   subtitle: const Text("Set 58mm or 80mm paper size"),
                   trailing: const Icon(Icons.arrow_forward_ios),
                   onTap: _openSettings,
                 ),
               )
            ],
          ),
        ),
      ),
    );
  }
}