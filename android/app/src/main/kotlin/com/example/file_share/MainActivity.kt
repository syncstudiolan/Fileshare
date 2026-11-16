package com.example.file_share

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.OpenableColumns
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Android system Sharesheet intake, including files shared from WhatsApp.
 *  Shares are copied to private staging; never sent until Flutter Send.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pending = mutableListOf<Map<String, String>>()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "file_share.native")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeSharedFiles" -> {
                    result.success(pending.toList())
                    pending.clear()
                }
                "startLanService" -> {
                    try {
                        val service = Intent(this, LanKeepAliveService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(service)
                        else startService(service)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BACKGROUND_RESTRICTED", e.message, null)
                    }
                }
                "stopLanService" -> {
                    stopService(Intent(this, LanKeepAliveService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        collectShared(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        collectShared(intent)
    }

    @Suppress("DEPRECATION")
    private fun collectShared(intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_SEND &&
            intent.action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = linkedSetOf<Uri>()
        intent.clipData?.let { clips ->
            for (index in 0 until clips.itemCount) {
                clips.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        if (intent.action == Intent.ACTION_SEND) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?.forEach { uris.add(it) }
        }
        val dir = File(filesDir, "fileshare_inbox")
        dir.mkdirs()
        for (uri in uris) {
            try {
                val filename = displayName(uri)
                    .replace(Regex("[/\\\\\\u0000-\\u001F]"), "_")
                    .takeLast(150)
                    .ifBlank { "shared_file" }
                val copy = File(dir, "stage_" + System.nanoTime().toString() + "_" + filename)
                contentResolver.openInputStream(uri)?.use { input ->
                    copy.outputStream().use { output -> input.copyTo(output) }
                }
                if (copy.exists()) pending.add(mapOf(
                    "name" to filename,
                    "path" to copy.absolutePath
                ))
            } catch (_: Exception) { /* Ignore an unreadable item only. */ }
        }
        if (pending.isNotEmpty()) channel?.invokeMethod("sharesReceived", true)
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
}

/** Helps keep the app's LAN process alive while the user leaves the UI.
 *  It cannot override Android 15's dataSync 6-hour background quota.
 */
class LanKeepAliveService : Service() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                "fileshare_lan", "LAN File Transfer",
                NotificationManager.IMPORTANCE_LOW))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(this, "fileshare_lan")
        else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("File Share")
            .setContentText("Ready for local Wi-Fi file transfers")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(4732, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else startForeground(4732, notification)
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("fileshare_discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) { }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY

    override fun onDestroy() {
        try { if (multicastLock?.isHeld == true) multicastLock?.release() }
        catch (_: Exception) { }
        multicastLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
