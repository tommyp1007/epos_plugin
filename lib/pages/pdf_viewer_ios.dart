import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'; // For compute
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

// Services
import '../services/printer_service.dart';
import '../services/language_service.dart';

// --- BACKGROUND ISOLATE DATA CLASSES ---
class ProcessingTask {
  final Uint8List rawBytes;
  final int printerWidth;
  ProcessingTask(this.rawBytes, this.printerWidth);
}

class ProcessedResult {
  final Uint8List displayBytes; // PNG for screen
  final List<int> printBytes;   // ESC/POS for printer
  ProcessedResult(this.displayBytes, this.printBytes);
}

// --- HEAVY PROCESSING FUNCTION (Runs in Background) ---
// Must be top-level function for 'compute'
Future<ProcessedResult> _heavyImageProcessing(ProcessingTask task) async {
  final img.Image? decoded = img.decodeImage(task.rawBytes);
  if (decoded == null) throw Exception("Failed to decode image");

  // 1. FIX: Flatten Transparent Pixels to White
  // (Prevents transparent PDF backgrounds from turning into black bars)
  img.Image flatImage = PrintUtils.flattenToWhite(decoded);

  // 2. Trim WhiteSpace (Top/Bottom) to ensure seamless joining
  img.Image? trimmed = PrintUtils.trimWhiteSpace(flatImage);
  trimmed ??= flatImage; // If page is empty/cannot trim, use original flattened

  // 3. Prepare Display Image (High Quality PNG for UI)
  final Uint8List displayBytes = Uint8List.fromList(img.encodePng(trimmed));

  // 4. Resize for Printer (Width Adjustment)
  img.Image printerVer = img.copyResize(
    trimmed, 
    width: task.printerWidth, 
    interpolation: img.Interpolation.cubic
  );

  // 5. Convert to ESC/POS
  List<int> escPosData = PrintUtils.convertBitmapToEscPos(printerVer);

  return ProcessedResult(displayBytes, escPosData);
}

