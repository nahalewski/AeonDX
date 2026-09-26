package org.love2d.android;

import android.app.Activity;
import android.app.Presentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Choreographer;
import android.view.Display;
import android.view.View;
import android.view.WindowManager;

import org.libsdl.app.SDLActivity;

/**
 * Mirroring the running game's top screen to a TV: a Presentation on the
 * first external display Android offers (Samsung Smart View / Miracast,
 * HDMI or USB-C, or a virtual display from a mirroring app such as
 * jqssun's Mirror: AirPlay, Moonlight, DisplayLink).  The pictures come from
 * libemucore (mirror.c, filled by fold3ds/mirror.lua); the view copies the
 * newest one on every vsync and draws it as large as fits, black around.
 *
 * FoldBridge calls:
 *   mirror.display   the external display's name, or "" when there is none
 *   mirror.on        "ok" (showing), "none" (no external display)
 *   mirror.off       "ok"
 *   mirror.smooth    "1" / "0": smoothed or sharp pixels
 */
public final class FoldMirror {
    private static final String TAG = "FoldMirror";

    private static native long nativeSerial();
    private static native int nativeSize();
    private static native long nativeCopy(Bitmap bitmap);

    private static boolean loaded;
    private static volatile boolean wanted;
    private static volatile boolean smooth;
    private static Presentation shown;
    private static DisplayManager.DisplayListener listener;

    private static boolean load() {
        if (loaded) return true;
        try {
            System.loadLibrary("emucore");
            loaded = true;
        } catch (Throwable e) {
            Log.w(TAG, "libemucore: " + e);
        }
        return loaded;
    }

    static String call(String cmd, String arg) {
        Context c = SDLActivity.getContext();
        if (!(c instanceof Activity)) return "error:no activity";
        final Activity a = (Activity) c;
        switch (cmd) {
            case "display": {
                Display d = external(a);
                return d == null ? "" : d.getName();
            }
            case "smooth":
                smooth = arg.equals("1");
                return "ok";
            case "on": {
                if (!load()) return "error:no emucore";
                wanted = true;
                if (external(a) == null) { listen(a); return "none"; }
                a.runOnUiThread(() -> show(a));
                listen(a);
                return "ok";
            }
            case "off":
                wanted = false;
                a.runOnUiThread(FoldMirror::hide);
                return "ok";
            default:
                return "error:unknown mirror." + cmd;
        }
    }

    /** The first display to present on: a presentation display, else any but the phone's own. */
    private static Display external(Context c) {
        DisplayManager dm = (DisplayManager) c.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) return null;
        Display[] ds = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        if (ds != null && ds.length > 0) return ds[0];
        for (Display d : dm.getDisplays()) {
            if (d.getDisplayId() != Display.DEFAULT_DISPLAY && d.isValid()) return d;
        }
        return null;
    }

    /** Follow displays coming and going: show on one that arrives while wanted. */
    private static void listen(final Activity a) {
        if (listener != null) return;
        DisplayManager dm = (DisplayManager) a.getSystemService(Context.DISPLAY_SERVICE);
        if (dm == null) return;
        listener = new DisplayManager.DisplayListener() {
            @Override public void onDisplayAdded(int id) { if (wanted) show(a); }
            @Override public void onDisplayRemoved(int id) {
                if (shown != null && shown.getDisplay().getDisplayId() == id) hide();
            }
            @Override public void onDisplayChanged(int id) {}
        };
        dm.registerDisplayListener(listener, new Handler(Looper.getMainLooper()));
    }

    private static void show(Activity a) {
        Display d = external(a);
        if (d == null || !wanted) return;
        if (shown != null) {
            if (shown.getDisplay().getDisplayId() == d.getDisplayId() && shown.isShowing()) return;
            hide();
        }
        try {
            Screen p = new Screen(a, d);
            p.show();
            shown = p;
        } catch (WindowManager.InvalidDisplayException e) {
            Log.w(TAG, "display went away: " + e);
        }
    }

    private static void hide() {
        if (shown != null) {
            try { shown.dismiss(); } catch (Throwable ignored) {}
            shown = null;
        }
    }

    /** The TV's screen: the newest picture, as large as fits. */
    private static final class Screen extends Presentation {
        Screen(Context outer, Display display) { super(outer, display); }

        @Override
        protected void onCreate(Bundle state) {
            super.onCreate(state);
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            setContentView(new Picture(getContext()));
        }
    }

    private static final class Picture extends View implements Choreographer.FrameCallback {
        private Bitmap bitmap;
        private long serial;
        private final Paint paint = new Paint();
        private final Rect dst = new Rect();

        Picture(Context c) {
            super(c);
            setBackgroundColor(Color.BLACK);
        }

        @Override protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            Choreographer.getInstance().postFrameCallback(this);
        }

        @Override protected void onDetachedFromWindow() {
            Choreographer.getInstance().removeFrameCallback(this);
            super.onDetachedFromWindow();
        }

        @Override public void doFrame(long frameTimeNanos) {
            long s = nativeSerial();
            if (s != serial && s > 0) {
                int size = nativeSize();
                int w = size >>> 16, h = size & 0xFFFF;
                if (w > 0 && h > 0) {
                    if (bitmap == null || bitmap.getWidth() != w || bitmap.getHeight() != h) {
                        bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    }
                    long got = nativeCopy(bitmap);
                    if (got > 0) { serial = got; invalidate(); }
                }
            }
            Choreographer.getInstance().postFrameCallback(this);
        }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (bitmap == null) return;
            int vw = getWidth(), vh = getHeight();
            float k = Math.min(vw / (float) bitmap.getWidth(), vh / (float) bitmap.getHeight());
            int dw = Math.round(bitmap.getWidth() * k), dh = Math.round(bitmap.getHeight() * k);
            dst.set((vw - dw) / 2, (vh - dh) / 2, (vw - dw) / 2 + dw, (vh - dh) / 2 + dh);
            paint.setFilterBitmap(smooth);
            canvas.drawBitmap(bitmap, null, dst, paint);
        }
    }
}
