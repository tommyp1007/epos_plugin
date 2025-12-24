import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// Image & PDF Processing
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';

import '../services/printer_service.dart';
import '../services/language_service.dart';

class PdfViewerPage extends StatefulWidget {
  final String filePath;
  final PrinterService printerService;
  final String? connectedMac;
  final bool autoPrint; // Controls if we print immediately

  const PdfViewerPage({
    Key? key,
    required this.filePath,
    required this.printerService,
    this.connectedMac,
    this.autoPrint = false, // Default false
  }) : super(key: key);

  @override
  _PdfViewerPageState createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  bool _isLoading = true;
  bool _isPrinting = false;

  List<img.Image> _processedImages = [];
  List<Uint8List> _previewBytes = [];

  int _printerWidth = 384;
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
    String cleanPath = widget.filePath;
    File fileToProcess;

    try {
      // 1. Handle URL or Local Path
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
        // Basic cleaning just in case main.dart missed something
        if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        try {
          cleanPath = Uri.decodeFull(cleanPath);
        } catch (e) {
          debugPrint("Error decoding path: $e");
        }

        fileToProcess = File(cleanPath);
        if (!await fileToProcess.exists()) {
          throw Exception("File not found at path: $cleanPath");
        }
      }

      // 2. Process Content (PDF or Image)
      final String ext = fileToProcess.path.split('.').last.toLowerCase();
      List<img.Image> rawImages = [];
      // If it ends in PDF or if we downloaded it as temp.pdf
      bool isPdf = ext == 'pdf' || fileToProcess.path.endsWith('pdf');

      if (isPdf) {
        final pdfBytes = await fileToProcess.readAsBytes();
        // Rasterize PDF at 203 DPI (Standard Thermal)
        await for (var page in Printing.raster(pdfBytes, dpi: 203)) {
          final pngBytes = await page.toPng();
          final decoded = img.decodeImage(pngBytes);
          if (decoded != null) rawImages.add(decoded);
        }
      } else {
        // Assume Image
        final bytes = await fileToProcess.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) rawImages.add(decoded);
      }

      if (rawImages.isEmpty) throw Exception("Could not decode content.");

      // 3. Resize & Convert for Thermal Printer
      _processedImages.clear();
      _previewBytes.clear();

      for (var image in rawImages) {
        // Resize to width
        img.Image resized = img.copyResize(image, width: _printerWidth);
        // Convert to grayscale
        resized = img.grayscale(resized);
        
        _processedImages.add(resized);
        _previewBytes.add(img.encodePng(resized));
      }

      // 4. Finish Loading & Check Auto Print
      if (mounted) {
        setState(() => _isLoading = false);

        // --- AUTO PRINT TRIGGER ---
        if (widget.autoPrint) {
          // Check connection first
          bool ready = await _ensureConnected();
          if (ready) {
            _doPrint();
          } else {
             ScaffoldMessenger.of(context).showSnackBar(
               const SnackBar(content: Text("Auto-print paused: No printer connected."), backgroundColor: Colors.orange)
             );
          }
        }
      }

    } catch (e) {
       if(mounted) {
         setState(() {
           _errorMessage = "Error processing file: $e";
           _isLoading = false;
         });
       }
    }
  }

  Future<File> _downloadFile(String url) async {
    final http.Response response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final Directory tempDir = await getTemporaryDirectory();
      // Generate unique name to avoid conflicts
      final String uniqueName = "temp_${DateTime.now().millisecondsSinceEpoch}.pdf";
      final String tempPath = '${tempDir.path}/$uniqueName';
      final File file = File(tempPath);
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception("Failed to download file. Status: ${response.statusCode}");
    }
  }

  Future<bool> _ensureConnected() async {
    // If passed from Home as connected, assume good
    if (widget.connectedMac != null) return true;
    
    final prefs = await SharedPreferences.getInstance();
    final savedMac = prefs.getString('selected_printer_mac');

    if (savedMac != null && savedMac.isNotEmpty) {
       setState(() => _isPrinting = true);
       try {
         bool success = await widget.printerService.connect(savedMac);
         return success;
       } catch (e) {
         return false;
       } finally {
         // Keep spinner active if we are about to print, otherwise _doPrint handles it
       }
    }
    return false;
  }

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    setState(() => _isPrinting = true);

    bool isConnected = await _ensureConnected();

    if (!isConnected) {
       if (mounted) {
        setState(() => _isPrinting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(lang.translate('msg_disconnected')),
            backgroundColor: Colors.red,
          )
        );
       }
       return;
    }

    try {
      List<int> bytesToPrint = [];
      bytesToPrint += [27, 64]; // Init
      bytesToPrint += [27, 97, 1]; // Center Align

      for (var image in _processedImages) {
        bytesToPrint += PrintUtils.imageToEscPos(image);
        bytesToPrint += [10]; // Small gap
      }

      bytesToPrint += [10, 10, 10]; // Feed
      bytesToPrint += [29, 86, 66, 0]; // Cut

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
    String statusText = widget.connectedMac != null
        ? "Printer Ready"
        : "Checking connection..."; 

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Print Preview"),
            Text("Target Width: $_printerWidth dots",
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
      backgroundColor: Colors.grey[200],
      body: _isLoading
        ? const Center(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 15),
              Text("Preparing content..."),
            ],
          ))
        : _errorMessage.isNotEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text("Error: $_errorMessage", style: const TextStyle(color: Colors.red)),
            ))
          : Column(
              children: [
                // Status Bar
                Container(
                  width: double.infinity,
                  color: Colors.blue[50],
                  padding: const EdgeInsets.all(8),
                  child: Text(statusText, textAlign: TextAlign.center, style: TextStyle(color: Colors.blue[900])),
                ),

                // Preview
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Column(
                        children: _previewBytes.map((bytes) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            constraints: const BoxConstraints(maxWidth: 400),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [BoxShadow(blurRadius: 5, color: Colors.black.withOpacity(0.2))]
                            ),
                            child: Image.memory(bytes, fit: BoxFit.contain, filterQuality: FilterQuality.none),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),

                // Print Button
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
                        label: Text(_isPrinting ? "Printing..." : "PRINT NOW"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
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

// Helper Class (Kept in same file to ensure no import errors)
class PrintUtils {
  static List<int> imageToEscPos(img.Image image) {
    List<int> bytes = [];
    int widthBytes = (image.width + 7) ~/ 8;
    int height = image.height;
    bytes += [0x1D, 0x76, 0x30, 0x00];
    bytes += [widthBytes % 256, widthBytes ~/ 256];
    bytes += [height % 256, height ~/ 256];
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < widthBytes; x++) {
        int byte = 0;
        for (int b = 0; b < 8; b++) {
          int px = x * 8 + b;
          if (px < image.width) {
            var pixel = image.getPixel(px, y);
            if (pixel.r < 128) byte |= (1 << (7 - b));
          }
        }
        bytes.add(byte);
      }
    }
    return bytes;
  }
}