// -------------------------------------------------------

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
  // State for UI
  bool _isLoading = true;
  bool _isProcessingPages = false;
  String _errorMessage = '';
    
  // Zoom Controller
  final TransformationController _transformController = TransformationController();

  // Data Containers
  List<Uint8List> _previewImages = []; // For Screen
  List<List<int>> _readyToPrintChunks = []; // For Printer
    
  // Printing State
  bool _isPrinting = false;
  static const int _maxQueueSize = 5;
  int _printerWidth = 384; 

  @override
  void initState() {
    super.initState();
    _loadSettingsAndProcessFile();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadSettingsAndProcessFile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      int? savedWidth = prefs.getInt('printer_width_dots');
      _printerWidth = (savedWidth != null && savedWidth > 0) ? savedWidth : 384;
        
      await _prepareDocument();
    } catch (e) {
      debugPrint("Error loading settings: $e");
      await _prepareDocument();
    }
  }

  Future<void> _prepareDocument() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    String cleanPath = widget.filePath;
    File fileToProcess;

    try {
      if (cleanPath.toLowerCase().startsWith('http')) {
        fileToProcess = await _downloadFile(cleanPath);
      } else {
        if (cleanPath.startsWith('file://')) cleanPath = cleanPath.substring(7);
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) {}
        fileToProcess = File(cleanPath);
         
        if (!await fileToProcess.exists()) {
          throw Exception("${lang.translate('err_file_not_found')} $cleanPath");
        }
      }

      final String ext = fileToProcess.path.split('.').last.toLowerCase();
      Uint8List rawBytes = await fileToProcess.readAsBytes();
      bool isPdf = ext == 'pdf' || fileToProcess.path.endsWith('pdf');

      // Clear previous data
      _previewImages.clear();
      _readyToPrintChunks.clear();
      
      if (mounted) setState(() { _isLoading = false; _isProcessingPages = true; });

      // --- START PROCESSING ---
      
      if (isPdf) {
        // Rasterize PDF pages one by one
        await for (var page in Printing.raster(rawBytes, dpi: 300)) {
          if (!mounted) break;
          
          final pngBytes = await page.toPng();
          
          // Offload heavy work to background isolate
          final ProcessedResult result = await compute(
            _heavyImageProcessing, 
            ProcessingTask(pngBytes, _printerWidth)
          );

          setState(() {
            _previewImages.add(result.displayBytes);
            _readyToPrintChunks.add(result.printBytes);
          });
        }
      } else {
        // Single Image
        final ProcessedResult result = await compute(
            _heavyImageProcessing, 
            ProcessingTask(rawBytes, _printerWidth)
        );
        
        setState(() {
           _previewImages.add(result.displayBytes);
           _readyToPrintChunks.add(result.printBytes);
        });
      }

      if (mounted) {
        setState(() => _isProcessingPages = false);
        if (widget.autoPrint) _doPrint();
      }

    } catch (e) {
       if(mounted) setState(() { _errorMessage = "${lang.translate('msg_error_prefix')} $e"; _isLoading = false; _isProcessingPages = false; });
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
    final savedMac = prefs.getString('selected_printer_mac'); 
     
    if (savedMac != null && savedMac.isNotEmpty) {
       try { 
         return await widget.printerService.connect(savedMac); 
       } catch (e) { 
         return false; 
       }
    }
    return false;
  }

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    if (widget.printerService.pendingJobs >= _maxQueueSize) {
      _showSnackBar(lang.translate('msg_queue_full_wait'), isError: true);
      return;
    }

    if (_isProcessingPages || _readyToPrintChunks.isEmpty) {
       // Use "Working..." as a placeholder for preparing
       _showSnackBar("${lang.translate('working')}...", isError: false);
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
      
      // Combine all chunks seamlessly (No cuts or feeds in between)
      for (var processedBytes in _readyToPrintChunks) {
        bytesToPrint += processedBytes;
      }
      
      // Footer Commands (Feed & Cut ONLY at the very end)
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
    final Size screenSize = MediaQuery.of(context).size;

    int pendingCount = widget.printerService.pendingJobs;
    bool isQueueFull = pendingCount >= _maxQueueSize;

    return Scaffold(
      appBar: AppBar(
        // FIXED: Key updated to 'title_preview' based on provided translations
        title: Text(lang.translate('title_preview')),
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
          // 1. CONTENT LAYER (Zoomable)
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_errorMessage.isNotEmpty)
            Center(child: Text(_errorMessage, style: const TextStyle(color: Colors.red)))
          else
            InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5,
              maxScale: 4.0,
              boundaryMargin: const EdgeInsets.all(20),
              panEnabled: true,
              child: SizedBox(
                width: screenSize.width,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 20),
                      if (_previewImages.isEmpty && !_isProcessingPages)
                          // UPDATED: Use 'err_decode' (Could not decode content) as closest match
                          Center(child: Text(lang.translate('err_decode'))),
                      
                      // Render all pages
                      ..._previewImages.map((bytes) => Container(
                        // VISUAL PREVIEW: Keep slight margin for UI, but actual print is seamless
                        margin: const EdgeInsets.only(bottom: 5, left: 16, right: 16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, spreadRadius: 2)]
                        ),
                        child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
                      )).toList(),

                      if (_isProcessingPages)
                        const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
                      
                      const SizedBox(height: 80), // Space for button
                    ],
                  ),
                ),
              ),
            ),

          // 2. STATUS BAR (Top Overlay)
          if (pendingCount > 0)
            Positioned(
              top: 0, left: 0, right: 0,
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
          if (!_isLoading)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))]
                ),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      icon: (_isPrinting || _isProcessingPages)
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.print),
                      label: Text(
                          isQueueFull 
                            ? lang.translate('btn_wait') 
                            : (_isProcessingPages 
                                // UPDATED: "ANALYZING..." replaced with 'working' key
                                ? lang.translate('working') 
                                : (_isPrinting ? lang.translate('btn_queueing') : lang.translate('btn_print_receipt')))
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (isQueueFull || _isProcessingPages) ? Colors.grey : Colors.blueAccent
                      ),
                      onPressed: (_isPrinting || isQueueFull || _isProcessingPages) ? null : _doPrint,
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

