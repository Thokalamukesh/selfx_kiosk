package com.whimsicaldev.capacitor.plugin;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.util.Base64;
import android.util.Log;

import com.csnprintersdk.csnio.CSNUSBPrinting;
import com.csnprintersdk.csnio.CSNPOS;

import org.json.JSONArray;
import org.json.JSONObject;

public class EpsonUSBPrinter {
    private static final String TAG = "EpsonUSBPrinter";
    private final Context context;
    private final String actionString;
    private final UsbManager manager;
    private final Object lock = new Object();
    private UsbDevice connectedDevice;
    CSNPOS mPos = new CSNPOS();
	CSNUSBPrinting mUsb = new CSNUSBPrinting();

    public String echo(String value) {
        Log.i("Echo", value);
        return value;
    }

    public EpsonUSBPrinter(Context context) {
        this.context = context;
        mPos.Set(mUsb);
        this.actionString = this.context.getPackageName() + ".USB_PERMISSION";
        this.manager =  (UsbManager) this.context.getSystemService(Context.USB_SERVICE);
    }

    public String getPermissionAction() {
        return actionString;
    }

    public List<Map<String, Object>> getPrinterList() {
        List<Map<String, Object>> printerList = new ArrayList<>();

        HashMap<String, UsbDevice> deviceList = this.manager.getDeviceList();
        for (UsbDevice usbDevice : deviceList.values()) {
            boolean isPrinter = isAPrinter(usbDevice);
            Map<String, Object> printerInfo = new HashMap<>();
            printerInfo.put("deviceId", usbDevice.getDeviceId());
            printerInfo.put("vendorId", usbDevice.getVendorId());
            printerInfo.put("productId", usbDevice.getProductId());
            printerInfo.put("productName", usbDevice.getProductName());
            printerInfo.put("manufacturerName", usbDevice.getManufacturerName());
            printerInfo.put("hasPermission", manager.hasPermission(usbDevice));
            printerInfo.put("isConnected", isConnectedTo(usbDevice));
            printerInfo.put("isPrinter", isPrinter);
            printerList.add(printerInfo);
        }

        return printerList;
    }

    public String POS_RTQueryStatus(Integer deviceId, Integer vendorId, Integer productId) throws Exception {
        ensureConnected(deviceId, vendorId, productId);

        byte[] status = new byte[1];
        if (this.mPos.POS_RTQueryStatus(status, 2, 3000, 2)) {
            if ((status[0] & 0x12) == 0x12) {
                return "PRINT_NORMAL";
            } else if ((status[0] & 0x76) == 0x76) {
                return "PRINT_COVER_OPEN";
            } else if ((status[0] & 0x72) == 0x72) {
                return "PRINT_OUT_OF_PAPER";
            } else {
                return "UNKNOWN_STATUS";
            }
        }
        throw new Exception("Failed to query printer status.");
    }

    private boolean isAPrinter(UsbDevice usbDevice) {
        for (int i = 0; i < usbDevice.getInterfaceCount(); i += 1) {
            UsbInterface usbInterface = usbDevice.getInterface(i);
            for (int j = 0; j < usbInterface.getEndpointCount(); j++) {
                UsbEndpoint usbEndpoint = usbInterface.getEndpoint(j);
                if (UsbConstants.USB_ENDPOINT_XFER_BULK == usbEndpoint.getType()
                        && UsbConstants.USB_DIR_OUT == usbEndpoint.getDirection()) {
                    return true;
                }
            }
        }
        return false;
    }

    private boolean isConnectedTo(UsbDevice device) {
        return connectedDevice != null
                && connectedDevice.getDeviceId() == device.getDeviceId()
                && mPos.GetIO().IsOpened();
    }

    public void requestPermission(UsbDevice device) {
        if (manager.hasPermission(device)) {
            return;
        }
        PendingIntent mPermissionIntent = PendingIntent.getBroadcast(
                this.context,
                0,
                new Intent(actionString),
                PendingIntent.FLAG_IMMUTABLE
        );
        manager.requestPermission(device, mPermissionIntent);
    }

    public boolean requestPermissionByIds(Integer deviceId, Integer vendorId, Integer productId) {
        UsbDevice device = findDevice(deviceId, vendorId, productId);
        if (device == null) {
            return false;
        }
        requestPermission(device);
        return true;
    }

