import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    // 1. Get the Flutter Controller
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
      
    // 2. Create the Method Channel (Must match the name in Flutter: 'com.zen.printer/channel')
    let printerChannel = FlutterMethodChannel(name: "com.zen.printer/channel",
                                              binaryMessenger: controller.binaryMessenger)
      
    // 3. Handle Method Calls from Flutter
    printerChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      
      // Check which method Flutter is calling
      if call.method == "printPdf" {
          
          // Extract arguments (file path and mac address)
          guard let args = call.arguments as? [String: Any],
                let path = args["path"] as? String else {
              result(FlutterError(code: "INVALID_ARGS", message: "File path is required", details: nil))
              return
          }
          
          let mac = args["macAddress"] as? String
          let fileUrl = URL(fileURLWithPath: path)
          
          // 4. Call your Native Printer Service
          // The service handles the background task, queue, and bluetooth connection
          PrinterService.shared.printPdf(fileUrl: fileUrl, macAddress: mac)
          
          // Send success back to Flutter
          result("Success")
          
      } else {
          // Method not found
          result(FlutterMethodNotImplemented)
      }
    })

    // 5. Standard Flutter Plugin Registration
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}