package com.denartes.bygdoketernal

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.denartes.bygdoketernal.realm.ComponentStatus
import com.denartes.bygdoketernal.realm.RealmForegroundService
import com.denartes.bygdoketernal.realm.RealmRuntime

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op: notification is optional */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DashboardScreen(
                        onStart = { startForegroundService(Intent(this, RealmForegroundService::class.java)) },
                        onStop = {
                            startService(
                                Intent(this, RealmForegroundService::class.java)
                                    .setAction(RealmForegroundService.ACTION_STOP)
                            )
                        }
                    )
                }
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

@Composable
private fun DashboardScreen(onStart: () -> Unit, onStop: () -> Unit) {
    val state by RealmRuntime.state.collectAsState()
    val logLines by RealmRuntime.logLines.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp)
    ) {
        Text("BYGDOK ETERNAL", style = MaterialTheme.typography.headlineMedium)
        Spacer(modifier = Modifier.height(32.dp))
        Status("Database", state.database)
        Status("Authserver", state.authserver)
        Status("Worldserver", state.worldserver)
        Spacer(modifier = Modifier.height(24.dp))
        Button(
            onClick = if (state.isRunning || state.isBusy) onStop else onStart,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                when {
                    state.isBusy -> "STARTING..."
                    state.isRunning -> "STOP REALM"
                    else -> "START REALM"
                }
            )
        }
        Spacer(modifier = Modifier.height(32.dp))
        Text("Server Log", style = MaterialTheme.typography.titleLarge)
        Spacer(modifier = Modifier.height(8.dp))
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
            items(logLines) { line ->
                Text(text = line, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun Status(label: String, status: ComponentStatus) {
    Text(
        text = "$label\n${status.name}",
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier.padding(vertical = 6.dp)
    )
}