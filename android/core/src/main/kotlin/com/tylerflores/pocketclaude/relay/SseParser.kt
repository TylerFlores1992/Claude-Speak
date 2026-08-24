package com.tylerflores.pocketclaude.relay

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Turns the relay's SSE byte stream into events.
 *
 * Deliberately free of any Android import. Everything that can go wrong here
 * is ordinary text handling, and keeping it on plain Kotlin means it runs as a
 * JVM unit test -- which matters more than usual on this side of the project,
 * because nothing Android can be compiled outside CI and nothing at all can be
 * run on a device from here.
 *
 * The frame format is `event: <name>\n` `data: <json>\n` `\n`, written by
 * `sse()` in relay/server.mjs.
 *
 * **Feed it whatever arrives.** A socket read boundary has nothing to do with
 * a frame boundary: one read can carry half a frame, three frames, or the tail
 * of one and the head of the next. So bytes accumulate here until a blank line
 * proves a frame is complete, and a trailing partial stays buffered for the
 * next read rather than being parsed early and lost. That exact mistake --
 * treating a read as a message -- is what silently dropped every answer on the
 * relay side once, and it is worth not making twice.
 */
class SseParser {

    private val buffer = StringBuilder()

    private val json = Json {
        // The relay may add fields; an old client should keep working.
        ignoreUnknownKeys = true
        isLenient = true
    }

    /**
     * Adds what just arrived and returns every event now complete.
     *
     * Returns an empty list when the bytes so far do not finish a frame, which
     * is normal and not a failure.
     */
    fun feed(text: String): List<RelayEvent> {
        buffer.append(text)
        val events = mutableListOf<RelayEvent>()

        while (true) {
            val end = indexOfFrameEnd() ?: break
            val frame = buffer.substring(0, end.first)
            buffer.delete(0, end.second)
            parseFrame(frame)?.let(events::add)
        }
        return events
    }

    /**
     * Where the next complete frame ends, as (content end, consume through).
     *
     * A frame is terminated by a blank line. Both `\n\n` and `\r\n\r\n` are
     * accepted: the relay writes the former, but nothing about SSE promises no
     * proxy will normalise line endings on the way, and a client that only
     * understood one would fail in a way that looks like the relay going
     * silent.
     */
    private fun indexOfFrameEnd(): Pair<Int, Int>? {
        val lf = buffer.indexOf("\n\n")
        val crlf = buffer.indexOf("\r\n\r\n")
        return when {
            lf == -1 && crlf == -1 -> null
            crlf != -1 && (lf == -1 || crlf < lf) -> crlf to crlf + 4
            else -> lf to lf + 2
        }
    }

    private fun parseFrame(frame: String): RelayEvent? {
        var name: String? = null
        val data = StringBuilder()

        for (rawLine in frame.split("\n")) {
            val line = rawLine.removeSuffix("\r")
            when {
                line.startsWith("event:") -> name = line.removePrefix("event:").trim()
                // Multiple data: lines concatenate, per the SSE spec. The relay
                // writes one, but a client that assumed so would be guessing.
                line.startsWith("data:") -> {
                    if (data.isNotEmpty()) data.append('\n')
                    data.append(line.removePrefix("data:").trim())
                }
                // ":" alone is an SSE comment, used as a keep-alive. Ignored.
            }
        }

        val payload = data.toString()
        if (name == null || payload.isEmpty()) return null
        return decode(name, payload)
    }

    /**
     * A frame whose JSON will not parse is dropped rather than thrown.
     *
     * This is not the swallowing this project keeps finding: a malformed frame
     * mid-stream is one lost delta in a stream that reconciles against `result`
     * at the end, whereas throwing would abandon an answer that is still
     * arriving. The end of the turn is what decides success, not any one frame.
     */
    private fun decode(name: String, payload: String): RelayEvent? {
        val obj = try {
            json.parseToJsonElement(payload).jsonObject
        } catch (e: Exception) {
            return null
        }

        fun str(key: String): String? =
            runCatching { obj[key]?.jsonPrimitive?.contentOrNullSafe() }.getOrNull()

        return when (name) {
            "session" -> RelayEvent.Session(str("sessionId"))
            "chunk" -> RelayEvent.Chunk(str("text") ?: return null)
            "status" -> RelayEvent.Status(str("text") ?: return null)
            "tool" -> {
                val names = runCatching {
                    obj["names"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNullSafe() }
                }.getOrNull().orEmpty()
                if (names.isEmpty()) null else RelayEvent.Tool(names)
            }
            "done" -> RelayEvent.Done(
                sessionId = str("sessionId"),
                costUsd = runCatching { obj["costUSD"]?.jsonPrimitive?.content?.toDouble() }
                    .getOrNull(),
                isError = runCatching { obj["isError"]?.jsonPrimitive?.content == "true" }
                    .getOrDefault(false),
                result = str("result"),
            )
            // The relay sends `message` here, not `text`. Getting that wrong
            // would show an empty error, which reads as no error at all.
            "error" -> RelayEvent.Failure(str("message") ?: "The relay stopped without saying why.")
            else -> null
        }
    }
}

/**
 * `content` for a real value, null for JSON null.
 *
 * kotlinx.serialization returns the string "null" from `content` for a JSON
 * null, so a sessionId that is genuinely absent would arrive as the four
 * characters n-u-l-l and be passed to `--resume` as if it were an id.
 */
private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
    if (this is kotlinx.serialization.json.JsonNull) null else content
