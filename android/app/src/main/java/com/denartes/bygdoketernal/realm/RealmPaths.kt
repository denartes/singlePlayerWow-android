package com.denartes.bygdoketernal.realm

import android.content.Context
import java.io.File

/** Centralizes the on-device directory layout for the embedded realm runtime. */
class RealmPaths(context: Context) {
    val root: File = File(context.filesDir, "realm")
    val dataDir: File = File(root, "data")
    val clientDataDir: File = File(root, "client-data")
    val etcDir: File = File(root, "etc")
    val logsDir: File = File(root, "logs")
    val sqlDir: File = File(root, "sql")
    val mariadbBaseDir: File = File(root, "mariadb-basedir")
    val socketFile: File = File(root, "mysqld.sock")
    val pidFile: File = File(root, "mysqld.pid")

    val authserverConf: File = File(etcDir, "authserver.conf")
    val worldserverConf: File = File(etcDir, "worldserver.conf")

    val nativeLibraryDir: String = context.applicationInfo.nativeLibraryDir

    fun ensureDirectories() {
        for (dir in listOf(root, dataDir, clientDataDir, etcDir, logsDir, sqlDir, mariadbBaseDir)) {
            dir.mkdirs()
        }
    }
}
