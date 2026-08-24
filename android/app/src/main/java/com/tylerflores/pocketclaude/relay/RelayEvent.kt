package com.tylerflores.pocketclaude.relay

/**
 * One thing the relay said while answering.
 *
 * These mirror `relay/server.mjs`'s `interpret()` exactly, because that
 * function is the contract: it decides which of Claude Code's stream-json
 * records become frames and what shape they take. Anything it drops -- a
 * partial line, CLI chatter, and every record carrying `parent_tool_use_id`,
 * which is a subagent talking to itself -- never reaches here at all.
 */
sealed interface RelayEvent {

    /** The Claude Code session id, sent once at the start. Resume uses it. */
    data class Session(val sessionId: String?) : RelayEvent

    /** A piece of the answer. These arrive many times and concatenate. */
    data class Chunk(val text: String) : RelayEvent

    /** Tool names, so a status line can say what is happening. */
    data class Tool(val names: List<String>) : RelayEvent

    /** Something worth saying that is not the answer, e.g. a retry. */
    data class Status(val text: String) : RelayEvent

    /**
     * The turn is over.
     *
     * [result] is the complete answer. The relay sends it even though the
     * chunks already spelled it out, so a client can reconcile the two rather
     * than trust that it caught every delta.
     *
     * [costUsd] is an estimate of what the same work would have cost on the
     * API, not a charge: this path runs on a Claude subscription.
     */
    data class Done(
        val sessionId: String?,
        val costUsd: Double?,
        val isError: Boolean,
        val result: String?,
    ) : RelayEvent

    /** The relay gave up. Carries `message`, not `text`. */
    data class Failure(val message: String) : RelayEvent
}
