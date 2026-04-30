package com.example.api_selfxo_project

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

class BootReceiver : BroadcastReceiver() {
    private val launchFlags =
        Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED

    private fun shouldLaunch(action: String?): Boolean {
        return action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_USER_UNLOCKED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (!shouldLaunch(intent.action)) return

        val pendingResult = goAsync()
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                NativeLogStore.append(
                    context.applicationContext,
                    "[BOOT] launching app from ${intent.action}"
                )
                val launchIntent = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)
                    ?.apply {
                        addFlags(launchFlags)
                    }
                    ?: Intent(context, MainActivity::class.java).apply {
                        addFlags(launchFlags)
                    }
                context.startActivity(launchIntent)
            } catch (e: Exception) {
                NativeLogStore.append(
                    context.applicationContext,
                    "[BOOT] launch failed from ${intent.action}: ${e.message}"
                )
            } finally {
                pendingResult.finish()
            }
        }, 2000)
    }
}
