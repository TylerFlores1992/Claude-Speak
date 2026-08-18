import SwiftUI

/// The watch half of PocketClaude.
///
/// **Why a watch app at all.** Starting a take on the phone needs its screen
/// on: a backgrounded app on a locked phone can't reliably acquire the
/// microphone. The watch is a separate device with its own audio session and
/// its own microphone, so none of that applies. Raise your wrist, tap, speak.
///
/// The watch does not talk to the relay itself. It has no Tailscale, and the
/// relay lives on a private tailnet the phone is already on — so the watch
/// hands the question to the phone, and the phone answers it and speaks the
/// reply through whatever earbud you're wearing.
@main
struct PocketClaudeWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchContentView(link: link)
        }
    }
}
