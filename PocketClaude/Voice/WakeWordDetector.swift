import Foundation

/// Finds a wake phrase in a live transcript and returns what was said after it.
///
/// Pulled out of the listening loop so it can be tested against real recogniser
/// output, which is messier than it looks: Apple's recogniser punctuates and
/// capitalises as it goes, so "hey claude" arrives as "Hey, Claude" one moment
/// and "Hey Claude!" the next, and a plain `contains` misses both.
///
/// Swift note: this is a struct with no reference semantics — copied, not
/// shared. Closer to a plain object literal in TypeScript than to a class.
struct WakeWordDetector {
    var phrase: String
    var endKeyword: String

    /// Everything said after the most recent wake phrase, or nil if the phrase
    /// has not been heard yet.
    ///
    /// The *most recent*, deliberately: saying the phrase again should start a
    /// new question rather than append to the abandoned one.
    func pendingQuestion(in transcript: String) -> String? {
        let normalized = Normalized(transcript)
        let needle = Self.normalize(phrase)
        guard !needle.isEmpty,
              let after = normalized.lastRangeEnd(of: needle)
        else { return nil }

        // Drop whatever separated the phrase from the question. The mapped
        // index lands *on* that separator, not past it, so "Hey Claude, what
        // time is it" would otherwise be answered as ", what time is it" - and
        // "Pocket Claude - what time is it" as "- what time is it". Skipping to
        // the first letter or digit covers every separator the recogniser
        // invents without listing them.
        let question = String(transcript[after...])
            .drop { !$0.isLetter && !$0.isNumber }
        return String(question).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the pending question ends with the end keyword, which is the
    /// explicit "I am done talking" signal. Silence is handled by the caller,
    /// which is the only thing that knows how long the transcript has been
    /// still.
    func isComplete(_ question: String) -> Bool {
        let keyword = Self.normalize(endKeyword)
        guard !keyword.isEmpty else { return false }
        let spoken = Self.normalize(question)
        return spoken == keyword || spoken.hasSuffix(" " + keyword)
    }

    /// The question with a trailing end keyword removed, since "done" is an
    /// instruction to the app rather than part of what you asked.
    func stripEndKeyword(from question: String) -> String {
        let keyword = Self.normalize(endKeyword)
        guard !keyword.isEmpty else { return question }

        let normalized = Normalized(question)
        guard normalized.text == keyword || normalized.text.hasSuffix(" " + keyword) else {
            return question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cut = normalized.text.count - keyword.count
        guard let index = normalized.originalIndex(forNormalizedOffset: cut) else {
            return question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(question[question.startIndex..<index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // A stray comma is what is left of "…the tests, done".
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
    }

    /// Lowercased, with every run of non-alphanumerics collapsed to one space.
    /// This is what makes "Hey, Claude!" and "hey claude" the same string.
    static func normalize(_ text: String) -> String {
        var out = ""
        var lastWasSpace = true // leading spaces are dropped
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// A normalized copy that can still point back into the original string.
    ///
    /// Needed because the answer has to be the text the person actually said,
    /// with its capitalisation and punctuation, not the flattened form used for
    /// matching.
    private struct Normalized {
        let text: String
        /// For each character of `text`, where it came from in the original.
        private let origins: [String.Index]
        private let source: String

        init(_ original: String) {
            var text = ""
            var origins: [String.Index] = []
            var lastWasSpace = true

            var index = original.startIndex
            while index < original.endIndex {
                let character = original[index]
                if character.isLetter || character.isNumber {
                    // Lowercasing can lengthen a character - Turkish dotted I
                    // becomes two scalars - so append however many arrive and
                    // point all of them at the one original position. Building
                    // a Character from the result would trap on exactly that
                    // case.
                    let lowered = character.lowercased()
                    text.append(contentsOf: lowered)
                    for _ in lowered { origins.append(index) }
                    lastWasSpace = false
                } else if !lastWasSpace {
                    text.append(" ")
                    origins.append(index)
                    lastWasSpace = true
                }
                index = original.index(after: index)
            }
            if text.hasSuffix(" ") {
                text.removeLast()
                origins.removeLast()
            }

            self.text = text
            self.origins = origins
            self.source = original
        }

        /// Where in the original string the last match of `needle` ends.
        func lastRangeEnd(of needle: String) -> String.Index? {
            guard let found = text.range(of: needle, options: .backwards) else { return nil }
            let offset = text.distance(from: text.startIndex, to: found.upperBound)
            return originalIndex(forNormalizedOffset: offset)
        }

        /// Maps an offset in the normalized text back to the original string.
        func originalIndex(forNormalizedOffset offset: Int) -> String.Index? {
            if offset >= origins.count { return source.endIndex }
            guard offset >= 0 else { return nil }
            return origins[offset]
        }
    }
}
