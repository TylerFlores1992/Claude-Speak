import SwiftUI

/// Just enough Markdown to read an answer comfortably.
///
/// SwiftUI's `Text` understands *inline* Markdown — bold, italic, code spans —
/// but nothing structural. Claude answers in headings, bullets and fenced code
/// blocks, so passing the raw string to `Text` showed literal `**` and `##`
/// everywhere, which is what you were looking at.
///
/// This is deliberately small. It is not a Markdown implementation; it is the
/// five block kinds that actually appear in an answer, with inline formatting
/// delegated to `AttributedString`, which already does it properly. Anything it
/// doesn't recognise falls through as a paragraph rather than being dropped —
/// the failure mode is "renders plainly", never "text disappears".
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case code(String)

    /// Splits text into blocks. Never throws and never loses a line.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(level: min(hashes, 3), text: title))
                    continue
                }
            }

            if let bullet = Self.bulletBody(line) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }

            if let (marker, body) = Self.numberedBody(line) {
                flushParagraph()
                blocks.append(.numbered(marker: marker, text: body))
                continue
            }

            paragraph.append(line)
        }

        // An unterminated fence still has to show its contents.
        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    /// `- x`, `* x` or `• x`. Requires the space, so "*emphasis*" and a
    /// horizontal rule aren't mistaken for list items.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let body = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    /// `1. x` up to two digits, so a sentence starting with a year isn't a list.
    private static func numberedBody(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : (String(digits), body)
    }
}

/// Renders parsed blocks. Inline formatting goes through `AttributedString`,
/// which handles `**bold**`, `*italic*`, `` `code` `` and links already.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title3 : level == 2 ? .headline : .subheadline)
                        .fontWeight(.semibold)

                case .paragraph(let text):
                    inline(text)

                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(text)
                    }

                case .numbered(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(marker).").foregroundStyle(.secondary).monospacedDigit()
                        inline(text)
                    }

                case .code(let code):
                    // Horizontally scrollable: wrapping code is harder to read
                    // than scrolling it, and a long line must not stretch the
                    // whole transcript.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Falls back to the plain string if the Markdown doesn't parse, so a stray
    /// bracket can never blank out an answer.
    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}
