package org.love2d.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.PendingIntent;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.ParcelUuid;
import android.util.Log;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.libsdl.app.SDLActivity;

/**
 * AeonDX Link: one byte stream between the app and an ESP32-S3 board, over
 * USB (CDC-ACM or the S3's USB Serial/JTAG, USB-OTG) or Bluetooth LE (the
 * board's aeon_link GATT service, tools/nintendo_link/esp32_s3_ble_link).
 * Whatever the board's firmware speaks over serial passes through unchanged.
 *
 * FoldBridge calls (bytes as hex):
 *   link.scan       start looking for boards over BLE (stops after 15 s)
 *   link.found      "addr|name|rssi" per board seen, one a line
 *   link.usb        the USB serial devices plugged in, "vid:pid|name" a line
 *   link.open       "usb" (the first USB serial device; asks permission) or
 *                   "ble|<addr>" -> "ok" / "error:..."
 *   link.state      "closed" | "opening" | "usb" | "ble" | "error:<why>"
 *   link.write      hex -> bytes written (queued for BLE)
 *   link.read       what has arrived since the last read, as hex
 *   link.close      "ok"
 */
public final class FoldLink {
    private static final String TAG = "FoldLink";

    // aeon_link's GATT service
    static final UUID SVC = UUID.fromString("8f2a0001-5b3c-4d7e-9a61-2c4e6f8a0b1d");
    static final UUID RX = UUID.fromString("8f2a0002-5b3c-4d7e-9a61-2c4e6f8a0b1d");
    static final UUID TX = UUID.fromString("8f2a0003-5b3c-4d7e-9a61-2c4e6f8a0b1d");
    static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final String USB_PERMISSION = "org.love2d.android.FoldLink.USB";

    private static final ByteArrayOutputStream inbox = new ByteArrayOutputStream();
    private static volatile String state = "closed";

    // BLE
    private static BluetoothLeScanner scanner;
    private static ScanCallback scanCb;
    private static final Map<String, String> found = Collections.synchronizedMap(new LinkedHashMap<>());
    private static BluetoothGatt gatt;
    private static BluetoothGattCharacteristic rxChar;
    private static int mtu = 23;
    private static final List<byte[]> bleQueue = new ArrayList<>();
    private static boolean bleWriting;

    // USB
    private static UsbDeviceConnection usbConn;
    private static UsbEndpoint usbIn, usbOut;
    private static Thread usbReader;

    static String call(String cmd, String arg) {
        Context c = SDLActivity.getContext();
        if (!(c instanceof Activity)) return "error:no activity";
        Activity a = (Activity) c;
        switch (cmd) {
            case "scan": return scan(a);
            case "found": {
                StringBuilder sb = new StringBuilder();
                synchronized (found) {
                    for (Map.Entry<String, String> e : found.entrySet()) sb.append(e.getKey()).append('|').append(e.getValue()).append('\n');
                }
                return sb.toString();
            }
            case "usb": return usbList(a);
            case "open":
                close();
                if (arg.equals("usb")) return openUsb(a);
                if (arg.startsWith("ble|")) return openBle(a, arg.substring(4));
                return "error:open usb or ble|<address>";
            case "state": return state;
            case "write": return Integer.toString(write(unhex(arg)));
            case "read": {
                synchronized (inbox) {
                    String s = hex(inbox.toByteArray());
                    inbox.reset();
                    return s;
                }
            }
            case "close": close(); return "ok";
            default: return "error:unknown link." + cmd;
        }
    }

    private static void received(byte[] b, int n) {
        synchronized (inbox) {
            if (inbox.size() > (1 << 20)) inbox.reset();  // nobody reading: don't grow forever
            inbox.write(b, 0, n);
        }
    }

    // ------------------------------------------------------------ BLE

    private static boolean blePermitted(Activity a) {
        String[] want = Build.VERSION.SDK_INT >= 31
                ? new String[] { Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT }
                : new String[] { Manifest.permission.ACCESS_FINE_LOCATION };
        boolean ok = true;
        for (String p : want) ok &= ContextCompat.checkSelfPermission(a, p) == PackageManager.PERMISSION_GRANTED;
        if (!ok) ActivityCompat.requestPermissions(a, want, 0x4c4b);
        return ok;
    }

