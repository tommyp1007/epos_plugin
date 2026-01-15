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
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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
  // State for UI Preview
  Uint8List? _docBytes;
  bool _isLoadingDoc = true;
  String _errorMessage = '';

  // State for Thermal Printing
  bool _isProcessingPrintData = true; // Processing ESC/POS in background
  bool _isPrinting = false; // Sending data to printer
  List<List<int>> _readyToPrintBytes = []; 
  
  // SAFETY LIMIT: Prevent more than 5 jobs in memory
  static const int _maxQueueSize = 5;

  // Defaults to 576 (80mm) per 'MyInvois e-Pos Printer' specs
  int _printerWidth = 576; 

  @override
  void initState() {
    super.initState();
    _loadSettingsAndProcessFile();
  }

  Future<void> _loadSettingsAndProcessFile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // FIX: Use 'printer_width_dots', NOT 'flutter.printer_width_dots'
      // SharedPreferences abstract the prefix on the Dart side.
      int savedWidth = prefs.getInt('printer_width_dots') ?? -1;
      
      if (savedWidth > 0) {
        _printerWidth = savedWidth;
      } else {
        _printerWidth = 576; 
      }

      await _prepareDocument();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoadingDoc = false;
        });
      }
    }
  }

  Future<void> _prepareDocument() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    String cleanPath = widget.filePath;
    File fileToProcess;

    try {
      // 1. Download or Resolve File
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
        if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) {}
        fileToProcess = File(cleanPath);
        
        if (!await fileToProcess.exists()) {
          throw Exception("${lang.translate('err_file_not_found')} $cleanPath");
        }
      }

      final String ext = fileToProcess.path.split('.').last.toLowerCase();
      Uint8List rawBytes = await fileToProcess.readAsBytes();
      
      // 2. Prepare Bytes for PDF Previewer
      if (ext == 'pdf' || fileToProcess.path.endsWith('pdf')) {
         _docBytes = rawBytes;
      } else {
         // If image, wrap in PDF so the Viewer can handle zoom/scroll
         final image = pw.MemoryImage(rawBytes);
         final pdf = pw.Document();
         pdf.addPage(pw.Page(
           build: (pw.Context context) {
             return pw.Center(child: pw.Image(image));
           }
         ));
         _docBytes = await pdf.save();
      }

      // 3. Show Preview Immediately (Fixes Lag)
      if (mounted) {
        setState(() => _isLoadingDoc = false);
      }

      // 4. Start Heavy Processing for Thermal Printer (Background)
      _generateThermalPrintData(rawBytes, ext == 'pdf');

    } catch (e) {
       if(mounted) setState(() { _errorMessage = "${lang.translate('msg_error_prefix')} $e"; _isLoadingDoc = false; });
    }
  }

  // --- Background Processing for Printer Commands ---
  Future<void> _generateThermalPrintData(Uint8List sourceBytes, bool isPdf) async {
    try {
      List<img.Image> rawImages = [];

      if (isPdf) {
         // Rasterize at high DPI for Thermal Printer Clarity
         await for (var page in Printing.raster(sourceBytes, dpi: 300)) {
           final pngBytes = await page.toPng();
           final decoded = img.decodeImage(pngBytes);
           if (decoded != null) rawImages.add(decoded);
         }
      } else {
         final decoded = img.decodeImage(sourceBytes);
         if (decoded != null) rawImages.add(decoded);
      }

      if (rawImages.isEmpty) throw Exception("Empty Document");

      _readyToPrintBytes.clear();

      // Convert each page to ESC/POS
      for (var image in rawImages) {
        // A. Smart Crop
        img.Image? trimmed = PrintUtils.trimWhiteSpace(image);
        if (trimmed == null) continue;

        // B. Resize to Printer Width (Cubic for quality)
        // THIS IS WHERE YOUR SETTING IS APPLIED
        img.Image resized = img.copyResize(
          trimmed, 
          width: _printerWidth, 
          interpolation: img.Interpolation.cubic
        );

        // C. Dither & Convert
        List<int> escPosData = PrintUtils.convertBitmapToEscPos(resized);
        _readyToPrintBytes.add(escPosData);
      }

      // 5. Enable Print Button
      if (mounted) {
        setState(() {
          _isProcessingPrintData = false;
        });
        if (widget.autoPrint) _doPrint();
      }

    } catch (e) {
      debugPrint("Error generating print data: $e");
      if(mounted) setState(() => _isProcessingPrintData = false);
    }
  }

  Future<File> _downloadFile(String url) async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    final http.Response response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File file = File(tempPath);
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } else {
      throw Exception("${lang.translate('err_download')} ${response.statusCode}");
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
      _showSnackBar(lang.translate('msg_queue_full_wait'), isError: true);
      return;
    }

    if (_readyToPrintBytes.isEmpty) {
       _showSnackBar("Preparing print data... please wait.", isError: false);
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
        _showSnackBar("${lang.translate('msg_added_queue')} (${widget.printerService.pendingJobs} pending)");
      }
    } catch (e) {
      if (mounted) _showSnackBar("${lang.translate('msg_error_prefix')} $e", isError: true);
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
    final lang = Provider.of<LanguageService>(context);

    int pendingCount = widget.printerService.pendingJobs;
    bool isQueueFull = pendingCount >= _maxQueueSize;

    return Scaffold(
      appBar: AppBar(
        title: Text(lang.translate('preview_title')),
        actions: [
          if (pendingCount > 0)
            Center(child: Padding(
              padding: const EdgeInsets.only(right: 15),
              child: Text(
                "${lang.translate('lbl_queue')}: $pendingCount", 
                style: const TextStyle(fontWeight: FontWeight.bold)
              ),
            ))
        ],
      ),
      backgroundColor: Colors.grey[200],
      body: Stack(
        children: [
          // 1. THE PDF VIEWER (Background Layer)
          if (_isLoadingDoc)
            const Center(child: CircularProgressIndicator())
          else if (_docBytes != null)
             PdfPreview(
               build: (format) => _docBytes!,
               useActions: false, 
               canChangeOrientation: false,
               canChangePageFormat: false,
               canDebug: false,
               scrollViewDecoration: BoxDecoration(color: Colors.grey[200]),
               maxPageWidth: 700, 
             )
          else
            Center(child: Text(_errorMessage, style: const TextStyle(color: Colors.red))),

          // 2. STATUS BAR (Top Overlay)
          if (pendingCount > 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                width: double.infinity,
                color: Colors.orange.withOpacity(0.9),
                padding: const EdgeInsets.all(8),
                child: Text(
                  isQueueFull 
                      ? lang.translate('status_queue_full')
                      : "${lang.translate('status_printing')} ($pendingCount ${lang.translate('status_left')})", 
                  textAlign: TextAlign.center, 
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
                ),
              ),
            ),

          // 3. PRINT BUTTON (Bottom Overlay)
          if (!_isLoadingDoc)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      icon: (_isPrinting || _isProcessingPrintData)
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.print),
                      label: Text(
                          isQueueFull 
                            ? lang.translate('btn_wait') 
                            : (_isProcessingPrintData 
                                ? "ANALYZING..." 
                                : (_isPrinting ? lang.translate('btn_queueing') : lang.translate('btn_print_receipt')))
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (isQueueFull || _isProcessingPrintData) ? Colors.grey : Colors.blueAccent
                      ),
                      onPressed: (_isPrinting || isQueueFull || _isProcessingPrintData) ? null : _doPrint,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PrintUtils {
  static int clamp(int value) => value.clamp(0, 255);

  static img.Image? trimWhiteSpace(img.Image source) {
    int width = source.width;
    int height = source.height;
    int minX = width, maxX = 0, minY = height, maxY = 0;
    bool foundContent = false;
    
    const int darknessThreshold = 240; 
    const int minDarkPixelsPerRow = 2; 

    for (int y = 0; y < height; y++) {
      int darkPixelsInRow = 0;
      for (int x = 0; x < width; x++) {
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

    const int padding = 5;
    minX = math.max(0, minX - padding);
    maxX = math.min(width, maxX + padding);
    minY = math.max(0, minY - padding);
    maxY = math.min(height, maxY + padding + 40); 

    return img.copyCrop(source, x: minX, y: minY, width: maxX - minX, height: maxY - minY);
  }

  static List<int> convertBitmapToEscPos(img.Image srcImage) {
    int width = srcImage.width;
    int height = srcImage.height;
    int widthBytes = (width + 7) ~/ 8;
    
    List<int> grayPlane = List.filled(width * height, 0);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = srcImage.getPixel(x, y);
        
        int r = clamp((p.r * 1.2 - 20).toInt());
        int g = clamp((p.g * 1.2 - 20).toInt());
        int b = clamp((p.b * 1.2 - 20).toInt());
        
        grayPlane[y * width + x] = (0.299 * r + 0.587 * g + 0.114 * b).toInt();
      }
    }

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int i = y * width + x;
        int oldPixel = grayPlane[i];
        int newPixel = oldPixel < 128 ? 0 : 255;
        
        grayPlane[i] = newPixel;
        int error = oldPixel - newPixel;

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

    List<int> cmd = [0x1D, 0x76, 0x30, 0x00, widthBytes % 256, widthBytes ~/ 256, height % 256, height ~/ 256];
    
    for (int y = 0; y < height; y++) {
      for (int xByte = 0; xByte < widthBytes; xByte++) {
        int byteValue = 0;
        for (int bit = 0; bit < 8; bit++) {
          int x = xByte * 8 + bit;
          if (x < width) {
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