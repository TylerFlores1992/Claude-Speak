import Foundation

/// Whether a string is an address the relay client can actually call.
///
/// Exists because `URL(string:)` is far more permissive than it looks:
/// `URL(string: "mini-pc:8788")` succeeds with **scheme `mini-pc`**, so the
/// obvious `url.scheme != nil` check accepts a bare host:port that no request
/// can be made to. A test on the pairing link caught it; the same check was
/// guarding Settings, `RelayClient.make` and the configured-state flag, so all
/// four now share this one rule.
enum RelayAddress {
    /// Accepts only http and https, which are the two the relay speaks.
    static func isUsable(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              // A scheme with no host is "http://" and nothing else.
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}
