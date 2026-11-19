package com.example.file_share

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import android.content.ContentValues
import android.os.Environment
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * One cached FlutterEngine remains alive while the UI Activity is removed.
 * The connectedDevice foreground service keeps the LAN process available.
 * Android force-stop, reboot and OEM battery kills are still OS limitations.
 */
class FileShareApplication : Application() {
    companion object {
        const val ENGINE_ID = "file_share_lan"
        const val CHANNEL_NAME = "file_share.native"
    }
    private val shared = mutableListOf<Map<String, String>>()
    private var channel: MethodChannel? = null

    @Synchronized
    fun engine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(this)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "openUpstreamPdfTools" -> try {
                    val options = call.arguments as? Map<*, *>
                    val path = options?.get("path") as? String
                    val launch = Intent(this, com.sammyi57.pdftools.MainActivity::class.java)
                    launch.putExtra("fileshare.pdf.theme", options?.get("theme") as? String ?: "system")
                    launch.putExtra("fileshare.pdf.embedded", true)
                    launch.putExtra("fileshare.pdf.share", options?.get("action") == "share")
                    if (!path.isNullOrBlank()) {
                        val input = File(path)
                        require(input.isFile && input.canRead()) { "PDF file unavailable" }
                        require(input.extension.equals("pdf", ignoreCase = true)) { "Expected a PDF file" }
                        launch.action = Intent.ACTION_VIEW
                        launch.putExtra("fileshare.pdf.path", input.absolutePath)
                    }
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launch)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("PDF_TOOLS_OPEN_FAILED", e.message, null)
                }
                "zipSafDirectory" -> {
                    val uriString = call.argument<String>("uri")
                    val targetPath = call.argument<String>("target")
                    val folderName = call.argument<String>("name")
                    if (uriString.isNullOrBlank() || targetPath.isNullOrBlank()) {
                        result.error("FOLDER_URI_MISSING", "Select a folder", null)
                    } else {
                        Thread {
                            val target = File(targetPath)
                            try {
                                val tree = Uri.parse(uriString)
                                require(tree.scheme == "content") { "Expected a SAF folder" }
                                target.parentFile?.mkdirs()
                                ZipOutputStream(target.outputStream().buffered()).use { zip ->
                                    val rootName = safeZipSegment(folderName ?: "Folder")
                                    zipSafChildren(tree,
                                        DocumentsContract.getTreeDocumentId(tree),
                                        "$rootName/", zip, 0, intArrayOf(0))
                                }
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.success(mapOf("path" to target.absolutePath))
                                }
                            } catch (e: Exception) {
                                target.delete()
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.error("SAF_FOLDER_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                }
                "saveReceivedFile" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    val image = call.argument<Boolean>("image") ?: false
                    if (path.isNullOrEmpty() || name.isNullOrEmpty()) {
                        result.error("INVALID_FILE", "File path or name missing", null)
                    } else {
                        Thread {
                            try {
                                val uri = saveReceivedToPublicCollection(File(path), name, image)
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.success(uri.toString())
                                }
                            } catch (e: Exception) {
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.error("SAVE_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                }
                "convertDocxToPdf" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("DOCX_PATH_MISSING", "Select a DOCX file", null)
                    } else {
                        // Avoid synchronous ZIP/XML/PDF work on the Flutter platform UI thread.
                        Thread {
                            try {
                                val converted = DocxPreviewPdf.convert(File(path), cacheDir)
                                runOnUiThread { result.success(converted.absolutePath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("DOCX_CONVERSION_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                }
                "takeSharedFiles" -> {
                    synchronized(shared) {
                        result.success(shared.toList())
                        shared.clear()
                    }
                }
                "startLanService" -> try {
                    val background = getSharedPreferences(
                        "file_share_background", Context.MODE_PRIVATE)
                    if (!background.contains("lan_boot_receiver_enabled")) {
                        background.edit().putBoolean("lan_boot_receiver_enabled", true).apply()
                    }
                    if (background.getBoolean("lan_boot_receiver_enabled", true)) {
                        val intent = Intent(this, LanKeepAliveService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                        else startService(intent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.error("BACKGROUND_RESTRICTED", e.message, null)
                }
                "setLanBootReceiver" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    getSharedPreferences("file_share_background", Context.MODE_PRIVATE)
                        .edit().putBoolean("lan_boot_receiver_enabled", enabled).apply()
                    if (enabled) {
                        try {
                            val intent = Intent(this, LanKeepAliveService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                            else startService(intent)
                        } catch (e: Exception) {
                            result.error("BACKGROUND_RESTRICTED", e.message, null)
                            return@setMethodCallHandler
                        }
                    } else {
                        stopService(Intent(this, LanKeepAliveService::class.java))
                    }
                    result.success(enabled)
                }
                "getLanBootReceiver" -> {
                    result.success(getSharedPreferences(
                        "file_share_background", Context.MODE_PRIVATE)
                        .getBoolean("lan_boot_receiver_enabled", true))
                }
                "stopLanService" -> {
                    stopService(Intent(this, LanKeepAliveService::class.java))
                    result.success(true)
                }
                "notifyReceived" -> {
                    val name = call.argument<String>("name") ?: "a file"
                    val sender = call.argument<String>("sender") ?: "Nearby device"
                    notifyFile(name, sender)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        return engine
    }

    override fun onCreate() {
        super.onCreate()
        // Lazy engine creation: the Activity or foreground LAN service calls
        // engine(). A disabled BOOT_COMPLETED receiver must not start Dart.
    }

    private fun safeZipSegment(input: String): String =
        input.replace('/', '_').replace('\\', '_')
            .replace("..", "_").filter { it.code >= 32 }
            .take(120).ifBlank { "unnamed" }

    /**
     * Recursively stream SAF files into an archive, without exposing device
     * paths or following symbolic links. Preserve nested folder structure.
     * Bounded depth/count defend against pathological provider trees.
     */
    private fun zipSafChildren(tree: Uri, documentId: String,
                               prefix: String, zip: ZipOutputStream,
                               depth: Int, count: IntArray) {
        require(depth < 40) { "Folder nesting too deep" }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
        contentResolver.query(children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE),
            null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                count[0]++
                require(count[0] <= 100000) { "Too many folder items" }
                val childId = cursor.getString(0)
                val filename = safeZipSegment(cursor.getString(1) ?: "unnamed")
                val mime = cursor.getString(2)
                val childUri = DocumentsContract.buildDocumentUriUsingTree(tree, childId)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val dirname = "$prefix$filename/"
                    zip.putNextEntry(ZipEntry(dirname))
                    zip.closeEntry()
                    zipSafChildren(tree, childId, dirname, zip, depth + 1, count)
                } else {
                    zip.putNextEntry(ZipEntry("$prefix$filename"))
                    try {
                        val input = contentResolver.openInputStream(childUri)
                            ?: throw IllegalStateException("Cannot read $filename")
                        input.use { it.copyTo(zip, 256 * 1024) }
                    } finally {
                        zip.closeEntry()
                    }
                }
            }
        } ?: throw IllegalStateException("Cannot browse selected folder")
    }

    /**
     * On Android 10+ use public MediaStore, not the private downloads cache:
     * photographs go into DCIM/FileShare and are immediately gallery-visible;
     * other MIME types go into public Download/FileShare.
     * IS_PENDING hides incomplete copies. On failure the row is removed.
     */
    private fun saveReceivedToPublicCollection(source: File, originalName: String,
                                               image: Boolean): Uri {
        require(source.isFile && source.canRead()) { "Received file unavailable" }
        val clean = originalName.replace('/', '_').replace('\\', '_')
            .filter { it.code >= 32 }.takeLast(160).ifBlank { "received_file" }
        val ext = clean.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: if (image) "image/jpeg" else "application/octet-stream"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val target = if (image) MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                         else MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val subdir = if (image) Environment.DIRECTORY_DCIM + "/FileShare"
                         else Environment.DIRECTORY_DOWNLOADS + "/FileShare"
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, clean)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, subdir)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(target, values)
                ?: throw IllegalStateException("Could not create public destination")
            try {
                contentResolver.openOutputStream(uri)?.use { stream ->
                    source.inputStream().use { input -> input.copyTo(stream, 256 * 1024) }
                } ?: throw IllegalStateException("Could not open destination stream")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                return uri
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
        }
        // Old Android versions lack scoped-storage MediaStore downloads APIs.
        // Preserve data in the app's external files, rather than silently fail.
        val dir = File(getExternalFilesDir(
            if (image) Environment.DIRECTORY_PICTURES
            else Environment.DIRECTORY_DOWNLOADS), "FileShare").apply { mkdirs() }
        var target = File(dir, clean)
        var i = 1
        while (target.exists()) target = File(dir, "${i++}_$clean")
        source.copyTo(target)
        return Uri.fromFile(target)
    }



    /** Copies an internally created PDF to the same persistent staging queue as incoming files.
     * The user must still press Send. No network transfer starts here.
     */
    @Synchronized
    fun stagePdfFromTools(source: File, suggestedName: String): Boolean {
        if (!source.isFile || !source.canRead() ||
            !source.extension.equals("pdf", ignoreCase = true)) return false
        val safe = suggestedName.replace('/', '_').replace(92.toChar(), '_')
            .filter { it.code >= 32 }.take(140).ifBlank { "document.pdf" }
        val name = if (safe.endsWith(".pdf", ignoreCase = true)) safe else "$safe.pdf"
        val folder = File(filesDir, "fileshare_inbox").apply { mkdirs() }
        val copy = File(folder, "pdf_cart_" + System.nanoTime() + "_" + name)
        return try {
            source.copyTo(copy)
            synchronized(shared) {
                shared.add(mapOf("name" to name, "path" to copy.absolutePath))
            }
            notifySharedToUi()
            true
        } catch (_: Exception) {
            copy.delete()
            false
        }
    }

    fun notifySharedToUi() {
        channel?.invokeMethod("sharesReceived", true)
    }

    @Suppress("DEPRECATION")
    fun collectShared(intent: Intent?) {
        if (intent == null || (intent.action != Intent.ACTION_SEND &&
                intent.action != Intent.ACTION_SEND_MULTIPLE)) return
        val uris = linkedSetOf<Uri>()
        intent.clipData?.let { clips ->
            for (i in 0 until clips.itemCount)
                clips.getItemAt(i).uri?.let(uris::add)
        }
        if (intent.action == Intent.ACTION_SEND) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?.forEach(uris::add)
        }
        val dir = File(filesDir, "fileshare_inbox")
        dir.mkdirs()
        for (uri in uris) {
            try {
                val safe = displayName(uri)
                    .replace('/', '_').replace('\\', '_')
                    .filter { it.code >= 32 }.takeLast(150).ifBlank { "shared_file" }
                val copy = File(dir, "stage_" + System.nanoTime() + "_" + safe)
                contentResolver.openInputStream(uri)?.use { input ->
                    copy.outputStream().use { output -> input.copyTo(output) }
                }
                if (copy.exists()) synchronized(shared) {
                    shared.add(mapOf("name" to safe, "path" to copy.absolutePath))
                }
            } catch (_: Exception) { }
        }
        synchronized(shared) {
            if (shared.isNotEmpty()) notifySharedToUi()
        }
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
        } catch (_: Exception) { }
        return uri.lastPathSegment ?: "shared_file"
    }

    private fun notifyFile(name: String, sender: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                "fileshare_received", "Files received", NotificationManager.IMPORTANCE_DEFAULT
            ))
        }
        val open = PendingIntent.getActivity(
            this, 4711,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notice = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, "fileshare_received")
        else Notification.Builder(this)
        manager.notify(
            (System.currentTimeMillis() % Int.MAX_VALUE).toInt(),
            notice.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("File from " + sender)
                .setContentText(name)
                .setStyle(Notification.BigTextStyle().bigText(name))
                .setContentIntent(open).setAutoCancel(true).build()
        )
    }
}

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as FileShareApplication).engine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        (application as FileShareApplication).collectShared(intent)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4701)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as FileShareApplication).collectShared(intent)
    }

    override fun onResume() {
        super.onResume()
        (application as FileShareApplication).notifySharedToUi()
    }
}

/**
 * The connectedDevice type supports nearby computer/phone communication.
 * No 6h dataSync quota; OEM battery limits and force-stop still apply.
 */
class LanKeepAliveService : Service() {
    private var multicast: WifiManager.MulticastLock? = null
    override fun onCreate() {
        super.onCreate()
        (application as FileShareApplication).engine()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("fileshare_lan", "Background LAN",
                NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(
            this, 4722, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, "fileshare_lan")
        else Notification.Builder(this)
        val notification = notice
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("File Share • LAN ready")
            .setContentText("Ready to receive files on local Wi-Fi")
            .setContentIntent(open).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(
            4732, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(4732, notification)
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("fileshare_discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) { }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY
    override fun onDestroy() {
        try { if (multicast?.isHeld == true) multicast?.release() }
        catch (_: Exception) { }
        multicast = null
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
