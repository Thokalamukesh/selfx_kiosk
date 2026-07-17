package com.example.api_selfxo_project

import android.content.Context
import android.hardware.usb.UsbDevice
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.whimsicaldev.capacitor.plugin.EpsonUSBPrinter
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class PrinterManager private constructor(context: Context) {
    enum class State { DETECTED, CONNECTING, CONNECTED, PRINTING, ERROR }

    private val appContext = context.applicationContext
    private val printer = EpsonUSBPrinter(appContext)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    private var eventChannel: MethodChannel? = null
    private var state: State = State.DETECTED
    private var selectedDeviceId: Int? = null
    private var selectedVendorId: Int? = null
    private var selectedProductId: Int? = null
    private var lastAutoPrintKey: String? = null

    companion object {
        @Volatile private var instance: PrinterManager? = null

        fun getInstance(context: Context): PrinterManager {
            return instance ?: synchronized(this) {
                instance ?: PrinterManager(context).also { instance = it }
            }
        }
    }

    fun bindEventChannel(channel: MethodChannel) {
        eventChannel = channel
        log("PrinterManager bound to Flutter channel")
    }

    fun start() {
        refreshSelectionFromPrefs()
        scanAndConnect()
    }

    fun setSelectedPrinter(deviceId: Int?, vendorId: Int?, productId: Int?) {
        selectedDeviceId = deviceId
        selectedVendorId = vendorId
        selectedProductId = productId
        log("Selected printer updated: deviceId=$deviceId vendorId=$vendorId productId=$productId")
    }

    fun getPrinterList(): List<Map<String, Any?>> {
        val printers = printer.getPrinterList()
        val result = ArrayList<Map<String, Any?>>()
        val selectedKey = selectionKey(selectedDeviceId, selectedVendorId, selectedProductId)

        for (item in printers) {
            val map = HashMap<String, Any?>()
            map.putAll(item as Map<String, Any?>)
            val key = selectionKey(
                toInt(map["deviceId"]),
                toInt(map["vendorId"]),
                toInt(map["productId"])
            )
            if (selectedKey != null && key == selectedKey) {
                map["isSelected"] = true
            }
            result.add(map)
        }

        log("USB scan found ${result.size} device(s)")
        return result
    }

    fun scanAndConnect() {
        Thread {
            try {
                log("Scanning USB devices...")
                val printers = printer.getPrinterList().map { it as Map<String, Any?> }
                val target = pickTargetDevice(printers)
                if (target == null) {
                    updateState(State.ERROR, "No USB printer found")
                    return@Thread
                }

                updateState(State.DETECTED, "USB printer detected")
                connectToDevice(
                    toInt(target["deviceId"]),
                    toInt(target["vendorId"]),
                    toInt(target["productId"]),
                    target
                )
            } catch (e: Exception) {
                updateState(State.ERROR, "Scan failed: ${e.message}")
                emitError("SCAN_FAILED", e.message)
            }
        }.start()
    }

    fun connectToPrinter(deviceId: Int?, vendorId: Int?, productId: Int?): Boolean {
        val target = mapOf(
            "deviceId" to deviceId,
            "vendorId" to vendorId,
            "productId" to productId
        )
        return connectToDevice(deviceId, vendorId, productId, target)
    }

    fun requestUsbPermission(deviceId: Int?, vendorId: Int?, productId: Int?): Boolean {
        val requested = printer.requestPermissionByIds(deviceId, vendorId, productId)
        if (requested) {
            log("USB permission requested for deviceId=$deviceId vendorId=$vendorId productId=$productId")
        } else {
            log("USB permission request failed: device not found")
        }
        return requested
    }

    fun onUsbAttached(device: UsbDevice?) {
        val info = deviceInfo(device)
        log("USB attached: $info")
        scanAndConnect()
    }

    fun onUsbDetached(device: UsbDevice?) {
        val info = deviceInfo(device)
        log("USB detached: $info")
        synchronized(lock) {
            printer.disconnect()
            lastAutoPrintKey = null
        }
        updateState(State.ERROR, "USB device detached")
    }

    fun onPermissionResult(device: UsbDevice?, granted: Boolean) {
        val info = deviceInfo(device)
        if (granted) {
            log("USB permission granted: $info")
            scanAndConnect()
        } else {
            updateState(State.ERROR, "USB permission denied")
            emitError("USB_PERMISSION_DENIED", "USB permission denied")
        }
    }

    fun printData(printObject: String, lineFeed: Int, cutFeedLines: Int, deviceId: Int?, vendorId: Int?, productId: Int?) {
        synchronized(lock) {
            try {
                log("Print request received (bytes=${printObject.length})")
                emitPrintStatus("PRINT_STARTED", "Print started")
                updateState(State.PRINTING, "Printing receipt")
                emitPrintStatus("PRINTING", "Printing in progress")
                printer.print(printObject, lineFeed, cutFeedLines, deviceId, vendorId, productId)
                updateState(State.CONNECTED, "Print success")
                emitPrintStatus("PRINT_SUCCESS", "Print completed")
            } catch (e: Exception) {
                updateState(State.ERROR, "Print failed: ${e.message}")
                emitPrintStatus("PRINT_ERROR", e.message ?: "Print failed")
                emitError("PRINT_FAILED", e.message)
                throw e
            }
        }
    }

    fun queryStatus(deviceId: Int?, vendorId: Int?, productId: Int?): String {
        return printer.POS_RTQueryStatus(deviceId, vendorId, productId)
    }

    private fun connectToDevice(
        deviceId: Int?,
        vendorId: Int?,
        productId: Int?,
        deviceInfo: Map<String, Any?>
    ): Boolean {
        return synchronized(lock) {
            try {
                updateState(State.CONNECTING, "Connecting to printer")

                if (deviceId == null && vendorId == null && productId == null) {
                    updateState(State.ERROR, "Invalid device identifiers")
                    return@synchronized false
                }

                selectedDeviceId = deviceId
                selectedVendorId = vendorId
                selectedProductId = productId

                val connected = printer.connectToPrinter(deviceId, vendorId, productId)
                if (connected) {
                    updateState(State.CONNECTED, "Printer connected")
                    emitConnected(deviceInfo)
                } else {
                    updateState(State.ERROR, "Printer connection failed")
                }
                connected
            } catch (e: Exception) {
                if (e.message == "USB_PERMISSION_REQUIRED") {
                    updateState(State.ERROR, "USB permission required")
                    emitError("USB_PERMISSION_REQUIRED", "USB permission required")
                } else {
                    updateState(State.ERROR, "Connection failed: ${e.message}")
                    emitError("CONNECT_FAILED", e.message)
                }
                false
            }
        }
    }

    private fun autoTestPrint(deviceId: Int?, vendorId: Int?, productId: Int?) {
        val key = selectionKey(deviceId, vendorId, productId) ?: return
        if (lastAutoPrintKey == key) {
            log("Auto test print skipped (already printed for this device)")
            return
        }

        try {
            updateState(State.PRINTING, "Auto test print started")
            emitPrintStatus("PRINT_STARTED", "Auto test print started")
            printer.print(buildAutoTestPrint(), 1, 2, deviceId, vendorId, productId)
            lastAutoPrintKey = key
            updateState(State.CONNECTED, "Auto test print completed")
            emitPrintStatus("PRINT_SUCCESS", "Auto test print completed")
        } catch (e: Exception) {
            updateState(State.ERROR, "Auto test print failed: ${e.message}")
            emitPrintStatus("PRINT_ERROR", e.message ?: "Auto test print failed")
            emitError("AUTO_TEST_PRINT_FAILED", e.message)
        }
    }

    private fun buildAutoTestPrint(): String {
        val arr = JSONArray()
        arr.put(
            JSONObject()
                .put("type", "text")
                .put("text", "Printer connected successfully")
                .put(
                    "options",
                    JSONObject()
                        .put("align", 1)
                        .put("fontStyle", 1)
                        .put("widthTimes", 1)
                        .put("heightTimes", 1)
                )
        )
        arr.put(JSONObject().put("type", "feedLine"))
        arr.put(JSONObject().put("type", "fullCutPaper"))
        return arr.toString()
    }

    private fun pickTargetDevice(printers: List<Map<String, Any?>>): Map<String, Any?>? {
        refreshSelectionFromPrefs()

        val printerCandidates = printers.filter {
            val flag = it["isPrinter"]
            flag is Boolean && flag
        }
        val candidates = if (printerCandidates.isNotEmpty()) printerCandidates else printers

        if (selectedDeviceId == null && selectedVendorId == null && selectedProductId == null) {
            return candidates.firstOrNull()
        }

        for (device in candidates) {
            val deviceId = toInt(device["deviceId"])
            val vendorId = toInt(device["vendorId"])
            val productId = toInt(device["productId"])
            if (selectionKey(deviceId, vendorId, productId) ==
                selectionKey(selectedDeviceId, selectedVendorId, selectedProductId)) {
                return device
            }
        }

        return candidates.firstOrNull()
    }

    private fun refreshSelectionFromPrefs() {
        val prefs = appContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.selected_usb_printer", null)
            ?: prefs.getString("selected_usb_printer", null)
        if (raw.isNullOrBlank()) return

        try {
            val obj = JSONObject(raw)
            selectedDeviceId = readInt(obj, "deviceId")
            selectedVendorId = readInt(obj, "vendorId")
            selectedProductId = readInt(obj, "productId")
            log("Loaded selected printer from prefs: deviceId=$selectedDeviceId vendorId=$selectedVendorId productId=$selectedProductId")
        } catch (e: Exception) {
            log("Failed to parse saved printer: ${e.message}")
        }
    }

    private fun readInt(obj: JSONObject, key: String): Int? {
        if (!obj.has(key)) return null
        val value = obj.opt(key)
        return toInt(value)
    }

    private fun toInt(value: Any?): Int? {
        return when (value) {
            is Int -> value
            is Number -> value.toInt()
            is String -> value.toIntOrNull()
            else -> null
        }
    }

    private fun selectionKey(deviceId: Int?, vendorId: Int?, productId: Int?): String? {
        if (deviceId == null && vendorId == null && productId == null) return null
        return "${deviceId ?: "x"}-${vendorId ?: "x"}-${productId ?: "x"}"
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

    private fun updateState(newState: State, message: String) {
        state = newState
        log("State=$newState • $message")
        emitState(newState.name, message)
    }

    private fun emitState(state: String, message: String) {
        val payload = mapOf("state" to state, "message" to message, "timestamp" to timestamp())
        mainHandler.post { eventChannel?.invokeMethod("onPrinterState", payload) }
    }

    private fun emitConnected(info: Map<String, Any?>) {
        val payload = HashMap<String, Any?>()
        payload.putAll(info)
        payload["timestamp"] = timestamp()
        mainHandler.post { eventChannel?.invokeMethod("onPrinterConnected", payload) }
    }

    private fun emitError(code: String, message: String?) {
        val payload = mapOf(
            "code" to code,
            "message" to (message ?: ""),
            "timestamp" to timestamp()
        )
        mainHandler.post { eventChannel?.invokeMethod("onPrinterError", payload) }
    }

    private fun emitPrintStatus(status: String, message: String) {
        val payload = mapOf(
            "status" to status,
            "message" to message,
            "timestamp" to timestamp()
        )
        mainHandler.post { eventChannel?.invokeMethod("onPrinterPrintStatus", payload) }
    }

    private fun log(message: String) {
        val entry = "[${timestamp()}] $message"
        NativeLogStore.append(appContext, entry)
        val payload = mapOf("message" to message, "timestamp" to timestamp())
        mainHandler.post { eventChannel?.invokeMethod("onPrinterLog", payload) }
        Log.i("PrinterManager", message)
    }

    private fun timestamp(): String {
        val formatter = SimpleDateFormat("HH:mm:ss", Locale.US)
        return formatter.format(Date())
    }
}
