package org.love2d.android;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Build;
import android.util.Log;
import android.view.KeyEvent;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import androidx.annotation.Keep;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.zip.Deflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

import org.libsdl.app.SDLActivity;

/**
 * The foldable layer's odds and ends, reached from Lua as
 * love.system.foldCamera("call", command, argument) -> string:
 *
 *   vol.capture  "1" / "0"   the volume keys move the drawn 3DS volume
 *                            slider instead of Android's volume (no popup)
 *   vol.take                 the volume key presses since last asked ("+2")
 *   zip          "<root>|<out.zip>|<rel>;<rel>..."   zip files / folders
 *   unzip        "<zip>|<root>|<backup dir>"  unpack (saves and mods only),
 *                            moving any file it replaces into the backup
 *   steps                    today's steps from the phone's step counter
 *                            ("-1" none / not allowed, "-2" asking)
 *   hinge                    the fold as the 3DS XL hinge, polled every frame:
 *                            "seq|angle|posture|axis|foldPos|foldSize|rotation"
 *                            seq       bumps on every change (skip parsing if equal)
 *                            angle     degrees from the hinge sensor, -1 if none
 *                                      (0 closed ... 180 flat)
 *                            posture   flat | half | closed | none (no fold seen:
 *                                      outer screen, or not a foldable)
 *                            axis      h | v | - : the fold line runs horizontally
 *                                      (screens above/below it) or vertically
 *                            foldPos   the fold's centre in window pixels along the
 *                                      other axis (y for h, x for v), -1 if none
 *                            foldSize  the fold's thickness in pixels (0: a seam)
 *                            rotation  display rotation 0 / 90 / 180 / 270
 *   hinge.angle              just the raw, unsmoothed angle ("0".."180"), or ""
 *                            when the phone has no hinge sensor (the lid stays open)
 *   dp.*                     Download Play (FoldPlay)
 *   fetch, files.*, external downloads and shared storage for the HOME
 *                            menu's emulators (FoldFetch)
 */
@Keep
public final class FoldBridge {
    private static final String TAG = "FoldBridge";
    private static volatile boolean captureVolume = false;
    private static int volumeSteps = 0;

    private FoldBridge() {}

