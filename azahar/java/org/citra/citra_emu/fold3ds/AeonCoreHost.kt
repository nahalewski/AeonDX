// A Switch game played INSIDE the 3DS shell (and the Switch skin) on the Eden
// core: Eden as a downloaded .aeoncore (tools/cores: its official Android
// build's classes*.dex and lib/arm64-v8a, repacked), not a separate app.
//
// The core is loaded into this process with a child-first DexClassLoader
// (its own Kotlin / AndroidX copies win over ours; android.* and java.* are
// the system's), its library path the unpacked core's lib/.  Eden's start-up
// (YuzuApplication.onCreate) is replayed against our context: its
// YuzuApplication wraps our application context, then DirectoryInitialization,
// the GPU driver parameters and the input devices.  Its renderer draws into an
// ImageReader, as Fold3dsShell does for Azahar: each frame is copied into one
// of two direct buffers the shell reads through LuaJIT's FFI (fold3ds/eden.lua).
// Buttons, sticks and touch go into Eden's virtual controller (the path its
// on-screen overlay takes).
//
// Reached from Lua through FoldBridge.call("nx.<cmd>", arg): available, start,
// frame, key, stick, touch, pause, resume, stop, state.
package org.citra.citra_emu.fold3ds

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import dalvik.system.DexClassLoader
import java.io.File
import java.nio.ByteBuffer
import org.citra.citra_emu.CitraApplication

object AeonCoreHost {
    private const val TAG = "aeoncore"
    private const val W = 1280
    private const val H = 720