    private UsbDevice findDevice(Integer deviceId, Integer vendorId, Integer productId) {
        HashMap<String, UsbDevice> deviceList = this.manager.getDeviceList();
        if (deviceId != null) {
            for (UsbDevice device : deviceList.values()) {
                if (deviceId == device.getDeviceId()) {
                    return device;
                }
            }
        }

        if (vendorId != null && productId != null) {
            for (UsbDevice device : deviceList.values()) {
                if (vendorId == device.getVendorId() && productId == device.getProductId()) {
                    return device;
                }
            }
        }

        if (productId != null) {
            for (UsbDevice device : deviceList.values()) {
                if (productId == device.getProductId()) {
                    return device;
                }
            }
        }

        return null;
    }

    private void ensureConnected(Integer deviceId, Integer vendorId, Integer productId) throws Exception {
        UsbDevice selectedDevice = findDevice(deviceId, vendorId, productId);
        if (selectedDevice == null) {
            throw new Exception("USB device not found.");
        }

        synchronized (lock) {
            if (isConnectedTo(selectedDevice)) {
                return;
            }

            if (!manager.hasPermission(selectedDevice)) {
                requestPermission(selectedDevice);
                throw new Exception("USB_PERMISSION_REQUIRED");
            }

            try {
                if (mPos.GetIO().IsOpened()) {
                    mUsb.Close();
                }

                boolean opened = this.mUsb.Open(this.manager, selectedDevice, this.context);
                if (!opened) {
                    throw new Exception("Failed to open USB connection.");
                }
                connectedDevice = selectedDevice;
            } catch (Exception e) {
                connectedDevice = null;
                throw new Exception("Failed to establish connection: " + e.getMessage());
            }
        }
    }

    public boolean connectToPrinter(Integer deviceId, Integer vendorId, Integer productId) throws Exception {
        ensureConnected(deviceId, vendorId, productId);
        return true;
    }

    public void disconnect() {
        synchronized (lock) {
            try {
                if (mPos.GetIO().IsOpened()) {
                    mUsb.Close();
                }
            } catch (Exception e) {
                Log.w(TAG, "Failed to close USB connection", e);
            } finally {
                connectedDevice = null;
            }
        }
    }

    public void POS_Reset() throws Exception {
        this.mPos.POS_Reset();
    }

    public void POS_FeedLine() throws Exception {
        this.mPos.POS_FeedLine();
    }

    public void POS_TextOut(String text, int nLan, int nOrgx, int nWidthTimes, int nHeightTimes, int nFontType, int nFontStyle) throws Exception {
        this.mPos.POS_TextOut(text, nLan, nOrgx, nWidthTimes, nHeightTimes, nFontType, nFontStyle);
    }

    private void printTextLine(String text, int nLan, int nOrgx, int nWidthTimes, int nHeightTimes, int nFontType, int nFontStyle) throws Exception {
        String value = text == null ? "" : text;
        this.mPos.POS_TextOut(value, nLan, nOrgx, nWidthTimes, nHeightTimes, nFontType, nFontStyle);
    }

    private void feedOneLine() throws Exception {
        this.mPos.POS_TextOut("\r\n", 0, 0, 0, 0, 0, 0);
    }

    private void safeCut(boolean halfCut) throws Exception {
        feedOneLine();
        feedOneLine();
        try {
            if (halfCut) {
                this.mPos.POS_HalfCutPaper();
            } else {
                this.mPos.POS_FullCutPaper();
            }
        } catch (Exception e) {
            Log.w(TAG, "Cut command ignored; printer may not support cutter", e);
        }
    }

    private int clampInt(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }

    private int qrErrorLevel(JSONObject command, JSONObject options) {
        Object raw = null;
        if (command.has("errorLevel")) {
            raw = command.opt("errorLevel");
        } else if (command.has("error_level")) {
            raw = command.opt("error_level");
        } else if (options != null && options.has("errorLevel")) {
            raw = options.opt("errorLevel");
        }

        if (raw instanceof Number) {
            return clampInt(((Number) raw).intValue(), 0, 3);
        }

        String value = raw == null ? "" : raw.toString().trim().toLowerCase();
        if ("l".equals(value) || "low".equals(value)) {
            return 0;
        }
        if ("q".equals(value)) {
            return 2;
        }
        if ("h".equals(value) || "high".equals(value)) {
            return 3;
        }
        if (!value.isEmpty()) {
            try {
                return clampInt(Integer.parseInt(value), 0, 3);
            } catch (NumberFormatException ignored) {
            }
        }
        return 1;
    }

