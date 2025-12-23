package com.example.epos_print_plugin // TODO: Make sure this matches your folder structure

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PrintAttributes
import android.print.PrintAttributes.MediaSize
import android.print.PrintAttributes.Resolution
import android.print.PrinterCapabilitiesInfo
import android.print.PrinterId
import android.print.PrinterInfo
import android.printservice.PrintJob
import android.printservice.PrintService
import android.printservice.PrinterDiscoverySession
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

class MyPrintService : PrintService() {

    companion object {
        private const val TAG = "MyPrintService"
        private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        
        // =================================================================
        // WIDTH CONFIGURATION
        // =================================================================
        private const val WIDTH_58MM = 384
        private const val WIDTH_80MM = 576
        
        // ESC/POS Commands
        private val INIT_PRINTER = byteArrayOf(0x1B, 0x40)
        private val FEED_PAPER = byteArrayOf(0x1B, 0x64, 0x04) 
        private val CUT_PAPER = byteArrayOf(0x1D, 0x56, 0x42, 0x00)
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession {
        return object : PrinterDiscoverySession() {
            override fun onStartPrinterDiscovery(priorityList: List<PrinterId>) {
                val printers = ArrayList<PrinterInfo>()
                val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()

                // --- 1. GET SELECTED PRINTER FROM FLUTTER ---
                // We use the file name "FlutterSharedPreferences" and key "flutter.selected_printer_mac"
                // This is the standard way Flutter stores SharedPrefs on Android.
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val activeMac = prefs.getString("flutter.selected_printer_mac", "") ?: ""

                // 2. HARDWARE DETECTION (For Built-in Sunmi V3)
                val manufacturer = Build.MANUFACTURER.uppercase()
                val model = Build.MODEL.uppercase()
                val isSunmiHandheld = manufacturer.contains("SUNMI") && 
                                     (model.contains("V3") || model.contains("V2") || model.contains("P2"))

                // 3. DEFINE MEDIA SIZES
                val mediaSunmi58 = MediaSize("SUNMI_58", "58mm (Small)", 2280, 50000)
                val mediaSunmi80 = MediaSize("SUNMI_80", "80mm (Large)", 3150, 50000)
                
                // --- CUSTOM SETTING: "e-Pos System Setting" ---
                val mediaEpos = MediaSize("EPOS_SETTING", "e-Pos System Setting", 8270, 11690)
                val res203 = Resolution("R203", "Standard (203 dpi)", 203, 203)

                fun addBluetoothPrinters() {
                    if (bluetoothAdapter != null && bluetoothAdapter.isEnabled) {
                        try {
                            val bondedDevices = bluetoothAdapter.bondedDevices
                            for (device in bondedDevices) {
                                
                                // --- FILTERING LOGIC ---
                                // If Flutter has a connected device (activeMac is not empty),
                                // WE SKIP ALL OTHER DEVICES.
                                // This forces the Android Print Dialog to only see the connected printer,
                                // making it selected by default.
                                if (activeMac.isNotEmpty() && device.address != activeMac) {
                                    continue 
                                }

                                val printerId = generatePrinterId(device.address)
                                val capsBuilder = PrinterCapabilitiesInfo.Builder(printerId)
                                
                                val devName = (device.name ?: "Unknown").uppercase()
                                
                                val likely80mm = devName.contains("80") || devName.contains("MTP-3") || devName.contains("T80")
                                val likely58mm = devName.contains("58") || devName.contains("MTP-2") || devName.contains("MTP-II") 
                                                                             || devName.contains("BLUETOOTH PRINTER") 
                                                                             || isSunmiHandheld 

                                // We add the physical sizes as options (isDefault = false)
                                if (likely80mm) {
                                    capsBuilder.addMediaSize(mediaSunmi80, false)
                                    capsBuilder.addMediaSize(mediaSunmi58, false)
                                } else {
                                    capsBuilder.addMediaSize(mediaSunmi58, false) 
                                    capsBuilder.addMediaSize(mediaSunmi80, false)
                                }
                                
                                // --- DEFAULT MEDIA SETTING ---
                                // Set "e-Pos System Setting" as DEFAULT (true)
                                capsBuilder.addMediaSize(mediaEpos, true)
                                
                                capsBuilder.setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
                                capsBuilder.addResolution(res203, true)
                                capsBuilder.setMinMargins(PrintAttributes.Margins(0, 0, 0, 0))

                                val info = PrinterInfo.Builder(
                                    printerId, 
                                    device.name ?: "BT Printer", 
                                    PrinterInfo.STATUS_IDLE
                                ).setCapabilities(capsBuilder.build()).build()

                                printers.add(info)
                            }
                        } catch (e: SecurityException) {
                            Log.e(TAG, "Permission denied")
                        }
                    }
                }

                addBluetoothPrinters()
                
                if (printers.isEmpty()) {
                    val dummyId = generatePrinterId("sunmi_virtual")
                    val capsBuilder = PrinterCapabilitiesInfo.Builder(dummyId)
                    
                    // Also set default here for virtual printer
                    capsBuilder.addMediaSize(mediaEpos, true)
                    
                    capsBuilder.setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
                    capsBuilder.addResolution(res203, true)
                    capsBuilder.setMinMargins(PrintAttributes.Margins(0, 0, 0, 0))
                    
                    printers.add(PrinterInfo.Builder(dummyId, "No Printer Found", PrinterInfo.STATUS_IDLE)
                        .setCapabilities(capsBuilder.build()).build())
                }
                addPrinters(printers)
            }
            override fun onStopPrinterDiscovery() {}
            override fun onValidatePrinters(printerIds: List<PrinterId>) {}
            override fun onStartPrinterStateTracking(printerId: PrinterId) {}
            override fun onStopPrinterStateTracking(printerId: PrinterId) {}
            override fun onDestroy() {}
        }
    }

    override fun onPrintJobQueued(printJob: PrintJob) {
        if (printJob.isCancelled) {
            printJob.cancel()
            return
        }

        val info = printJob.info
        val printerId = info.printerId
        val rawFileDescriptor = printJob.document.data 

        if (printerId == null || rawFileDescriptor == null) {
            printJob.fail("Invalid Job Data")
            return
        }

        printJob.start()

        executor.execute {
            var socket: BluetoothSocket? = null
            var success = false
            var errorMessage = ""
            var tempFile: File? = null
            var seekablePfd: ParcelFileDescriptor? = null

            try {
                val macAddress = printerId.localId
                
                // =================================================================
                // 4. SMART AUTO DETECT WIDTH logic
                // =================================================================
                var printerName = "Unknown"
                if (macAddress != "sunmi_virtual") {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    val device = adapter.getRemoteDevice(macAddress)
                    printerName = (device.name ?: "Unknown").uppercase()
                }

                val manufacturer = Build.MANUFACTURER.uppercase()
                val model = Build.MODEL.uppercase()
                val isSunmiV3 = manufacturer.contains("SUNMI") && (model.contains("V3") || model.contains("V2"))

                val isGeneric58mm = printerName.contains("58") || printerName.contains("MTP-2") || 
                                    printerName.contains("MTP-II") || printerName.contains("BLUETOOTH PRINTER") 

                val isGeneric80mm = printerName.contains("80") || printerName.contains("MTP-3") || 
                                    printerName.contains("T80")

                // Shared Preferences Check
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val savedWidth = prefs.getLong("flutter.printer_width_dots", -1L)
                val attributes = info.attributes
                val selectedMediaId = attributes.mediaSize?.id ?: ""
                
                var targetWidth: Int

                if (savedWidth > 0) {
                    targetWidth = savedWidth.toInt()
                    Log.d(TAG, "Width: Manual Override -> $targetWidth")
                } 
                else if (selectedMediaId == "SUNMI_80") {
                    targetWidth = WIDTH_80MM
                } 
                else if (selectedMediaId == "SUNMI_58") {
                    targetWidth = WIDTH_58MM
                }
                else {
                    // Default logic fallback if EPOS_SETTING is selected but no manual override exists
                    if (isGeneric80mm) {
                        targetWidth = WIDTH_80MM
                    } else if (isGeneric58mm || isSunmiV3) {
                        targetWidth = WIDTH_58MM
                    } else {
                        targetWidth = WIDTH_58MM 
                    }
                }

                tempFile = File(cacheDir, "web_print.pdf")
                seekablePfd = transferToTempFile(rawFileDescriptor, tempFile)

                if (macAddress == "sunmi_virtual") {
                      Thread.sleep(1000)
                      success = true
                } else {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    val device: BluetoothDevice = adapter.getRemoteDevice(macAddress)
                    
                    try {
                        socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                        socket.connect()
                    } catch (e: Exception) {
                        errorMessage = "Connection Failed: ${e.message}"
                        return@execute 
                    }

                    if (socket.isConnected) {
                        val outputStream = socket.outputStream
                        outputStream.write(INIT_PRINTER)
                        Thread.sleep(50)

                        // If process returns false (blank page), we don't cut paper
                        val hasContent = processPdfAndPrint(seekablePfd, outputStream, targetWidth)

                        if (hasContent) {
                            outputStream.write(FEED_PAPER)
                            outputStream.write(CUT_PAPER)
                        } else {
                            Log.d(TAG, "Skipping Print - Page was Blank")
                        }

                        try { Thread.sleep(1000) } catch (e: InterruptedException) { }
                        outputStream.flush()
                        socket.close()
                        success = true
                    }
                }

            } catch (e: Exception) {
                errorMessage = "Error: ${e.message}"
                Log.e(TAG, errorMessage, e)
            } finally {
                try { socket?.close() } catch (e: IOException) { }
                try { seekablePfd?.close() } catch (e: IOException) { }
                try { rawFileDescriptor?.close() } catch (e: IOException) { }
                tempFile?.delete()
                
                mainHandler.post {
                    if (success) {
                        if (!printJob.isCancelled) printJob.complete()
                    } else {
                        printJob.fail(errorMessage)
                    }
                }
            }
        }
    }

    @Throws(IOException::class)
    private fun transferToTempFile(inputPfd: ParcelFileDescriptor, outputFile: File): ParcelFileDescriptor {
        ParcelFileDescriptor.AutoCloseInputStream(inputPfd).use { input ->
            FileOutputStream(outputFile).use { output ->
                input.copyTo(output)
            }
        }
        return ParcelFileDescriptor.open(outputFile, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    // Returns TRUE if content was found and printed, FALSE if blank
    private fun processPdfAndPrint(
        fileDescriptor: ParcelFileDescriptor, 
        outputStream: OutputStream, 
        targetWidthPx: Int
    ): Boolean {
        val renderer = PdfRenderer(fileDescriptor)
        val pageCount = renderer.pageCount
        val pagesToPrint = min(pageCount, 20)
        var anyPagePrinted = false

        for (i in 0 until pagesToPrint) {
            val page = renderer.openPage(i)
            
            // 1. High-Res Capture
            val captureWidth = max(targetWidthPx * 2, 600) 
            val scale = captureWidth.toFloat() / page.width.toFloat()
            val captureHeight = (page.height * scale).toInt()

            val tempBitmap = Bitmap.createBitmap(captureWidth, captureHeight, Bitmap.Config.ARGB_8888)
            tempBitmap.eraseColor(Color.WHITE) 
            
            val paint = Paint()
            val cm = ColorMatrix()
            // High contrast filter
            cm.set(floatArrayOf(
                1.2f, 0f, 0f, 0f, -20f,
                0f, 1.2f, 0f, 0f, -20f,
                0f, 0f, 1.2f, 0f, -20f,
                0f, 0f, 0f, 1f, 0f
            ))
            paint.colorFilter = ColorMatrixColorFilter(cm)
            
            val matrix = Matrix()
            matrix.setScale(scale, scale)
            
            val canvas = Canvas(tempBitmap)
            page.render(tempBitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
            page.close()

            // 2. SMART AUTO-CROP
            val trimmedBitmap = trimWhiteSpace(tempBitmap)
            
            if (trimmedBitmap == null) {
                // Page was blank (or only noise)
                tempBitmap.recycle()
                continue
            }

            // 3. Scale to Printer Width
            val finalHeight = (trimmedBitmap.height * (targetWidthPx.toFloat() / trimmedBitmap.width)).toInt()
            val finalBitmap = Bitmap.createScaledBitmap(trimmedBitmap, targetWidthPx, max(1, finalHeight), true)
            
            if (finalBitmap != trimmedBitmap) {
                trimmedBitmap.recycle()
            }

            // 4. Send
            if (finalBitmap.height > 5) {
                val ditheredBytes = convertBitmapToEscPos(finalBitmap)
                writeWithSplitting(outputStream, ditheredBytes, finalBitmap.width, finalBitmap.height)
                anyPagePrinted = true
            }
            
            if (!finalBitmap.isRecycled) finalBitmap.recycle()
            if (!tempBitmap.isRecycled) tempBitmap.recycle()
        }
        renderer.close()
        return anyPagePrinted
    }

    /**
     * AUTO-ZOOM & CUT HELPER:
     * Returns NULL if the page is effectively blank/white/noise.
     * Returns Cropped Bitmap if content exists.
     */
    private fun trimWhiteSpace(source: Bitmap): Bitmap? {
        val width = source.width
        val height = source.height
        val pixels = IntArray(width * height)
        source.getPixels(pixels, 0, width, 0, 0, width, height)

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        var foundContent = false

        // --- NOISE FILTER THRESHOLDS ---
        // 1. Pixel Darkness: Must be darker than 128 (Mid Grey) to be valid
        val darknessThreshold = 128
        // 2. Line Noise: A horizontal line needs > 5 dark pixels to be "Content"
        val minDarkPixelsPerRow = 5

        for (y in 0 until height) {
            var darkPixelsInRow = 0
            
            // Scan row
            for (x in 0 until width) {
                val pixel = pixels[y * width + x]
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8) and 0xFF
                val b = pixel and 0xFF
                
                // Check if pixel is dark
                if (r < darknessThreshold || g < darknessThreshold || b < darknessThreshold) {
                    darkPixelsInRow++
                }
            }

            // If this row has enough dark pixels, we count it as content
            if (darkPixelsInRow > minDarkPixelsPerRow) {
                foundContent = true
                if (y < minY) minY = y
                if (y > maxY) maxY = y
                
                // We also need to find X bounds (we can approximate X bounds based on the valid row)
                // Re-scanning X is expensive, so strictly speaking we can optimize, 
                // but usually Y cropping is what matters for paper saving.
                // For X, we'll just check the whole valid row.
                for (x in 0 until width) {
                    val pixel = pixels[y * width + x]
                    val r = (pixel shr 16) and 0xFF
                    if (r < darknessThreshold) { // Simple check since we know row is valid
                        if (x < minX) minX = x
                        if (x > maxX) maxX = x
                    }
                }
            }
        }

        // --- BLANK PAGE CHECK ---
        if (!foundContent) return null 

        val padding = 5
        minX = max(0, minX - padding)
        maxX = min(width, maxX + padding)
        minY = max(0, minY - padding)
        maxY = min(height, maxY + padding + 40) // Bottom padding for cutter

        val trimWidth = maxX - minX
        val trimHeight = maxY - minY
        
        if (trimWidth <= 0 || trimHeight <= 0) return null

        return Bitmap.createBitmap(source, minX, minY, trimWidth, trimHeight)
    }

    private fun writeWithSplitting(outputStream: OutputStream, data: ByteArray, width: Int, height: Int) {
        val widthBytes = (width + 7) / 8
        val linesPerChunk = 200
        
        var currentY = 0
        var offset = 0
        
        while (currentY < height) {
            val linesToSend = min(linesPerChunk, height - currentY)
            val chunkDataSize = linesToSend * widthBytes
            
            outputStream.write(byteArrayOf(0x1D, 0x76, 0x30, 0x00))
            outputStream.write(byteArrayOf((widthBytes % 256).toByte(), (widthBytes / 256).toByte()))
            outputStream.write(byteArrayOf((linesToSend % 256).toByte(), (linesToSend / 256).toByte()))
            
            outputStream.write(data, offset, chunkDataSize)
            outputStream.flush()
            
            offset += chunkDataSize
            currentY += linesToSend
            
            try { Thread.sleep(30) } catch (e: InterruptedException) { }
        }
    }

    private fun convertBitmapToEscPos(bitmap: Bitmap): ByteArray {
        val width = bitmap.width
        val height = bitmap.height
        val widthBytes = (width + 7) / 8
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        
        val grayPixels = Array(height) { IntArray(width) }

        for (y in 0 until height) {
            for (x in 0 until width) {
                val color = pixels[y * width + x]
                val r = (color shr 16) and 0xFF
                val g = (color shr 8) and 0xFF
                val b = color and 0xFF
                
                var lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                
                if (lum > 215) {
                    lum = 255 
                } else if (lum < 130) {
                    lum = 0   
                }
                
                grayPixels[y][x] = lum
            }
        }

        // Dithering loop...
        for (y in 0 until height) {
            for (x in 0 until width) {
                val oldPixel = grayPixels[y][x]
                val newPixel = if (oldPixel < 128) 0 else 255
                grayPixels[y][x] = newPixel
                val quantError = oldPixel - newPixel

                if (x + 1 < width)
                    grayPixels[y][x + 1] = clamp(grayPixels[y][x + 1] + (quantError * 7 / 16))
                if (x - 1 >= 0 && y + 1 < height)
                    grayPixels[y + 1][x - 1] = clamp(grayPixels[y + 1][x - 1] + (quantError * 3 / 16))
                if (y + 1 < height)
                    grayPixels[y + 1][x] = clamp(grayPixels[y + 1][x] + (quantError * 5 / 16))
                if (x + 1 < width && y + 1 < height)
                    grayPixels[y + 1][x + 1] = clamp(grayPixels[y + 1][x + 1] + (quantError * 1 / 16))
            }
        }

        val data = ByteArray(widthBytes * height)
        var index = 0
        
        for (y in 0 until height) {
            for (x in 0 until widthBytes) {
                var byteValue = 0
                for (b in 0 until 8) {
                    val currentX = x * 8 + b
                    if (currentX < width) {
                        if (grayPixels[y][currentX] == 0) { 
                            byteValue = byteValue or (1 shl (7 - b))
                        }
                    }
                }
                data[index++] = byteValue.toByte()
            }
        }
        return data
    }

    private fun clamp(value: Int): Int {
        return max(0, min(255, value))
    }

    override fun onRequestCancelPrintJob(printJob: PrintJob) {
        try {
            printJob.cancel()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel print job", e)
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}