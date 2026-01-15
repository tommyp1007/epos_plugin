import 'dart:io'; 
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:provider/provider.dart'; 

import '../services/language_service.dart'; 

class WidthSettings extends StatefulWidget {
  final String? connectedDeviceName;

  const WidthSettings({Key? key, this.connectedDeviceName}) : super(key: key);

  @override
  _WidthSettingsState createState() => _WidthSettingsState();
}

class _WidthSettingsState extends State<WidthSettings> {
  int _selectedDpi = 203;
  final TextEditingController _widthController = TextEditingController(text: "384");
    
  String _detectedModelInfo = "";
  bool _canAutoDetect = false;
  bool _isInit = true; 

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInit) {
      _checkAutoDetectCapability();
      _isInit = false;
    }
  }

  void _checkAutoDetectCapability() {
    final lang = Provider.of<LanguageService>(context, listen: false);
    String name = widget.connectedDeviceName ?? "";
    
    if (Platform.isAndroid && name.toLowerCase().contains("innerprinter")) {
      setState(() {
        _canAutoDetect = true;
        _detectedModelInfo = lang.translate('msg_internal_detect'); 
      });
    } else if (Platform.isIOS) {
       setState(() {
        _canAutoDetect = false;
        _detectedModelInfo = lang.translate('msg_ios_manual'); 
      });
    } else {
      setState(() {
        _canAutoDetect = false;
        _detectedModelInfo = name.isEmpty 
            ? lang.translate('msg_no_printer') 
            : "${lang.translate('msg_external_printer')} ($name). ${lang.translate('msg_manual_select')}"; 
      });
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedDpi = prefs.getInt('printer_dpi') ?? 203;
      // KEY: printer_width_dots
      _widthController.text = (prefs.getInt('printer_width_dots') ?? 384).toString();
    });
  }

  Future<void> _saveSettingsOnly() async {
    final lang = Provider.of<LanguageService>(context, listen: false); 
    final prefs = await SharedPreferences.getInstance();
    
    // Save DPI
    await prefs.setInt('printer_dpi', _selectedDpi);
    
    // Save Width (Dots)
    // KEY: printer_width_dots
    int? dots = int.tryParse(_widthController.text);
    if (dots != null) {
      await prefs.setInt('printer_width_dots', dots);
      
      double mm = dots / 8.0;
      
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("${lang.translate('msg_saved')} $dots dots (~${mm.toStringAsFixed(0)}mm)"), 
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleAutoDetect() async {
    if (!Platform.isAndroid) return;
    
    final lang = Provider.of<LanguageService>(context, listen: false); 
    final deviceInfo = DeviceInfoPlugin();
    
    try {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      String manufacturer = androidInfo.manufacturer.toUpperCase();
      String model = androidInfo.model.toUpperCase();
      
      setState(() {
        _detectedModelInfo = "${lang.translate('msg_scanned')} $manufacturer $model"; 
      });

      if (manufacturer.contains("SUNMI")) {
        if (_isSunmi80mm(model)) {
          _updateWidthField(576, "${lang.translate('msg_detect_sunmi_80')} ($model)"); 
        } else {
          _updateWidthField(384, "${lang.translate('msg_detect_sunmi_58')} ($model)"); 
        }
      } else if (manufacturer.contains("HUAWEI") || manufacturer.contains("HONOR")) {
         _updateWidthField(384, lang.translate('msg_detect_huawei')); 
      } else {
        _updateWidthField(384, lang.translate('msg_unknown_internal')); 
      }
    } catch (e) {
      _updateWidthField(384, lang.translate('msg_detect_error')); 
    }
  }

  bool _isSunmi80mm(String model) {
    List<String> models80mm = ["T2", "T2S", "T1", "K2", "T5711"];
    for (var m in models80mm) {
      if (model.contains(m)) return true;
    }
    return false;
  }

  void _updateWidthField(int dots, String message) {
    setState(() {
      _widthController.text = dots.toString();
    });
    
    if(mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.teal, content: Text(message))
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageService>(context);
    int currentDots = int.tryParse(_widthController.text) ?? 384;

    return Scaffold(
      appBar: AppBar(title: Text(lang.translate('title_config'))), 
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(lang.translate('lbl_paper_size'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), 
              const SizedBox(height: 10),
              
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => setState(() => _widthController.text = "384"), 
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _widthController.text == "384" ? Colors.blue : Colors.grey[300],
                        foregroundColor: _widthController.text == "384" ? Colors.white : Colors.black
                      ),
                      child: Column(children: [
                        Text(lang.translate('btn_58mm')), 
                        Text(lang.translate('lbl_standard'), style: const TextStyle(fontSize: 10)) 
                      ]),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => setState(() => _widthController.text = "576"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _widthController.text == "576" ? Colors.blue : Colors.grey[300],
                        foregroundColor: _widthController.text == "576" ? Colors.white : Colors.black
                      ),
                      child: Column(children: [
                        Text(lang.translate('btn_80mm')), 
                        Text(lang.translate('lbl_large'), style: const TextStyle(fontSize: 10)) 
                      ]),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              Text(lang.translate('lbl_advanced'), style: const TextStyle(fontWeight: FontWeight.bold)), 
              const SizedBox(height: 5),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _widthController,
                      keyboardType: TextInputType.number,
                      onChanged: (val) => setState(() {}), 
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(), 
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  
                  Expanded(
                    child: SizedBox(
                      height: 53, 
                      child: ElevatedButton.icon(
                        onPressed: _canAutoDetect ? _handleAutoDetect : null, 
                        icon: const Icon(Icons.perm_device_information),
                        label: Text(lang.translate('btn_auto_detect')), 
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey[300],
                          disabledForegroundColor: Colors.grey[600],
                          elevation: 0, 
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4.0), 
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6.0, left: 2.0),
                child: Text(
                  lang.translate('hint_dots'), 
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.only(top: 4.0), 
                child: Text(
                  _detectedModelInfo, 
                  style: TextStyle(
                    color: _canAutoDetect ? Colors.green[700] : Colors.orange[800], 
                    fontStyle: FontStyle.italic,
                    fontSize: 12
                  ),
                ),
              ),

              const SizedBox(height: 30),
              Text(lang.translate('lbl_visual'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)), 
              const SizedBox(height: 5),
              
              Container(
                height: 50,
                width: double.infinity, 
                decoration: BoxDecoration(
                  color: Colors.grey[300], 
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4)
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CustomPaint(
                    painter: RulerPainter(currentDots: currentDots, activeLabel: lang.translate('lbl_active_area')), 
                    child: Container(),
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    "${currentDots} dots / ${(currentDots/8).toStringAsFixed(1)}mm", 
                    style: const TextStyle(fontSize: 10, color: Colors.grey)
                  ),
                ),
              ),

              const SizedBox(height: 30),
              
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _saveSettingsOnly,
                  icon: const Icon(Icons.save),
                  label: Text(lang.translate('btn_save_settings')), 
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue, 
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class RulerPainter extends CustomPainter {
  final int currentDots;
  final String activeLabel; 
  final int maxDots = 576; 

  RulerPainter({required this.currentDots, required this.activeLabel});

  @override
  void paint(Canvas canvas, Size size) {
    double ratio = currentDots / maxDots;
    if (ratio > 1.0) ratio = 1.0; 
    
    double activeWidth = size.width * ratio;

    final paperPaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, activeWidth, size.height), paperPaint);

    final edgePaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.5)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(activeWidth, 0), Offset(activeWidth, size.height), edgePaint);
    
    final tickPaint = Paint()..color = Colors.black87..strokeWidth = 1;
    
    double step = activeWidth / 10; 
    
    for (int i = 0; i <= 10; i++) {
      double x = i * step;
      double tickHeight = (i % 5 == 0) ? 15.0 : 6.0;
      canvas.drawLine(Offset(x, 0), Offset(x, tickHeight), tickPaint);
    }
    
    final textPainter = TextPainter(
      text: TextSpan(
        text: activeLabel, 
        style: TextStyle(color: Colors.black.withOpacity(0.2), fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    
    if (activeWidth > 50) {
      textPainter.paint(canvas, Offset((activeWidth - textPainter.width) / 2, (size.height - textPainter.height) / 2));
    }
  }

  @override
  bool shouldRepaint(covariant RulerPainter oldDelegate) {
    return oldDelegate.currentDots != currentDots;
  }
}