package com.tylerflores.pocketclaude.relay

import kotlinx.serialization.json.JsonObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * Talks to `relay/server.mjs`.
 *
 * Thin on purpose. Everything that involves a decision -- how the URL is built,
 * what the body carries, how the stream is framed -- lives in [RelayRequest]
 * and [SseParser], which have no Android or network dependency and are unit
 * tested. What is left here is the part that can only be proven by pointing it
 * at a real relay, so there is deliberately as little of it as possible.
 *
 * `HttpURLConnection` rather than a library: the whole surface is one POST that
 * streams a response, the platform does that, and a dependency here would be
 * one more version to keep right in a project that cannot compile Android
 * outside CI.
 */
class RelayClient(
    private val baseUrl: String,
    private val token: String,
) {

    /**
     * Asks a question and reports each event as it arrives.
     *
     * [onEvent] is called on the calling thread, which must not be the main
     * one. Chunks arrive many times a second during a fast answer, so whatever
     * consumes them should hand off rather than do work here.
     *
     * A turn can run for minutes, so the read timeout is generous while the
     * connect timeout stays short: failing to reach the relay at all should be
     * reported quickly, and only waiting for Claude should be slow.
     */
    fun ask(
        text: String,
        sessionId: String? = null,
        project: String? = null,
        model: String? = null,
        effort: String? = null,
        onEvent: (RelayEvent) -> Unit,
    ) {
        val body = RelayRequest.askBody(
            text = text,
            sessionId = sessionId,
            project = project,
            model = model,
            effort = effort,
        )
        stream(path = "ask", body = body, onEvent = onEvent)
    }

    private fun stream(path: String, body: JsonObject, onEvent: (RelayEvent) -> Unit) {
        val connection = (URL(RelayRequest.url(baseUrl, path)).openConnection()
            as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            // A real turn is 10-60 seconds and can be far longer. The relay
            // enforces its own ceiling (RELAY_TIMEOUT_MS), so this only needs
            // to be longer than that rather than correct in its own right.
            readTimeout = 10 * 60 * 1000
            setRequestProperty("Content-Type", "application/json")
            val (header, value) = RelayRequest.authorization(token)
            setRequestProperty(header, value)
            // Without this the platform may buffer, and a stream that arrives
            // all at once is not a stream -- the point is speaking the first
            // sentence before the last one exists.
            setChunkedStreamingMode(0)
        }

        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }

            val code = connection.responseCode
            if (code !in 200..299) {
                // The relay puts a reason in the body on a 4xx. Reading it is
                // the difference between "HTTP 400" and "text is required".
                val detail = connection.errorStream
                    ?.let { BufferedReader(InputStreamReader(it)).use(BufferedReader::readText) }
                    ?.take(300)
                    .orEmpty()
                onEvent(
                    RelayEvent.Failure(
                        if (detail.isBlank()) "The relay refused that (HTTP $code)."
                        else "The relay refused that (HTTP $code): $detail"
                    )
                )
                return
            }

            val parser = SseParser()
            connection.inputStream.reader().use { reader ->
                val chunk = CharArray(4096)
                while (true) {
                    val read = reader.read(chunk)
                    if (read == -1) break
                    // Whatever arrived, however it was split. SseParser holds a
                    // partial frame until the rest of it turns up.
                    parser.feed(String(chunk, 0, read)).forEach(onEvent)
                }
            }
        } finally {
            connection.disconnect()
        }
    }
}
