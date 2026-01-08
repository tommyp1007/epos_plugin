import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

// PDF & Printing Imports
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// Image Processing
import 'package:image/image.dart' as img;

// File Picker (Required for Section 4 Manual Selection)
import 'package:file_picker/file_picker.dart'; 

import '../services/printer_service.dart';
import '../services/language_service.dart';
import 'width_settings.dart';
import 'scan_devices.dart';
import 'app_info.dart';

// Import the viewer page (This file already contains PrintUtils, so we don't redefine it here)
import 'pdf_viewer_ios.dart'; 

class HomePage extends StatefulWidget {
  final String? sharedFilePath;
  const HomePage({Key? key, this.sharedFilePath}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final PrinterService _printerService = PrinterService();

  List<BluetoothInfo> _pairedDevices = [];
  BluetoothInfo? _selectedPairedDevice;
  String? _connectedMac;
  bool _isLoadingPaired = false;
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // Detect app resume
    _checkPermissions();

    // Handle file on initial launch (Auto-print logic)
    if (widget.sharedFilePath != null) {
      _handleSharedFile(widget.sharedFilePath!);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // --- REFRESH STATUS ON APP RESUME ---
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verifyConnectionStatus();
    }
  }

  // Handle file when app is already running (background)
  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sharedFilePath != null && widget.sharedFilePath != oldWidget.sharedFilePath) {
      _handleSharedFile(widget.sharedFilePath!);
    }
  }

  // --- UPDATED: Direct Navigation Logic (Shared/Intent Files) ---
  void _handleSharedFile(String path) {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        // Auto-print true for shared files
        _navigateToPreview(path, isAutoPrint: true);
      }
    });
  }

  // --- NEW: Manual File Picker for Section 4 ---
  Future<void> _pickAndPrintFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      );

      if (result != null && result.files.single.path != null) {
        // Auto-print false for manual selection (so you can preview first)
        _navigateToPreview(result.files.single.path!, isAutoPrint: false);
      }
    } catch (e) {
      debugPrint("Error picking file: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error picking file: $e"), backgroundColor: Colors.red),
      );
    }
  }

  // --- UPDATED: Navigate to Preview ---
  void _navigateToPreview(String filePath, {bool isAutoPrint = true}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PdfViewerPage(
          filePath: filePath,
          printerService: _printerService,
          connectedMac: _connectedMac, 
          autoPrint: isAutoPrint, // Pass the flag
        ),
      ),
    );
  }

  // ==========================================
  // UPDATED PERMISSIONS (Notification + Battery Popup)
  // ==========================================

  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      // 1. Request Core Permissions + NOTIFICATION
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
        Permission.notification, // Critical for Android 13+
      ].request();

      // 2. TRIGGER BATTERY OPTIMIZATION POP-UP
      // This automatically opens the "Allow / Deny" dialog if not already granted.
      // No button needed in UI; this runs on app startup.
      var status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } else if (Platform.isIOS) {
      await [Permission.bluetooth].request();
    }
    await _loadBondedDevices();
    _verifyConnectionStatus(); // Check actual connection state immediately
  }

  // ==========================================
  // EXISTING METHODS
  // ==========================================

  Future<void> _loadBondedDevices({String? autoSelectMac}) async {
    setState(() => _isLoadingPaired = true);
    
    try {
      List<BluetoothInfo> devices = await _printerService.getBondedDevices();
      
      final prefs = await SharedPreferences.getInstance();
      final String? lastUsedMac = prefs.getString('selected_printer_mac');
      final String? lastUsedName = prefs.getString('selected_printer_name');

      if (Platform.isIOS && lastUsedMac != null && lastUsedName != null) {
          BluetoothInfo savedDevice = BluetoothInfo(name: lastUsedName, macAdress: lastUsedMac);
          if (!devices.any((d) => d.macAdress == lastUsedMac)) {
            devices.add(savedDevice);
          }
      }

      if (mounted) {
        setState(() {
          _pairedDevices = devices;
          
          if (devices.isNotEmpty) {
            if (autoSelectMac != null) {
              try {
                _selectedPairedDevice = devices.firstWhere((d) => d.macAdress == autoSelectMac);
              } catch (e) {
                 _selectedPairedDevice = BluetoothInfo(name: "Selected Device", macAdress: autoSelectMac);
                 _pairedDevices.add(_selectedPairedDevice!);
              }
            } 
            else if (lastUsedMac != null && devices.any((d) => d.macAdress == lastUsedMac)) {
               try {
                _selectedPairedDevice = devices.firstWhere((d) => d.macAdress == lastUsedMac);
              } catch (e) {
                _selectedPairedDevice = devices.first;
              }
            } 
            else if (Platform.isAndroid) {
              if (_selectedPairedDevice == null) {
                _selectedPairedDevice = devices.first;
              } else {
                bool exists = devices.any((d) => d.macAdress == _selectedPairedDevice!.macAdress);
                if (!exists) _selectedPairedDevice = devices.first;
              }
            }
          } else {
            _selectedPairedDevice = null;
          }
        });
      }
    } catch (e) {
      debugPrint("Error loading bonded devices: $e");
    } finally {
      if (mounted) setState(() => _isLoadingPaired = false);
    }
  }

  /// Verifies if the printer is *actually* connected.
  Future<void> _verifyConnectionStatus() async {
    try {
      // --- FIX APPLIED HERE ---
      // Instead of calling PrintBluetoothThermal directly (which is Android/Classic only),
      // we ask the PrinterService. It will check _bleService for iOS.
      bool isConnected = await _printerService.isConnected();
      
      final prefs = await SharedPreferences.getInstance();
      String? savedMac = prefs.getString('selected_printer_mac');

      if (mounted) {
        setState(() {
          if (isConnected && savedMac != null) {
            _connectedMac = savedMac;
          } else {
            _connectedMac = null; // Force UI to show "Disconnected"
          }
        });
      }
    } catch (e) {
      debugPrint("Error verifying connection: $e");
    }
  }

  Future<void> _handleFullRefresh() async {
    setState(() => _isLoadingPaired = true);
    final lang = Provider.of<LanguageService>(context, listen: false);

    try {
      await _printerService.disconnect();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('selected_printer_mac'); 
      await prefs.remove('selected_printer_name'); 
      await prefs.remove('printer_width_dots');     
      await prefs.remove('printer_dpi');            
      await prefs.remove('printer_width_mode');     
      
      if (Platform.isIOS) {
        await prefs.remove('ios_saved_printers');
      }

      if (mounted) {
        setState(() {
          _connectedMac = null;
          _selectedPairedDevice = null;
          _pairedDevices = []; 
          _isConnecting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('msg_reset_defaults')))
        );
      }
      await _loadBondedDevices();

    } catch (e) {
      debugPrint("Error refreshing: $e");
    } finally {
      if (mounted) setState(() => _isLoadingPaired = false);
    }
  }

  // --- TOGGLE CONNECTION METHOD ---
  Future<void> _toggleConnection() async {
    if (_selectedPairedDevice == null || _isConnecting) return; 

    final lang = Provider.of<LanguageService>(context, listen: false);

    setState(() => _isConnecting = true);

    String selectedMac = _selectedPairedDevice!.macAdress;
    String selectedName = _selectedPairedDevice!.name;
    
    bool isCurrentlyConnectedToSelection = (_connectedMac == selectedMac);
    final prefs = await SharedPreferences.getInstance();

    try {
      if (isCurrentlyConnectedToSelection) {
        await _printerService.disconnect();
        await prefs.remove('selected_printer_mac');
        await prefs.remove('selected_printer_name'); 

        if (mounted) {
          setState(() {
            _connectedMac = null;
            _isConnecting = false;
          });
          _showSnackBar(lang.translate('msg_disconnected'));
        }
      } else {
        await _printerService.disconnect();
        
        if (Platform.isAndroid) {
           await Future.delayed(const Duration(milliseconds: 200));
        }

        bool success = false;

        if (Platform.isAndroid) {
           try {
             success = await _printerService.connect(selectedMac);
           } catch (e) {
             debugPrint("Attempt 1 failed: $e");
           }

           if (!success) {
             await Future.delayed(const Duration(milliseconds: 500));
             try {
               success = await _printerService.connect(selectedMac);
             } catch (e) {
               debugPrint("Attempt 2 failed: $e");
             }
           }
        } else {
           success = await _printerService.connect(selectedMac);
        }

        if (success) {
          await prefs.setString('selected_printer_mac', selectedMac);
          await prefs.setString('selected_printer_name', selectedName); 

          // Auto-set width to 58mm (384 dots) on successful connection
          await prefs.setInt('printer_width_dots', 384);

          if (mounted) {
            setState(() {
              _connectedMac = selectedMac; 
              _isConnecting = false;
            });
            _showSnackBar("${lang.translate('msg_connected')} $selectedName");
          }
        } else {
          await prefs.remove('selected_printer_mac');
          await prefs.remove('selected_printer_name');
          if (mounted) {
            setState(() {
              _connectedMac = null;
              _isConnecting = false;
            });
            _showSnackBar(lang.translate('msg_failed'));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        _showSnackBar("${lang.translate('msg_error_conn')} $e");
      }
    }
  }

  // --- SCAN PAGE NAVIGATION ---
  Future<void> _navigateToScanPage() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ScanDevicesPage()),
    );

    if (result != null) {
      String mac = "";
      String name = "Unknown";
      BluetoothInfo? deviceResult;

      if (result is BluetoothInfo) {
        deviceResult = result;
        mac = result.macAdress;
        name = result.name;
      } else if (result is String) {
        mac = result;
      }

      await _loadBondedDevices(autoSelectMac: mac);
      
      if (deviceResult != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('selected_printer_name', name);
          await prefs.setString('selected_printer_mac', mac);
          await prefs.setInt('printer_width_dots', 384);

          final lang = Provider.of<LanguageService>(context, listen: false);

          setState(() {
            _selectedPairedDevice = deviceResult;
            _connectedMac = mac; 
          });
          
          _showSnackBar("${lang.translate('msg_connected')} $name");
      }
    } else {
      _loadBondedDevices();
      _verifyConnectionStatus();
    }
  }

  Future<void> _testNativePrintService() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.reload(); 

    final int inputDots = prefs.getInt('printer_width_dots') ?? 384;
    final String dynamicConfigStr = "$inputDots dots (~${(inputDots / 8).toStringAsFixed(0)}mm)";

    if (Platform.isIOS) {
      if (_connectedMac == null) {
        _showSnackBar(lang.translate('msg_disconnected'));
        return;
      }

      try {
        int estimatedCharsPerLine = (inputDots / 12).floor();
        if (estimatedCharsPerLine < 20) estimatedCharsPerLine = 32;

        List<int> bytes = [];
        bytes += [27, 64]; 
        bytes += [27, 97, 1]; 
        bytes += [27, 69, 1]; 
        bytes += [27, 33, 16];
        bytes += utf8.encode(lang.translate('test_print_title') + "\n");
        bytes += [27, 33, 0]; 
        bytes += [27, 69, 0]; 
        bytes += [10]; 

        bytes += utf8.encode("${lang.translate('test_print_config')}$dynamicConfigStr\n");
        bytes += [10];

        String separator = "-" * estimatedCharsPerLine; 
        bytes += utf8.encode(separator + "\n");
        bytes += [10];

        bytes += [27, 97, 0]; 
        String leftTxt = lang.translate('test_print_left');
        String centerTxt = lang.translate('test_print_center');
        String rightTxt = lang.translate('test_print_right');
        
        int totalSpaces = estimatedCharsPerLine - (leftTxt.length + centerTxt.length + rightTxt.length);

        if (totalSpaces > 0) {
          int spaceGap = (totalSpaces / 2).floor();
          String gap = " " * spaceGap;
          String line = "$leftTxt$gap$centerTxt$gap$rightTxt";
          bytes += utf8.encode(line + "\n");
        } else {
          bytes += utf8.encode("$leftTxt $centerTxt $rightTxt\n");
        }
        bytes += [10];
        bytes += utf8.encode(separator + "\n");
        bytes += [10]; 

        bytes += [27, 97, 1]; 
        String qrData = 'e-Pos System Test';
        List<int> qrDataBytes = utf8.encode(qrData);
        int storeLen = qrDataBytes.length + 3;
        int storePL = storeLen % 256;
        int storePH = storeLen ~/ 256;
        bytes += [29, 40, 107, 4, 0, 49, 65, 50, 0];
        bytes += [29, 40, 107, 3, 0, 49, 67, 6];
        bytes += [29, 40, 107, 3, 0, 49, 69, 49];
        bytes += [29, 40, 107, storePL, storePH, 49, 80, 48];
        bytes += qrDataBytes;
        bytes += [29, 40, 107, 3, 0, 49, 81, 48];
        bytes += [10]; 

        bytes += utf8.encode(lang.translate('test_print_instruction'));
        bytes += [10, 10, 10];
        bytes += [29, 86, 66, 0];

        await _printerService.sendBytes(bytes);
        _showSnackBar(lang.translate('msg_connected_success'));
      } catch (e) {
        _showSnackBar("${lang.translate('msg_print_error')} $e");
      }
      return;
    }

    // ANDROID LOGIC (PDF GENERATION)
    try {
      double paperWidthMm = (inputDots > 450) ? 79.0 : 58.0;
      
      final receiptFormat = PdfPageFormat(
          paperWidthMm * PdfPageFormat.mm,
          double.infinity, 
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
                    pw.Text(
                      lang.translate('test_print_title'),
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16),
                      textAlign: pw.TextAlign.center,
                    ),
                    pw.SizedBox(height: 5),
                    
                    pw.Text("${lang.translate('test_print_config')}$dynamicConfigStr"),
                    
                    pw.SizedBox(height: 10),
                    pw.Container(width: double.infinity, height: 2, color: PdfColors.black),
                    pw.SizedBox(height: 5),
                    pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(lang.translate('test_print_left')),
                          pw.Text(lang.translate('test_print_center')),
                          pw.Text(lang.translate('test_print_right')),
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
                    pw.Text(
                      lang.translate('test_print_instruction'),
                      textAlign: pw.TextAlign.center
                    ),
                  ],
                );
              }
          ));
          return doc.save();
        },
        name: 'ePos_Receipt_Test',
      );
    } catch (e) {
      _showSnackBar("${lang.translate('msg_error_launch')} $e");
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
            builder: (_) => AppInfoPage(connectedDeviceName: deviceName)
        )
    );
  }

  void _openPrinterConfig() {
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

  Widget _buildAndroidConnectionManager(LanguageService lang, bool isSelectedDeviceConnected) {
    return Column(
      children: [
        DropdownButton<BluetoothInfo>(
          isExpanded: true,
          hint: Text(lang.translate('select_hint')),
          value: (_pairedDevices.isNotEmpty && _selectedPairedDevice != null) 
              ? _pairedDevices.firstWhere(
                  (d) => d.macAdress == _selectedPairedDevice!.macAdress, 
                  orElse: () => _pairedDevices.first
                ) 
              : null,
          items: _pairedDevices.map((device) {
            return DropdownMenuItem(
              value: device, 
              child: Text(device.name.isEmpty ? lang.translate('unknown_device') : device.name)
            );
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
              ? lang.translate('working')
              : (isSelectedDeviceConnected ? lang.translate('disconnect') : lang.translate('connect_selected'))),
          style: ElevatedButton.styleFrom(
            backgroundColor: isSelectedDeviceConnected ? Colors.redAccent : Colors.green,
            foregroundColor: Colors.white,
          ),
          onPressed: (_selectedPairedDevice == null || _isConnecting) ? null : _toggleConnection,
        ),
        
        if (_connectedMac != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Text(
              isSelectedDeviceConnected
                  ? "${lang.translate('connected_to')} ${_selectedPairedDevice?.name}"
                  : lang.translate('connected_other'),
              style: TextStyle(
                color: isSelectedDeviceConnected ? Colors.green : Colors.orange,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        const Divider(),
        OutlinedButton.icon(
            icon: const Icon(Icons.search),
            label: Text(lang.translate('search_devices')),
            onPressed: _navigateToScanPage
        ),
      ],
    );
  }

  Widget _buildIOSConnectionManager(LanguageService lang, bool isSelectedDeviceConnected) {
    if (_connectedMac == null) {
      return Column(
        children: [
          const SizedBox(height: 10),
          const Icon(Icons.bluetooth_searching, size: 50, color: Colors.blueGrey),
          const SizedBox(height: 10),
          Text(
            lang.translate('status_not_connected'), 
            style: TextStyle(color: Colors.grey[600], fontSize: 16)
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.search),
              label: Text(lang.translate('search_devices'), style: const TextStyle(fontSize: 16)), 
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue, 
                foregroundColor: Colors.white
              ),
              onPressed: _navigateToScanPage,
            ),
          ),
          const SizedBox(height: 10),
        ],
      );
    }

    return Column(
      children: [
        const SizedBox(height: 10),
        const Icon(Icons.print_outlined, size: 50, color: Colors.green),
        const SizedBox(height: 10),
        Text(
          lang.translate('connected_to'), 
          style: TextStyle(color: Colors.grey[600])
        ),
        Text(
          _selectedPairedDevice?.name ?? lang.translate('unknown_device'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(
          _selectedPairedDevice?.macAdress ?? _connectedMac ?? "",
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 20),
        
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            icon: _isConnecting 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white))
              : const Icon(Icons.link_off),
            label: Text(_isConnecting ? lang.translate('working') : lang.translate('disconnect')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent, 
              foregroundColor: Colors.white
            ),
            onPressed: _isConnecting ? null : _toggleConnection,
          ),
        ),
         const SizedBox(height: 10),
         TextButton(
           child: Text(lang.translate('search_devices')), 
           onPressed: _navigateToScanPage,
         )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);

    bool isSelectedDeviceConnected = false;
    if (_selectedPairedDevice != null && _connectedMac != null) {
      isSelectedDeviceConnected = (_selectedPairedDevice!.macAdress == _connectedMac);
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/menu_icon.png',
              height: 24,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 8),
            Text(
              lang.translate('app_title'),
              style: const TextStyle(
                fontSize: 16,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _handleFullRefresh) 
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(lang.translate('sec_connection'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Platform.isAndroid 
                    ? _buildAndroidConnectionManager(lang, isSelectedDeviceConnected)
                    : _buildIOSConnectionManager(lang, isSelectedDeviceConnected),
                ),
              ),
              const SizedBox(height: 20),

              Text(lang.translate('sec_native'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Card(
                color: Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      Text(lang.translate('native_desc'), textAlign: TextAlign.center),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.print),
                          label: Text(lang.translate('test_system_button')),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                          onPressed: _testNativePrintService,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Text(lang.translate('sec_config'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.settings_applications, size: 40, color: Colors.blueGrey),
                  title: Text(lang.translate('width_dpi')),
                  subtitle: Text(lang.translate('width_desc')),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: _openPrinterConfig,
                ),
              ),
              
              // --- SECTION 4: PDF Viewer (iOS ONLY) ---
              if (Platform.isIOS) ...[
                const SizedBox(height: 20),
                const Text("Section 4: PDF Viewer / Manual Print", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Card(
                  elevation: 2,
                  child: ListTile(
                    leading: const Icon(Icons.picture_as_pdf, size: 40, color: Colors.red),
                    title: const Text("Select Document"),
                    subtitle: const Text("Pick a PDF or Image to print"),
                    trailing: const Icon(Icons.arrow_forward_ios),
                    onTap: _pickAndPrintFile,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}