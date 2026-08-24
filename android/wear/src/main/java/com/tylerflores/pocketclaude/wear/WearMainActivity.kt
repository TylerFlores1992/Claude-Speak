package com.tylerflores.pocketclaude.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/**
 * Deliberately empty of behaviour, for the same reason as the phone's
 * MainActivity: the pipeline is proven before anything rides on it.
 *
 * The shape this will take is already settled, though, and it is not the shape
 * the watchOS app has. watchOS records audio and ships the file to the phone to
 * be transcribed, because the watch could not do it. Wear OS can:
 * RecognizerIntent.ACTION_RECOGNIZE_SPEECH runs on the watch, so what crosses
 * to the phone is a short string rather than a WAV. The phone still owns the
 * network, because Tailscale does not run here.
 */
class WearMainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { WearApp() }
    }
}

@Composable
fun WearApp() {
    MaterialTheme {
        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "PocketClaude",
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.title3
            )
            Text(
                text = "Not yet wired to the phone.",
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.caption2
            )
        }
    }
}
