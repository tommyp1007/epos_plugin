package com.example.epos_print_plugin

import android.app.NotificationChannel
import android.app.NotificationManager
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
import android.os.PowerManager
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
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max
import kotlin.math.min

class MyPrintService : PrintService() {

    companion object {
        private const val TAG = "EposPrinterService"
        private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        
        // NOTIFICATION CONFIG
        private const val CHANNEL_ID = "epos_print_channel"
        private const val NOTIFICATION_ID = 8888
        
        // WIDTH CONFIGURATION
        private const val WIDTH_58MM = 384
        private const val WIDTH_80MM = 576
        
        // ESC/POS COMMANDS
        private val INIT_PRINTER = byteArrayOf(0x1B, 0x40)
        private val FEED_PAPER = byteArrayOf(0x1B, 0x64, 0x04) 
        private val CUT_PAPER = byteArrayOf(0x1D, 0x56, 0x42, 0x00)
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // TRACKING QUEUE SIZE
    private val activeJobCount = AtomicInteger(0)
    
    // Volatile flag to control the input stream reader thread
    @Volatile
    private var isReaderRunning = false

    // --- HELPER TO GET LANGUAGE FROM FLUTTER SHARED PREFS ---
    private fun getCurrentLanguage(): String {
        // "FlutterSharedPreferences" is the default XML file name used by the Flutter plugin
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        // Flutter prefixes keys with "flutter.", so we read "flutter.language_code"
        return prefs.getString("flutter.language_code", "en") ?: "en"
    }

    // --- NOTIFICATION MANAGER SETUP ---
    private fun updateServiceNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val langCode = getCurrentLanguage()

        // Localized Strings for Notification Channel
        val channelName = if (langCode == "ms") "Status Perkhidmatan Pencetak" else "Printer Service Status"
        val channelDesc = if (langCode == "ms") "Menunjukkan status giliran pencetak aktif" else "Shows active printer queue status"

        // 1. Create Channel (Android 8+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                channelName,
                NotificationManager.IMPORTANCE_LOW // Low importance = No sound, just visual
            )
            channel.description = channelDesc
            notificationManager.createNotificationChannel(channel)
        }

        // 2. Manage Notification
        val currentCount = activeJobCount.get()
        
        if (currentCount > 0) {
            // Localized Strings for Notification Content
            val notifTitle = if (langCode == "ms") "Pencetak e-Pos Sedang Berjalan" else "e-Pos Printer Running"
            val notifText = if (langCode == "ms") 
                "Mencetak di latar belakang... ($currentCount dalam giliran)" 
            else 
                "Printing in background... ($currentCount in queue)"

            // SHOW NOTIFICATION
            val builder = NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download) // Or your app icon
                .setContentTitle(notifTitle)
                .setContentText(notifText)
                .setOngoing(false) // FALSE means user CAN swipe it away if they want
                .setProgress(0, 0, true) // Indeterminate progress bar
                .setPriority(NotificationCompat.PRIORITY_LOW)

            try {
                notificationManager.notify(NOTIFICATION_ID, builder.build())
            } catch (e: SecurityException) {
                Log.e(TAG, "Notification permission missing")
            }
        } else {
            // CANCEL NOTIFICATION (Queue empty)
            notificationManager.cancel(NOTIFICATION_ID)
        }
    }

    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession {
        return object : PrinterDiscoverySession() {
            override fun onStartPrinterDiscovery(priorityList: List<PrinterId>) {
                // =========================================================================
                // 1. SECURITY CHECK: IS USER LOGGED IN?
                // =========================================================================
                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val isLoggedIn = prefs.getBoolean("flutter.is_logged_in", false)
                
                // Get Fresh Language
                val langCode = getCurrentLanguage()

                // Localized Strings for Auth
                val authLabel = if (langCode == "ms") "Log Masuk Diperlukan" else "Login Required"
                val loginRequiredTitle = if (langCode == "ms") "MyInvois e-Pos: Log Masuk Diperlukan" else "MyInvois e-Pos: Login Required"
                val loginRequiredDesc = if (langCode == "ms") "Sila log masuk ke aplikasi MyInvois e-Pos untuk mengaktifkan cetakan." else "Please login to the MyInvois e-Pos app to enable printing."

                // Define dummy capabilities for the Auth message
                val mediaAuth = MediaSize("AUTH_MSG", authLabel, 2000, 2000)
                val resAuth = Resolution("R1", "200dpi", 200, 200)

                if (!isLoggedIn) {
                    // --- ACCESS DENIED: User is not logged in ---
                    // We add a dummy "Unavailable" printer to Grey Out the service.
                    val authId = generatePrinterId("auth_required")
                    
                    val capsBuilder = PrinterCapabilitiesInfo.Builder(authId)
                    capsBuilder.addMediaSize(mediaAuth, true)
                    capsBuilder.addResolution(resAuth, true)
                    capsBuilder.setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)

                    val authPrinter = PrinterInfo.Builder(
                        authId, 
                        loginRequiredTitle, // Name visible to user
                        PrinterInfo.STATUS_UNAVAILABLE // This Greys it out / marks unavailable
                    )
                    .setDescription(loginRequiredDesc)
                    .setCapabilities(capsBuilder.build())
                    .build()

                    // Add only this printer and STOP processing.
                    addPrinters(listOf(authPrinter))
                    return
                }

                // =========================================================================
                // 2. USER IS LOGGED IN: PROCEED WITH ACTUAL DISCOVERY
                // =========================================================================
                val printers = ArrayList<PrinterInfo>()
                val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()

                // --- 1. GET PREFERENCES ---
                val activeMac = prefs.getString("flutter.selected_printer_mac", "") ?: ""

                // 2. HARDWARE DETECTION
                val manufacturer = Build.MANUFACTURER.uppercase()
                val model = Build.MODEL.uppercase()
                val isSunmiHandheld = manufacturer.contains("SUNMI") && 
                                     (model.contains("V3") || model.contains("V2") || model.contains("P2"))

                // 3. DEFINE MEDIA SIZES (TRANSLATED)
                val labelSmall = if (langCode == "ms") "58mm (Kecil)" else "58mm (Small)"
                val labelLarge = if (langCode == "ms") "80mm (Besar)" else "80mm (Large)"
                val labelSetting = if (langCode == "ms") "Tetapan Pencetak MyInvois e-Pos" else "MyInvois e-Pos Printer"
                val labelStandard = if (langCode == "ms") "Standard (203 dpi)" else "Standard (203 dpi)"

                val mediaSunmi58 = MediaSize("SUNMI_58", labelSmall, 2280, 50000)
                val mediaSunmi80 = MediaSize("SUNMI_80", labelLarge, 3150, 50000)
                val mediaEpos = MediaSize("EPOS_SETTING", labelSetting, 3150, 23620)
                val res203 = Resolution("R203", labelStandard, 203, 203)

                fun addBluetoothPrinters() {
                    if (bluetoothAdapter != null && bluetoothAdapter.isEnabled) {
                        try {
                            val bondedDevices = bluetoothAdapter.bondedDevices
                            for (device in bondedDevices) {
                                if (activeMac.isNotEmpty() && device.address != activeMac) continue 

                                val printerId = generatePrinterId(device.address)
                                val capsBuilder = PrinterCapabilitiesInfo.Builder(printerId)
                                
                                val unknownName = if (langCode == "ms") "Tidak Diketahui" else "Unknown"
                                val devName = (device.name ?: unknownName).uppercase()
                                
                                val likely80mm = devName.contains("80") || devName.contains("MTP-3") || devName.contains("T80")
                                val likely58mm = devName.contains("58") || 
                                                 devName.contains("MTP-2") || 
                                                 devName.contains("MTP-II") || 
                                                 devName.contains("BLUETOOTH PRINTER") ||
                                                 devName.contains("KPRINTER") ||
                                                 isSunmiHandheld 

                                if (likely80mm) {
                                    capsBuilder.addMediaSize(mediaSunmi80, false)
                                    capsBuilder.addMediaSize(mediaSunmi58, false)
                                } else {
                                    capsBuilder.addMediaSize(mediaSunmi58, false) 
                                    capsBuilder.addMediaSize(mediaSunmi80, false)
                                }
                                
                                capsBuilder.addMediaSize(mediaEpos, true)
                                capsBuilder.setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
                                capsBuilder.addResolution(res203, true)
                                capsBuilder.setMinMargins(PrintAttributes.Margins(0, 0, 0, 0))

                                val defaultName = if (langCode == "ms") "Pencetak BT" else "BT Printer"
                                printers.add(PrinterInfo.Builder(printerId, device.name ?: defaultName, PrinterInfo.STATUS_IDLE)
                                    .setCapabilities(capsBuilder.build()).build())
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
                    capsBuilder.addMediaSize(mediaEpos, true)
                    capsBuilder.setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
                    capsBuilder.addResolution(res203, true)
                    capsBuilder.setMinMargins(PrintAttributes.Margins(0, 0, 0, 0))
                    
                    val noPrinterText = if (langCode == "ms") "Tiada Pencetak Ditemui" else "No Printer Found"
                    
                    printers.add(PrinterInfo.Builder(dummyId, noPrinterText, PrinterInfo.STATUS_IDLE)
                        .setCapabilities(capsBuilder.build()).build())
                }
                
                // Add the actual printers (this replaces the auth printer if it was there)
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

        val langCode = getCurrentLanguage()
        val info = printJob.info
        val printerId = info.printerId
        val rawFileDescriptor = printJob.document.data 

        if (printerId == null || rawFileDescriptor == null) {
            val errorMsg = if (langCode == "ms") "Data Kerja Tidak Sah" else "Invalid Job Data"
            printJob.fail(errorMsg)
            return
        }

        printJob.start()

        // --- INCREMENT QUEUE & SHOW NOTIFICATION ---
        activeJobCount.incrementAndGet()
        updateServiceNotification()

        executor.execute {
            var socket: BluetoothSocket? = null
            var success = false
            var errorMessage = ""
            var tempFile: File? = null
            var seekablePfd: ParcelFileDescriptor? = null
            var wakeLock: PowerManager.WakeLock? = null

            try {
                // --- WAKELOCK ---
                try {
                    val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                    wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "EposPrinter:QueueLock")
                    wakeLock.acquire(180 * 1000L)
                } catch (e: Exception) {
                    Log.e(TAG, "WakeLock Error: ${e.message}")
                }

                val macAddress = printerId.localId
                
                // --- WIDTH DETECTION ---
                var printerName = "Unknown"
                if (macAddress != "sunmi_virtual" && macAddress != "auth_required") {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    val device = adapter.getRemoteDevice(macAddress)
                    printerName = (device.name ?: "Unknown").uppercase()
                }

                val manufacturer = Build.MANUFACTURER.uppercase()
                val model = Build.MODEL.uppercase()
                val isSunmiV3 = manufacturer.contains("SUNMI") && (model.contains("V3") || model.contains("V2"))

                val isGeneric58mm = printerName.contains("58") || 
                                    printerName.contains("MTP-2") || 
                                    printerName.contains("MTP-II") || 
                                    printerName.contains("BLUETOOTH PRINTER") ||
                                    printerName.contains("KPRINTER")

                val isGeneric80mm = printerName.contains("80") || printerName.contains("MTP-3") || 
                                    printerName.contains("T80")

                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val savedWidth = prefs.getLong("flutter.printer_width_dots", -1L)
                val attributes = info.attributes
                val selectedMediaId = attributes.mediaSize?.id ?: ""
                
                var targetWidth: Int

                if (savedWidth > 0) {
                    targetWidth = savedWidth.toInt()
                } 
                else if (selectedMediaId == "SUNMI_80") {
                    targetWidth = WIDTH_80MM
                } 
                else if (selectedMediaId == "SUNMI_58") {
                    targetWidth = WIDTH_58MM
                }
                else {
                    if (isGeneric80mm) {
                        targetWidth = WIDTH_80MM
                    } else if (isGeneric58mm || isSunmiV3) {
                        targetWidth = WIDTH_58MM
                    } else {
                        targetWidth = WIDTH_58MM 
                    }
                    if (selectedMediaId == "EPOS_SETTING" && !isGeneric58mm && !isSunmiV3 && isGeneric80mm) {
                         targetWidth = WIDTH_80MM
                    }
                }

                tempFile = File(cacheDir, "web_print_${System.currentTimeMillis()}.pdf")
                seekablePfd = transferToTempFile(rawFileDescriptor, tempFile)

                // Silent success for dummy printers
                if (macAddress == "sunmi_virtual" || macAddress == "auth_required") {
                      Thread.sleep(1000)
                      success = true 
                } else {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    val device: BluetoothDevice = adapter.getRemoteDevice(macAddress)
                    
                    // --- ROBUST CONNECT LOGIC ---
                    try {
                        socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                        socket.connect()
                    } catch (e: Exception) {
                        Log.w(TAG, "Secure connect failed, trying Insecure...")
                        try {
                            socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                            socket.connect()
                        } catch (e2: Exception) {
                            val connFailText = if (langCode == "ms") "Sambungan Gagal: " else "Connection Failed: "
                            errorMessage = "$connFailText${e2.message}"
                            return@execute 
                        }
                    }

                    if (socket?.isConnected == true) {
                        val outputStream = socket!!.outputStream
                        val inputStream = socket!!.inputStream

                        // --- INPUT DRAINER ---
                        startInputDrainer(inputStream)

                        // Wake up sequence
                        Thread.sleep(500) 
                        outputStream.write(byteArrayOf(0x00, 0x00, 0x00))
                        Thread.sleep(100)
                        outputStream.write(INIT_PRINTER)
                        Thread.sleep(100) 

                        val hasContent = processPdfAndPrint(seekablePfd, outputStream, targetWidth)

                        if (hasContent) {
                            outputStream.write(FEED_PAPER)
                            outputStream.write(CUT_PAPER)
                        } else {
                            val skipText = if (langCode == "ms") "Langkau Cetak - Halaman Kosong" else "Skipping Print - Page was Blank"
                            Log.d(TAG, skipText)
                        }

                        try { Thread.sleep(1500) } catch (e: InterruptedException) { }
                        
                        isReaderRunning = false
                        outputStream.flush()
                        socket!!.close()
                        success = true
                    }
                }

            } catch (e: Exception) {
                val errPrefix = if (langCode == "ms") "Ralat: " else "Error: "
                errorMessage = "$errPrefix${e.message}"
                Log.e(TAG, errorMessage, e)
            } finally {
                // Cleanup
                isReaderRunning = false
                try { socket?.close() } catch (e: IOException) { }
                try { seekablePfd?.close() } catch (e: IOException) { }
                try { rawFileDescriptor?.close() } catch (e: IOException) { }
                tempFile?.delete()
                
                if (wakeLock != null && wakeLock!!.isHeld) {
                    try { wakeLock!!.release() } catch (e: Exception) { }
                }
                
                activeJobCount.decrementAndGet()
                updateServiceNotification()

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

    private fun startInputDrainer(inputStream: InputStream) {
        isReaderRunning = true
        Thread {
            val buffer = ByteArray(1024)
            while (isReaderRunning) {
                try {
                    if (inputStream.available() > 0) {
                        inputStream.read(buffer)
                    } else {
                        Thread.sleep(50)
                    }
                } catch (e: IOException) {
                    isReaderRunning = false
                } catch (e: InterruptedException) {
                    isReaderRunning = false
                }
            }
        }.start()
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
            if (Thread.currentThread().isInterrupted) break

            val page = renderer.openPage(i)
            
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

            val trimmedBitmap = trimWhiteSpace(tempBitmap)
            
            if (trimmedBitmap == null) {
                tempBitmap.recycle()
                continue
            }

            val finalHeight = (trimmedBitmap.height * (targetWidthPx.toFloat() / trimmedBitmap.width)).toInt()
            val finalBitmap = Bitmap.createScaledBitmap(trimmedBitmap, targetWidthPx, max(1, finalHeight), true)
            
            if (finalBitmap != trimmedBitmap) {
                trimmedBitmap.recycle()
            }

            if (finalBitmap.height > 0) {
                try {
                    val ditheredBytes = convertBitmapToEscPos(finalBitmap)
                    writeWithSplitting(outputStream, ditheredBytes, finalBitmap.width, finalBitmap.height)
                    anyPagePrinted = true
                } catch (e: IOException) {
                    Log.e(TAG, "Print transmission failed", e)
                    break 
                }
            }
            
            if (!finalBitmap.isRecycled) finalBitmap.recycle()
            if (!tempBitmap.isRecycled) tempBitmap.recycle()

            try { Thread.sleep(200) } catch (e: InterruptedException) { }
        }
        renderer.close()
        return anyPagePrinted
    }

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

        val darknessThreshold = 240
        val minDarkPixelsPerRow = 2 

        for (y in 0 until height) {
            var darkPixelsInRow = 0
            for (x in 0 until width) {
                val pixel = pixels[y * width + x]
                val r = (pixel shr 16) and 0xFF
                if (r < darknessThreshold) {
                    darkPixelsInRow++
                }
            }

            if (darkPixelsInRow >= minDarkPixelsPerRow) {
                foundContent = true
                if (y < minY) minY = y
                if (y > maxY) maxY = y
                
                for (x in 0 until width) {
                    val pixel = pixels[y * width + x]
                    val r = (pixel shr 16) and 0xFF
                    if (r < darknessThreshold) { 
                        if (x < minX) minX = x
                        if (x > maxX) maxX = x
                    }
                }
            }
        }

        if (!foundContent) return null 

        val padding = 5
        minX = max(0, minX - padding)
        maxX = min(width, maxX + padding)
        minY = max(0, minY - padding)
        maxY = min(height, maxY + padding + 40) 

        val trimWidth = maxX - minX
        val trimHeight = maxY - minY
        
        if (trimWidth <= 0 || trimHeight <= 0) return null

        return Bitmap.createBitmap(source, minX, minY, trimWidth, trimHeight)
    }

    private fun writeWithSplitting(outputStream: OutputStream, data: ByteArray, width: Int, height: Int) {
        val widthBytes = (width + 7) / 8
        val linesPerChunk = 30 
        
        var currentY = 0
        var offset = 0
        
        while (currentY < height) {
            val linesToSend = min(linesPerChunk, height - currentY)
            val chunkDataSize = linesToSend * widthBytes
            
            val header = byteArrayOf(
                0x1D, 0x76, 0x30, 0x00,
                (widthBytes % 256).toByte(), (widthBytes / 256).toByte(),
                (linesToSend % 256).toByte(), (linesToSend / 256).toByte()
            )
            
            outputStream.write(header)
            outputStream.write(data, offset, chunkDataSize)
            outputStream.flush()
            
            offset += chunkDataSize
            currentY += linesToSend
            
            try { Thread.sleep(60) } catch (e: InterruptedException) { }
        }
    }

    private fun convertBitmapToEscPos(bitmap: Bitmap): ByteArray {
        val width = bitmap.width
        val height = bitmap.height
        val widthBytes = (width + 7) / 8
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        
        val data = ByteArray(widthBytes * height)
        var dataIndex = 0
        
        val grayPlane = IntArray(width * height)
        for (i in 0 until width * height) {
            val c = pixels[i]
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            grayPlane[i] = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
        }

        for (y in 0 until height) {
            for (x in 0 until width) {
                val i = y * width + x
                val oldPixel = grayPlane[i]
                val newPixel = if (oldPixel < 128) 0 else 255
                grayPlane[i] = newPixel 
                val error = oldPixel - newPixel
                if (x + 1 < width) grayPlane[i + 1] = clamp(grayPlane[i + 1] + (error * 7 / 16))
                if (y + 1 < height) {
                    if (x - 1 >= 0) grayPlane[i + width - 1] = clamp(grayPlane[i + width - 1] + (error * 3 / 16))
                    grayPlane[i + width] = clamp(grayPlane[i + width] + (error * 5 / 16))
                    if (x + 1 < width) grayPlane[i + width + 1] = clamp(grayPlane[i + width + 1] + (error * 1 / 16))
                }
            }
        }

        for (y in 0 until height) {
            val rowStart = y * width
            for (xByte in 0 until widthBytes) {
                var byteValue = 0
                for (bit in 0 until 8) {
                    val x = xByte * 8 + bit
                    if (x < width && grayPlane[rowStart + x] == 0) {
                        byteValue = byteValue or (1 shl (7 - bit))
                    }
                }
                data[dataIndex++] = byteValue.toByte()
            }
        }
        return data
    }

    private fun clamp(value: Int): Int = if (value < 0) 0 else if (value > 255) 255 else value

    override fun onRequestCancelPrintJob(printJob: PrintJob) {
        try { printJob.cancel() } catch (e: Exception) { Log.e(TAG, "Cancel failed", e) }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        isReaderRunning = false
        executor.shutdown()
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_ID)
    }
}