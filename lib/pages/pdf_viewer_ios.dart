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
  
  // SAFETY LIMIT: Prevent more than 5 jobs in memory
  static const int _maxQueueSize = 5;

  List<Uint8List> _previewBytes = [];
  List<List<int>> _readyToPrintBytes = []; 

  // Defaults to 576 (80mm) per 'MyInvois e-Pos Printer' specs, but adjusts based on prefs
  int _printerWidth = 576; 
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadSettingsAndProcessFile();
  }

  Future<void> _loadSettingsAndProcessFile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Detect Width Logic (Matching Kotlin Preference Retrieval)
      // If user manually set a width, use it. Otherwise default to 576 (80mm) for "EPOS_SETTING"
      int savedWidth = prefs.getInt('flutter.printer_width_dots') ?? -1;
      
      if (savedWidth > 0) {
        _printerWidth = savedWidth;
      } else {
        // Default logic: Assume "MyInvois e-Pos Printer" (mediaEpos) is 80mm
        // You can add logic here to check 'flutter.selected_printer_mac' if you want 
        // to detect specific 58mm devices, but 576 is the safe high-quality default.
        _printerWidth = 576; 
      }

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
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
        if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) {}

        fileToProcess = File(cleanPath);
        if (!await fileToProcess.exists()) {
          throw Exception("File not found at path: $cleanPath");
        }
      }

      final String ext = fileToProcess.path.split('.').last.toLowerCase();
      List<img.Image> rawImages = [];
      bool isPdf = ext == 'pdf' || fileToProcess.path.endsWith('pdf');

      if (isPdf) {
        final pdfBytes = await fileToProcess.readAsBytes();
        
        // --- HIGH QUALITY CAPTURE (EPOS_SETTING Logic) ---
        // Kotlin uses: max(targetWidthPx * 2, 600)
        // In Flutter/Printing, 300 DPI roughly equates to >1200px width for standard paper,
        // which satisfies the "Double Width" requirement for crisp downscaling.
        await for (var page in Printing.raster(pdfBytes, dpi: 300)) {
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

      _previewBytes.clear();
      _readyToPrintBytes.clear();

      for (var image in rawImages) {
        // 1. SMART AUTO-CROP (Using Updated 240 Threshold)
        img.Image? trimmed = PrintUtils.trimWhiteSpace(image);
        if (trimmed == null) continue;

        // 2. SCALE TO PRINTER WIDTH
        // We use Cubic Interpolation to match Kotlin's 'filter=true' in createScaledBitmap
        // This prevents text from becoming blocky when resizing from 300DPI down to 576px.
        img.Image resized = img.copyResize(
          trimmed, 
          width: _printerWidth, 
          interpolation: img.Interpolation.cubic
        );

        // 3. CONVERT TO ESC/POS (With High Contrast + Dithering)
        List<int> escPosData = PrintUtils.convertBitmapToEscPos(resized);
        
        _readyToPrintBytes.add(escPosData);
        
        // Generate a preview image (Grayscale)
        _previewBytes.add(img.encodePng(img.grayscale(resized)));
      }

      if (mounted) {
        setState(() => _isLoading = false);
        if (widget.autoPrint) _doPrint();
      }
    } catch (e) {
       if(mounted) setState(() { _errorMessage = "Error: $e"; _isLoading = false; });
    }
  }

  Future<File> _downloadFile(String url) async {
    final http.Response response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File file = File(tempPath);
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception("Download Failed: ${response.statusCode}");
    }
  }

  Future<bool> _ensureConnected() async {
    if (await widget.printerService.isConnected()) return true;
    final prefs = await SharedPreferences.getInstance();
    final savedMac = prefs.getString('flutter.selected_printer_mac'); 
    if (savedMac != null && savedMac.isNotEmpty) {
       try { return await widget.printerService.connect(savedMac); } catch (e) { return false; }
    }
    return false;
  }

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    if (widget.printerService.pendingJobs >= _maxQueueSize) {
      _showSnackBar("Print queue is full. Please wait.", isError: true);
      return;
    }

    setState(() => _isPrinting = true);

    try {
      bool isConnected = await _ensureConnected();
      if (!isConnected) {
        if (mounted) {
          _showSnackBar(lang.translate('msg_disconnected'), isError: true);
          setState(() => _isPrinting = false);
        }
        return;
      }

      // Construct ESC/POS Commands
      List<int> bytesToPrint = [];
      bytesToPrint += [0x1B, 0x40]; // Init
      bytesToPrint += [27, 97, 1]; // Center align
      
      for (var processedBytes in _readyToPrintBytes) {
        bytesToPrint += processedBytes;
        bytesToPrint += [10]; // Small gap between pages
      }
      
      bytesToPrint += [0x1B, 0x64, 0x04]; // Feed 4 lines
      bytesToPrint += [0x1D, 0x56, 0x42, 0x00]; // Cut Paper

      await widget.printerService.sendBytes(bytesToPrint);

      if (mounted) {
        _showSnackBar("Added to queue (${widget.printerService.pendingJobs} pending)");
      }
    } catch (e) {
      if (mounted) _showSnackBar("Error: $e", isError: true);
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message), 
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 1),
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    int pendingCount = widget.printerService.pendingJobs;
    bool isQueueFull = pendingCount >= _maxQueueSize;

    return Scaffold(
      appBar: AppBar(
        title: const Text("MyInvois Receipt Preview"),
        actions: [
          if (pendingCount > 0)
            Center(child: Padding(
              padding: const EdgeInsets.only(right: 15),
              child: Text("Queue: $pendingCount", style: const TextStyle(fontWeight: FontWeight.bold)),
            ))
        ],
      ),
      backgroundColor: Colors.grey[200],
      body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              if (pendingCount > 0)
                Container(
                  width: double.infinity,
                  color: Colors.orange,
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    isQueueFull ? "QUEUE FULL - PLEASE WAIT" : "PRINTING IN PROGRESS ($pendingCount LEFT)", 
                    textAlign: TextAlign.center, 
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
                  ),
                ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Column(
                      children: _previewBytes.map((bytes) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [BoxShadow(blurRadius: 5, color: Colors.black.withOpacity(0.2))]
                        ),
                        // Display the processed, resized image (High Quality Preview)
                        child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
                      )).toList(),
                    ),
                  ),
                ),
              ),

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
                      label: Text(isQueueFull ? "PLEASE WAIT..." : (_isPrinting ? "QUEUEING..." : "PRINT RECEIPT")),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isQueueFull ? Colors.grey : Colors.blueAccent
                      ),
                      onPressed: (_isPrinting || isQueueFull) ? null : _doPrint,
                    ),
                  ),
                ),
              )
            ],
          ),
    );
  }
}

