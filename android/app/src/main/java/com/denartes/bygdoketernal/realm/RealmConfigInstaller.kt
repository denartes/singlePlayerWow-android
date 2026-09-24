package com.denartes.bygdoketernal.realm

import android.content.Context
import java.io.File

/**
 * Copies the canonical authserver/worldserver configs and the SQL update
 * tree from APK assets into app-private storage, patching only the handful
 * of paths that must become on-device absolute paths. Database connection
 * strings are left untouched: the repository's default
 * `127.0.0.1;3306;acore;acore;<db>` already matches the embedded mariadbd.
 */
class RealmConfigInstaller(private val context: Context, private val paths: RealmPaths) {

    fun install() {
        installConfig("authserver.conf", paths.authserverConf) { line ->
            patchDirective(line, "LogsDir", paths.logsDir.absolutePath)
                ?: patchDirective(line, "SourceDirectory", paths.sqlDir.absolutePath)
                ?: line
        }
        installConfig("worldserver.conf", paths.worldserverConf) { line ->
            patchDirective(line, "LogsDir", paths.logsDir.absolutePath)
                ?: patchDirective(line, "SourceDirectory", paths.sqlDir.absolutePath)
                ?: patchDirective(line, "DataDir", paths.clientDataDir.absolutePath)
                ?: line
        }
        copyAssetTreeIfPresent("sql", paths.sqlDir)
        copyAssetTreeIfPresent("mariadb-share", File(paths.mariadbBaseDir, "share"))
    }

    private fun installConfig(assetName: String, destination: File, patchLine: (String) -> String) {
        val text = context.assets.open(assetName).bufferedReader().use { it.readText() }
        val patched = text.lineSequence().joinToString("\n") { patchLine(it) }
        destination.writeText(patched)
    }

    /** Matches `Key = "value"` or `Key = value` at the start of a config line. */
    private fun patchDirective(line: String, key: String, newValue: String): String? {
        val trimmed = line.trimStart()
        if (!trimmed.startsWith("$key ") && !trimmed.startsWith("$key=")) return null
        val equalsIndex = line.indexOf('=')
        if (equalsIndex < 0) return null
        val prefix = line.substring(0, equalsIndex + 1)
        return "$prefix \"$newValue\""
    }

    private fun copyAssetTreeIfPresent(assetPath: String, destinationDir: File) {
        val entries = context.assets.list(assetPath) ?: return
        if (entries.isEmpty()) {
            // A leaf file rather than a directory.
            destinationDir.parentFile?.mkdirs()
            context.assets.open(assetPath).use { input ->
                destinationDir.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }
        destinationDir.mkdirs()
        for (entry in entries) {
            copyAssetTreeIfPresent("$assetPath/$entry", File(destinationDir, entry))
        }
    }
}
