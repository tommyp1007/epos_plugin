import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:image/image.dart' as img; // Required for image processing
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // Required for BLE

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
  // Configuration
  final int WIDTH_58MM = 384;
  final int WIDTH_80MM = 576;
  final List<int> INIT_PRINTER = [0x1B, 0x40];
  final List<int> FEED_PAPER = [0x1B, 0x64, 0x04];
  final List<int> CUT_PAPER = [0x1D, 0x56, 0x42, 0x00];

  bool _isLoading = true;
  bool _isPrinting = false;
  String _errorMessage = '';

  List<Uint8List> _previewBytes = [];
  File? _localFile;

  final TransformationController _transformController = TransformationController();

  // Bluetooth State
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  @override
  void initState() {
    super.initState();
    // Initial standard preview load
    _loadAndGeneratePreview(initialLoad: true);
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  // =========================================================
  // MARK: - FILE PREPARATION
  // =========================================================

  Future<void> _loadAndGeneratePreview({bool initialLoad = false}) async {
    try {
      if (mounted) setState(() => _isLoading = true);
      
      if (initialLoad) {
        await _prepareFile();
      }

      // If it's a reload or initial load, we generate a standard preview (150 DPI)
      // The high-res 400% preview happens when clicking "Print"
      if (_localFile != null && _previewBytes.isEmpty) {
         await _generatePreviewImages(dpi: 150);
      }

      if (mounted) {
        setState(() => _isLoading = false);
        if (widget.autoPrint && initialLoad) {
          // Default to 58mm for auto-print or logic needs to be defined
          Future.delayed(const Duration(milliseconds: 500), () => _startPrintProcess(WIDTH_58MM));
        }
      }
    } catch (e) {
      if (mounted) {
        final lang = Provider.of<LanguageService>(context, listen: false);
        setState(() {
          _errorMessage = "${lang.translate('msg_error_prefix')} $e";
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _prepareFile() async {
    String cleanPath = widget.filePath;
    if (cleanPath.toLowerCase().startsWith('http')) {
      _localFile = await _downloadFile(cleanPath);
    } else {
      try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) { debugPrint("URI Decode Error: $e"); }
      if (cleanPath.startsWith('file://')) cleanPath = cleanPath.substring(7);
      _localFile = await _copyFileSecurely(cleanPath);
    }
  }

  /// Generates images from the file and updates _previewBytes
  Future<void> _generatePreviewImages({double dpi = 150}) async {
    if (_localFile == null) return;
    
    final String ext = _localFile!.path.split('.').last.toLowerCase();
    bool isPdf = ext == 'pdf' || _localFile!.path.endsWith('pdf');
    List<Uint8List> newImages = [];

    if (isPdf) {
      final pdfBytes = await _localFile!.readAsBytes();
      // Rasterize using Printing package
      await for (var page in Printing.raster(pdfBytes, dpi: dpi)) {
        final pngBytes = await page.toPng();
        newImages.add(pngBytes);
      }
    } else {
      final bytes = await _localFile!.readAsBytes();
      // If it's an image, we might want to scale it up if DPI is high, 
      // but for simplicity, we just reload bytes. 
      // Real scaling happens in the print processor for images.
      newImages.add(bytes);
    }

    if (mounted) {
      setState(() {
        _previewBytes = newImages;
      });
    }
  }

  Future<File> _copyFileSecurely(String sourcePath) async {
    final File sourceFile = File(sourcePath);
    final Directory tempDir = await getTemporaryDirectory();
    final String fileName = sourcePath.split('/').last.replaceAll(RegExp(r'[^\w\.-]'), '_');
    final String safePath = '${tempDir.path}/$fileName';
    final File destFile = File(safePath);

    try {
      if (await destFile.exists()) await destFile.delete();
      return await sourceFile.copy(safePath);
    } catch (e) {
      final IOSink sink = destFile.openWrite();
      await sourceFile.openRead().pipe(sink);
      return destFile;
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

  // =========================================================
  // MARK: - PRINT FLOW UI
  // =========================================================

  void _showPrintOptions(BuildContext context) {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lang.translate('btn_print_receipt'), // Or "Select Paper Size"
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text("Select paper roll size to scale document:", style: TextStyle(color: Colors.grey[600])),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _buildOptionBtn(
                        label: "58mm", 
                        icon: Icons.receipt_long, 
                        onTap: () {
                          Navigator.pop(ctx);
                          _startPrintProcess(WIDTH_58MM);
                        }
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildOptionBtn(
                        label: "80mm", 
                        icon: Icons.receipt, 
                        onTap: () {
                          Navigator.pop(ctx);
                          _startPrintProcess(WIDTH_80MM);
                        }
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      }
    );
  }

  Widget _buildOptionBtn({required String label, required IconData icon, required VoidCallback onTap}) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 20),
        backgroundColor: Colors.blue[50],
        foregroundColor: Colors.blue[800],
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.blue.shade100)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 30),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // =========================================================
  // MARK: - PRINT LOGIC
  // =========================================================

  Future<void> _startPrintProcess(int targetWidth) async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    
    setState(() => _isPrinting = true);
    
    // 1. UPDATE PREVIEW (Scale to 400% / 300 DPI)
    // We do this on Main Thread because Platform Channels (Printing) often require it.
    // This updates the UI so the user sees the "Latest" look.
    try {
       await _generatePreviewImages(dpi: 300); // ~400% scale relative to screen 72dpi
    } catch (e) {
       debugPrint("Preview generation failed: $e");
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      
      // 2. CONNECT BLUETOOTH
      String targetMac = widget.connectedMac ?? prefs.getString('selected_printer_mac') ?? "";
      await _connectBluetooth(targetMac);

      if (_connectedDevice == null || _writeCharacteristic == null) {
        throw Exception("Printer not found or disconnected");
      }

      // 3. PROCESS IMAGES IN BACKGROUND ISOLATE
      // We pass the ALREADY rasterized PNG bytes (from step 1) to the isolate.
      // This ensures the heavy pixel math (dithering) doesn't lag the UI.
      if (_previewBytes.isEmpty) throw Exception("No image data to print");

      final Map<String, dynamic> params = {
        'imageBytesList': _previewBytes, // These are the high-res PNGs
        'targetWidth': targetWidth,
        'init': INIT_PRINTER,
        'feed': FEED_PAPER,
        'cut': CUT_PAPER,
      };

      // Run computationally expensive task in background
      List<int> dataToSend = await compute(_convertPngsToEscPos, params);

      // 4. SEND TO PRINTER
      await _sendToPrinter(dataToSend);

      if (mounted) _showSnackBar(lang.translate('msg_added_queue'));

    } catch (e) {
      if (mounted) _showSnackBar("${lang.translate('msg_error_prefix')} $e", isError: true);
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  // =========================================================
  // MARK: - BLUETOOTH HELPERS
  // =========================================================

  Future<void> _connectBluetooth(String targetMac) async {
    if (_connectedDevice != null && _writeCharacteristic != null) {
      if (_connectedDevice!.isConnected) return;
    }

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    BluetoothDevice? foundDevice;
    
    await for (var results in FlutterBluePlus.scanResults) {
      for (ScanResult r in results) {
        String name = r.device.platformName;
        String id = r.device.remoteId.str;
        
        if (targetMac.isNotEmpty && id == targetMac) {
          foundDevice = r.device;
          break;
        }
        if (targetMac.isEmpty && (name.contains("Printer") || name.contains("MTP") || name.contains("InnerPrinter"))) {
          foundDevice = r.device;
          break;
        }
      }
      if (foundDevice != null) break;
    }
    
    await FlutterBluePlus.stopScan();

    if (foundDevice != null) {
      _connectedDevice = foundDevice;
      await _connectedDevice!.connect();
      
      List<BluetoothService> services = await _connectedDevice!.discoverServices();
      for (var service in services) {
        for (var char in service.characteristics) {
          if (char.properties.write || char.properties.writeWithoutResponse) {
            _writeCharacteristic = char;
            return;
          }
        }
      }
    }
  }

  Future<void> _sendToPrinter(List<int> data) async {
    if (_writeCharacteristic == null) return;
    const int chunkSize = 150; 
    
    for (int i = 0; i < data.length; i += chunkSize) {
      int end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
      List<int> chunk = data.sublist(i, end);
      await _writeCharacteristic!.write(chunk, withoutResponse: true);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  // =========================================================
  // MARK: - BACKGROUND PROCESSING (ISOLATE)
  // =========================================================

  /// Pure Dart function to run in 'compute'
  /// Input: List of PNG bytes (Uint8List), target width, commands
  /// Output: Full ESC/POS bytes
  static Future<List<int>> _convertPngsToEscPos(Map<String, dynamic> params) async {
    List<Uint8List> sourceImages = params['imageBytesList'];
    int targetWidth = params['targetWidth'];
    List<int> initCmd = params['init'];
    List<int> feedCmd = params['feed'];
    List<int> cutCmd = params['cut'];

    List<int> dataToSend = [];
    dataToSend.addAll(initCmd);
    dataToSend.addAll([0x1B, 0x61, 0x01]); // Center Align

    // Max 50 pages to prevent overflow
    int count = math.min(sourceImages.length, 50);

    for (int i = 0; i < count; i++) {
      // Decode the high-res PNG
      img.Image? src = img.decodePng(sourceImages[i]);
      if (src == null) continue;

      // 1. Trim Whitespace
      img.Image? trimmed = _trimImage(src);
      if (trimmed == null) continue;

      // 2. Resize to Printer Width (High Quality Cubic Interpolation)
      img.Image resized = img.copyResize(trimmed, width: targetWidth, interpolation: img.Interpolation.cubic);

      // 3. Dither & Bit Pack
      List<int> escBytes = _processImageToBytes(resized);
      dataToSend.addAll(escBytes);
    }

    dataToSend.addAll(feedCmd);
    dataToSend.addAll(cutCmd);
    return dataToSend;
  }

  static List<int> _processImageToBytes(img.Image src) {
    int width = src.width;
    int height = src.height;
    List<int> grayPlane = List.filled(width * height, 255);

    // Grayscale + Contrast
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = src.getPixel(x, y);
        double r = p.r.toDouble();
        double g = p.g.toDouble();
        double b = p.b.toDouble();
        // Contrast boost
        double rC = (r * 1.2 - 20).clamp(0, 255);
        double gC = (g * 1.2 - 20).clamp(0, 255);
        double bC = (b * 1.2 - 20).clamp(0, 255);
        int gray = (0.299 * rC + 0.587 * gC + 0.114 * bC).toInt();
        grayPlane[y * width + x] = gray;
      }
    }

    // Floyd-Steinberg Dithering
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int i = y * width + x;
        int oldPixel = grayPlane[i];
        int newPixel = oldPixel < 128 ? 0 : 255;
        grayPlane[i] = newPixel;
        
        int error = oldPixel - newPixel;
        
        if (x + 1 < width) {
           int idx = i + 1;
           grayPlane[idx] = (grayPlane[idx] + error * 7 / 16).toInt().clamp(0, 255);
        }
        if (y + 1 < height) {
           if (x - 1 >= 0) {
             int idx = i + width - 1;
             grayPlane[idx] = (grayPlane[idx] + error * 3 / 16).toInt().clamp(0, 255);
           }
           int idxB = i + width;
           grayPlane[idxB] = (grayPlane[idxB] + error * 5 / 16).toInt().clamp(0, 255);
           if (x + 1 < width) {
             int idxC = i + width + 1;
             grayPlane[idxC] = (grayPlane[idxC] + error * 1 / 16).toInt().clamp(0, 255);
           }
        }
      }
    }

    // Pack Bits (GS v 0 format)
    List<int> escPosData = [];
    int widthBytes = (width + 7) ~/ 8;
    
    escPosData.addAll([0x1D, 0x76, 0x30, 0x00]);
    escPosData.add(widthBytes % 256);
    escPosData.add(widthBytes ~/ 256);
    escPosData.add(height % 256);
    escPosData.add(height ~/ 256);

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
        escPosData.add(byteValue);
      }
    }
    return escPosData;
  }

  static img.Image? _trimImage(img.Image src) {
    int width = src.width;
    int height = src.height;
    int minX = width, maxX = 0, minY = height, maxY = 0;
    bool foundContent = false;
    int threshold = 240;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = src.getPixel(x, y);
        if (p.r < threshold || p.g < threshold || p.b < threshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          foundContent = true;
        }
      }
    }

    if (!foundContent) return null;
    minX = math.max(0, minX - 1);
    maxX = math.min(width, maxX + 1);
    minY = math.max(0, minY - 1);
    maxY = math.min(height, maxY + 1);

    return img.copyCrop(src, x: minX, y: minY, width: maxX - minX, height: maxY - minY);
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      )
    );
  }

  // =========================================================
  // MARK: - BUILD
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);
    final Size screenSize = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: Text(lang.translate('title_preview')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : () => _loadAndGeneratePreview(initialLoad: true),
          )
        ],
      ),
      backgroundColor: Colors.grey[300],
      body: _isLoading
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 10),
                Text(_isPrinting ? "Scaling & Processing..." : "Loading...", style: const TextStyle(color: Colors.grey)),
                if (_errorMessage.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text(_errorMessage, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  )
                ]
              ],
            ),
          )
        : Column(
            children: [
              Expanded(
                child: InteractiveViewer(
                  transformationController: _transformController,
                  panEnabled: true,
                  boundaryMargin: const EdgeInsets.symmetric(vertical: 80, horizontal: 20),
                  minScale: 0.5,
                  maxScale: 4.0,
                  constrained: false,
                  child: SizedBox(
                    width: screenSize.width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 20),
                        if (_previewBytes.isEmpty)
                           Padding(
                             padding: const EdgeInsets.all(20.0),
                             child: Text(lang.translate('err_decode')),
                           )
                        else
                           ..._previewBytes.map((bytes) => Container(
                            margin: const EdgeInsets.only(bottom: 2, left: 16, right: 16), 
                            decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.15),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                  offset: const Offset(0, 4)
                                )
                              ]
                            ),
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.high,
                            ),
                          )).toList(),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
                ),
              ),

              Container(
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
                      icon: _isPrinting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.print),
                      label: Text(_isPrinting ? lang.translate('btn_queueing') : lang.translate('btn_print_receipt')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        elevation: 0,
                      ),
                      // CHANGED: Now opens the option dialog instead of printing immediately
                      onPressed: _isPrinting ? null : () => _showPrintOptions(context),
                    ),
                  ),
                ),
              )
            ],
          ),
    );
  }
}