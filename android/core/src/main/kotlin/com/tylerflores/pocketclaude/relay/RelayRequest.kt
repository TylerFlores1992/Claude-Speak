package com.tylerflores.pocketclaude.relay

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Builds what goes on the wire, without putting anything on it.
 *
 * Split from the code that opens a socket so the decisions can be unit tested:
 * how a base address and a path are joined, and which fields the body carries.
 * Both have already been a bug on the iOS side -- a query string folded into
 * URLComponents.path came back percent-encoded and the relay answered 400 to
 * every transcript request, and the History button that depended on it was
 * correctly hidden every time.
 */
object RelayRequest {

    /**
     * Joins a base address and a relay path.
     *
     * Tolerates what someone actually types in a settings field: a trailing
     * slash or none, and a scheme or none. A bare `host:port` is assumed to be
     * `http`, because the relay is reached over Tailscale, which is already
     * encrypted -- requiring someone to type `http://` to reach their own
     * machine is a papercut that reads as a broken address.
     */
    fun url(baseUrl: String, path: String): String {
        val trimmed = baseUrl.trim()
        require(trimmed.isNotEmpty()) { "the relay address is empty" }

        val withScheme =
            if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) trimmed
            else "http://$trimmed"

        return withScheme.trimEnd('/') + "/" + path.trimStart('/')
    }

    /**
     * The body for `POST /ask`.
     *
     * `model` and `effort` are omitted rather than sent empty when unset. The
     * relay reads them as `typeof payload.model === "string" ? payload.model :
     * ""`, so an empty string is a value it would act on; leaving the key out
     * is what lets the server's own configuration decide.
     *
     * `sessionId` is likewise omitted when absent, because the relay treats
     * only a non-empty string as a session to resume.
     */
    fun askBody(
        text: String,
        sessionId: String? = null,
        project: String? = null,
        model: String? = null,
        effort: String? = null,
    ): JsonObject = buildJsonObject {
        put("text", text)
        sessionId?.takeIf { it.isNotBlank() }?.let { put("sessionId", it) }
        project?.takeIf { it.isNotBlank() }?.let { put("project", it) }
        model?.takeIf { it.isNotBlank() }?.let { put("model", it) }
        effort?.takeIf { it.isNotBlank() }?.let { put("effort", it) }
    }

    /** The one header every route but `/health` requires. */
    fun authorization(token: String): Pair<String, String> =
        "Authorization" to "Bearer ${token.trim()}"
}
