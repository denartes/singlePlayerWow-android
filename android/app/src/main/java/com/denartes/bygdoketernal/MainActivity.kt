package com.denartes.bygdoketernal

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DashboardScreen()
                }
            }
        }
    }
}

@Composable
private fun DashboardScreen() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center
    ) {
        Text("BYGDOK ETERNAL", style = MaterialTheme.typography.headlineMedium)
        Spacer(modifier = Modifier.height(32.dp))
        Status("Realm")
        Status("Authserver")
        Status("Worldserver")
        Status("Database")
        Spacer(modifier = Modifier.height(24.dp))
        Button(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) {
            Text("START REALM")
        }
        Spacer(modifier = Modifier.height(32.dp))
        Text("Server Log", style = MaterialTheme.typography.titleLarge)
        Spacer(modifier = Modifier.height(8.dp))
        Text("Native runtime integration is not yet implemented.")
    }
}

@Composable
private fun Status(label: String) {
    Text(
        text = "$label\nNot configured",
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier.padding(vertical = 6.dp)
    )
}