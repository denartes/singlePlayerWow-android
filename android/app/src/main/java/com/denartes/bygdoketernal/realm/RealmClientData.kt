package com.denartes.bygdoketernal.realm

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Downloads and extracts the WoW client data (maps/vmaps/mmaps/dbc) that
 * worldserver requires. This reuses the exact URL already proven by the
 * project's Termux install scripts; it is not a new/unproven mechanism.
 */
object RealmClientData {
    private const val DATA_URL = "https://github.com/wowgaming/client-data/releases/download/v16/data.zip"

    fun isPresent(clientDataDir: File): Boolean =
        File(clientDataDir, "dbc").isDirectory && File(clientDataDir, "maps").isDirectory

    fun download(clientDataDir: File, onProgress: (String) -> Unit) {
        if (isPresent(clientDataDir)) {
            onProgress("Client data already present; skipping download")
            return
        }

        onProgress("Downloading WoW client data (maps/vmaps/mmaps/dbc)...")
        val connection = URL(DATA_URL).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connect()
        check(connection.responseCode in 200..299) {
            "Client data download failed with HTTP ${connection.responseCode}"
        }

        clientDataDir.mkdirs()
        ZipInputStream(connection.inputStream.buffered()).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                val target = File(clientDataDir, entry.name)
                if (entry.isDirectory) {
                    target.mkdirs()
                } else {
                    target.parentFile?.mkdirs()
                    target.outputStream().use { output -> zip.copyTo(output) }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        onProgress("Client data extracted")
    }
}
