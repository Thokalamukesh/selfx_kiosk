package com.example.api_selfxo_project

import android.content.Context
import android.os.Build
import java.io.File

object NativeLogStore {
    private const val FILE_NAME = "printer_debug.log"
    private val lock = Any()

    private fun storageContext(context: Context): Context {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }
    }

    fun append(context: Context, message: String) {
        synchronized(lock) {
            val file = File(storageContext(context).filesDir, FILE_NAME)
            file.appendText(message + "\n")
        }
    }

    fun readLines(context: Context, maxLines: Int = 300): List<String> {
        synchronized(lock) {
            val file = File(storageContext(context).filesDir, FILE_NAME)
            if (!file.exists()) return emptyList()
            val lines = file.readLines()
            return if (lines.size <= maxLines) lines else lines.takeLast(maxLines)
        }
    }

    fun clear(context: Context) {
        synchronized(lock) {
            val file = File(storageContext(context).filesDir, FILE_NAME)
            if (file.exists()) {
                file.delete()
            }
        }
    }
}
