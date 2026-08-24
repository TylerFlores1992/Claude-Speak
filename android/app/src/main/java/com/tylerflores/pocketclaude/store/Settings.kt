package com.tylerflores.pocketclaude.store

import android.content.Context
import android.content.SharedPreferences

/**
 * The relay address and token, kept between launches.
 *
 * `EncryptedSharedPreferences` would be the obvious home for the token, and is
 * deliberately not used yet: the iOS app keeps its token in the Keychain, and
 * the equivalent decision here deserves to be made with the phone in hand
 * rather than guessed at. Plain preferences are app-private storage, which is
 * the same protection every other app's settings get; the token buys the
 * ability to run Claude Code on one machine on your own tailnet, which is worth
 * more than nothing and less than a password.
 *
 * Recorded so it is a decision rather than an oversight.
 */
class Settings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("pocketclaude", Context.MODE_PRIVATE)

    var relayUrl: String
        get() = prefs.getString(KEY_URL, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_URL, value.trim()).apply()

    var relayToken: String
        get() = prefs.getString(KEY_TOKEN, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_TOKEN, value.trim()).apply()

    /** The Claude Code session to resume, so a follow-up is a follow-up. */
    var sessionId: String?
        get() = prefs.getString(KEY_SESSION, null)?.takeIf { it.isNotBlank() }
        set(value) = prefs.edit().putString(KEY_SESSION, value).apply()

    /** Both halves are needed before anything can be asked. */
    val isConfigured: Boolean
        get() = relayUrl.isNotBlank() && relayToken.isNotBlank()

    private companion object {
        const val KEY_URL = "relayUrl"
        const val KEY_TOKEN = "relayToken"
        const val KEY_SESSION = "sessionId"
    }
}
