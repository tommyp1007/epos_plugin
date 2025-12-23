import 'dart:io'; // Required for Platform checks
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';

class WidthSettings extends StatefulWidget {
  // We need to know which printer is connected to decide if we can Auto-Detect
  final String? connectedDeviceName;

  const WidthSettings({Key? key, this.connectedDeviceName}) : super(key: key);

  @override
  _WidthSettingsState createState() => _WidthSettingsState();
}

class _WidthSettingsState extends State<WidthSettings> {
  // Default to 384 dots (Sunmi 58mm standard @ 203dpi)
  int _selectedDpi = 203;
  final TextEditingController _widthController = TextEditingController(text: "384");
   
  String _detectedModelInfo = "";
  bool _canAutoDetect = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkAutoDetectCapability();
  }

  // LOGIC: Check if we can run auto-detect based on Platform and connection
  void _checkAutoDetectCapability() {
    String name = widget.connectedDeviceName ?? "";
    
    // Auto-detect relies on reading internal hardware info, which is:
    // 1. Only reliably available on Android
    // 2. Only relevant if using the "InnerPrinter"
    
    if (Platform.isAndroid && name.toLowerCase().contains("innerprinter")) {
      setState(() {
        _canAutoDetect = true;
        _detectedModelInfo = "Internal Printer detected. Auto-detect available.";
      });
    } else if (Platform.isIOS) {
       setState(() {
        _canAutoDetect = false;
        _detectedModelInfo = "iOS Device: Please select paper size manually.";
      });
    } else {
      setState(() {
        _canAutoDetect = false;
        _detectedModelInfo = name.isEmpty 
            ? "No printer connected. Auto-detect disabled."
            : "External Bluetooth Printer ($name). Please select size manually.";
      });
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedDpi = prefs.getInt('printer_dpi') ?? 203;
      _widthController.text = (prefs.getInt('printer_width_dots') ?? 384).toString();
    });
  }

  Future<void> _saveSettingsOnly() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('printer_dpi', _selectedDpi);
    
    int? dots = int.tryParse(_widthController.text);
    if (dots != null) {
      await prefs.setInt('printer_width_dots', dots);
      
      double mm = dots / 8.0;
      
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Settings Saved: $dots dots (~${mm.toStringAsFixed(0)}mm)"),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // --- AUTO DETECT HANDLER (Only runs for InnerPrinter on Android) ---
  Future<void> _handleAutoDetect() async {
    // Safety check: Don't run this on iOS
    if (!Platform.isAndroid) return;

    final deviceInfo = DeviceInfoPlugin();
    try {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      String manufacturer = androidInfo.manufacturer.toUpperCase();
      String model = androidInfo.model.toUpperCase();
      
      setState(() {
        _detectedModelInfo = "Scanned Hardware: $manufacturer $model";
      });

      if (manufacturer.contains("SUNMI")) {
        if (_isSunmi80mm(model)) {
          _updateWidthField(576, "Detected Sunmi 80mm ($model)");
        } else {
          _updateWidthField(384, "Detected Sunmi 58mm ($model)");
        }
      } else if (manufacturer.contains("HUAWEI") || manufacturer.contains("HONOR")) {
         // Huawei generic fallback (most handhelds are 58mm)
         _updateWidthField(384, "Detected Huawei Device. Defaulting to 58mm.");
      } else {
        // If it's InnerPrinter but not recognized, default to 58mm
        _updateWidthField(384, "Unknown Internal Device. Defaulting to 58mm.");
      }
    } catch (e) {
      _updateWidthField(384, "Detection Error. Defaulting to 58mm.");
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
    // Parse current dots for the ruler visualization
    int currentDots = int.tryParse(_widthController.text) ?? 384;

    return Scaffold(
      appBar: AppBar(title: const Text("Printer Configuration")),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Paper Size (Width)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              
              // --- MANUAL OPTIONS ---
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => setState(() => _widthController.text = "384"), 
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _widthController.text == "384" ? Colors.blue : Colors.grey[300],
                        foregroundColor: _widthController.text == "384" ? Colors.white : Colors.black
                      ),
                      child: const Column(children: [Text("58mm"), Text("Standard", style: TextStyle(fontSize: 10))]),
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
                      child: const Column(children: [Text("80mm"), Text("Large/POS", style: TextStyle(fontSize: 10))]),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              const Text("Advanced Settings:", style: TextStyle(fontWeight: FontWeight.bold)),
              
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _widthController,
                      keyboardType: TextInputType.number,
                      // Ensure ruler updates when typing manually
                      onChanged: (val) => setState(() {}), 
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: "Dots",
                        helperText: "384 = 58mm, 576 = 80mm"
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  
                  // --- AUTO DETECT BUTTON ---
                  SizedBox(
                    height: 55,
                    child: ElevatedButton.icon(
                      // Disable button if not Android or not InnerPrinter
                      onPressed: _canAutoDetect ? _handleAutoDetect : null, 
                      icon: const Icon(Icons.perm_device_information),
                      label: const Text("AUTO\nDETECT"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey[300],
                        disabledForegroundColor: Colors.grey[600],
                      ),
                    ),
                  ),
                ],
              ),
              
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _detectedModelInfo, 
                  style: TextStyle(
                    color: _canAutoDetect ? Colors.green[700] : Colors.orange[800], 
                    fontStyle: FontStyle.italic,
                    fontSize: 12
                  )
                ),
              ),

              const SizedBox(height: 30),
              const Text("Visual Preview:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 5),
              
              // --- UPDATED RULER VISUAL ---
              // Shows the relative size of the paper compared to max 80mm
              Container(
                height: 50,
                width: double.infinity, // This represents the Max Printer Width (80mm)
                decoration: BoxDecoration(
                  color: Colors.grey[300], // Background is the "Empty Space"
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4)
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CustomPaint(
                    painter: RulerPainter(currentDots: currentDots),
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
                )
              ),

              const SizedBox(height: 30),
              
              // --- SAVE BUTTON ---
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _saveSettingsOnly,
                  icon: const Icon(Icons.save),
                  label: const Text("SAVE SETTINGS"),
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

// --- UPDATED PAINTER ---
class RulerPainter extends CustomPainter {
  final int currentDots;
  
  // We assume 576 dots (80mm) is the standard maximum width for handheld POS
  final int maxDots = 576; 

  RulerPainter({required this.currentDots});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Calculate how much width the current setting takes up
    // Scale: If currentDots is 384 and max is 576, it should take ~66% of the screen width
    double ratio = currentDots / maxDots;
    if (ratio > 1.0) ratio = 1.0; // Clamp if user enters crazy high number
    
    double activeWidth = size.width * ratio;

    // 2. Draw Active Paper Area (White)
    final paperPaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, activeWidth, size.height), paperPaint);

    // 3. Draw Edge Line (Right side of paper)
    final edgePaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.5)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(activeWidth, 0), Offset(activeWidth, size.height), edgePaint);
    
    // 4. Draw Ruler Ticks
    final tickPaint = Paint()..color = Colors.black87..strokeWidth = 1;
    
    // We draw 10 major sections across the *Active* width
    double step = activeWidth / 10; 
    
    for (int i = 0; i <= 10; i++) {
      double x = i * step;
      // Make 0, 5, 10 longer ticks
      double tickHeight = (i % 5 == 0) ? 15.0 : 6.0;
      canvas.drawLine(Offset(x, 0), Offset(x, tickHeight), tickPaint);
    }
    
    // 5. Draw "Paper" Label inside
    final textPainter = TextPainter(
      text: TextSpan(
        text: "Active Area",
        style: TextStyle(color: Colors.black.withOpacity(0.2), fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    
    // Center text in the active area
    if (activeWidth > 50) {
      textPainter.paint(canvas, Offset((activeWidth - textPainter.width) / 2, (size.height - textPainter.height) / 2));
    }
  }

  @override
  bool shouldRepaint(covariant RulerPainter oldDelegate) {
    return oldDelegate.currentDots != currentDots;
  }
}