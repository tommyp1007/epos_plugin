import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/bluetooth_print_service.dart';
import '../utils/raw_commands.dart';

class TestPrintPage extends StatefulWidget {
  @override
  _TestPrintPageState createState() => _TestPrintPageState();
}

class _TestPrintPageState extends State<TestPrintPage> {
  final _service = BluetoothPrintService();
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  String? _connectedDeviceName;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  void _initBluetooth() {
    _service.scanResults.listen((results) {
      if(mounted) setState(() => _scanResults = results);
    });
    FlutterBluePlus.isScanning.listen((state) {
      if(mounted) setState(() => _isScanning = state);
    });
    _startScan();
  }

  void _startScan() async {
    await _service.requestPermissions();
    _service.startScan();
  }

  void _connectToDevice(BluetoothDevice device) async {
    await _service.stopScan();
    bool success = await _service.connect(device);
    if (success && mounted) {
      setState(() => _connectedDeviceName = device.platformName.isNotEmpty ? device.platformName : device.remoteId.str);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connected!")));
    }
  }

  void _printTest() async {
    try {
      List<int> bytes = [];
      bytes.addAll(RawCommands.reset());
      bytes.addAll("e-Pos BLE Service Test\n".codeUnits);
      bytes.addAll("----------------\n".codeUnits);
      bytes.addAll("Works on iOS & Android!\n\n\n".codeUnits);
      bytes.addAll(RawCommands.feed(3));

      await _service.sendBytes(bytes);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Print Error: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("BLE Printer Manager")),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: _connectedDeviceName != null ? Colors.green[100] : Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(_connectedDeviceName != null ? "Connected: $_connectedDeviceName" : "Not Connected")),
                if (_connectedDeviceName != null) ElevatedButton(onPressed: _printTest, child: const Text("TEST PRINT"))
              ],
            ),
          ),
          if (!_isScanning)
            TextButton.icon(icon: const Icon(Icons.refresh), label: const Text("Scan Again"), onPressed: _startScan)
          else 
            const Padding(padding: EdgeInsets.all(8.0), child: LinearProgressIndicator()),
          Expanded(
            child: ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                if (result.device.platformName.isEmpty) return const SizedBox.shrink();
                return ListTile(
                  title: Text(result.device.platformName),
                  subtitle: Text(result.device.remoteId.str),
                  trailing: Text("${result.rssi} dBm"),
                  onTap: () => _connectToDevice(result.device),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}