class PrintUtils {
  static int clamp(int value) => value.clamp(0, 255);

  /// Matches Kotlin 'trimWhiteSpace' logic with High Sensitivity (240)
  /// This ensures faint borders or light gray frames are detected and kept.
  static img.Image? trimWhiteSpace(img.Image source) {
    int width = source.width;
    int height = source.height;
    int minX = width, maxX = 0, minY = height, maxY = 0;
    bool foundContent = false;
    
    // Matched Kotlin: Threshold 240 detects even very light gray lines
    const int darknessThreshold = 240; 
    const int minDarkPixelsPerRow = 2; // Matched Kotlin

    for (int y = 0; y < height; y++) {
      int darkPixelsInRow = 0;
      for (int x = 0; x < width; x++) {
        // Get Luminance directly
        if (img.getLuminance(source.getPixel(x, y)) < darknessThreshold) {
          darkPixelsInRow++;
        }
      }
      
      if (darkPixelsInRow >= minDarkPixelsPerRow) {
        foundContent = true;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        
        for (int x = 0; x < width; x++) {
          if (img.getLuminance(source.getPixel(x, y)) < darknessThreshold) {
             if (x < minX) minX = x;
             if (x > maxX) maxX = x;
          }
        }
      }
    }

    if (!foundContent) return null;

    // Apply Padding (Matching Kotlin Logic)
    const int padding = 5;
    minX = math.max(0, minX - padding);
    maxX = math.min(width, maxX + padding);
    minY = math.max(0, minY - padding);
    // Extra bottom padding for cutter (matched Kotlin +40)
    maxY = math.min(height, maxY + padding + 40); 

    return img.copyCrop(source, x: minX, y: minY, width: maxX - minX, height: maxY - minY);
  }

  /// Optimized Bitmap to ESC/POS conversion (Raster Bit Image)
  /// Replicates the ColorMatrix high-contrast filter + Floyd-Steinberg dithering
  static List<int> convertBitmapToEscPos(img.Image srcImage) {
    int width = srcImage.width;
    int height = srcImage.height;
    int widthBytes = (width + 7) ~/ 8;
    
    // Using 1D array logic for performance (similar to Kotlin)
    List<int> grayPlane = List.filled(width * height, 0);

    // 1. Convert to Gray & Apply High Contrast (Matching Kotlin ColorMatrix)
    // The Kotlin Matrix was: Scale 1.2, Offset -20
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = srcImage.getPixel(x, y);
        
        // High Contrast Formula (Scale 1.2, Offset -20)
        int r = clamp((p.r * 1.2 - 20).toInt());
        int g = clamp((p.g * 1.2 - 20).toInt());
        int b = clamp((p.b * 1.2 - 20).toInt());
        
        // Standard Grayscale Weights
        grayPlane[y * width + x] = (0.299 * r + 0.587 * g + 0.114 * b).toInt();
      }
    }

    // 2. Floyd-Steinberg Dithering
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int i = y * width + x;
        int oldPixel = grayPlane[i];
        int newPixel = oldPixel < 128 ? 0 : 255;
        
        grayPlane[i] = newPixel;
        int error = oldPixel - newPixel;

        // Distribute error to neighbors
        if (x + 1 < width) {
          int idx = i + 1;
          grayPlane[idx] = clamp(grayPlane[idx] + (error * 7 ~/ 16));
        }
        
        if (y + 1 < height) {
          if (x - 1 >= 0) {
            int idx = i + width - 1;
            grayPlane[idx] = clamp(grayPlane[idx] + (error * 3 ~/ 16));
          }
          int idx = i + width;
          grayPlane[idx] = clamp(grayPlane[idx] + (error * 5 ~/ 16));
          
          if (x + 1 < width) {
             int idx = i + width + 1;
             grayPlane[idx] = clamp(grayPlane[idx] + (error * 1 ~/ 16));
          }
        }
      }
    }

    // 3. Bit Packing (GS v 0)
    // We send the header inside here to keep the chunk self-contained if needed
    List<int> cmd = [0x1D, 0x76, 0x30, 0x00, widthBytes % 256, widthBytes ~/ 256, height % 256, height ~/ 256];
    
    for (int y = 0; y < height; y++) {
      for (int xByte = 0; xByte < widthBytes; xByte++) {
        int byteValue = 0;
        for (int bit = 0; bit < 8; bit++) {
          int x = xByte * 8 + bit;
          if (x < width) {
            // 0 is black (print), 255 is white (no print)
            if (grayPlane[y * width + x] == 0) {
              byteValue |= (1 << (7 - bit));
            }
          }
        }
        cmd.add(byteValue);
      }
    }
    return cmd;
  }
}