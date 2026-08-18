import Foundation

/// Configuration handed over in a single tap.
///
/// The relay prints `pocketclaude://pair?url=…&token=…` when it starts. Send
/// that line to yourself, tap it, and both Settings fields are filled in —
/// instead of transcribing a 64-character token into a phone, which is what
/// made a short memorable token look attractive and weakened it.
///
/// Parsing lives here rather than in the view so it can be tested: a link that
/// silently half-applies would leave the app pointed at a relay with the wrong
/// token, which reads as "the relay is broken".
struct PairingLink: Equatable {
    let relayURL: String
    let token: String

    /// Returns nil for anything that isn't a complete pairing link. Partial
    /// links are refused rather than applied, because applying half of one
    /// leaves settings in a state that's worse than not touching them.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "pocketclaude",
              url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let relay = value("url"), !relay.isEmpty,
              let token = value("token"), !token.isEmpty,
              // Must be a usable address, not just any text: a link with a
              // mangled URL should fail loudly at the tap, not later.
              let parsed = URL(string: relay), parsed.scheme != nil
        else { return nil }

        self.relayURL = relay
        self.token = token
    }

    /// The link the relay prints. Kept here so both ends agree on the shape and
    /// a test can round-trip it.
    static func make(relayURL: String, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "pocketclaude"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "url", value: relayURL),
            URLQueryItem(name: "token", value: token),
        ]
        return components.url
    }
}
