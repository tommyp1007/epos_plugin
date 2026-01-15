import UIKit
import Social
import MobileCoreServices
import CoreBluetooth
import CoreGraphics

class ShareViewController: SLComposeServiceViewController {

    // MARK: - Configuration
    // REPLACE THIS WITH YOUR ACTUAL APP GROUP ID
    private let appGroupID = "group.com.example.eposprinter"
    
    // MARK: - Properties
    private let printerHelper = BluetoothPrinterHelper()
    private var printerWidth: Int = 384 // Default 58mm
    private var processingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 1. Customize UI
        self.title = "MyInvois e-Pos Print"
        self.placeholder = "Processing document for printing..."
        
        // 2. Load Settings from Shared App Group
        loadSettings()
        
        // 3. Disable the "Post" button initially
        self.navigationController?.navigationBar.topItem?.rightBarButtonItem?.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // 4. Start Process Automatically
        handleIncomingContent()
    }

    // MARK: - Logic
    
    private func loadSettings() {
        if let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            // Note: Flutter SharedPreferences usually adds "flutter." prefix
            let savedWidth = sharedDefaults.integer(forKey: "flutter.printer_width_dots")
            if savedWidth > 0 {
                self.printerWidth = savedWidth
            }
            
            // Try to get last used printer Identifier (UUID string)
            if let savedUUID = sharedDefaults.string(forKey: "flutter.selected_printer_uuid") {
                printerHelper.targetUUID = UUID(uuidString: savedUUID)
            }
        }
        print("Extension Loaded - Width: \(printerWidth)")
    }

    private func handleIncomingContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        let dispatchGroup = DispatchGroup()
        
        for provider in attachments {
            dispatchGroup.enter()
            
            // Check for PDF
            if provider.hasItemConformingToTypeIdentifier(kUTTypePDF as String) {
                provider.loadItem(forTypeIdentifier: kUTTypePDF as String, options: nil) { [weak self] (data, error) in
                    if let url = data as? URL {
                        self?.processPdf(url: url)
                    }
                    dispatchGroup.leave()
                }
            } 
            // Check for Image
            else if provider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                provider.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { [weak self] (data, error) in
                    if let url = data as? URL, let image = UIImage(contentsOfFile: url.path) {
                        self?.processImage(image: image)
                    } else if let image = data as? UIImage {
                        self?.processImage(image: image)
                    }
                    dispatchGroup.leave()
                }
            } else {
                dispatchGroup.leave()
            }
        }
    }

    // MARK: - Processing
    
    private func processPdf(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return }
        
        self.textView.text = "Rendering PDF..."
        
        // Render PDF to Images & Convert to ESC/POS
        var allData: [UInt8] = []
        allData.append(contentsOf: printerHelper.INIT_PRINTER)
        
        let pageCount = min(document.numberOfPages, 10) // Limit pages for extension memory safety
        
        for i in 1...pageCount {
            guard let page = document.page(at: i) else { continue }
            
            let pageRect = page.getBoxRect(.mediaBox)
            let scale = CGFloat(printerWidth) / pageRect.width
            let targetHeight = Int(pageRect.height * scale)
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            
            guard let context = CGContext(data: nil,
                                          width: printerWidth,
                                          height: targetHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { continue }
            
            context.interpolationQuality = .high
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: printerWidth, height: targetHeight))
            
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1.0, y: -1.0)
            context.drawPDFPage(page)
            context.restoreGState()
            
            if let cgImage = context.makeImage() {
                let uiImage = UIImage(cgImage: cgImage)
                // Trim & Resize
                if let trimmed = uiImage.trim()?.resize(to: printerWidth) {
                    let escData = trimmed.convertToEscPos(width: printerWidth)
                    allData.append(contentsOf: escData)
                }
            }
        }
        
        allData.append(contentsOf: printerHelper.FEED_PAPER)
        allData.append(contentsOf: printerHelper.CUT_PAPER)
        
        printToBluetooth(data: allData)
    }
    
    private func processImage(image: UIImage) {
        self.textView.text = "Processing Image..."
        
        var allData: [UInt8] = []
        allData.append(contentsOf: printerHelper.INIT_PRINTER)
        
        if let resized = image.resize(to: printerWidth).trim() {
             // Re-resize after trim to ensure width is exact
             let final = resized.resize(to: printerWidth)
             let escData = final.convertToEscPos(width: printerWidth)
             allData.append(contentsOf: escData)
        }
        
        allData.append(contentsOf: printerHelper.FEED_PAPER)
        allData.append(contentsOf: printerHelper.CUT_PAPER)
        
        printToBluetooth(data: allData)
    }
    
    private func printToBluetooth(data: [UInt8]) {
        DispatchQueue.main.async {
            self.textView.text = "Connecting to Printer..."
        }
        
        printerHelper.connectAndPrint(data: data) { success, message in
            DispatchQueue.main.async {
                if success {
                    self.textView.text = "Printed Successfully!"
                    // Delay slightly to let user see message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                    }
                } else {
                    self.textView.text = "Error: \(message)"
                    // Enable Post button to allow retry or cancel
                    self.navigationController?.navigationBar.topItem?.rightBarButtonItem?.isEnabled = true
                }
            }
        }
    }

    // Required overrides
    override func isContentValid() -> Bool { return true }
    override func didSelectPost() {
        // Retry logic if needed
    }
    override func configurationItems() -> [Any]! { return [] }
}

