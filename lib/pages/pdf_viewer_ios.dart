import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;

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
  final bool autoPrint;

  const PdfViewerPage({
    Key? key,
    required this.filePath,
    required this.printerService,
    this.connectedMac,
    this.autoPrint = false,
  }) : super(key: key);

  @override
  _PdfViewerPageState createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  bool _isLoading = true;
  bool _isPrinting = false;

  List<Uint8List> _previewBytes = [];
  List<List<int>> _readyToPrintBytes = []; 

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
      // 1. GET SETTINGS FROM YOUR WIDTH CONFIGURATION PAGE
      // Default to 384 (58mm) if not set.
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
      // --- 1. Handle URL or Local Path ---
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
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

      // --- 2. Decode Content ---
      final String ext = fileToProcess.path.split('.').last.toLowerCase();
      List<img.Image> rawImages = [];
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
        final bytes = await fileToProcess.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) rawImages.add(decoded);
      }

      if (rawImages.isEmpty) throw Exception("Could not decode content.");

      // --- 3. Process Images (Trimming & Dithering) ---
      _previewBytes.clear();
      _readyToPrintBytes.clear();

      for (var image in rawImages) {
        // A. Smart Auto-Crop (Crucial for Receipts)
        // This removes the massive white space if printing a small receipt on an A4 PDF
        img.Image? trimmed = PrintUtils.trimWhiteSpace(image);
        
        // If trimmed is null, the page was blank/noise, skip it
        if (trimmed == null) continue;

        // B. Resize to Printer Width (e.g., 384 or 576)
        // We maintain aspect ratio for height
        img.Image resized = img.copyResize(trimmed, width: _printerWidth);
        
        // C. Apply Logic (High Contrast -> Dither -> ESC/POS Bytes)
        List<int> escPosData = PrintUtils.convertBitmapToEscPos(resized);
        
        _readyToPrintBytes.add(escPosData);

        // D. Preview
        _previewBytes.add(img.encodePng(img.grayscale(resized)));
      }

      if (_readyToPrintBytes.isEmpty) {
         throw Exception("Document appeared blank after processing.");
      }

      // --- 4. Finish Loading ---
      if (mounted) {
        setState(() => _isLoading = false);

        if (widget.autoPrint) {
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
         // Keep spinner active if we are about to print
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

      for (var processedBytes in _readyToPrintBytes) {
        bytesToPrint += processedBytes;
        bytesToPrint += [10]; // Small gap between pages
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
            const Text("Receipt Preview"),
            Text("Width: $_printerWidth dots",
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
              Text("Formatting Receipt..."),
            ],
          ))
        : _errorMessage.isNotEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text("Error: $_errorMessage", style: const TextStyle(color: Colors.red)),
            ))
          : Column(
              children: [
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
                            child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
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
                        label: Text(_isPrinting ? "Printing..." : "PRINT RECEIPT"),
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

// =========================================================
//  LOGIC PORTED FROM KOTLIN (Auto-Crop + High Contrast)
// =========================================================
class PrintUtils {
  
  static int clamp(int value) {
    return value.clamp(0, 255);
  }

  /// 1. AUTO-CROP FUNCTION
  /// Removes empty whitespace from top/bottom. Crucial for receipts.
  static img.Image? trimWhiteSpace(img.Image source) {
    int width = source.width;
    int height = source.height;

    int minX = width;
    int maxX = 0;
    int minY = height;
    int maxY = 0;
    bool foundContent = false;

    // Thresholds
    const int darknessThreshold = 200; // If pixel luminance < 200, it's dark
    const int minDarkPixelsPerRow = 5; // A line needs 5 dots to be considered content

    for (int y = 0; y < height; y++) {
      int darkPixelsInRow = 0;
      
      for (int x = 0; x < width; x++) {
        img.Pixel pixel = source.getPixel(x, y);
        num lum = img.getLuminance(pixel);

        if (lum < darknessThreshold) {
          darkPixelsInRow++;
        }
      }

      if (darkPixelsInRow > minDarkPixelsPerRow) {
        foundContent = true;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;

        // Determine X bounds
        for (int x = 0; x < width; x++) {
          img.Pixel pixel = source.getPixel(x, y);
          if (img.getLuminance(pixel) < darknessThreshold) {
             if (x < minX) minX = x;
             if (x > maxX) maxX = x;
          }
        }
      }
    }

    if (!foundContent) return null; // Blank page

    // Add Padding
    const int padding = 5;
    minX = math.max(0, minX - padding);
    maxX = math.min(width, maxX + padding);
    minY = math.max(0, minY - padding);
    maxY = math.min(height, maxY + padding + 40); // Extra bottom padding for cutter

    int trimWidth = maxX - minX;
    int trimHeight = maxY - minY;

    if (trimWidth <= 0 || trimHeight <= 0) return null;

    return img.copyCrop(source, x: minX, y: minY, width: trimWidth, height: trimHeight);
  }

  /// 2. CONVERT TO ESC/POS
  /// High Contrast -> Threshold -> Dither -> Bit Pack
  static List<int> convertBitmapToEscPos(img.Image srcImage) {
    int width = srcImage.width;
    int height = srcImage.height;
    int widthBytes = (width + 7) ~/ 8;

    List<List<int>> grayPixels = List.generate(
      height, 
      (_) => List.filled(width, 0)
    );

    // Initial Grayscale + High Contrast Filter
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel pixel = srcImage.getPixel(x, y);
        
        int r = pixel.r.toInt();
        int g = pixel.g.toInt();
        int b = pixel.b.toInt();

        // High Contrast: R' = R * 1.2 - 20
        r = clamp(((r * 1.2) - 20).toInt());
        g = clamp(((g * 1.2) - 20).toInt());
        b = clamp(((b * 1.2) - 20).toInt());

        int lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt();

        // Hard clamping to clean up noise
        if (lum > 215) {
          lum = 255; 
        } else if (lum < 130) {
          lum = 0;   
        }

        grayPixels[y][x] = lum;
      }
    }

    // Floyd-Steinberg Dithering
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int oldPixel = grayPixels[y][x];
        int newPixel = (oldPixel < 128) ? 0 : 255;
        
        grayPixels[y][x] = newPixel;
        
        int quantError = oldPixel - newPixel;

        if (x + 1 < width) {
          grayPixels[y][x + 1] = clamp(grayPixels[y][x + 1] + (quantError * 7 ~/ 16));
        }
        if (x - 1 >= 0 && y + 1 < height) {
          grayPixels[y + 1][x - 1] = clamp(grayPixels[y + 1][x - 1] + (quantError * 3 ~/ 16));
        }
        if (y + 1 < height) {
           grayPixels[y + 1][x] = clamp(grayPixels[y + 1][x] + (quantError * 5 ~/ 16));
        }
        if (x + 1 < width && y + 1 < height) {
           grayPixels[y + 1][x + 1] = clamp(grayPixels[y + 1][x + 1] + (quantError * 1 ~/ 16));
        }
      }
    }

    // Bit Packing GS v 0
    List<int> commandBytes = [];
    commandBytes += [0x1D, 0x76, 0x30, 0x00];
    commandBytes += [widthBytes % 256, widthBytes ~/ 256];
    commandBytes += [height % 256, height ~/ 256];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < widthBytes; x++) {
        int byteValue = 0;
        for (int b = 0; b < 8; b++) {
          int currentX = x * 8 + b;
          if (currentX < width) {
            if (grayPixels[y][currentX] == 0) {
              byteValue |= (1 << (7 - b));
            }
          }
        }
        commandBytes.add(byteValue);
      }
    }

    return commandBytes;
  }
}