    @SuppressLint("MissingPermission")
    private static String scan(Activity a) {
        if (!blePermitted(a)) return "error:permission";
        BluetoothManager bm = (BluetoothManager) a.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
        if (ad == null || !ad.isEnabled()) return "error:bluetooth off";
        scanner = ad.getBluetoothLeScanner();
        if (scanner == null) return "error:no scanner";
        found.clear();
        if (scanCb != null) scanner.stopScan(scanCb);
        scanCb = new ScanCallback() {
            @Override public void onScanResult(int type, ScanResult r) {
                BluetoothDevice d = r.getDevice();
                String name = r.getScanRecord() != null ? r.getScanRecord().getDeviceName() : null;
                found.put(d.getAddress(), (name == null ? "AeonDX Link" : name) + "|" + r.getRssi());
            }
        };
        List<ScanFilter> filters = Collections.singletonList(
                new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SVC)).build());
        ScanSettings settings = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
        scanner.startScan(filters, settings, scanCb);
        final ScanCallback mine = scanCb;
        a.getWindow().getDecorView().postDelayed(() -> {
            if (scanner != null && scanCb == mine) { scanner.stopScan(mine); scanCb = null; }
        }, 15000);
        return "ok";
    }

    @SuppressLint("MissingPermission")
    private static String openBle(Activity a, String addr) {
        if (!blePermitted(a)) return "error:permission";
        BluetoothManager bm = (BluetoothManager) a.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
        if (ad == null || !ad.isEnabled()) return "error:bluetooth off";
        if (scanner != null && scanCb != null) { scanner.stopScan(scanCb); scanCb = null; }
        BluetoothDevice d;
        try { d = ad.getRemoteDevice(addr); } catch (IllegalArgumentException e) { return "error:bad address"; }
        state = "opening";
        gatt = d.connectGatt(a, false, new BluetoothGattCallback() {
            @Override public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
                    g.requestMtu(517);
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (!state.equals("closed")) state = "error:disconnected";
                    g.close();
                    if (gatt == g) gatt = null;
                }
            }

            @Override public void onMtuChanged(BluetoothGatt g, int m, int status) {
                mtu = status == BluetoothGatt.GATT_SUCCESS ? m : 23;
                g.discoverServices();
            }

            @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
                BluetoothGattService s = g.getService(SVC);
                if (s == null) { state = "error:not an AeonDX Link"; g.disconnect(); return; }
                rxChar = s.getCharacteristic(RX);
                BluetoothGattCharacteristic tx = s.getCharacteristic(TX);
                if (rxChar == null || tx == null) { state = "error:not an AeonDX Link"; g.disconnect(); return; }
                g.setCharacteristicNotification(tx, true);
                BluetoothGattDescriptor dsc = tx.getDescriptor(CCCD);
                if (dsc != null) {
                    dsc.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                    g.writeDescriptor(dsc);
                } else {
                    state = "ble";
                }
            }

            @Override public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
                state = status == BluetoothGatt.GATT_SUCCESS ? "ble" : "error:notify refused";
                pumpBle();
            }

            @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic ch) {
                if (TX.equals(ch.getUuid())) {
                    byte[] v = ch.getValue();
                    if (v != null) received(v, v.length);
                }
            }

            @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic ch, int status) {
                synchronized (bleQueue) { bleWriting = false; }
                pumpBle();
            }
        }, BluetoothDevice.TRANSPORT_LE);
        return gatt == null ? "error:connect failed" : "ok";
    }

    /** one write at a time: Android's GATT takes a single outstanding write */
    @SuppressLint("MissingPermission")
    private static void pumpBle() {
        byte[] next;
        synchronized (bleQueue) {
            if (bleWriting || bleQueue.isEmpty() || gatt == null || rxChar == null || !state.equals("ble")) return;
            next = bleQueue.remove(0);
            bleWriting = true;
        }
        rxChar.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        rxChar.setValue(next);
        if (!gatt.writeCharacteristic(rxChar)) {
            synchronized (bleQueue) { bleQueue.add(0, next); bleWriting = false; }
        }
    }

    // ------------------------------------------------------------ USB

    /** a device with a bulk IN / OUT pair (CDC data or vendor class) */
    private static UsbInterface serialInterface(UsbDevice d) {
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            UsbInterface f = d.getInterface(i);
            int cls = f.getInterfaceClass();
            if (cls != UsbConstants.USB_CLASS_CDC_DATA && cls != UsbConstants.USB_CLASS_VENDOR_SPEC) continue;
            boolean in = false, out = false;
            for (int k = 0; k < f.getEndpointCount(); k++) {
                UsbEndpoint e = f.getEndpoint(k);
                if (e.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) continue;
                if (e.getDirection() == UsbConstants.USB_DIR_IN) in = true; else out = true;
            }
            if (in && out) return f;
        }
        return null;
    }

    private static String usbList(Activity a) {
        UsbManager um = (UsbManager) a.getSystemService(Context.USB_SERVICE);
        if (um == null) return "";
        StringBuilder sb = new StringBuilder();
        for (UsbDevice d : um.getDeviceList().values()) {
            if (serialInterface(d) == null) continue;
            sb.append(String.format("%04x:%04x", d.getVendorId(), d.getProductId())).append('|')
              .append(d.getProductName() == null ? d.getDeviceName() : d.getProductName()).append('\n');
        }
        return sb.toString();
    }

    private static String openUsb(Activity a) {
        UsbManager um = (UsbManager) a.getSystemService(Context.USB_SERVICE);
        if (um == null) return "error:no usb";
        for (UsbDevice d : um.getDeviceList().values()) {
            UsbInterface f = serialInterface(d);
            if (f == null) continue;
            if (!um.hasPermission(d)) {
                Intent i = new Intent(USB_PERMISSION).setPackage(a.getPackageName());
                int flags = Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0;
                um.requestPermission(d, PendingIntent.getBroadcast(a, 0, i, flags));
                state = "error:allow USB, then open again";
                return "error:permission";
            }
            UsbDeviceConnection conn = um.openDevice(d);
            if (conn == null || !conn.claimInterface(f, true)) return "error:could not open";
            // CDC-ACM control: the interface before the data one; 115200 8N1,
            // DTR / RTS left low (GB-Link's protocol: don't toggle them)
            byte[] coding = { 0x00, (byte) 0xC2, 0x01, 0x00, 0, 0, 8 };
            conn.controlTransfer(0x21, 0x20, 0, Math.max(0, f.getId() - 1), coding, coding.length, 200);
            for (int k = 0; k < f.getEndpointCount(); k++) {
                UsbEndpoint e = f.getEndpoint(k);
                if (e.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) continue;
                if (e.getDirection() == UsbConstants.USB_DIR_IN) usbIn = e; else usbOut = e;
            }
            usbConn = conn;
            state = "usb";
            final UsbDeviceConnection rc = conn;
            final UsbEndpoint in = usbIn;
            usbReader = new Thread(() -> {
                byte[] buf = new byte[Math.max(64, in.getMaxPacketSize())];
                while (usbConn == rc) {
                    int n = rc.bulkTransfer(in, buf, buf.length, 100);
                    if (n > 0) received(buf, n);
                }
            }, "FoldLink-usb");
            usbReader.start();
            return "ok";
        }
        return "error:no USB serial device";
    }

    // ------------------------------------------------------------ both

    private static int write(byte[] b) {
        if (b.length == 0) return 0;
        if (state.equals("usb") && usbConn != null) {
            int n = usbConn.bulkTransfer(usbOut, b, b.length, 500);
            return Math.max(0, n);
        }
        if (state.equals("ble")) {
            int chunk = Math.max(20, mtu - 3);
            synchronized (bleQueue) {
                for (int o = 0; o < b.length; o += chunk) {
                    byte[] part = new byte[Math.min(chunk, b.length - o)];
                    System.arraycopy(b, o, part, 0, part.length);
                    bleQueue.add(part);
                }
            }
            pumpBle();
            return b.length;
        }
        return 0;
    }

    @SuppressLint("MissingPermission")
    private static void close() {
        state = "closed";
        if (usbConn != null) {
            UsbDeviceConnection c = usbConn;
            usbConn = null;
            try { c.close(); } catch (Throwable ignored) {}
        }
        if (gatt != null) {
            try { gatt.disconnect(); gatt.close(); } catch (Throwable ignored) {}
            gatt = null;
        }
        rxChar = null;
        synchronized (bleQueue) { bleQueue.clear(); bleWriting = false; }
        synchronized (inbox) { inbox.reset(); }
    }

    private static String hex(byte[] b) {
        char[] out = new char[b.length * 2];
        final char[] d = "0123456789abcdef".toCharArray();
        for (int i = 0; i < b.length; i++) { out[i * 2] = d[(b[i] >> 4) & 15]; out[i * 2 + 1] = d[b[i] & 15]; }
        return new String(out);
    }

    private static byte[] unhex(String s) {
        int n = s.length() / 2;
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        return b;
    }
}
