package com.tylerflores.pocketclaude.relay

/**
 * What one question and its answer look like as they arrive.
 *
 * Kept as plain data with no Android in it, so the rules below are unit tested
 * rather than inspected on a phone.
 */
data class Turn(
    val answer: String = "",
    val status: String? = null,
    val sessionId: String? = null,
    val costUsd: Double? = null,
    val error: String? = null,
    val isFinished: Boolean = false,
) {
    val isFailed: Boolean get() = error != null
}

/**
 * Folds the relay's events into a [Turn].
 *
 * The rule worth knowing is the last one. The relay sends the whole answer
 * again in the `done` frame, having already sent it in pieces, and this trusts
 * that copy over the pieces it assembled. That is not redundancy for its own
 * sake: a chunk can be lost -- a frame whose JSON did not parse is dropped by
 * [SseParser] rather than throwing, precisely so a turn still arriving is not
 * abandoned -- and `result` is what makes that recoverable instead of silently
 * producing a shorter answer than Claude gave.
 */
class TurnAssembler {

    private val chunks = StringBuilder()
    private var turn = Turn()

    fun accept(event: RelayEvent): Turn {
        turn = when (event) {
            is RelayEvent.Session -> turn.copy(sessionId = event.sessionId ?: turn.sessionId)

            is RelayEvent.Chunk -> {
                chunks.append(event.text)
                // Status is cleared: text arriving is itself the news.
                turn.copy(answer = chunks.toString(), status = null)
            }

            is RelayEvent.Tool -> turn.copy(status = event.names.joinToString(", "))

            is RelayEvent.Status -> turn.copy(status = event.text)

            is RelayEvent.Failure -> turn.copy(
                error = event.message,
                status = null,
                isFinished = true,
            )

            is RelayEvent.Done -> {
                val streamed = chunks.toString()
                // `result` wins when it has something to say. A dropped chunk
                // would otherwise leave a short answer that reads as complete.
                val whole = event.result?.takeIf { it.isNotBlank() } ?: streamed
                turn.copy(
                    answer = whole,
                    status = null,
                    sessionId = event.sessionId ?: turn.sessionId,
                    costUsd = event.costUsd,
                    error = if (event.isError) {
                        whole.takeIf { it.isNotBlank() } ?: "The relay reported an error."
                    } else {
                        turn.error
                    },
                    isFinished = true,
                )
            }
        }
        return turn
    }

    /** The turn as it currently stands. */
    fun current(): Turn = turn
}