    private void printQrCode(String data, int align, int size, int errorLevel) throws Exception {
        String value = cleanQrData(data);
        if (value.isEmpty()) {
            return;
        }

        int moduleSize = clampInt(size, 3, 8);
        int ecc = clampInt(errorLevel, 0, 3);
        this.mPos.POS_S_Align(align);

        boolean printed = false;
        try {
            printed = this.mPos.POS_S_SetQRcode(value, moduleSize, ecc, 0);
        } catch (Exception e) {
            Log.w(TAG, "POS_S_SetQRcode failed, trying EPSON QR command", e);
        }

        if (!printed) {
            try {
                printed = this.mPos.POS_EPSON_SetQRCode(value, moduleSize, ecc);
            } catch (Exception e) {
                Log.w(TAG, "POS_EPSON_SetQRCode failed, printing QR payload as text", e);
            }
        }

        if (!printed) {
            printTextLine(value, 0, 0, 0, 0, 0, 0);
        }
        feedOneLine();
    }

    private String cleanQrData(String data) {
        if (data == null) {
            return "";
        }
        String value = data.trim()
                .replace("\\/", "/")
                .replace("\r", "")
                .replace("\n", "")
                .replace("\t", "");
        if (value.length() >= 2) {
            boolean doubleQuoted = value.startsWith("\"") && value.endsWith("\"");
            boolean singleQuoted = value.startsWith("'") && value.endsWith("'");
            if (doubleQuoted || singleQuoted) {
                value = value.substring(1, value.length() - 1).trim();
            }
        }
        return value;
    }

