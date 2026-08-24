package com.tylerflores.pocketclaude.relay

import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class RelayRequestTest {

    @Test
    fun joinsAnAddressAndAPath() {
        assertEquals(
            "http://relay.test:8788/ask",
            RelayRequest.url("http://relay.test:8788", "ask")
        )
    }

    @Test
    fun toleratesATrailingSlash() {
        // Whatever someone pastes into a settings field should work.
        assertEquals(
            "http://relay.test:8788/ask",
            RelayRequest.url("http://relay.test:8788/", "ask")
        )
    }

    @Test
    fun toleratesALeadingSlashOnThePath() {
        assertEquals(
            "http://relay.test:8788/ask",
            RelayRequest.url("http://relay.test:8788", "/ask")
        )
    }

    @Test
    fun assumesHttpWhenNoSchemeIsTyped() {
        // The relay is reached over Tailscale, which is already encrypted.
        // Demanding "http://" to reach your own machine reads as a broken
        // address rather than a missing scheme.
        assertEquals(
            "http://100.119.76.63:8788/ask",
            RelayRequest.url("100.119.76.63:8788", "ask")
        )
    }

    @Test
    fun keepsHttpsWhenItIsGiven() {
        assertEquals(
            "https://desktop.example.ts.net/ask",
            RelayRequest.url("https://desktop.example.ts.net", "ask")
        )
    }

    @Test
    fun anEmptyAddressIsRefusedRatherThanGuessed() {
        assertThrows(IllegalArgumentException::class.java) {
            RelayRequest.url("   ", "ask")
        }
    }

    @Test
    fun aQueryStringSurvivesTheJoin() {
        // The iOS bug worth not repeating: a "?" folded into a path setter came
        // back percent-encoded as %3F, the relay saw one long path with no
        // parameters, and answered 400 to every transcript request.
        assertEquals(
            "http://relay.test:8788/cloud/transcript?sessionId=abc",
            RelayRequest.url("http://relay.test:8788", "cloud/transcript?sessionId=abc")
        )
    }

    @Test
    fun carriesTheQuestion() {
        val body = RelayRequest.askBody(text = "what does the hold code do?")
        assertEquals("what does the hold code do?", body["text"]?.jsonPrimitive?.content)
    }

    @Test
    fun omitsModelAndEffortWhenUnset() {
        // Omitted rather than empty: the relay treats "" as a value to act on,
        // so leaving the key out is what lets the server decide.
        val body = RelayRequest.askBody(text = "hello")
        assertNull(body["model"])
        assertNull(body["effort"])
        assertNull(body["sessionId"])
        assertNull(body["project"])
    }

    @Test
    fun omitsBlankValuesToo() {
        val body = RelayRequest.askBody(text = "hello", sessionId = "  ", model = "")
        assertNull(body["sessionId"])
        assertNull(body["model"])
    }

    @Test
    fun sendsModelAndEffortWhenSet() {
        val body = RelayRequest.askBody(text = "hello", model = "opus", effort = "high")
        assertEquals("opus", body["model"]?.jsonPrimitive?.content)
        assertEquals("high", body["effort"]?.jsonPrimitive?.content)
    }

    @Test
    fun resumesWhenGivenASessionId() {
        val body = RelayRequest.askBody(text = "and then?", sessionId = "sess-1")
        assertEquals("sess-1", body["sessionId"]?.jsonPrimitive?.content)
    }

    @Test
    fun buildsTheBearerHeader() {
        val (name, value) = RelayRequest.authorization("  tok  ")
        assertEquals("Authorization", name)
        assertEquals("Bearer tok", value)
    }
}
