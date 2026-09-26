// Eden's side of the 3DS HOME menu (Steam Dev) -- our code, beside Fold3dsBridge; nothing
// of Eden's (dev.eden.eden_emulator, a separate installed app) is changed or linked.
//
// Whenever the shell comes to the front: is Eden installed, is a Switch games folder chosen,
// and what games are in it. Written into every LÖVE save folder as fold3ds/eden.lua reads it:
//
//   fold3ds_eden/games.tsv
//     state<TAB>ready | setup | missing
//     gamesdir<TAB>the folder (a content:// tree URI)
//     game<TAB>key<TAB>title<TAB>subtitle<TAB>icon 0|1<TAB>file (content:// URI)<TAB>title id
//
// Titles come from the file name and title ids from the "[0100...]" tag most dumps carry.
// Reading them from inside an NSP/XCI needs the console's keys, which we do not have and do
// not ship, so there are no icons yet (icon is always 0).
//   fold3ds_eden/running.tsv
//     running<TAB>key   while that game is up in Eden's pane; empty once it is not
//
// "Running" is ours to know, since Eden is another app: set when EdenLinkActivity starts a
// game, cleared when the shell is back to a full window (Eden's pane closed) or Eden is gone.
//
// The other direction (the shell opening a game or a page) is EdenLinkActivity.
package org.citra.citra_emu.fold3ds

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.util.Log
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

object EdenBridge {
    private const val TAG = "fold3ds-eden"
    private const val DIR = "fold3ds_eden"
    private const val PREFS = "fold3ds_eden"
    const val PREF_TREE = "games_tree"

    /** Eden's package names: release, and the two suffixed build flavours (Video Dev). */
    val PACKAGES = listOf("dev.eden.eden_emulator", "dev.eden.eden_emulator.nightly", "dev.eden.eden_emulator.relWithDebInfo")
    private val EXTENSIONS = setOf("nsp", "xci", "nsz", "xcz")
    private val TITLE_ID = Regex("\\[(0100[0-9A-Fa-f]{12})]")

    data class Game(val key: String, val title: String, val file: String, val titleId: String?)

    private val executor = Executors.newSingleThreadExecutor()
    private val queued = AtomicBoolean(false)
    @Volatile private var byKey: Map<String, Game> = emptyMap()
    @Volatile private var running: String? = null
    @Volatile private var startedAt = 0L
    private var shell: WeakReference<Activity>? = null
    /** Split screen takes a moment to form after a launch; don't read "full window" as "closed" before. */
    private const val SETTLE_MS = 5000L

