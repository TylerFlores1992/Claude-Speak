package com.tylerflores.pocketclaude.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The frames here are written the way relay/server.mjs writes them:
 * `event: <name>\ndata: <json>\n\n`. If that changes, these should fail.
 */
class SseParserTest {

    private fun frame(event: String, data: String) = "event: $event\ndata: $data\n\n"

    @Test
    fun readsOneCompleteFrame() {
        val events = SseParser().feed(frame("chunk", """{"kind":"chunk","text":"hello"}"""))
        assertEquals(listOf(RelayEvent.Chunk("hello")), events)
    }

    @Test
    fun readsSeveralFramesFromOneRead() {
        // A fast turn puts many deltas into a single socket read.
        val parser = SseParser()
        val events = parser.feed(
            frame("session", """{"sessionId":"abc"}""") +
                frame("chunk", """{"text":"one "}""") +
                frame("chunk", """{"text":"two"}""")
        )
        assertEquals(
            listOf(
                RelayEvent.Session("abc"),
                RelayEvent.Chunk("one "),
                RelayEvent.Chunk("two"),
            ),
            events
        )
    }

    @Test
    fun aFrameSplitAcrossReadsIsNotLost() {
        // The bug this class exists to avoid. A read boundary has nothing to do
        // with a frame boundary, and treating one as the other silently drops
        // answers -- which is exactly what happened on the relay side once.
        val parser = SseParser()
        val whole = frame("chunk", """{"text":"split me"}""")

        for (cut in 1 until whole.length) {
            val fresh = SseParser()
            val first = fresh.feed(whole.substring(0, cut))
            val second = fresh.feed(whole.substring(cut))
            assertEquals(
                "cut at $cut produced the wrong events",
                listOf(RelayEvent.Chunk("split me")),
                first + second
            )
        }
        // And once more byte by byte, which is the worst case.
        var collected = emptyList<RelayEvent>()
        for (ch in whole) collected = collected + parser.feed(ch.toString())
        assertEquals(listOf(RelayEvent.Chunk("split me")), collected)
    }

    @Test
    fun aPartialFrameYieldsNothingYet() {
        val parser = SseParser()
        assertTrue(parser.feed("event: chunk\ndata: {\"text\":\"wai").isEmpty())
        assertEquals(
            listOf(RelayEvent.Chunk("waiting")),
            parser.feed("ting\"}\n\n")
        )
    }

    @Test
    fun handlesCarriageReturnsFromAProxy() {
        // The relay writes bare newlines, but nothing promises no hop between
        // here and it normalises line endings.
        val events = SseParser().feed("event: chunk\r\ndata: {\"text\":\"crlf\"}\r\n\r\n")
        assertEquals(listOf(RelayEvent.Chunk("crlf")), events)
    }

    @Test
    fun readsTheEndOfATurn() {
        val events = SseParser().feed(
            frame(
                "done",
                """{"sessionId":"s1","costUSD":0.0123,"isError":false,"result":"the answer"}"""
            )
        )
        val done = events.single() as RelayEvent.Done
        assertEquals("s1", done.sessionId)
        assertEquals(0.0123, done.costUsd!!, 1e-9)
        assertEquals(false, done.isError)
        assertEquals("the answer", done.result)
    }

    @Test
    fun aNullSessionIdIsNullAndNotTheWordNull() {
        // kotlinx.serialization hands back the string "null" for a JSON null,
        // so an absent id would be passed to --resume as four characters.
        val events = SseParser().feed(frame("session", """{"sessionId":null}"""))
        assertNull((events.single() as RelayEvent.Session).sessionId)
    }

    @Test
    fun readsToolNames() {
        val events = SseParser().feed(frame("tool", """{"names":["Read","Bash"]}"""))
        assertEquals(listOf("Read", "Bash"), (events.single() as RelayEvent.Tool).names)
    }

    @Test
    fun anErrorCarriesMessageNotText() {
        // The relay sends `message` here and `text` everywhere else. Reading
        // the wrong key would show an empty error, which reads as no error.
        val events = SseParser().feed(frame("error", """{"message":"Timed out after 300s"}"""))
        assertEquals(
            RelayEvent.Failure("Timed out after 300s"),
            events.single()
        )
    }

    @Test
    fun anErrorWithNoMessageStillSaysSomething() {
        val events = SseParser().feed(frame("error", """{}"""))
        assertTrue((events.single() as RelayEvent.Failure).message.isNotBlank())
    }

    @Test
    fun malformedJsonCostsOneFrameAndNotTheStream() {
        // Dropping a bad frame is deliberate: the stream reconciles against
        // `result` at the end, so one lost delta is recoverable and throwing
        // would abandon an answer still arriving.
        val parser = SseParser()
        val events = parser.feed(
            frame("chunk", "{not json") + frame("chunk", """{"text":"survived"}""")
        )
        assertEquals(listOf(RelayEvent.Chunk("survived")), events)
    }

    @Test
    fun anUnknownEventNameIsIgnoredRatherThanFatal() {
        // Room for the relay to grow a frame this client has never heard of.
        val parser = SseParser()
        val events = parser.feed(
            frame("somethingNew", """{"x":1}""") + frame("chunk", """{"text":"still here"}""")
        )
        assertEquals(listOf(RelayEvent.Chunk("still here")), events)
    }

    @Test
    fun keepAliveCommentsAreIgnored() {
        val parser = SseParser()
        val events = parser.feed(":\n\n" + frame("chunk", """{"text":"after a ping"}"""))
        assertEquals(listOf(RelayEvent.Chunk("after a ping")), events)
    }

    @Test
    fun chunksConcatenateIntoTheAnswer() {
        // What the UI actually does with these, asserted end to end.
        val parser = SseParser()
        val stream = frame("session", """{"sessionId":"s"}""") +
            frame("chunk", """{"text":"Hello, "}""") +
            frame("chunk", """{"text":"world"}""") +
            frame("chunk", """{"text":"."}""") +
            frame("done", """{"sessionId":"s","result":"Hello, world."}""")

        val events = parser.feed(stream)
        val spoken = events.filterIsInstance<RelayEvent.Chunk>().joinToString("") { it.text }
        val done = events.filterIsInstance<RelayEvent.Done>().single()
        assertEquals("Hello, world.", spoken)
        assertEquals(spoken, done.result)
    }
}