    /** Loads a core's classes itself first, the system's (android.*, java.*) from the parent. */
    private class ChildFirst(dex: String, opt: String, lib: String, parent: ClassLoader) :
        DexClassLoader(dex, opt, lib, parent) {
        private val shared = listOf("android.", "java.", "javax.", "dalvik.", "org.json.", "org.xml.", "org.w3c.")
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (shared.any { name.startsWith(it) }) return super.loadClass(name, resolve)
            synchronized(getClassLoadingLock(name)) {
                findLoadedClass(name)?.let { return it }
                return try { findClass(name) } catch (_: ClassNotFoundException) { super.loadClass(name, resolve) }
            }
        }
    }

    private var loader: ClassLoader? = null
    private var nativeLib: Any? = null      // org.yuzu.yuzu_emu.NativeLibrary (a Kotlin object)
    private var nativeInput: Any? = null    // org.yuzu.yuzu_emu.features.input.NativeInput
    private var ready = false

    @Volatile private var running = false
    @Volatile private var paused = false
    private var reader: ImageReader? = null
    private var readerThread: HandlerThread? = null
    private val buffers = arrayOfNulls<ByteBuffer>(2)
    private val addresses = LongArray(2)
    @Volatile private var front = 0
    @Volatile private var serial = 0L

    @JvmStatic
    fun call(cmd: String, arg: String): String = try {
        when (cmd) {
            "available" -> if (coreDir(CitraApplication.appContext) != null) "1" else "0"
            "start" -> start(arg)
            "frame" -> frame()
            "key" -> key(arg)
            "stick" -> stick(arg)
            "touch" -> touch(arg)
            "pause" -> pause(true)
            "resume" -> pause(false)
            "stop" -> stop()
            "state" -> if (running) (if (paused) "paused" else "running") else "stopped"
            else -> "error:unknown $cmd"
        }
    } catch (e: Throwable) {
        Log.e(TAG, "nx.$cmd", e)
        "error:" + (e.cause?.message ?: e.message)
    }

    /** The unpacked Eden core in a LÖVE save folder (cores/eden/, fold3ds/cores.lua). */
    fun coreDir(context: Context): File? {
        val roots = listOfNotNull(context.getExternalFilesDir(null), context.filesDir)
        for (root in roots) {
            File(root, "save").listFiles()?.filter { it.isDirectory }?.forEach { save ->
                val dir = File(save, "cores/eden")
                if (File(dir, "aeoncore.txt").isFile) return dir
            }
        }
        return null
    }

    private fun manifest(dir: File): Map<String, String> =
        File(dir, "aeoncore.txt").readLines().mapNotNull { line ->
            val i = line.indexOf('=')
            if (i > 0) line.substring(0, i).trim() to line.substring(i + 1).trim() else null
        }.toMap()

    private fun obj(name: String): Any = loader!!.loadClass(name).getField("INSTANCE").get(null)

    private fun invoke(target: Any, name: String, vararg args: Any?): Any? {
        val m = target.javaClass.declaredMethods.firstOrNull { it.name == name && it.parameterTypes.size == args.size }
            ?: target.javaClass.methods.first { it.name == name && it.parameterTypes.size == args.size }
        m.isAccessible = true
        return m.invoke(target, *args)
    }

    private fun tryInvoke(target: Any, name: String, vararg args: Any?) {
        try { invoke(target, name, *args) } catch (e: Throwable) { Log.w(TAG, "$name: ${e.cause ?: e}") }
    }

    /** Load the core and replay Eden's start-up (once a process). */
    private fun prepare(context: Context) {
        if (ready) return
        val dir = coreDir(context) ?: throw IllegalStateException("the Eden core isn't installed")
        val m = manifest(dir)
        val dex = (m["dex"] ?: "classes.dex").split(',').map { File(dir, it.trim()).path }.joinToString(File.pathSeparator)
        val lib = File(dir, m["libdir"] ?: "lib/arm64-v8a").path
        val opt = File(context.codeCacheDir, "aeoncore-eden").apply { mkdirs() }.path
        // the dex must not be writable (Android 14+)
        dex.split(File.pathSeparator).forEach { File(it).setReadOnly() }
        val l = ChildFirst(dex, opt, lib, AeonCoreHost::class.java.classLoader!!)
        loader = l
        // YuzuApplication around our application context, as its companion's `application`
        val appClass = l.loadClass("org.yuzu.yuzu_emu.YuzuApplication")
        val app = appClass.getDeclaredConstructor().newInstance() as Application
        val attach = ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
        attach.isAccessible = true
        attach.invoke(app, context.applicationContext)
        val companion = appClass.getField("Companion").get(null)
        companion.javaClass.getMethod("setApplication", appClass).invoke(companion, app)
        // YuzuApplication.onCreate without its notification channels (they use its resources)
        nativeLib = obj("org.yuzu.yuzu_emu.NativeLibrary")
        nativeInput = obj("org.yuzu.yuzu_emu.features.input.NativeInput")
        invoke(obj("org.yuzu.yuzu_emu.utils.DirectoryInitialization"), "start")
        val gpu = obj("org.yuzu.yuzu_emu.utils.GpuDriverHelper")
        tryInvoke(gpu, "initializeFreedrenoConfigEarly")
        tryInvoke(nativeLib!!, "playTimeManagerInit")
        tryInvoke(gpu, "initializeDriverParameters")
        tryInvoke(nativeInput!!, "reloadInputDevices")
        ready = true
    }

    private fun start(key: String): String {
        val context = CitraApplication.appContext
        if (running) return "error:running"
        val game = EdenBridge.find(key) ?: return "error:nogame"
        prepare(context)
        for (i in 0..1) {
            val b = ByteBuffer.allocateDirect(W * H * 4)
            buffers[i] = b
            addresses[i] = Fold3dsShell.addressOf(b)
        }
        serial = 0
        val t = HandlerThread("aeoncore-frames").also { it.start() }
        readerThread = t
        val r = ImageReader.newInstance(W, H, PixelFormat.RGBA_8888, 3,
            HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_CPU_READ_OFTEN)
        r.setOnImageAvailableListener({ onFrame(it) }, Handler(t.looper))
        reader = r
        running = true
        paused = false
        invoke(nativeLib!!, "surfaceChanged", r.surface as Surface?)
        Thread({
            try {
                invoke(nativeLib!!, "run", game.file, 0, true)
            } catch (e: Throwable) {
                Log.e(TAG, "Eden core stopped", e)
            }
            running = false
        }, "aeoncore-eden").start()
        return "ok"
    }

    private fun onFrame(r: ImageReader) {
        val image = try { r.acquireLatestImage() } catch (_: Exception) { null } ?: return
        try {
            val plane = image.planes[0]
            val src = plane.buffer
            val stride = plane.rowStride
            val back = 1 - front
            val dst = buffers[back] ?: return
            dst.clear()
            val row = W * 4
            if (stride == row) {
                src.limit(minOf(src.capacity(), row * H))
                dst.put(src)
            } else {
                for (y in 0 until H) {
                    src.limit(y * stride + row)
                    src.position(y * stride)
                    dst.put(src)
                }
            }
            front = back
            serial++
        } catch (e: Exception) {
            Log.w(TAG, "frame copy", e)
        } finally {
            image.close()
        }
    }

    // "hi:lo:width:height:serial" -- the newest frame's address in two 32-bit halves
    private fun frame(): String {
        if (!running && serial == 0L) return "none"
        val a = addresses[front]
        return "${(a ushr 32) and 0xffffffffL}:${a and 0xffffffffL}:$W:$H:$serial"
    }

    // the shell's buttons -> Eden's NativeButton ids (settings_input.h)
    private val BUTTONS = mapOf(
        "a" to 0, "b" to 1, "x" to 2, "y" to 3, "l" to 6, "r" to 7, "zl" to 8, "zr" to 9,
        "start" to 10, "plus" to 10, "select" to 11, "minus" to 11,
        "left" to 12, "up" to 13, "right" to 14, "down" to 15, "capture" to 19,
    )

    private fun key(arg: String): String {
        val parts = arg.split('|')
        val id = BUTTONS[parts[0]] ?: return "error:unknown button"
        val down = parts.getOrNull(1) == "1"
        invoke(nativeInput!!, "onOverlayButtonEventImpl", 0, id, if (down) 1 else 0)
        return "ok"
    }

    // "x|y" in -1..1 for the left stick, "r|x|y" for the right
    private fun stick(arg: String): String {
        val p = arg.split('|')
        val right = p.size >= 3 && p[0] == "r"
        val x = (if (right) p[1] else p[0]).toFloatOrNull() ?: 0f
        val y = (if (right) p[2] else p.getOrNull(1))?.toFloatOrNull() ?: 0f
        invoke(nativeInput!!, "onOverlayJoystickEventImpl", 0, if (right) 1 else 0, x, -y)
        return "ok"
    }

    // "down|u|v" / "move|u|v" / "up": u, v in 0..1 over the game's picture
    private fun touch(arg: String): String {
        val p = arg.split('|')
        val u = (p.getOrNull(1)?.toFloatOrNull() ?: 0f) * W
        val v = (p.getOrNull(2)?.toFloatOrNull() ?: 0f) * H
        when (p[0]) {
            "down", "pressed" -> invoke(nativeInput!!, "onTouchPressed", 0, u, v)
            "move", "moved" -> invoke(nativeInput!!, "onTouchMoved", 0, u, v)
            else -> invoke(nativeInput!!, "onTouchReleased", 0)
        }
        return "ok"
    }

    private fun pause(on: Boolean): String {
        if (!running) return "stopped"
        if (on && !paused) invoke(nativeLib!!, "pauseEmulation")
        if (!on && paused) invoke(nativeLib!!, "unpauseEmulation")
        paused = on
        return "ok"
    }

    private fun stop(): String {
        if (running) tryInvoke(nativeLib!!, "stopEmulation")
        running = false
        paused = false
        tryInvoke(nativeLib!!, "surfaceDestroyed")
        reader?.close()
        reader = null
        readerThread?.quitSafely()
        readerThread = null
        return "ok"
    }
}
