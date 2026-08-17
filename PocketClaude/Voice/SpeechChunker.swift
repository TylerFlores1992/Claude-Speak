import Foundation

/// Turns a stream of text fragments into whole sentences that are worth saying
/// out loud, so speech can start before the answer has finished generating.
///
/// Three jobs, none of which a naive "speak every chunk" approach handles:
///
/// 1. **Wait for sentence ends.** Model output arrives a few tokens at a time.
///    Speaking each fragment produces stuttering nonsense; speaking whole
///    sentences sounds like a person reading.
/// 2. **Skip fenced code.** Hearing a shell script read character by character
///    is useless. Code stays on screen where it belongs.
/// 3. **Survive split markers.** A ``` fence or a sentence end can arrive
///    across two chunks, so nothing is emitted until the buffer proves it.
///
/// Swift note: this is a `struct` with `mutating` methods — a value type, so it
/// has no shared state and is trivial to test. Callers keep their own copy.
struct SpeechChunker {
    /// Text seen but not yet emitted.
    private var buffer = ""
    /// Whether the text so far has an unclosed ``` fence.
    private var insideFence = false
    /// Don't emit an utterance shorter than this unless the stream is ending;
    /// one- or two-word fragments make the speech choppy.
    private let minimumLength: Int

    init(minimumLength: Int = 12) {
        self.minimumLength = minimumLength
    }

    /// Adds a fragment and returns any complete sentences ready to speak.
    mutating func append(_ text: String) -> [String] {
        buffer += text
        return drain(flushing: false)
    }

    /// Ends the stream, returning whatever is left worth saying.
    mutating func flush() -> [String] {
        let remaining = drain(flushing: true)
        buffer = ""
        insideFence = false
        return remaining
    }

    /// True when nothing is waiting to be spoken.
    var isEmpty: Bool { buffer.isEmpty }

    // MARK: - Internals

    private mutating func drain(flushing: Bool) -> [String] {
        var utterances: [String] = []

        while true {
            guard let (spoken, consumed) = nextUtterance(flushing: flushing) else { break }
            buffer = String(buffer.dropFirst(consumed))
            let cleaned = Self.clean(spoken)
            if !cleaned.isEmpty {
                utterances.append(cleaned)
            }
            if buffer.isEmpty { break }
        }

        return utterances
    }

    /// Finds the next speakable run, returning it with how many characters of
    /// the buffer it consumed (which includes any skipped code fence).
    private mutating func nextUtterance(flushing: Bool) -> (String, Int)? {
        let characters = Array(buffer)
        guard !characters.isEmpty else { return nil }

        var index = 0
        var spoken = ""

        while index < characters.count {
            if isFenceMarker(characters, at: index) {
                insideFence.toggle()
                index += 3
                // Leaving a code block is a natural place to speak what came
                // before it, rather than gluing it to the text that follows.
                if !insideFence, !spoken.isEmpty, spoken.count >= minimumLength {
                    return (spoken, index)
                }
                continue
            }

            // A partial fence at the very end of the buffer: wait for the rest
            // rather than reading backticks aloud.
            if !flushing, characters[index] == "`", characters.count - index < 3 {
                break
            }

            let character = characters[index]
            index += 1

            if insideFence { continue }
            spoken.append(character)

            if isSentenceEnd(characters, at: index - 1), spoken.count >= minimumLength {
                return (spoken, index)
            }
        }

        // Nothing conclusive. Only give up the remainder when the stream ends.
        guard flushing, !insideFence || !spoken.isEmpty else { return nil }
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (spoken, characters.count)
    }

    private func isFenceMarker(_ characters: [Character], at index: Int) -> Bool {
        guard index + 2 < characters.count else { return false }
        return characters[index] == "`"
            && characters[index + 1] == "`"
            && characters[index + 2] == "`"
    }

    /// A sentence ends at `.`, `!`, `?` or a newline — but not after a digit,
    /// which would split "1." in a numbered list and "3.14" mid-number.
    private func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        let character = characters[index]

        if character.isNewline { return true }
        guard character == "." || character == "!" || character == "?" else { return false }

        if index > 0, characters[index - 1].isNumber { return false }

        // Needs whitespace after it, otherwise we can't tell "e.g." from an end.
        guard index + 1 < characters.count else { return false }
        return characters[index + 1].isWhitespace
    }

    /// Strips the markdown that would otherwise be read out as punctuation.
    /// Deliberately light: this runs per sentence, so anything spanning
    /// sentences (like a fence) is handled by the scanner above instead.
    static func clean(_ text: String) -> String {
        var result = text

        // Inline code, bold, italic and heading markers become plain words.
        for marker in ["**", "__", "`", "*", "_", "#"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        // Bullets read as "dash", which is noise.
        result = result.replacingOccurrences(
            of: "^\\s*[-•]\\s+",
            with: "",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: [.regularExpression]
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