    /** From GameActivity.dispatchKeyEvent: true when the key was taken. */
    public static boolean volumeKey(KeyEvent event) {
        int code = event.getKeyCode();
        if (!captureVolume || (code != KeyEvent.KEYCODE_VOLUME_UP && code != KeyEvent.KEYCODE_VOLUME_DOWN)) {
            return false;
        }
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            synchronized (FoldBridge.class) {
                volumeSteps += code == KeyEvent.KEYCODE_VOLUME_UP ? 1 : -1;
            }
        }
        return true;
    }

    @Keep
    public static String call(String cmd, String arg) {
        try {
            if (cmd == null) return "";
            if (arg == null) arg = "";
            if (cmd.equals("ping")) return "ok";
            if (cmd.equals("vol.capture")) {
                captureVolume = arg.equals("1");
                return "ok";
            }
            if (cmd.equals("vol.take")) {
                synchronized (FoldBridge.class) {
                    int n = volumeSteps;
                    volumeSteps = 0;
                    return Integer.toString(n);
                }
            }
            if (cmd.equals("steps")) return steps();
            if (cmd.equals("hinge")) return hinge();
            if (cmd.equals("hinge.angle")) {  // Theme Dev's lid.lua: raw degrees, "" when there is no sensor
                hinge();
                return hingeAngle < 0 ? "" : Float.toString(hingeAngle);
            }
            if (cmd.equals("zip")) return zip(arg);
            if (cmd.equals("unzip")) return unzip(arg);
            if (cmd.startsWith("dp.")) return FoldPlay.call(cmd.substring(3), arg);
            if (cmd.startsWith("mirror.")) return FoldMirror.call(cmd.substring(7), arg);
            // a 3DS game in the shell: Azahar's side
            if (cmd.startsWith("3ds.")) return appCall("org.citra.citra_emu.fold3ds.Fold3dsShell", cmd.substring(4), arg);
            // a Switch game in the shell: the Eden core (a downloaded .aeoncore)
            if (cmd.startsWith("nx.")) return appCall("org.citra.citra_emu.fold3ds.AeonCoreHost", cmd.substring(3), arg);
            if (cmd.equals("sounds.fetch")) return soundsFetch(arg);
            if (cmd.equals("sounds.state")) return soundsState;
            if (cmd.startsWith("link.")) return FoldLink.call(cmd.substring(5), arg);
            if (cmd.equals("fetch") || cmd.startsWith("files.") || cmd.equals("external")) return FoldFetch.call(cmd, arg);
        } catch (Throwable e) {
            Log.d(TAG, cmd + ": " + e);
            return "error:" + e.getMessage();
        }
        return "error:unknown " + cmd;
    }

    // ------------------------------------------------------------ system sounds
    // The Switch's and the 3DS's own menu sounds, downloaded on the phone
    // into the save folder (sounds/switch/, sounds/3ds/) for this phone only:
    // never in the repository or the APK.  sounds.fetch|<save folder> starts
    // it; sounds.state says idle / running / done:<switch>:<3ds> / error:...
    private static final String[][] SOUND_SOURCES = {
        // 211 Switch sounds (WAV/*.wav) from github.com/TOM-BadEN/Nintendo-Switch-Sounds-Effect
        { "switch", "https://codeload.github.com/TOM-BadEN/Nintendo-Switch-Sounds-Effect/zip/refs/heads/main", "/WAV/" },
        // the 3DS HOME Menu's sounds from The Sounds Resource (asset 443937)
        { "3ds", "https://sounds.spriters-resource.com/media/assets/443/443937.zip", "" },
    };
    private static volatile String soundsState = "idle";

    private static String soundsFetch(final String saveDir) {
        if (soundsState.equals("running")) return soundsState;
        soundsState = "running";
        new Thread(new Runnable() {
            public void run() {
                int[] got = new int[SOUND_SOURCES.length];
                String err = null;
                for (int i = 0; i < SOUND_SOURCES.length; i++) {
                    try {
                        got[i] = fetchSounds(SOUND_SOURCES[i][1], SOUND_SOURCES[i][2],
                            new File(saveDir, "sounds/" + SOUND_SOURCES[i][0]));
                    } catch (Exception e) {
                        Log.d(TAG, "sounds " + SOUND_SOURCES[i][0] + ": " + e);
                        err = SOUND_SOURCES[i][0] + ": " + e.getMessage();
                    }
                }
                soundsState = (got[0] + got[1] == 0 && err != null)
                    ? "error:" + err : "done:" + got[0] + ":" + got[1];
            }
        }, "fold3ds-sounds").start();
        return soundsState;
    }

    // every .wav in the zip at url whose path contains `within`, flattened
    // into dir (streamed: nothing but the WAVs is written)
    static int fetchSounds(String url, String within, File dir) throws IOException {
        java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(30000);
        c.setRequestProperty("User-Agent", "Mozilla/5.0 (Android) gen1recomp-Fold");
        int n = 0;
        try {
            if (c.getResponseCode() != 200) throw new IOException("HTTP " + c.getResponseCode());
            dir.mkdirs();
            ZipInputStream zis = new ZipInputStream(c.getInputStream());
            try {
                ZipEntry e;
                while ((e = zis.getNextEntry()) != null) {
                    String name = e.getName();
                    if (e.isDirectory() || !name.toLowerCase().endsWith(".wav")) continue;
                    if (within.length() > 0 && !name.contains(within)) continue;
                    String base = name.substring(name.lastIndexOf('/') + 1);
                    if (base.length() == 0 || base.startsWith(".")) continue;
                    File out = new File(dir, base);
                    File part = new File(dir, base + ".part");
                    OutputStream o = new FileOutputStream(part);
                    try {
                        copy(zis, o);
                    } finally {
                        o.close();
                    }
                    if (part.renameTo(out)) n++;
                }
            } finally {
                zis.close();
            }
        } finally {
            c.disconnect();
        }
        return n;
    }

    // the app module's side (Azahar's in-shell 3DS, the downloaded Android
    // cores), found by name: this module can't link against it
    private static final java.util.Map<String, java.lang.reflect.Method> appCalls = new java.util.HashMap<>();

    private static String appCall(String cls, String cmd, String arg) throws Exception {
        java.lang.reflect.Method m = appCalls.get(cls);
        if (m == null) {
            m = Class.forName(cls).getMethod("call", String.class, String.class);
            appCalls.put(cls, m);
        }
        Object r = m.invoke(null, cmd, arg);
        return r == null ? "" : r.toString();
    }

    // ------------------------------------------------------------ steps
    // The hardware step counter counts since the phone started; today's
    // steps are the count less its value when the day began (kept in its
    // own preferences, apart from the Pokewalker bridge's).

    private static final String STEP_PREFS = "fold3ds_steps";
    private static boolean listening = false, asked = false;
    private static volatile long counter = -1;

    private static String steps() {
        Context c = SDLActivity.getContext();
        if (!(c instanceof Activity)) return "-1";
        final Activity a = (Activity) c;
        if (Build.VERSION.SDK_INT >= 29 && ContextCompat.checkSelfPermission(a,
                Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) {
            if (asked) return "-1";
            asked = true;
            a.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    ActivityCompat.requestPermissions(a,
                        new String[]{ Manifest.permission.ACTIVITY_RECOGNITION }, 7303);
                }
            });
            return "-2";
        }
        if (!listening) {
            SensorManager m = (SensorManager) a.getSystemService(Context.SENSOR_SERVICE);
            Sensor s = m == null ? null : m.getDefaultSensor(Sensor.TYPE_STEP_COUNTER);
            if (s == null) return "-1";
            listening = m.registerListener(new SensorEventListener() {
                @Override
                public void onSensorChanged(SensorEvent e) {
                    if (e.values.length > 0) counter = (long) e.values[0];
                }

                @Override
                public void onAccuracyChanged(Sensor sensor, int accuracy) {}
            }, s, SensorManager.SENSOR_DELAY_UI);
            if (!listening) return "-1";
        }
        long now = counter;
        if (now < 0) return "0";
        SharedPreferences p = a.getSharedPreferences(STEP_PREFS, Context.MODE_PRIVATE);
        String today = new java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US).format(new java.util.Date());
        long base = p.getLong("base", -1);
        long shown = p.getLong("shown", 0);
        if (!today.equals(p.getString("day", "")) || base < 0) {
            base = now;
            shown = 0;
        } else if (now < base) {
            // the phone restarted and its counter began again: keep today's
            base = now - shown;
        }
        shown = now - base;
        p.edit().putString("day", today).putLong("base", base).putLong("shown", shown).apply();
        return Long.toString(shown);
    }

    // ------------------------------------------------------------ hinge
    // The fold is the 3DS XL hinge. Two sources, both started on the first
    // poll: the hinge-angle sensor (API 30+, the lid animation) and Jetpack
    // WindowManager's FoldingFeature (posture, and WHERE the fold is in this
    // window, which follows every rotation). Lua polls "hinge" each frame;
    // the string only changes when seq does.

    private static volatile float hingeAngle = -1f;
    private static volatile String hingeFeature = "none|-|-1|0";
    private static volatile int hingeSeq = 0;
    private static int hingeRotation = -1;
    private static boolean hingeStarted = false;

    private static String hinge() {
        Context c = SDLActivity.getContext();
        if (!(c instanceof Activity)) return "0|-1|none|-|-1|0|0";
        final Activity a = (Activity) c;
        if (!hingeStarted) {
            hingeStarted = true;
            startHingeSensor(a);
            a.runOnUiThread(new Runnable() {
                @Override
                public void run() { startFoldingFeature(a); }
            });
        }
        int rotation = 0;
        try {
            rotation = a.getWindowManager().getDefaultDisplay().getRotation() * 90;
        } catch (Throwable ignored) {}
        if (rotation != hingeRotation) {  // a rotation alone must bump seq too (no fold on some screens)
            hingeRotation = rotation;
            hingeSeq++;
        }
        String[] f = hingeFeature.split("\\|");
        String posture = f[0];
        float angle = hingeAngle;
        // no FoldingFeature while folded shut on the outer screen: the sensor
        // still knows, so a closing lid reads as closed, not "none"
        if (posture.equals("none") && angle >= 0 && angle < 20f) posture = "closed";
        return hingeSeq + "|" + Math.round(angle * 10f) / 10f + "|" + posture + "|" + f[1] + "|" + f[2]
            + "|" + f[3] + "|" + rotation;
    }

    private static void startHingeSensor(Activity a) {
        if (Build.VERSION.SDK_INT < 30) return;
        SensorManager m = (SensorManager) a.getSystemService(Context.SENSOR_SERVICE);
        Sensor s = m == null ? null : m.getDefaultSensor(Sensor.TYPE_HINGE_ANGLE);
        if (s == null) return;
        m.registerListener(new SensorEventListener() {
            @Override
            public void onSensorChanged(SensorEvent e) {
                if (e.values.length > 0 && Math.abs(e.values[0] - hingeAngle) >= 0.5f) {
                    hingeAngle = e.values[0];
                    hingeSeq++;
                }
            }

            @Override
            public void onAccuracyChanged(Sensor sensor, int accuracy) {}
        }, s, SensorManager.SENSOR_DELAY_GAME);
    }

    private static void startFoldingFeature(Activity a) {
        try {
            androidx.window.java.layout.WindowInfoTrackerCallbackAdapter t =
                new androidx.window.java.layout.WindowInfoTrackerCallbackAdapter(
                    androidx.window.layout.WindowInfoTracker.Companion.getOrCreate(a));
            t.addWindowLayoutInfoListener(a, new java.util.concurrent.Executor() {
                @Override
                public void execute(Runnable r) { r.run(); }
            }, new androidx.core.util.Consumer<androidx.window.layout.WindowLayoutInfo>() {
                @Override
                public void accept(androidx.window.layout.WindowLayoutInfo info) {
                    String next = "none|-|-1|0";
                    for (androidx.window.layout.DisplayFeature d : info.getDisplayFeatures()) {
                        if (!(d instanceof androidx.window.layout.FoldingFeature)) continue;
                        androidx.window.layout.FoldingFeature ff = (androidx.window.layout.FoldingFeature) d;
                        boolean h = ff.getOrientation() == androidx.window.layout.FoldingFeature.Orientation.HORIZONTAL;
                        android.graphics.Rect b = ff.getBounds();
                        String posture = ff.getState() == androidx.window.layout.FoldingFeature.State.FLAT ? "flat" : "half";
                        next = posture + "|" + (h ? "h" : "v") + "|" + (h ? b.centerY() : b.centerX())
                            + "|" + (h ? b.height() : b.width());
                        break;
                    }
                    if (!next.equals(hingeFeature)) {
                        hingeFeature = next;
                        hingeSeq++;
                    }
                }
            });
        } catch (Throwable e) {
            // androidx.window missing or no WindowManager extensions: the sensor alone still drives the lid
            Log.d(TAG, "hinge: no FoldingFeature (" + e + ")");
        }
    }

    // ------------------------------------------------------------ zip

    private static String zip(String arg) throws IOException {
        String[] p = arg.split("\\|", 3);
        if (p.length < 3) return "error:bad arguments";
        File root = new File(p[0]);
        File out = new File(p[1]);
        out.getParentFile().mkdirs();
        int count = 0;
        ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(out));
        // 3DS games are gigabytes: pack fast rather than small
        zos.setLevel(Deflater.BEST_SPEED);
        try {
            for (String rel : p[2].split(";")) {
                if (rel.length() == 0 || rel.contains("..")) continue;
                // "/absolute/path=>entry/name": a file or folder outside the
                // save folder (a 3DS game, its title folder in Azahar's)
                int arrow = rel.indexOf("=>");
                if (arrow > 0) {
                    count += add(zos, root, new File(rel.substring(0, arrow)), rel.substring(arrow + 2));
                    continue;
                }
                count += add(zos, root, new File(root, rel), rel);
            }
        } finally {
            zos.close();
        }
        return "ok:" + count + ":" + out.length();
    }

    private static int add(ZipOutputStream zos, File root, File f, String rel) throws IOException {
        if (f.isDirectory()) {
            int n = 0;
            File[] kids = f.listFiles();
            if (kids == null) return 0;
            for (File k : kids) n += add(zos, root, k, rel + "/" + k.getName());
            return n;
        }
        if (!f.isFile()) return 0;
        zos.putNextEntry(new ZipEntry(rel));
        InputStream in = new FileInputStream(f);
        try {
            copy(in, zos);
        } finally {
            in.close();
        }
        zos.closeEntry();
        return 1;
    }

    // only what Download Play carries into the save folder: saves, mods and
    // the game's ROM (imported on arrival)
    private static boolean allowed(String name) {
        if (name.contains("..") || name.startsWith("/") || name.contains("\\")) return false;
        if (name.startsWith("saves/") || name.startsWith("mods/")) return true;
        if (name.matches("downloadplay/rom/[A-Za-z0-9_.-]+\\.(gb|gbc|gba)")) return true;
        return name.matches("save(_[a-z0-9_]+)?\\.lua(\\.bak)?");
    }

    // a 3DS game's files, to the same place in this phone's Azahar folder
    // (azahar/sdmc/Nintendo 3DS/...: the installed title, its update, DLC and
    // save data) or into its 3DS games folder (games3ds/<file>: a cartridge
    // dump); null when the entry is not one of those
    private static File azaharDest(String name, String azahar, String games) {
        if (name.contains("..") || name.contains("\\")) return null;
        if (name.startsWith("azahar/sdmc/Nintendo 3DS/") && azahar.length() > 0) {
            return new File(azahar, name.substring("azahar/".length()));
        }
        if (name.matches("games3ds/[^/]+\\.(3ds|cci|cxi|3dsx|z3ds|zcci|zcxi|z3dsx)") && games.length() > 0) {
            return new File(games, name.substring("games3ds/".length()));
        }
        return null;
    }

    private static boolean inside(File dest, File dir) throws IOException {
        return dest.getCanonicalPath().startsWith(dir.getCanonicalPath() + File.separator);
    }

    // zip|save folder|backup folder[|Azahar's folder|3DS games folder]
    private static String unzip(String arg) throws IOException {
        String[] p = arg.split("\\|", 5);
        if (p.length < 3) return "error:bad arguments";
        File root = new File(p[1]);
        File backup = new File(p[2]);
        String azahar = p.length > 3 ? p[3] : "";
        String games = p.length > 4 ? p[4] : "";
        int count = 0, skipped = 0, threeDs = 0;
        ZipInputStream zis = new ZipInputStream(new FileInputStream(p[0]));
        try {
            ZipEntry e;
            while ((e = zis.getNextEntry()) != null) {
                String name = e.getName();
                if (e.isDirectory()) continue;
                File dest = azaharDest(name, azahar, games);
                if (dest != null) {
                    File base = name.startsWith("azahar/") ? new File(azahar) : new File(games);
                    if (!inside(dest, base)) { skipped++; continue; }
                    threeDs++;
                } else {
                    if (!allowed(name)) { skipped++; continue; }
                    dest = new File(root, name);
                    if (!inside(dest, root)) { skipped++; continue; }
                }
                if (dest.isFile()) {
                    File keep = new File(backup, name);
                    keep.getParentFile().mkdirs();
                    if (!dest.renameTo(keep)) dest.delete();
                }
                dest.getParentFile().mkdirs();
                OutputStream out = new FileOutputStream(dest);
                try {
                    copy(zis, out);
                } finally {
                    out.close();
                }
                count++;
            }
        } finally {
            zis.close();
        }
        return "ok:" + count + ":" + skipped + ":" + threeDs;
    }

    static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    }
}
