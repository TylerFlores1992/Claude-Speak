import Foundation

/// What we actually render and speak.
///
/// `spoken` is the short, conversational summary sent to the AirPod; `detail` is
/// the full body shown in the on-screen transcript.
struct AgentResponse: Equatable, Sendable {
    var spoken: String
    var detail: String

    /// JSON Schema used when `useStructuredOutput` is enabled.
    static let jsonSchema: JSONValue = .from([
        "type": "object",
        "properties": [
            "spoken_summary": [
                "type": "string",
                "description": "A short, conversational answer to be read aloud. No code, no file paths, no markdown, under 60 words."
            ],
            "detail": [
                "type": "string",
                "description": "The full answer for the on-screen transcript. Markdown and code are fine here."
            ],
        ],
        "required": ["spoken_summary", "detail"],
        "additionalProperties": false,
    ])
}

/// Turns Claude's final turn into a `AgentResponse`.
///
/// The model is asked (via the system prompt, or a JSON schema when structured
/// output is on) to answer with `{"spoken_summary": ..., "detail": ...}`. Models
/// are not perfectly reliable about that, and a voice app that renders raw JSON
/// into your ear is useless — so this parser degrades in four steps:
///
///   1. Whole body is that JSON object.
///   2. A ```json fenced block (or any brace-balanced object) contains it.
///   3. A leading `Spoken:` / `Summary:` label.
///   4. Heuristic: strip code/markdown, take the first couple of sentences.
enum ResponseParser {
    static func parse(_ raw: String) -> AgentResponse {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AgentResponse(spoken: "I didn't get a response.", detail: "")
        }

        if let parsed = parseJSONObject(text) { return parsed }
        if let candidate = extractFencedOrEmbeddedObject(from: text),
           let parsed = parseJSONObject(candidate) {
            return parsed
        }
        if let parsed = parseLabelled(text) { return parsed }

        return AgentResponse(spoken: summarize(text), detail: text)
    }

    // MARK: - Step 1 & 2: JSON

    private static func parseJSONObject(_ candidate: String) -> AgentResponse? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }

        // Accept a couple of near-miss key spellings — cheap insurance.
        let spoken = root["spoken_summary"]?.stringValue
            ?? root["spokenSummary"]?.stringValue
            ?? root["spoken"]?.stringValue
        let detail = root["detail"]?.stringValue
            ?? root["details"]?.stringValue
            ?? root["body"]?.stringValue

        guard let spoken, !spoken.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let resolvedDetail = (detail?.isEmpty == false) ? detail! : spoken
        return AgentResponse(
            spoken: sanitizeForSpeech(spoken),
            detail: resolvedDetail
        )
    }

    /// Pulls a ```json fenced block, or the first brace-balanced object, out of
    /// prose that surrounds it.
    static func extractFencedOrEmbeddedObject(from text: String) -> String? {
        if let fenced = fencedBlock(in: text) { return fenced }
        return braceBalancedObject(in: text)
    }

    private static func fencedBlock(in text: String) -> String? {
        // Matches ```json ... ``` and bare ``` ... ```
        guard let openRange = text.range(of: "```") else { return nil }
        var contentStart = openRange.upperBound
        // Skip an optional language tag on the same line.
        if let lineEnd = text[contentStart...].firstIndex(where: { $0 == "\n" }) {
            let tag = text[contentStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if tag.count <= 12, !tag.contains("{") {
                contentStart = text.index(after: lineEnd)
            }
        }
        guard let closeRange = text.range(of: "```", range: contentStart..<text.endIndex) else {
            return nil
        }
        let body = String(text[contentStart..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.hasPrefix("{") ? body : nil
    }

    private static func braceBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Step 3: labelled prose

    private static func parseLabelled(_ text: String) -> AgentResponse? {
        let labels = ["spoken summary:", "spoken:", "summary:"]
        let lowercased = text.lowercased()
        for label in labels where lowercased.hasPrefix(label) {
            let afterLabel = text.index(text.startIndex, offsetBy: label.count)
            let remainder = String(text[afterLabel...])
            // The summary is everything up to the first blank line.
            let parts = remainder.components(separatedBy: "\n\n")
            let spoken = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !spoken.isEmpty else { return nil }
            let detail = parts.dropFirst().joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentResponse(
                spoken: sanitizeForSpeech(spoken),
                detail: detail.isEmpty ? spoken : detail
            )
        }
        return nil
    }

    // MARK: - Step 4: heuristic summary

    /// Best-effort spoken line when the model gave us plain prose: drop fenced
    /// code, drop markdown noise, keep the first couple of sentences.
    static func summarize(_ text: String, sentenceLimit: Int = 2, characterLimit: Int = 420) -> String {
        let withoutCode = stripFencedCode(text)
        let cleaned = sanitizeForSpeech(withoutCode)
        guard !cleaned.isEmpty else { return "I have an answer on screen." }

        var sentences: [String] = []
        var current = ""
        for character in cleaned {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { sentences.append(candidate) }
                current = ""
                if sentences.count >= sentenceLimit { break }
            }
        }
        if sentences.isEmpty {
            let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty { sentences.append(trailing) }
        }

        let joined = sentences.joined(separator: " ")
        guard joined.count > characterLimit else { return joined }
        return String(joined.prefix(characterLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func stripFencedCode(_ text: String) -> String {
        var result = ""
        var insideFence = false
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if !insideFence { result += line + "\n" }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes the punctuation that a TTS engine reads as literal noise.
    static func sanitizeForSpeech(_ text: String) -> String {
        var output = text
        for token in ["**", "__", "`", "#", ">"] {
            output = output.replacingOccurrences(of: token, with: "")
        }
        // Collapse bullet markers into pauses so lists don't run together.
        output = output.replacingOccurrences(
            of: "(?m)^\\s*[-*+]\\s+",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
