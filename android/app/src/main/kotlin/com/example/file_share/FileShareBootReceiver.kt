package com.example.file_share

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Restart the existing connectedDevice receiver after a device reboot.
 * This only happens once the user has opened File Share and enabled its
 * background receiver. Android force-stop and OEM power restrictions cannot
 * be bypassed; do not launch the full-screen UI from boot.
 */
class FileShareBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED) return
        val enabled = context.getSharedPreferences(
            "file_share_background", Context.MODE_PRIVATE
        ).getBoolean("lan_boot_receiver_enabled", false)
        if (!enabled) return
        try {
            val service = Intent(context, LanKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (e: RuntimeException) {
            // Android's FGS start restrictions and user battery policy take
            // priority. The next manual app launch starts receiving again.
            Log.w("FileShareBoot", "Unable to restore LAN receiver at boot", e)
        }
    }
}
