import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart'; 
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
  static const platform = MethodChannel('com.zen.printer/channel');

  bool _isLoading = true; 
  bool _isProcessingPages = false; 
  bool _isPrinting = false;
  String _errorMessage = '';

  List<Uint8List> _previewBytes = [];
  File? _localFile;

  final TransformationController _transformController = TransformationController();

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
        setState(() {
          _errorMessage = e.toString();
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
      return await sourceFile.copy(safePath);
    } catch (e) {
      debugPrint("Standard copy failed ($e). Attempting Stream Copy...");
      try {
        final IOSink sink = destFile.openWrite();
        await sourceFile.openRead().pipe(sink); 
        return destFile;
      } catch (e2) {
        throw Exception("Unable to read file: $e2");
      }
    }
  }

  Future<void> _prepareFile() async {
    String cleanPath = widget.filePath;
    
    try {
      if (cleanPath.toLowerCase().startsWith('http')) {
        _localFile = await _downloadFile(cleanPath);
      } else {
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (e) { debugPrint("URI Decode Error: $e"); }
        if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        _localFile = await _copyFileSecurely(cleanPath);
      }

      final String ext = _localFile!.path.split('.').last.toLowerCase();
      bool isPdf = ext == 'pdf' || _localFile!.path.endsWith('pdf');

      _previewBytes.clear();

      if (isPdf) {
        final pdfBytes = await _localFile!.readAsBytes();
        
        await for (var page in Printing.raster(pdfBytes, dpi: 150)) { 
           final pngBytes = await page.toPng();
           if (mounted) {
             setState(() {
               _previewBytes.add(pngBytes);
             });
           }
        }
      } else {
        final bytes = await _localFile!.readAsBytes();
        if (mounted) {
          setState(() {
            _previewBytes.add(bytes);
          });
        }
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        if (widget.autoPrint) _doPrint();
      }

    } catch (e) {
       debugPrint("Processing Error: $e");
       if(mounted) setState(() { _errorMessage = "Error loading file: $e"; _isLoading = false; });
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

  Future<void> _doPrint() async {
    final lang = Provider.of<LanguageService>(context, listen: false);

    if (_localFile == null) {
      _showSnackBar("File not loaded", isError: true);
      return;
    }

    setState(() => _isPrinting = true);
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final String savedMac = prefs.getString('selected_printer_mac') ?? "";

      await platform.invokeMethod('printPdf', {
        'path': _localFile!.path,
        'macAddress': savedMac.isNotEmpty ? savedMac : null
      });

      if (mounted) {
        _showSnackBar(lang.translate('msg_added_queue')); 
      }

    } on PlatformException catch (e) {
      if (mounted) _showSnackBar("Print Error: ${e.message}", isError: true);
    } catch (e) {
      if (mounted) _showSnackBar("Error: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
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
                           const Padding(
                             padding: EdgeInsets.all(20.0),
                             child: Text("No content found."),
                           )
                        else
                           ..._previewBytes.map((bytes) => Container(
                            margin: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
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