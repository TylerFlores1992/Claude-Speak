package com.tylerflores.pocketclaude

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Deliberately empty of behaviour.
 *
 * This module exists first so the build pipeline can be proven before anything
 * depends on it. Nothing in this repository can compile Android locally --
 * dl.google.com is egress-blocked from the build container, so the SDK cannot
 * be installed -- which makes CI the only thing that ever compiles this code.
 * A pipeline proven while there is nothing to lose is worth more than one
 * proven at the same time as the first feature.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { PocketClaudeApp() }
    }
}

@Composable
fun PocketClaudeApp() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text("PocketClaude", style = MaterialTheme.typography.headlineMedium)
                Text(
                    "Android client, not yet wired to the relay.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}
