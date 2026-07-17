package com.example.api_selfxo_project

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.net.Uri
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.KeyguardManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.PowerManager
import android.provider.Settings

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val PRINTER_CHANNEL = "com.whimsicaldev/epson_usb"
    private val USB_EVENT_CHANNEL = "com.whimsicaldev/usb_events"
    private val POWER_CHANNEL = "com.selfx/kiosk_power"
    private val DEVICE_SETTINGS_CHANNEL = "com.selfx/device_settings"
    private val USB_PERMISSION_ACTION by lazy { "${applicationContext.packageName}.USB_PERMISSION" }

    private lateinit var printerManager: PrinterManager
    private var printerManagerReady = false
    private var usbEventChannel: MethodChannel? = null
    private var receiverRegistered = false

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    if (printerManagerReady) {
                        printerManager.onUsbAttached(device)
                    }
                    usbEventChannel?.invokeMethod("usb_attached", deviceInfo(device))
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    if (printerManagerReady) {
                        printerManager.onUsbDetached(device)
                    }
                    usbEventChannel?.invokeMethod("usb_detached", deviceInfo(device))
                }
                USB_PERMISSION_ACTION -> {
                    val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (printerManagerReady) {
                        printerManager.onPermissionResult(device, granted)
                    }
                    if (granted) {
                        usbEventChannel?.invokeMethod("usb_permission_granted", deviceInfo(device))
                    } else {
                        usbEventChannel?.invokeMethod("usb_permission_denied", deviceInfo(device))
                    }
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            printerManager = PrinterManager.getInstance(this)
            printerManagerReady = true
        } catch (e: Exception) {
            NativeLogStore.append(applicationContext, "[BOOT] PrinterManager init failed: ${e.message}")
            printerManagerReady = false
        }

        enableFullscreen()
        keepKioskAwakeAndVisible()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PRINTER_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getPrinterList" -> {
                        val printers = if (printerManagerReady) {
                            printerManager.getPrinterList()
                        } else {
                            emptyList()
                        }
                        result.success(printers)
                    }

                    "connectToPrinter" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        val connected = if (printerManagerReady) {
                            printerManager.connectToPrinter(deviceId, vendorId, productId)
                        } else {
                            false
                        }
                        result.success(connected)
                    }

                    "printData" -> {
                        val printObject = call.argument<String>("printObject")
                        val lineFeed = call.argument<Int>("lineFeed") ?: 0
                        val cutFeedLines = call.argument<Int>("cutFeedLines") ?: 2
                        val deviceId = call.argument<Int>("deviceId")
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")

                        if (printObject == null) {
                            result.error("INVALID", "printObject missing", null)
                        } else {
                            if (printerManagerReady) {
                                printerManager.printData(printObject, lineFeed, cutFeedLines, deviceId, vendorId, productId)
                            }
                            result.success(true)
                        }
                    }

                    "queryStatus" -> {
                        // Wrapping in try-catch because Java method 'throws Exception'
                        try {
                            val deviceId = call.argument<Int>("deviceId")
                            val vendorId = call.argument<Int>("vendorId")
                            val productId = call.argument<Int>("productId")
                            val status = if (printerManagerReady) {
                                printerManager.queryStatus(deviceId, vendorId, productId)
                            } else {
                                "ERROR"
                            }
                            result.success(mapOf<String, Any?>("status" to status))
                        } catch (e: Exception) {
                            result.error("STATUS_ERROR", e.message, null)
                        }
                    }
                    "setSelectedPrinter" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        if (printerManagerReady) {
                            printerManager.setSelectedPrinter(deviceId, vendorId, productId)
                        }
                        result.success(true)
                    }
                    "scanAndConnect" -> {
                        if (printerManagerReady) {
                            printerManager.start()
                        }
                        result.success(true)
                    }
                    "requestUsbPermission" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        showSystemUiTemporarily(4000)
                        val requested = if (printerManagerReady) {
                            printerManager.requestUsbPermission(deviceId, vendorId, productId)
                        } else {
                            false
                        }
                        result.success(requested)
                    }
                    "requestUsbPermissionWithUi" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        val durationMs = call.argument<Int>("durationMs") ?: 20000
                        showSystemUiTemporarily(durationMs.toLong())
                        val requested = if (printerManagerReady) {
                            printerManager.requestUsbPermission(deviceId, vendorId, productId)
                        } else {
                            false
                        }
                        result.success(requested)
                    }
                    "getNativeLogs" -> {
                        val logs = NativeLogStore.readLines(applicationContext, 300)
                        result.success(logs)
                    }
                    "clearNativeLogs" -> {
                        NativeLogStore.clear(applicationContext)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                if (e.message == "USB_PERMISSION_REQUIRED") {
                    result.error("USB_PERMISSION_REQUIRED", "USB permission required", null)
                } else {
                    result.error("PRINTER_EXCEPTION", e.message, null)
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            POWER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            val pkg = packageName
                            if (!pm.isIgnoringBatteryOptimizations(pkg)) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$pkg")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BATTERY_OPT", e.message, null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_SETTINGS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openWifiSettings" -> {
                    try {
                        showSystemUiTemporarily(30000)
                        val intent = Intent(Settings.ACTION_WIFI_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val fallback = Intent(Settings.ACTION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(fallback)
                            result.success(true)
                        } catch (fallbackError: Exception) {
                            result.error("OPEN_SETTINGS_FAILED", fallbackError.message, null)
                        }
                    }
                }
                "openSystemSettings" -> {
                    try {
                        showSystemUiTemporarily(30000)
                        val intent = Intent(Settings.ACTION_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        usbEventChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            USB_EVENT_CHANNEL
        )
        if (printerManagerReady) {
            printerManager.bindEventChannel(usbEventChannel!!)
            try {
                printerManager.start()
            } catch (e: Exception) {
                NativeLogStore.append(applicationContext, "[BOOT] printerManager.start failed: ${e.message}")
            }
        }

        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
                addAction(USB_PERMISSION_ACTION)
            }
            registerReceiver(usbReceiver, filter)
            receiverRegistered = true
        }
    }

    override fun onResume() {
        super.onResume()
        keepKioskAwakeAndVisible()
        enableFullscreen()
    }

    override fun onDestroy() {
        if (receiverRegistered) {
            try {
                unregisterReceiver(usbReceiver)
            } catch (_: Exception) {}
            receiverRegistered = false
        }
        super.onDestroy()
    }

    private fun enableFullscreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_FULLSCREEN
        } else {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN
            )
        }
    }

    private fun keepKioskAwakeAndVisible() {
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setTurnScreenOn(true)
            setShowWhenLocked(true)
            try {
                val keyguardManager =
                    getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                keyguardManager.requestDismissKeyguard(this, null)
            } catch (_: Exception) {}
        }
    }

    private fun showSystemUiTemporarily(durationMs: Long) {
        runOnUiThread {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
        Handler(Looper.getMainLooper()).postDelayed(
            { enableFullscreen() },
            durationMs
        )
    }

    private fun deviceInfo(device: UsbDevice?): Map<String, Any?>? {
        if (device == null) return null
        return mapOf(
            "deviceId" to device.deviceId,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "productName" to device.productName,
            "manufacturerName" to device.manufacturerName
        )
    }
}
