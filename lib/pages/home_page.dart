import 'dart:async';
import 'dart:io';
// Import rootBundle to load assets for the PDF
import 'package:flutter/services.dart' show rootBundle;

import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart'; 

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../services/printer_service.dart';
import '../services/language_service.dart'; 
import 'width_settings.dart';
import 'scan_devices.dart';
import 'app_info.dart'; 

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
      debugPrint("Error loading bonded devices: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoadingPaired = false);
      }
    }
  }

  // --- FULL RESET FUNCTION ---
  Future<void> _handleFullRefresh() async {
    setState(() => _isLoadingPaired = true);
    final lang = Provider.of<LanguageService>(context, listen: false);

    try {
      // 1. Disconnect Printer
      await _printerService.disconnect();

      // 2. Clear Preferences (EXCEPT LANGUAGE)
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('selected_printer_mac'); // Clear connection memory
      await prefs.remove('printer_width_dots');   // Clear Section 3 Config
      await prefs.remove('printer_dpi');          // Clear Section 3 Config
      await prefs.remove('printer_width_mode');   // Clear Auto-detect Config
      
      // Note: We do NOT remove 'language_code', so translation stays.

      // 3. Reset UI State
      if (mounted) {
        setState(() {
          _connectedMac = null;
          _selectedPairedDevice = null;
          _isConnecting = false;
        });
      }

      // 4. Reload Paired Devices
      await _loadBondedDevices();

      // 5. Show Feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('msg_reset_defaults')))
        );
      }

    } catch (e) {
      debugPrint("Error refreshing: $e");
    } finally {
      if (mounted) setState(() => _isLoadingPaired = false);
    }
  }

  Future<void> _toggleConnection() async {
    if (_selectedPairedDevice == null) return;

    final lang = Provider.of<LanguageService>(context, listen: false);

    setState(() => _isConnecting = true);

    String selectedMac = _selectedPairedDevice!.macAdress;
    bool isCurrentlyConnectedToSelection = (_connectedMac == selectedMac);
    final prefs = await SharedPreferences.getInstance();

    try {
      if (isCurrentlyConnectedToSelection) {
        await _printerService.disconnect();
        await prefs.remove('selected_printer_mac');

        if (mounted) {
          setState(() {
            _connectedMac = null;
            _isConnecting = false;
          });
          _showSnackBar(lang.translate('msg_disconnected'));
        }
      } else {
        if (_connectedMac != null) {
          await _printerService.disconnect();
          await Future.delayed(const Duration(milliseconds: 500));
        }

        bool success = await _printerService.connect(selectedMac);

        if (success) {
          await prefs.setString('selected_printer_mac', selectedMac);

          if (mounted) {
            setState(() {
              _connectedMac = selectedMac;
              _isConnecting = false;
            });
            _showSnackBar("${lang.translate('msg_connected')} ${_selectedPairedDevice!.name}");
          }
        } else {
          await prefs.remove('selected_printer_mac');
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
    if (result is String) {
      _loadBondedDevices(autoSelectMac: result);
    } else if (result == true) {
      _loadBondedDevices();
    }
  }

  Future<void> _testNativePrintService() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final int inputDots = prefs.getInt('printer_width_dots') ?? 384;
      const int _selectedDpi = 203;
      // Using 79.0mm gives a tiny buffer on standard 80mm paper to prevent clipping
      const double paperWidthMm = 79.0;

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

          // 1. Load the image asset
          final logoImage = pw.MemoryImage(
            (await rootBundle.load('assets/images/print_test.png')).buffer.asUint8List(),
          );

          doc.addPage(pw.Page(
              pageFormat: receiptFormat,
              build: (pw.Context context) {
                // WRAP WITH ALIGN to force centering on the paper
                return pw.Align(
                  alignment: pw.Alignment.topCenter,
                  child: pw.Column(
                    mainAxisSize: pw.MainAxisSize.min,
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      // 2. Add Logo Image at top
                      pw.Center(
                        child: pw.Image(
                          logoImage,
                          width: 100,
                          height: 100,
                          fit: pw.BoxFit.contain,
                        ),
                      ),
                      pw.SizedBox(height: 10),

                      pw.Text(
                        lang.translate('test_print_title'),
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16),
                        textAlign: pw.TextAlign.center,
                      ),
                      pw.SizedBox(height: 5),
                      pw.Text("${lang.translate('test_print_dpi')}$_selectedDpi"), 
                      pw.Text("${lang.translate('test_print_config')}$inputDots${lang.translate('test_print_dots_suffix')}"), 
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
                  ),
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

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);

    bool isSelectedDeviceConnected = (_selectedPairedDevice != null && _selectedPairedDevice!.macAdress == _connectedMac);

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
                  child: Column(
                    children: [
                      DropdownButton<BluetoothInfo>(
                        isExpanded: true,
                        hint: Text(lang.translate('select_hint')),
                        value: (_pairedDevices.isNotEmpty && _selectedPairedDevice != null && _pairedDevices.contains(_selectedPairedDevice))
                            ? _selectedPairedDevice
                            : null,
                        items: _pairedDevices.map((device) {
                          return DropdownMenuItem(value: device, child: Text(device.name.isEmpty ? lang.translate('unknown_device') : device.name));
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
                  ),
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