    private Bitmap centerBitmapOnPaper(Bitmap source, int imageWidth, int paperWidth) {
        if (source == null) {
            return null;
        }
        int targetWidth = clampInt(imageWidth, 1, paperWidth);
        int targetHeight = Math.max(1, Math.round(source.getHeight() * (targetWidth / (float) source.getWidth())));
        Bitmap scaled = Bitmap.createScaledBitmap(source, targetWidth, targetHeight, true);
        Bitmap canvasBitmap = Bitmap.createBitmap(paperWidth, targetHeight, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(canvasBitmap);
        canvas.drawColor(Color.WHITE);
        int left = Math.max(0, (paperWidth - targetWidth) / 2);
        canvas.drawBitmap(scaled, left, 0, null);
        if (scaled != source) {
            scaled.recycle();
        }
        return canvasBitmap;
    }

    public void POS_HalfCutPaper() throws Exception {
        this.mPos.POS_FeedLine();
        this.mPos.POS_HalfCutPaper();
        try {
            Thread.currentThread();
            Thread.sleep(500);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }

    public void POS_FullCutPaper() throws Exception {
        this.mPos.POS_FeedLine();
        this.mPos.POS_FullCutPaper();
        try {
            Thread.currentThread();
            Thread.sleep(500);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }

    public void POS_S_Align(int nAlign) throws Exception {
        this.mPos.POS_S_Align(nAlign);
    }


    public void print(String printObject, int lineFeed, Integer deviceId, Integer vendorId, Integer productId) throws Exception {
        ensureConnected(deviceId, vendorId, productId);

        this.mPos.POS_Reset();
        JSONArray resObj = new JSONArray(printObject);
        for (int i = 0; i < resObj.length(); i++) {
            JSONObject jsonobject = resObj.getJSONObject(i);
            String type = jsonobject.getString("type");

            switch (type) {
                case "text":
                    String text = jsonobject.getString("text");
                    JSONObject options = jsonobject.getJSONObject("options");
                    int align = options.has("align") ? options.getInt("align") : 0;
                    int nLan = options.has("nLan") ? options.getInt("nLan") : 0;
                    int nOrgx = options.has("nOrgx") ? options.getInt("nOrgx") : 0;
                    int fontType = options.has("fontType") ? options.getInt("fontType") : 0;
                    int fontStyle = options.has("fontStyle") ? options.getInt("fontStyle") : 0;
                    int widthTimes = options.has("widthTimes") ? options.getInt("widthTimes") : 0;
                    int heightTimes = options.has("heightTimes") ? options.getInt("heightTimes") : 0;
                    if (options.has("align")) {
                        this.mPos.POS_S_Align(align);
                    }
                    printTextLine(text, nLan, nOrgx, widthTimes, heightTimes, fontType, fontStyle);
                    break;
                case "dottedLine":
                    this.mPos.POS_S_Align(0);
                    printTextLine("------------------------------", 0, 0, 0, 0, 0, 0);
                    feedOneLine();
                    break;
                case "image":
                    JSONObject imageOptions = jsonobject.optJSONObject("options");
                    int imageAlign = imageOptions != null && imageOptions.has("align") ? imageOptions.getInt("align") : 1;
                    int imageWidth = jsonobject.has("max_width_dots") ? jsonobject.getInt("max_width_dots") : 192;
                    int paperWidth = jsonobject.has("paper_width_dots") ? jsonobject.getInt("paper_width_dots") : 0;
                    String base64 = jsonobject.optString("base64", "");
                    if (!base64.isEmpty()) {
                        byte[] bytes = Base64.decode(base64, Base64.DEFAULT);
                        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                        if (bitmap != null) {
                            if (imageAlign == 1 && paperWidth > imageWidth) {
                                Bitmap centered = centerBitmapOnPaper(bitmap, imageWidth, paperWidth);
                                this.mPos.POS_S_Align(0);
                                this.mPos.POS_PrintPicture(centered, paperWidth, 0, 0);
                                centered.recycle();
                            } else {
                                this.mPos.POS_S_Align(imageAlign);
                                this.mPos.POS_PrintPicture(bitmap, imageWidth, 0, 0);
                            }
                            feedOneLine();
                            bitmap.recycle();
                        }
                    }
                    break;
                case "qr":
                case "qrcode":
                case "qr_code":
                    JSONObject qrOptions = jsonobject.optJSONObject("options");
                    int qrAlign = qrOptions != null && qrOptions.has("align") ? qrOptions.getInt("align") : 1;
                    int qrSize = jsonobject.has("size")
                            ? jsonobject.getInt("size")
                            : (qrOptions != null && qrOptions.has("size") ? qrOptions.getInt("size") : 5);
                    String qrData = jsonobject.optString("data", "");
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("text", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("value", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("payload", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("url", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("qr_url", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("qrUrl", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("tracking_url", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("trackingUrl", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("payment_url", "");
                    }
                    if (qrData.trim().isEmpty()) {
                        qrData = jsonobject.optString("paymentUrl", "");
                    }
                    printQrCode(qrData, qrAlign, qrSize, qrErrorLevel(jsonobject, qrOptions));
                    break;
                case "feedLine":
                    feedOneLine();
                    break;
                case "halfCutPaper":
                    safeCut(true);
                    break;
                case "fullCutPaper":
                    safeCut(false);
                    break;
                default:
                    break;
            }
        }

        for (int i = 0; i < lineFeed; i++) {
            feedOneLine();
        }
        // List<EpsonUSBPrinterLineEntry> printObjectList = this.objectMapper.readValue(printObject, new TypeReference<>() {});
        // Toast.makeText(this.context, "Print started", Toast.LENGTH_LONG).show();
        // this.mPos.POS_Reset();
        // for(EpsonUSBPrinterLineEntry lineEntry: printObjectList) {
        //     Toast.makeText(this.context,lineEntry.getType(), Toast.LENGTH_LONG).show();
        //     switch (lineEntry.getType()) {
        //         case "text":


        //             // this.mPos.POS_S_Align(align);
        //             // this.mPos.POS_TextOut(lineEntry.getLineText(), 0, 0, widthTimes, heightTimes, bold, 0);
        //             break;
        //         case "dottedLine":
        //             this.mPos.POS_TextOut("------------------------------------------\r\n", 0, 0, 0, 0, 0, 0);
        //             break;
        //         case "feedLine":
        //             this.mPos.POS_FeedLine();
        //             break;
        //         case "halfCutPaper":
        //             this.mPos.POS_HalfCutPaper();
        //             break;
        //         case "fullCutPaper":
        //             this.mPos.POS_FullCutPaper();
        //             break;
        //         default:
        //             break;
        //     }
        // }
       // Toast.makeText(this.context, "Print Ended", Toast.LENGTH_LONG).show();
    }
}