// MARK: - Bluetooth Helper (Internal)
class BluetoothPrinterHelper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    var centralManager: CBCentralManager!
    var targetPeripheral: CBPeripheral?
    var writeCharacteristic: CBCharacteristic?
    var dataToPrint: [UInt8] = []
    var completion: ((Bool, String) -> Void)?
    var targetUUID: UUID? // The UUID of the printer paired in main app
    
    let INIT_PRINTER: [UInt8] = [0x1B, 0x40]
    let FEED_PAPER: [UInt8] = [0x1B, 0x64, 0x04]
    let CUT_PAPER: [UInt8] = [0x1D, 0x56, 0x42, 0x00]
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func connectAndPrint(data: [UInt8], completion: @escaping (Bool, String) -> Void) {
        self.dataToPrint = data
        self.completion = completion
        
        if centralManager.state == .poweredOn {
            startScan()
        } else {
            // If BT is off, delegate will trigger scan when it turns on
        }
    }
    
    func startScan() {
        // Scan for peripherals.
        // If we have a saved UUID, we can try to retrieve it directly
        if let uuid = targetUUID, let known = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            print("Found known peripheral: \(known)")
            connect(peripheral: known)
        } else {
            // Otherwise scan broadly (battery intensive, but necessary if UUID unknown)
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
        
        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if self.targetPeripheral == nil {
                self.centralManager.stopScan()
                self.completion?(false, "Printer not found")
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        
        // Simple logic: Connect to devices named "Printer" or similar if no specific UUID saved
        // OR match the saved UUID
        
        if let target = targetUUID, peripheral.identifier == target {
            connect(peripheral: peripheral)
        } else if targetUUID == nil && (name.contains("Printer") || name.contains("MTP") || name.contains("Inner")) {
            connect(peripheral: peripheral)
        }
    }
    
    func connect(peripheral: CBPeripheral) {
        centralManager.stopScan()
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = char
                sendData()
                return
            }
        }
    }
    
    func sendData() {
        guard let p = targetPeripheral, let c = writeCharacteristic else { return }
        
        let chunkSize = 180
        for i in stride(from: 0, to: dataToPrint.count, by: chunkSize) {
            let end = min(i + chunkSize, dataToPrint.count)
            let chunk = Data(dataToPrint[i..<end])
            let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(chunk, for: c, type: type)
            usleep(15000) // Small delay to prevent buffer overflow
        }
        
        // Finish
        centralManager.cancelPeripheralConnection(p)
        completion?(true, "Done")
    }
}

// MARK: - Image Processing Extensions
extension UIImage {
    
    func resize(to width: Int) -> UIImage {
        let scale = CGFloat(width) / self.size.width
        let newHeight = self.size.height * scale
        let newSize = CGSize(width: CGFloat(width), height: newHeight)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: newSize))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage ?? self
    }
    
    func trim() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: height * width * 4)
        
        guard let context = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        var minX = width, maxX = 0, minY = height, maxY = 0, found = false
        let threshold: UInt8 = 240
        
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if rawData[i] < threshold || rawData[i+1] < threshold || rawData[i+2] < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    found = true
                }
            }
        }
        
        if !found { return nil }
        
        // Add Padding
        let padding = 5
        minX = max(0, minX - padding); maxX = min(width, maxX + padding)
        minY = max(0, minY - padding); maxY = min(height, maxY + padding + 40)
        
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
    
    func convertToEscPos(width: Int) -> [UInt8] {
        guard let inputCGImage = self.cgImage else { return [] }
        let height = inputCGImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var rawData = [UInt8](repeating: 0, count: height * width * 4)
        
        guard let context = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return [] }
        
        context.draw(inputCGImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        // Grayscale & Dither (Floyd-Steinberg)
        var grayPlane = [Int](repeating: 0, count: width * height)
        
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(rawData[offset])
            let g = Double(rawData[offset+1])
            let b = Double(rawData[offset+2])
            // High contrast
            let rC = max(0, min(255, r * 1.2 - 20))
            let gC = max(0, min(255, g * 1.2 - 20))
            let bC = max(0, min(255, b * 1.2 - 20))
            grayPlane[i] = Int(0.299 * rC + 0.587 * gC + 0.114 * bC)
        }
        
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let oldPixel = grayPlane[i]
                let newPixel = oldPixel < 128 ? 0 : 255
                grayPlane[i] = newPixel
                let error = Double(oldPixel - newPixel)
                
                if x + 1 < width { grayPlane[i + 1] = clamp(Double(grayPlane[i + 1]) + error * 7.0 / 16.0) }
                if y + 1 < height {
                    if x - 1 >= 0 { grayPlane[i + width - 1] = clamp(Double(grayPlane[i + width - 1]) + error * 3.0 / 16.0) }
                    grayPlane[i + width] = clamp(Double(grayPlane[i + width]) + error * 5.0 / 16.0)
                    if x + 1 < width { grayPlane[i + width + 1] = clamp(Double(grayPlane[i + width + 1]) + error * 1.0 / 16.0) }
                }
            }
        }
        
        // Bit Packing (GS v 0)
        let widthBytes = (width + 7) / 8
        var escData: [UInt8] = [0x1D, 0x76, 0x30, 0x00, UInt8(widthBytes % 256), UInt8(widthBytes / 256), UInt8(height % 256), UInt8(height / 256)]
        
        for y in 0..<height {
            for xByte in 0..<widthBytes {
                var byteValue: UInt8 = 0
                for bit in 0..<8 {
                    let x = xByte * 8 + bit
                    if x < width && grayPlane[y * width + x] == 0 {
                        byteValue |= (1 << (7 - bit))
                    }
                }
                escData.append(byteValue)
            }
        }
        return escData
    }
    
    private func clamp(_ value: Double) -> Int {
        return Int(max(0, min(255, value)))
    }
}