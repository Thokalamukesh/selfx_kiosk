package com.whimsicaldev.capacitor.plugin;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
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

    public void POS_HalfCutPaper() throws Exception {
        this.mPos.POS_FeedLine();
        this.mPos.POS_FeedLine();
        this.mPos.POS_HalfCutPaper();
        this.mPos.POS_FeedLine();
        this.mPos.POS_FeedLine();
        try {
            Thread.currentThread();
            Thread.sleep(4000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }

    public void POS_FullCutPaper() throws Exception {
        this.mPos.POS_FeedLine();
        this.mPos.POS_FeedLine();
        this.mPos.POS_FullCutPaper();
        this.mPos.POS_FeedLine();
        this.mPos.POS_FeedLine();
        try {
            Thread.currentThread();
            Thread.sleep(4000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }

    public void POS_S_Align(int nAlign) throws Exception {
        this.mPos.POS_S_Align(nAlign);
    }


    public void print(String printObject, int lineFeed, Integer deviceId, Integer vendorId, Integer productId) throws Exception {
        ensureConnected(deviceId, vendorId, productId);

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
                    this.mPos.POS_TextOut(text, nLan, nOrgx, widthTimes, heightTimes, fontType, fontStyle);
                    break;
                case "dottedLine":
                    this.mPos.POS_TextOut("--------------------------------\r\n", 0, 0, 0, 0, 0, 0);
                    break;
                case "feedLine":
                    this.mPos.POS_FeedLine();
                    break;
                case "halfCutPaper":
                    this.mPos.POS_HalfCutPaper();
                    break;
                case "fullCutPaper":
                    this.mPos.POS_FullCutPaper();
                    break;
                default:
                    break;
            }
        }

        for (int i = 0; i < lineFeed; i++) {
            this.mPos.POS_FeedLine();
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
