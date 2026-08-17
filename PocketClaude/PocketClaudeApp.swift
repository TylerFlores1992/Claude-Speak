import SwiftUI

@main
struct PocketClaudeApp: App {
    /// Owned here so settings and the view model share one instance.
    ///
    /// Swift note: `@StateObject` is the "create it once and keep it alive for
    /// the lifetime of this view" wrapper — closest analogue is a `useRef` around
    /// a store instance, as opposed to `@ObservedObject`, which is a plain prop.
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: ConversationViewModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: ConversationViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, settings: settings)
                .tint(.indigo)
        }
    }
}