// --- UTILS FOR IMAGE PROCESSING ---
class PrintUtils {
  static int clamp(int value) => value.clamp(0, 255);

  /// NEW: Fixes black backgrounds caused by transparency in PDFs.
  /// Creates a white canvas and draws the source image onto it.
  static img.Image flattenToWhite(img.Image source) {
    // If no alpha, return original
    if (!source.hasAlpha) return source;

    // Create a white background image of the same size
    img.Image whiteBg = img.Image(
      width: source.width, 
      height: source.height, 
      numChannels: 3, // RGB only, no Alpha
    );
    
    // Fill with White (255, 255, 255)
    img.fill(whiteBg, color: img.ColorRgb8(255, 255, 255));

    // Composite the source image (with alpha) onto the white background
    return img.compositeImage(whiteBg, source);
  }

  /// Ported from Swift: Tighter trimming logic to ensure seamless stitching
  static img.Image? trimWhiteSpace(img.Image source) {
    int width = source.width;
    int height = source.height;
    int minX = width, maxX = 0, minY = height, maxY = 0;
    bool foundContent = false;
    
    // Swift uses 240 as threshold
    const int darknessThreshold = 240; 
    const int minDarkPixelsPerRow = 2; 

    for (int y = 0; y < height; y++) {
      int darkPixelsInRow = 0;
      for (int x = 0; x < width; x++) {
        // Luminance check is safe now because we flattened the image to white first
        if (img.getLuminance(source.getPixel(x, y)) < darknessThreshold) {
          darkPixelsInRow++;
        }
      }
      
      if (darkPixelsInRow >= minDarkPixelsPerRow) {
        foundContent = true;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        
        // Scan X boundaries only on rows with content
        for (int x = 0; x < width; x++) {
          if (img.getLuminance(source.getPixel(x, y)) < darknessThreshold) {
              if (x < minX) minX = x;
              if (x > maxX) maxX = x;
          }
        }
      }
    }

    if (!foundContent) return null;

    // Swift Port: "Minimized padding to ensure seamless stitching"
    const int padding = 1; 
    minX = math.max(0, minX - padding);
    maxX = math.min(width, maxX + padding);
    minY = math.max(0, minY - padding);
    maxY = math.min(height, maxY + padding);

    return img.copyCrop(source, x: minX, y: minY, width: maxX - minX, height: maxY - minY);
  }

  static List<int> convertBitmapToEscPos(img.Image srcImage) {
    int width = srcImage.width;
    int height = srcImage.height;
    int widthBytes = (width + 7) ~/ 8;
    
    List<int> grayPlane = List.filled(width * height, 0);

    // 1. Grayscale & Contrast (Matches Swift: r * 1.2 - 20)
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = srcImage.getPixel(x, y);
        
        int r = clamp((p.r * 1.2 - 20).toInt());
        int g = clamp((p.g * 1.2 - 20).toInt());
        int b = clamp((p.b * 1.2 - 20).toInt());
        
        grayPlane[y * width + x] = (0.299 * r + 0.587 * g + 0.114 * b).toInt();
      }
    }

    // 2. Dither (Floyd-Steinberg)
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

    // 3. Pack Bits (GS v 0)
    List<int> cmd = [0x1D, 0x76, 0x30, 0x00, widthBytes % 256, widthBytes ~/ 256, height % 256, height ~/ 256];
    
    for (int y = 0; y < height; y++) {
      for (int xByte = 0; xByte < widthBytes; xByte++) {
        int byteValue = 0;
        for (int bit = 0; bit < 8; bit++) {
          int x = xByte * 8 + bit;
          if (x < width) {
            // Check based on dithered value (0 is black, 255 is white)
            // ESC/POS expects 1 for black (dot printed), 0 for white
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