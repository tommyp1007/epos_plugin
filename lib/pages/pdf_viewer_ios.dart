import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui; // Required for Image capture

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // For RepaintBoundary
import 'package:flutter/services.dart'; // Required for RootIsolateToken
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:image/image.dart' as img; 
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; 

// ML Kit & Formatting
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:intl/intl.dart';
import 'package:barcode_widget/barcode_widget.dart' as bw; 

import '../services/printer_service.dart';
import '../services/language_service.dart';

// ==========================================
// 1. DATA MODELS
// ==========================================
class ReceiptItem {
  final String productName;
  final double unitPrice;
  final int qty;
  final double totalPrice;

  ReceiptItem(this.productName, this.unitPrice, this.qty, this.totalPrice);
}

class ReceiptData {
  String companyName;
  String companyReg;
  String address;
  String orderNo;
  String receiptNo;
  String date;
  String barcodePayload;
  List<ReceiptItem> items;
  double subTotal;
  double tax;
  double rounding;
  double total;

  ReceiptData({
    this.companyName = "My Company Sdn Bhd",
    this.companyReg = "",
    this.address = "",
    this.orderNo = "",
    this.receiptNo = "",
    this.date = "",
    this.barcodePayload = "",
    this.items = const [],
    this.subTotal = 0.0,
    this.tax = 0.0,
    this.rounding = 0.0,
    this.total = 0.0,
  });
}

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
  bool _isConverting = false;
  String _errorMessage = '';

  List<Uint8List> _previewBytes = [];
  File? _localFile;

  final TransformationController _transformController = TransformationController();
  final GlobalKey _globalKey = GlobalKey(); // To capture the generated receipt

  // Bluetooth State
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  @override
  void initState() {
    super.initState();
    _loadAndGeneratePreview();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadAndGeneratePreview() async {
    try {
      if (mounted) setState(() => _isLoading = true);
      await _prepareFile();
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

  Future<void> _prepareFile() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    String cleanPath = widget.filePath;

    try {
      if (cleanPath.toLowerCase().startsWith('http')) {
        _localFile = await _downloadFile(cleanPath);
      } else {
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) { debugPrint("URI Decode Error: $e"); }
        if (cleanPath.startsWith('file://')) cleanPath = cleanPath.substring(7);
        _localFile = await _copyFileSecurely(cleanPath);
      }

      final String ext = _localFile!.path.split('.').last.toLowerCase();
      bool isPdf = ext == 'pdf' || _localFile!.path.endsWith('pdf');

      _previewBytes.clear();

      if (isPdf) {
        final pdfBytes = await _localFile!.readAsBytes();
        await for (var page in Printing.raster(pdfBytes, dpi: 150)) {
          final pngBytes = await page.toPng();
          if (mounted) setState(() => _previewBytes.add(pngBytes));
        }
      } else {
        final bytes = await _localFile!.readAsBytes();
        if (mounted) setState(() => _previewBytes.add(bytes));
      }

      if (mounted) {
        setState(() => _isLoading = false);
        if (widget.autoPrint) Future.delayed(const Duration(milliseconds: 500), _convertAndPrint);
      }

    } catch (e) {
      if(mounted) setState(() { _errorMessage = "${lang.translate('msg_error_prefix')} $e"; _isLoading = false; });
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
  // MARK: - OCR & PARSING LOGIC
  // =========================================================

  Future<void> _convertAndPrint() async {
    if (_previewBytes.isEmpty) return;
    setState(() => _isConverting = true);

    try {
      // 1. Initialize Parsers
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final barcodeScanner = BarcodeScanner();
      
      StringBuffer fullText = StringBuffer();
      String? foundQrCode;

      final Directory tempDir = await getTemporaryDirectory();

      // 2. Scan every page
      for (int i = 0; i < _previewBytes.length; i++) {
        final tempFile = File('${tempDir.path}/ocr_page_$i.png');
        await tempFile.writeAsBytes(_previewBytes[i]);
        final inputImage = InputImage.fromFilePath(tempFile.path);

        // Scan Text
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        fullText.writeln(recognizedText.text);

        // Scan Barcode
        if (foundQrCode == null) {
          final barcodes = await barcodeScanner.processImage(inputImage);
          for (Barcode barcode in barcodes) {
            if (barcode.rawValue != null) {
              foundQrCode = barcode.rawValue;
              break;
            }
          }
        }
        await tempFile.delete();
      }

      // 3. Parse Data
      ReceiptData data = _parseTextToReceiptData(fullText.toString(), foundQrCode);

      textRecognizer.close();
      barcodeScanner.close();

      // 4. Show Dialog with Capture Logic
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            contentPadding: EdgeInsets.zero,
            content: SizedBox(
              width: 400,
              height: 600,
              child: Column(
                children: [
                   Container(
                     padding: const EdgeInsets.all(16),
                     color: Colors.blueAccent,
                     width: double.infinity,
                     child: const Text("Generated Receipt Preview", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                   ),
                   Expanded(
                     child: SingleChildScrollView(
                       child: RepaintBoundary(
                         key: _globalKey, // <--- Key must be in tree here
                         child: Container(
                           color: Colors.white,
                           padding: const EdgeInsets.all(10),
                           child: OdooReceiptLayout(data: data),
                         ),
                       ),
                     ),
                   ),
                   Padding(
                     padding: const EdgeInsets.all(8.0),
                     child: Row(
                       mainAxisAlignment: MainAxisAlignment.end,
                       children: [
                         TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                         const SizedBox(width: 10),
                         ElevatedButton.icon(
                           icon: const Icon(Icons.print),
                           label: const Text("Print This"),
                           onPressed: () async {
                             // FIX: Capture BEFORE popping the dialog
                             bool success = await _captureAndSaveReceipt();
                             if (success) {
                               Navigator.pop(ctx);
                               // Small delay to allow dialog to close before printing starts
                               Future.delayed(const Duration(milliseconds: 200), () {
                                 _doPrint(); 
                               });
                             }
                           },
                         ),
                       ],
                     ),
                   )
                ],
              ),
            ),
          )
        );
      }

    } catch (e) {
      _showSnackBar("OCR Failed: $e", isError: true);
    } finally {
      if(mounted) setState(() => _isConverting = false);
    }
  }

  /// Captures the RepaintBoundary to a File and updates _localFile
  Future<bool> _captureAndSaveReceipt() async {
    try {
      RenderRepaintBoundary? boundary = _globalKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      
      if (boundary == null) {
        debugPrint("Boundary not found");
        return false;
      }

      // Capture image with higher pixel ratio for clarity
      ui.Image image = await boundary.toImage(pixelRatio: 2.0); 
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      
      if (byteData != null) {
        Uint8List pngBytes = byteData.buffer.asUint8List();
        
        final Directory tempDir = await getTemporaryDirectory();
        final String tempPath = '${tempDir.path}/generated_receipt_${DateTime.now().millisecondsSinceEpoch}.png';
        final File file = File(tempPath);
        await file.writeAsBytes(pngBytes);

        setState(() {
          _localFile = file; // Switch current file to this new image
          _previewBytes = [pngBytes]; // Update preview to show what will print
        });
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("Capture Error: $e");
      return false;
    }
  }

  ReceiptData _parseTextToReceiptData(String text, String? qrCode) {
    String company = "My Company Sdn Bhd"; 
    String orderNo = "Unknown";
    String date = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    double total = 0.0;
    List<ReceiptItem> items = [];

    final RegExp totalRegex = RegExp(r'(Total|Grand Total|Amount)[\s\:\$RM]*([\d\.,]+)', caseSensitive: false);
    final RegExp orderRegex = RegExp(r'(Order|Ref|Inv)[\s\:\.]*([A-Za-z0-9\-]+)', caseSensitive: false);
    
    var totalMatch = totalRegex.firstMatch(text);
    if (totalMatch != null) {
      String cleanTotal = totalMatch.group(2)!.replaceAll(',', '');
      total = double.tryParse(cleanTotal) ?? 0.0;
    }

    var orderMatch = orderRegex.firstMatch(text);
    if (orderMatch != null) orderNo = orderMatch.group(2) ?? "0001";

    List<String> lines = text.split('\n');
    for (var line in lines) {
      if (RegExp(r'\d+\.\d{2}$').hasMatch(line) && !line.toLowerCase().contains("total")) {
        List<String> parts = line.split(RegExp(r'\s+'));
        if (parts.length > 1) {
          String priceStr = parts.last.replaceAll(',', '');
          double price = double.tryParse(priceStr) ?? 0.0;
          String name = parts.sublist(0, parts.length - 1).join(" ");
          items.add(ReceiptItem(name, price, 1, price));
        }
      }
    }

    if (items.isEmpty && total > 0) {
      items.add(ReceiptItem("Consolidated Item", total, 1, total));
    }

    return ReceiptData(
      companyName: company,
      orderNo: orderNo,
      date: date,
      barcodePayload: qrCode ?? "https://lhdn.gov.my/einvoice",
      items: items,
      total: total,
      subTotal: total, 
    );
  }

  // =========================================================
  // MARK: - PRINTING LOGIC
  // =========================================================

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);
    if (_localFile == null) {
      _showSnackBar(lang.translate('err_file_not_found'), isError: true);
      return;
    }

    setState(() => _isPrinting = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      
      // 1. Get Settings
      String targetMac = widget.connectedMac ?? prefs.getString('selected_printer_mac') ?? "";
      
      // FIX: Get the width saved by WidthSettings page
      int savedWidth = prefs.getInt('printer_width_dots') ?? WIDTH_58MM; 
      
      // 2. Connect to Bluetooth
      await _connectBluetooth(targetMac);

      if (_connectedDevice == null || _writeCharacteristic == null) {
        throw Exception("Printer not found or disconnected");
      }

      // 3. Process PDF/Image -> ESC/POS Bytes
      bool isPdf = _localFile!.path.toLowerCase().endsWith('.pdf');

      // 4. Capture Root Isolate Token
      RootIsolateToken? rootToken = RootIsolateToken.instance;

      List<int> dataToSend = await compute(_processPdfToEscPos, {
        'fileBytes': await _localFile!.readAsBytes(),
        'width': savedWidth, // Use the saved width (384 or 576)
        'init': INIT_PRINTER,
        'feed': FEED_PAPER,
        'cut': CUT_PAPER,
        'isPdf': isPdf,
        'rootToken': rootToken, 
      });

      // 5. Send Bytes
      await _sendToPrinter(dataToSend);

      if (mounted) _showSnackBar(lang.translate('msg_added_queue'));

    } catch (e) {
      if (mounted) _showSnackBar("${lang.translate('msg_error_prefix')} $e", isError: true);
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

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
  // MARK: - IMAGE PROCESSING
  // =========================================================

  static Future<List<int>> _processPdfToEscPos(Map<String, dynamic> params) async {
    RootIsolateToken? rootToken = params['rootToken'];
    if (rootToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    }

    Uint8List fileBytes = params['fileBytes'];
    int targetWidth = params['width'];
    List<int> initCmd = params['init'];
    List<int> feedCmd = params['feed'];
    List<int> cutCmd = params['cut'];
    bool isPdf = params['isPdf'];

    List<int> dataToSend = [];
    
    // Header
    dataToSend.addAll(initCmd);
    dataToSend.addAll([0x1B, 0x61, 0x01]); // Align Center

    List<img.Image> rawImages = [];

    if (isPdf) {
      await for (var page in Printing.raster(fileBytes, dpi: 200)) {
        final png = await page.toPng();
        final image = img.decodePng(png);
        if (image != null) rawImages.add(image);
      }
    } else {
      final image = img.decodeImage(fileBytes);
      if (image != null) rawImages.add(image);
    }

    int count = math.min(rawImages.length, 50);

    for (int i = 0; i < count; i++) {
      img.Image src = rawImages[i];

      img.Image? trimmed = _trimImage(src);
      if (trimmed == null) continue; 

      // Resize to the Target Width from Settings
      img.Image resized = img.copyResize(trimmed, width: targetWidth, interpolation: img.Interpolation.cubic);

      List<int> escBytes = _convertImageToEscPos(resized);
      dataToSend.addAll(escBytes);
    }

    // Footer
    dataToSend.addAll(feedCmd);
    dataToSend.addAll(cutCmd);

    return dataToSend;
  }

  static List<int> _convertImageToEscPos(img.Image src) {
    int width = src.width;
    int height = src.height;
    
    // Grayscale Array
    List<int> grayPlane = List.filled(width * height, 255);

    // Grayscale + Contrast
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = src.getPixel(x, y);

        if (p.a < 128) {
          grayPlane[y * width + x] = 255;
          continue;
        }

        double r = p.r.toDouble();
        double g = p.g.toDouble();
        double b = p.b.toDouble();
        
        double rC = (r * 1.2 - 20).clamp(0, 255);
        double gC = (g * 1.2 - 20).clamp(0, 255);
        double bC = (b * 1.2 - 20).clamp(0, 255);
        
        int gray = (0.299 * rC + 0.587 * gC + 0.114 * bC).toInt();
        grayPlane[y * width + x] = gray;
      }
    }

    // Dither
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

    // Pack Bits
    List<int> escPosData = [];
    int widthBytes = (width + 7) ~/ 8;
    
    // GS v 0 Command
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
    int minX = width;
    int maxX = 0;
    int minY = height;
    int maxY = 0;
    bool foundContent = false;
    int threshold = 240;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        img.Pixel p = src.getPixel(x, y);
        
        if (p.a < 128) continue; 

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

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);
    final Size screenSize = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: Text(lang.translate('title_preview')),
        actions: [
          IconButton(
            icon: _isConverting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.receipt_long), 
            tooltip: "Convert A4 to Receipt",
            onPressed: (_isLoading || _isConverting) ? null : _convertAndPrint,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadAndGeneratePreview,
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
// 3. ODOO RECEIPT LAYOUT WIDGET
// =========================================================
class OdooReceiptLayout extends StatelessWidget {
  final ReceiptData data;

  const OdooReceiptLayout({Key? key, required this.data}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);

    const styleNormal = TextStyle(color: Colors.black, fontSize: 10, fontFamily: 'Roboto', decoration: TextDecoration.none);
    const styleBold = TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'Roboto', decoration: TextDecoration.none);
    const styleHeader = TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Roboto', decoration: TextDecoration.none);

    final currency = NumberFormat.currency(symbol: "RM ", decimalDigits: 2);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Header
        Text(data.companyName, style: styleHeader, textAlign: TextAlign.center),
        if (data.companyReg.isNotEmpty) Text("(${data.companyReg})", style: styleNormal),
        const SizedBox(height: 5),
        Text(data.address, style: styleNormal, textAlign: TextAlign.center),
        
        const SizedBox(height: 10),
        Text(lang.translate('rcpt_scan_qr'), style: styleBold),
        const SizedBox(height: 5),
        
        // QR Code
        Container(
          height: 120,
          width: 120,
          color: Colors.white,
          child: bw.BarcodeWidget(
             barcode: bw.Barcode.qrCode(),
             data: data.barcodePayload,
             drawText: false,
          ),
        ),
        
        const SizedBox(height: 10),
        
        // Order Info
        Row(children: [
           Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
             Text("${lang.translate('rcpt_order_no')} ${data.orderNo}", style: styleNormal),
             Text("${lang.translate('rcpt_date')} ${data.date}", style: styleNormal),
           ])
        ]),

        const SizedBox(height: 5),
        
        // Request Timeline Box
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(border: Border.all(color: Colors.black, width: 0.5)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(lang.translate('rcpt_timeline_title'), style: styleBold),
              Text(lang.translate('rcpt_start_date'), style: styleNormal),
              Text(lang.translate('rcpt_last_date'), style: styleNormal),
            ],
          ),
        ),

        const SizedBox(height: 15),

        // Order Lines Header
        const Divider(color: Colors.black, thickness: 1),
        Row(children: [
          Expanded(flex: 3, child: Text(lang.translate('rcpt_col_product'), style: styleNormal)),
          Expanded(flex: 2, child: Text(lang.translate('rcpt_col_price'), style: styleNormal, textAlign: TextAlign.right)),
          Expanded(flex: 1, child: Text(lang.translate('rcpt_col_qty'), style: styleNormal, textAlign: TextAlign.center)),
          Expanded(flex: 2, child: Text(lang.translate('rcpt_col_total'), style: styleNormal, textAlign: TextAlign.right)),
        ]),
        const Divider(color: Colors.black, thickness: 1),
        
        ...data.items.map((item) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Expanded(flex: 3, child: Text(item.productName, style: styleNormal)),
            Expanded(flex: 2, child: Text(currency.format(item.unitPrice), style: styleNormal, textAlign: TextAlign.right)),
            Expanded(flex: 1, child: Text("${item.qty}", style: styleNormal, textAlign: TextAlign.center)),
            Expanded(flex: 2, child: Text(currency.format(item.totalPrice), style: styleNormal, textAlign: TextAlign.right)),
          ]),
        )),

        const Divider(color: Colors.black, thickness: 1),

        // Totals
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(lang.translate('rcpt_subtotal'), style: styleBold),
          Text(currency.format(data.subTotal), style: styleBold),
        ]),
        if (data.tax > 0)
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(lang.translate('rcpt_tax'), style: styleNormal),
          Text(currency.format(data.tax), style: styleNormal),
        ]),
        
        const SizedBox(height: 5),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(lang.translate('rcpt_total_caps'), style: styleHeader),
          Text(currency.format(data.total), style: styleHeader),
        ]),

        const SizedBox(height: 20),
        Text(lang.translate('rcpt_thank_you'), style: styleNormal),
        const SizedBox(height: 20),
      ],
    );
  }
}