import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.denartes.bygdoketernal"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.denartes.bygdoketernal"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            // The canonical authserver/worldserver config templates live at
            // the repository root; expose them as assets without copying.
            assets.srcDirs("src/main/assets", "../../configs")
        }
    }

    packaging {
        // The embedded native binaries are ELF executables, not real shared
        // libraries; keep their original bytes uncompressed and unmodified.
        jniLibs.useLegacyPackaging = true
    }
}

// Stages the compiled server-runtime artifact (authserver, worldserver,
// mariadbd, and their .so dependencies) into jniLibs so Android installs
// them into the app's executable nativeLibraryDir. Renamed to the
// lib<name>.so convention because only files named that way, under
// jniLibs/<abi>/, are extracted to a location the OS will execute from
// (Android blocks executing arbitrary files from app-writable storage).
// If the runtime artifact hasn't been built/downloaded, this is a no-op
// and the resulting APK is dashboard-only, exactly as before this change.
val nativeRuntimeDir = file("../../runtime/build/bygdok-runtime-arm64")
val jniLibsDir = file("src/main/jniLibs/arm64-v8a")
val assetsSqlDir = file("src/main/assets/sql")

tasks.register("embedNativeRuntime") {
    doLast {
        if (!nativeRuntimeDir.exists()) {
            logger.lifecycle("[embedNativeRuntime] No runtime artifact at $nativeRuntimeDir; building dashboard-only APK.")
            return@doLast
        }

        jniLibsDir.mkdirs()

        val executableRenames = mapOf(
            "authserver" to "libauthserver.so",
            "worldserver" to "libworldserver.so",
            "mariadbd" to "libmariadbd.so",
            "mariadb_client" to "libmariadbclient.so"
        )
        val binDir = File(nativeRuntimeDir, "bin")
        executableRenames.forEach { (sourceName, destName) ->
            val sourceFile = File(binDir, sourceName)
            if (sourceFile.exists()) {
                sourceFile.copyTo(File(jniLibsDir, destName), overwrite = true)
            }
        }

        val libDir = File(nativeRuntimeDir, "lib")
        if (libDir.exists()) {
            libDir.listFiles { candidate -> candidate.extension == "so" }?.forEach { library ->
                library.copyTo(File(jniLibsDir, library.name), overwrite = true)
            }
        }

        val sqlDir = File(nativeRuntimeDir, "sql")
        if (sqlDir.exists()) {
            sqlDir.copyRecursively(assetsSqlDir, overwrite = true)
        }

        logger.lifecycle("[embedNativeRuntime] Embedded native runtime from $nativeRuntimeDir")
    }
}

tasks.named("preBuild") {
    dependsOn("embedNativeRuntime")
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
}