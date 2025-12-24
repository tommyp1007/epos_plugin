import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Image & PDF Processing
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../services/printer_service.dart';
import '../services/language_service.dart';
import 'home_page.dart'; // To access PrintUtils

class PdfViewerPage extends StatefulWidget {
  final String filePath;
  final PrinterService printerService;
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
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _processFile() async {
    final File file = File(widget.filePath);
    final String ext = widget.filePath.split('.').last.toLowerCase();

    List<img.Image> rawImages = [];

    if (ext == 'pdf') {
      final pdfBytes = await file.readAsBytes();
      // Rasterize PDF at 203 DPI (Standard Thermal)
      // We iterate properly through the async stream
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

    if (rawImages.isEmpty) {
      throw Exception("Could not decode file content.");
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

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    if (widget.connectedMac == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(lang.translate('msg_disconnected')))
      );
      return;
    }

    setState(() => _isPrinting = true);

    try {
      List<int> bytesToPrint = [];

      // Init Printer
      bytesToPrint += [27, 64]; 
      bytesToPrint += [27, 97, 1]; // Center Align

      // Convert processed images to ESC/POS
      for (var image in _processedImages) {
        bytesToPrint += PrintUtils.imageToEscPos(image);
        bytesToPrint += [10]; // Small gap between pages/images
      }

      // Feed and Cut
      bytesToPrint += [10, 10, 10];
      bytesToPrint += [29, 86, 66, 0];

      await widget.printerService.sendBytes(bytesToPrint);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Print Sent Successfully!"), backgroundColor: Colors.green)
        );
        // Optional: Go back after printing
        // Navigator.pop(context); 
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Print Error: $e"), backgroundColor: Colors.red)
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
      backgroundColor: Colors.grey[200], // Darker background to highlight "Paper"
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : _errorMessage.isNotEmpty
          ? Center(child: Text("Error: $_errorMessage"))
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Column(
                        children: _previewBytes.map((bytes) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            // Limit the onscreen width to simulate the narrow paper
                            // We allow it to scale up to 300 logical pixels or the actual width
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
                              filterQuality: FilterQuality.none, // Sharp pixels
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      icon: _isPrinting 
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.print),
                      label: Text(_isPrinting ? "Sending..." : "PRINT NOW"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white
                      ),
                      onPressed: _isPrinting ? null : _doPrint,
                    ),
                  ),
                )
              ],
            ),
    );
  }
}