    fun install(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                if (activity.javaClass.name != Fold3dsBridge.SHELL) return
                shell = WeakReference(activity)
                checkRunning(activity.applicationContext)
                refresh(activity.applicationContext)
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
        // leaving split screen resizes the shell: the moment Eden's pane has closed
        app.registerComponentCallbacks(object : ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) { checkRunning(app) }
            @Deprecated("ComponentCallbacks") override fun onLowMemory() {}
        })
        publishRunning(app)
    }

    /** EdenLinkActivity, once Eden has taken the game. */
    fun started(context: Context, game: Game) {
        running = game.key
        startedAt = System.currentTimeMillis()
        executor.execute { publishRunning(context) }
        // if split screen never forms (a phone held open, the launch refused), look again once settled
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ checkRunning(context) }, SETTLE_MS + 500)
    }

    private fun checkRunning(context: Context) {
        if (running == null || System.currentTimeMillis() - startedAt < SETTLE_MS) return
        val s = shell?.get()
        val splitGone = s != null && !s.isInMultiWindowMode
        if (splitGone || edenPackage(context) == null) {
            running = null
            executor.execute { publishRunning(context) }
        }
    }

    /** The installed Eden package, or null. */
    fun edenPackage(context: Context): String? = PACKAGES.firstOrNull {
        try { context.packageManager.getPackageInfo(it, 0); true } catch (_: PackageManager.NameNotFoundException) { false }
    }

    fun tree(context: Context): Uri? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(PREF_TREE, null)?.let(Uri::parse)

    fun setTree(context: Context, uri: Uri) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(PREF_TREE, uri.toString()).apply()
        refresh(context)
    }

    fun find(key: String): Game? = byKey[key]

    fun refresh(context: Context) {
        if (!queued.compareAndSet(false, true)) return
        executor.execute {
            queued.set(false)
            try { scan(context) } catch (e: Exception) { Log.w(TAG, "scan failed", e) }
        }
    }

    private fun scan(context: Context) {
        val tree = tree(context)
        val state = when {
            // Eden as a downloaded core (AeonCoreHost) or, still, the Eden app
            edenPackage(context) == null && AeonCoreHost.coreDir(context) == null -> "missing"
            tree == null -> "setup"
            else -> "ready"
        }
        val games = if (state == "ready") list(context, tree!!) else emptyList()
        byKey = games.associateBy { it.key }
        publish(context, state, tree, games)
    }

    /** Every Switch game file in the tree, one level of subfolders deep (dumps are often foldered). */
    private fun list(context: Context, tree: Uri): List<Game> {
        val out = ArrayList<Game>()
        fun walk(docId: String, depth: Int) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            context.contentResolver.query(children, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0); val name = c.getString(1) ?: continue; val mime = c.getString(2)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { if (depth < 1) walk(id, depth + 1); continue }
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (ext !in EXTENSIONS) continue
                    val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id).toString()
                    val tid = TITLE_ID.find(name)?.groupValues?.get(1)?.lowercase()
                    out.add(Game(key(tid, uri), title(name), uri, tid))
                }
            }
        }
        try { walk(DocumentsContract.getTreeDocumentId(tree), 0) }
        catch (e: SecurityException) { Log.w(TAG, "games folder permission lost", e) }
        return out.sortedBy { it.title.lowercase() }
    }

    /** Unique per file: the title id when the name carries one, plus the file's hash. */
    private fun key(titleId: String?, uri: String) = "${titleId ?: "0"}_%08x".format(uri.hashCode())

    /** "Super Mario Odyssey [0100000000010000][v0] (US).nsp" -> "Super Mario Odyssey". */
    private fun title(fileName: String): String =
        fileName.substringBeforeLast('.').replace(Regex("\\[[^]]*]|\\([^)]*\\)"), " ")
            .replace('_', ' ').replace(Regex("\\s+"), " ").trim().ifEmpty { fileName }

    private fun clean(s: String) = s.replace(Regex("[\\t\\r\\n]+"), " ").trim()

    private fun publish(context: Context, state: String, tree: Uri?, games: List<Game>) {
        val out = StringBuilder("state\t").append(state).append('\n')
        if (tree != null) out.append("gamesdir\t").append(tree.toString()).append('\n')
        for (g in games) {
            out.append("game\t").append(g.key).append('\t').append(clean(g.title)).append('\t')
                .append("Nintendo Switch").append('\t').append("0").append('\t')
                .append(clean(g.file)).append('\t').append(g.titleId ?: "").append('\n')
        }
        writeAll(context, "games.tsv", out.toString())
        Log.i(TAG, "state=$state games=${games.size}")
    }

    private fun publishRunning(context: Context) {
        val key = running
        writeAll(context, "running.tsv", if (key != null) "running\t$key\n" else "")
        Log.i(TAG, "running=${key ?: "none"}")
    }

    private fun writeAll(context: Context, name: String, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val roots = listOfNotNull(context.getExternalFilesDir(null), context.filesDir)
        for (root in roots) File(root, "save").listFiles()?.filter { it.isDirectory }?.forEach { save ->
            try {
                val dir = File(save, DIR).apply { mkdirs() }
                val tmp = File(dir, "$name.part")
                tmp.writeBytes(bytes)
                tmp.renameTo(File(dir, name))
            } catch (e: Exception) { Log.w(TAG, "could not write $name into $save", e) }
        }
    }
}
