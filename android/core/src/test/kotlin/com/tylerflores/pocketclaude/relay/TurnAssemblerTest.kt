package com.tylerflores.pocketclaude.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnAssemblerTest {

    @Test
    fun chunksBecomeTheAnswer() {
        val a = TurnAssembler()
        a.accept(RelayEvent.Chunk("Hello, "))
        a.accept(RelayEvent.Chunk("world"))
        val turn = a.accept(RelayEvent.Chunk("."))
        assertEquals("Hello, world.", turn.answer)
        assertFalse(turn.isFinished)
    }

    @Test
    fun theSessionIdIsRemembered() {
        // It arrives once, at the start, and every follow-up depends on it.
        val a = TurnAssembler()
        a.accept(RelayEvent.Session("sess-1"))
        val turn = a.accept(RelayEvent.Chunk("hi"))
        assertEquals("sess-1", turn.sessionId)
    }

    @Test
    fun aLaterNullSessionIdDoesNotEraseTheOneWeHave() {
        val a = TurnAssembler()
        a.accept(RelayEvent.Session("sess-1"))
        val turn = a.accept(RelayEvent.Done(null, null, false, "done"))
        assertEquals("sess-1", turn.sessionId)
    }

    @Test
    fun theResultSupersedesTheChunks() {
        // The rule this class exists for. A chunk whose JSON did not parse is
        // dropped by SseParser rather than thrown, so the streamed text can be
        // short. `result` is what makes that recoverable instead of quietly
        // producing less than Claude actually said.
        val a = TurnAssembler()
        a.accept(RelayEvent.Chunk("Hello, "))
        // "world" never arrived.
        val turn = a.accept(RelayEvent.Done("s", 0.01, false, "Hello, world."))
        assertEquals("Hello, world.", turn.answer)
        assertTrue(turn.isFinished)
    }

    @Test
    fun theChunksStandWhenTheResultIsEmpty() {
        val a = TurnAssembler()
        a.accept(RelayEvent.Chunk("all there is"))
        val turn = a.accept(RelayEvent.Done("s", null, false, null))
        assertEquals("all there is", turn.answer)
    }

    @Test
    fun toolNamesBecomeAStatusLine() {
        val a = TurnAssembler()
        val turn = a.accept(RelayEvent.Tool(listOf("Read", "Bash")))
        assertEquals("Read, Bash", turn.status)
    }

    @Test
    fun textArrivingClearsTheStatus() {
        // Once the answer starts, saying "Read, Bash" is stale news.
        val a = TurnAssembler()
        a.accept(RelayEvent.Tool(listOf("Read")))
        val turn = a.accept(RelayEvent.Chunk("the answer"))
        assertNull(turn.status)
    }

    @Test
    fun aFailureEndsTheTurnAndSaysWhy() {
        val a = TurnAssembler()
        a.accept(RelayEvent.Chunk("partial"))
        val turn = a.accept(RelayEvent.Failure("Timed out after 300s"))
        assertEquals("Timed out after 300s", turn.error)
        assertTrue(turn.isFailed)
        assertTrue(turn.isFinished)
    }

    @Test
    fun anErrorResultIsAnError() {
        // done can carry isError, and the text is then the reason rather than
        // the answer. Showing it as an answer would be the wrong shape twice.
        val a = TurnAssembler()
        val turn = a.accept(RelayEvent.Done("s", null, true, "permission denied"))
        assertTrue(turn.isFailed)
        assertEquals("permission denied", turn.error)
    }

    @Test
    fun anErrorWithNoTextStillSaysSomething() {
        val a = TurnAssembler()
        val turn = a.accept(RelayEvent.Done("s", null, true, null))
        assertTrue(turn.isFailed)
        assertTrue(turn.error!!.isNotBlank())
    }

    @Test
    fun costIsCarriedButNotCharged() {
        // The relay sends it even on a subscription run; it is an estimate of
        // what the API would have cost, not a charge.
        val a = TurnAssembler()
        val turn = a.accept(RelayEvent.Done("s", 0.0123, false, "hi"))
        assertEquals(0.0123, turn.costUsd!!, 1e-9)
    }

    @Test
    fun aWholeTurnEndToEnd() {
        val a = TurnAssembler()
        listOf(
            RelayEvent.Session("s1"),
            RelayEvent.Tool(listOf("Read")),
            RelayEvent.Chunk("The hold "),
            RelayEvent.Chunk("lifecycle "),
            RelayEvent.Chunk("expires."),
            RelayEvent.Done("s1", 0.02, false, "The hold lifecycle expires."),
        ).forEach(a::accept)

        val turn = a.current()
        assertEquals("The hold lifecycle expires.", turn.answer)
        assertEquals("s1", turn.sessionId)
        assertNull(turn.status)
        assertFalse(turn.isFailed)
        assertTrue(turn.isFinished)
    }
}
