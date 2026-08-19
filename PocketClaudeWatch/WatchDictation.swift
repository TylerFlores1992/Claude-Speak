import WatchKit

/// Opens watchOS's dictation screen directly.
///
/// SwiftUI's `TextFieldLink` presents the system input controller but gives no
/// say over which mode it opens in, and on a current watch that means Scribble
/// — draw-a-letter-at-a-time, which is not talking. WatchKit's own presenter
/// does take the choice: passing `nil` for suggestions goes straight to
/// dictation rather than showing the input picker first.
///
/// Swift note for a web dev: this is a callback-style API from the pre-async
/// era, so it takes a completion closure instead of being awaited. The closure
/// arrives on the main thread.
enum WatchDictation {
    /// Returns false when there is no controller to present from, which is the
    /// caller's cue to offer the keyboard instead. A button that silently does
    /// nothing is the failure worth avoiding.
    @discardableResult
    static func present(completion: @escaping (String) -> Void) -> Bool {
        // `WKExtension.shared()` is the SwiftUI-era hosting controller. It is
        // the documented route to a WKInterfaceController from a SwiftUI watch
        // app, and nil early in launch before anything is on screen.
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            return false
        }

        controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        ) { results in
            // Results can be strings or NSData for emoji; `.plain` rules the
            // latter out, but the array is still untyped, so pick carefully
            // rather than force-casting.
            let spoken = results?
                .compactMap { $0 as? String }
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !spoken.isEmpty else { return }
            completion(spoken)
        }
        return true
    }
}
