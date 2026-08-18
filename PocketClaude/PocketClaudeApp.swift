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
    /// Answers questions sent from the watch. Inert until a watch app is
    /// paired, so it costs nothing when there isn't one.
    @StateObject private var phoneLink = PhoneLink()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: ConversationViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel, settings: settings)
                .tint(.indigo)
                .task {
                    // A question from the wrist runs through exactly the same
                    // path as one asked on screen: same relay, same transcript,
                    // same spoken answer.
                    phoneLink.onQuestion = { [weak viewModel] question in
                        await viewModel?.answerFromWatch(question) ?? ""
                    }
                    phoneLink.activate()
                }
        }
    }
}
