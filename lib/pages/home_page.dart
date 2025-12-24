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

import '../services/printer_service.dart';
import '../services/language_service.dart';
import 'width_settings.dart';
import 'scan_devices.dart';
import 'app_info.dart';

// --- UPDATED: Import the new generic viewer page ---
import 'pdf_viewer_ios.dart'; 

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

    // --- UPDATED: Handle file on initial launch ---
    if (widget.sharedFilePath != null) {
      _handleSharedFile(widget.sharedFilePath!);
    }
  }

  // --- UPDATED: Handle file when app is already running (background) ---
  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sharedFilePath != null && widget.sharedFilePath != oldWidget.sharedFilePath) {
      _handleSharedFile(widget.sharedFilePath!);
    }
  }

  // --- UPDATED: Centralized Shared File Logic ---
  void _handleSharedFile(String path) {
    // Delay slightly to ensure context is ready
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _showSharedFileDialog(path);
      }
    });
  }

  // ==========================================
  // SHARED FILE HANDLING LOGIC (UPDATED)
  // ==========================================
  void _showSharedFileDialog(String filePath) {
    // Check if it is a website URL or a local file path
    bool isUrl = filePath.toLowerCase().startsWith('http');
    String displayName = isUrl ? "Website Document" : filePath.split('/').last;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Content Received"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isUrl 
              ? "A link was shared from a website." 
              : "A file was shared from another app."),
            const SizedBox(height: 10),
            // Show filename or generic name
            Text("Source: $displayName", 
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 10),
            const Text("Do you want to preview and print it?"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.preview),
            label: const Text("Preview & Print"),
            onPressed: () {
              Navigator.pop(ctx);
              _navigateToPreview(filePath);
            },
          )
        ],
      ),
    );
  }

  void _navigateToPreview(String filePath) {
    // Navigate to the new PDF/Image Viewer Page
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PdfViewerPage(
          filePath: filePath,
          printerService: _printerService,
          connectedMac: _connectedMac, // Passing the connected status
        ),
      ),
    );
  }

  // ==========================================
  // EXISTING METHODS
  // ==========================================

  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
      ].request();
    }
    _loadBondedDevices();
  }

  Future<void> _loadBondedDevices({String? autoSelectMac}) async {
    setState(() => _isLoadingPaired = true);
    
    try {
      List<BluetoothInfo> devices = await _printerService.getBondedDevices();
      
      final prefs = await SharedPreferences.getInstance();
      final String? lastUsedMac = prefs.getString('selected_printer_mac');
      final String? lastUsedName = prefs.getString('selected_printer_name');

      // Logic to add the last used device to list if not found (iOS behavior)
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
    if (_selectedPairedDevice == null) return;
    final lang = Provider.of<LanguageService>(context, listen: false);

    setState(() => _isConnecting = true);

    String selectedMac = _selectedPairedDevice!.macAdress;
    String selectedName = _selectedPairedDevice!.name;
    
    // Check if we are currently connected to the device selected in the dropdown
    bool isCurrentlyConnectedToSelection = (_connectedMac == selectedMac);
    
    final prefs = await SharedPreferences.getInstance();

    try {
      if (isCurrentlyConnectedToSelection) {
        // --- DISCONNECT ---
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
        // --- CONNECT ---

        // 1. FORCE DISCONNECT FIRST
        await _printerService.disconnect();
        
        if (Platform.isAndroid) {
           await Future.delayed(const Duration(milliseconds: 200));
        }

        bool success = false;

        if (Platform.isAndroid) {
           // ANDROID RETRY MECHANISM
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
           // iOS LOGIC
           success = await _printerService.connect(selectedMac);
        }

        if (success) {
          await prefs.setString('selected_printer_mac', selectedMac);
          await prefs.setString('selected_printer_name', selectedName); 

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

          final lang = Provider.of<LanguageService>(context, listen: false);

          setState(() {
            _selectedPairedDevice = deviceResult;
            _connectedMac = mac; 
          });
          
          _showSnackBar("${lang.translate('msg_connected')} $name");
      }
    } else {
      _loadBondedDevices();
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
              )
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// UTILITY FOR IMAGE TO ESC/POS CONVERSION
// ==========================================
class PrintUtils {
  static List<int> imageToEscPos(img.Image image) {
    List<int> bytes = [];
    
    // Command: GS v 0 (Raster Image)
    // Header: 0x1D 0x76 0x30 0x00 xL xH yL yH
    
    int widthBytes = (image.width + 7) ~/ 8;
    int height = image.height;
    
    bytes += [0x1D, 0x76, 0x30, 0x00];
    bytes += [widthBytes % 256, widthBytes ~/ 256];
    bytes += [height % 256, height ~/ 256];
    
    // Process pixels
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < widthBytes; x++) {
        int byte = 0;
        for (int b = 0; b < 8; b++) {
          int px = x * 8 + b;
          if (px < image.width) {
            // Get pixel (assuming grayscale)
            var pixel = image.getPixel(px, y);
            // Check luminance/brightness. If dark, bit is 1. If light, bit is 0.
            if (pixel.r < 128) { // Dark pixel
               byte |= (1 << (7 - b));
            }
          }
        }
        bytes.add(byte);
      }
    }
    return bytes;
  }
}