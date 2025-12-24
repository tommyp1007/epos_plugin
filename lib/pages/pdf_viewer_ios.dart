import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Image & PDF Processing
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';

import '../services/printer_service.dart';
import '../services/language_service.dart';

// NOTE: We do not need to import home_page.dart if we define PrintUtils here.
// If you prefer keeping PrintUtils in home_page.dart, uncomment the import below 
// and remove the PrintUtils class at the bottom of this file.
// import 'home_page.dart'; 

class PdfViewerPage extends StatefulWidget {
  final String filePath;
  final PrinterService printerService;
  // We accept the MAC that HomePage thinks is connected
  final String? connectedMac;

  const PdfViewerPage({
    Key? key,
    required this.filePath,
    required this.printerService,
    this.connectedMac,
  }) : super(key: key);

  @override
  _PdfViewerPageState createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  bool _isLoading = true;
  bool _isPrinting = false;
  
  // The processed images ready for the thermal printer
  List<img.Image> _processedImages = [];
  // The displayable bytes for the UI preview
  List<Uint8List> _previewBytes = [];
  
  int _printerWidth = 384; // Default 58mm
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadSettingsAndProcessFile();
  }

  Future<void> _loadSettingsAndProcessFile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _printerWidth = prefs.getInt('printer_width_dots') ?? 384;

      await _processFile();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _processFile() async {
    // --- FIX: DEFENSIVE PATH CLEANING ---
    String cleanPath = widget.filePath;
    
    // 1. Remove file:// prefix if present (common on iOS)
    if (cleanPath.startsWith('file://')) {
      cleanPath = cleanPath.substring(7);
    }
    
    // 2. Decode URI characters (e.g., convert "Invoice%20Scan.pdf" to "Invoice Scan.pdf")
    try {
      cleanPath = Uri.decodeFull(cleanPath);
    } catch (e) {
      print("Error decoding path: $e");
    }

    final File file = File(cleanPath);

    // 3. Check if file exists before reading
    if (!await file.exists()) {
      throw Exception("File not found at path: $cleanPath");
    }

    final String ext = cleanPath.split('.').last.toLowerCase();
    List<img.Image> rawImages = [];

    try {
      if (ext == 'pdf') {
        final pdfBytes = await file.readAsBytes();
        // Rasterize PDF at 203 DPI (Standard Thermal)
        await for (var page in Printing.raster(pdfBytes, dpi: 203)) {
          final pngBytes = await page.toPng();
          final decoded = img.decodeImage(pngBytes);
          if (decoded != null) rawImages.add(decoded);
        }
      } else {
        // It's an image
        final bytes = await file.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) rawImages.add(decoded);
      }
    } catch (e) {
       throw Exception("Error reading file: $e");
    }

    if (rawImages.isEmpty) {
      throw Exception("Could not decode file content (File might be empty or corrupted).");
    }

    // Resize logic to match Printer Width Settings
    _processedImages.clear();
    _previewBytes.clear();

    for (var image in rawImages) {
      // 1. Resize to fit the target printer width (e.g. 384 or 576)
      //    maintaining aspect ratio
      img.Image resized = img.copyResize(image, width: _printerWidth);
      
      // 2. Convert to Grayscale (Thermal printers are monochrome)
      resized = img.grayscale(resized);

      _processedImages.add(resized);
      
      // 3. Prepare for UI display (Encode back to PNG for Flutter Image widget)
      _previewBytes.add(img.encodePng(resized));
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // --- SMART CONNECTION LOGIC ---
  Future<bool> _ensureConnected() async {
    // 1. If passed from Home as connected, assume good
    if (widget.connectedMac != null) return true;

    // 2. If Home didn't pass a connection (Cold Start), check Preferences
    final prefs = await SharedPreferences.getInstance();
    final savedMac = prefs.getString('selected_printer_mac');

    if (savedMac != null && savedMac.isNotEmpty) {
       setState(() => _isPrinting = true); // Keep spinner going
       
       // Attempt to connect to the saved printer
       try {
         bool success = await widget.printerService.connect(savedMac);
         return success;
       } catch (e) {
         return false;
       }
    }
    return false;
  }

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    setState(() => _isPrinting = true);

    // STEP 1: Ensure Connection
    bool isConnected = await _ensureConnected();

    if (!isConnected) {
       if (mounted) {
        setState(() => _isPrinting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(lang.translate('msg_disconnected') + " (Please connect in Home Screen)"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          )
        );
       }
       return;
    }

    // STEP 2: Print
    try {
      List<int> bytesToPrint = [];

      // Init Printer
      bytesToPrint += [27, 64]; 
      bytesToPrint += [27, 97, 1]; // Center Align

      // Convert processed images to ESC/POS
      for (var image in _processedImages) {
        // Use the utility class defined below
        bytesToPrint += PrintUtils.imageToEscPos(image);
        bytesToPrint += [10]; // Small gap between pages/images
      }

      // Feed and Cut
      bytesToPrint += [10, 10, 10];
      bytesToPrint += [29, 86, 66, 0];

      await widget.printerService.sendBytes(bytesToPrint);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('msg_connected_success')), backgroundColor: Colors.green)
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${lang.translate('msg_print_error')} $e"), backgroundColor: Colors.red)
        );
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Approx mm calculation for display
    double mmWidth = _printerWidth / 8.0; 
    
    // Status text logic
    String statusText = widget.connectedMac != null 
        ? "Printer Ready" 
        : "Printer Not Detected (Will attempt auto-connect)";

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Print Preview"),
            Text("Target Width: $_printerWidth dots (~${mmWidth.toInt()}mm)", 
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
      backgroundColor: Colors.grey[200], 
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : _errorMessage.isNotEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text("Error: $_errorMessage", style: const TextStyle(color: Colors.red)),
            ))
          : Column(
              children: [
                // STATUS BAR
                Container(
                  width: double.infinity,
                  color: widget.connectedMac != null ? Colors.green[50] : Colors.orange[50],
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    statusText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12, 
                      color: widget.connectedMac != null ? Colors.green[800] : Colors.orange[900]
                    ),
                  ),
                ),
                
                // PREVIEW AREA
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Column(
                        children: _previewBytes.map((bytes) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            // Limit the onscreen width to simulate the narrow paper
                            constraints: const BoxConstraints(maxWidth: 400),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(blurRadius: 5, color: Colors.black.withOpacity(0.2))
                              ]
                            ),
                            child: Image.memory(
                              bytes, 
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.none, 
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                
                // PRINT BUTTON
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        icon: _isPrinting 
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.print),
                        label: Text(_isPrinting ? "Sending Data..." : "PRINT NOW"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                        ),
                        onPressed: _isPrinting ? null : _doPrint,
                      ),
                    ),
                  ),
                )
              ],
            ),
    );
  }
}

// ==========================================
// UTILITY FOR IMAGE TO ESC/POS CONVERSION
// ==========================================
// Included here to avoid "Undefined Class" errors if HomePage import is missing
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