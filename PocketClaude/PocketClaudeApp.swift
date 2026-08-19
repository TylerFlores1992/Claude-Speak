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
    @StateObject private var phoneLink: PhoneLink

    init() {
        let settings = AppSettings()
        let viewModel = ConversationViewModel(settings: settings)
        let phoneLink = PhoneLink()
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: viewModel)
        _phoneLink = StateObject(wrappedValue: phoneLink)

        // Wired here rather than in a view's `.task`, which is the whole reason
        // the watch only worked while this app was the one on screen.
        //
        // A recording from the wrist launches this app in the background. No
        // window is rendered there, so no `.task` runs, so `onQuestion` was
        // still nil and every question was answered "The app wasn't ready" —
        // unless you happened to have PocketClaude open at the time. Doing it
        // in `init` means the delegate and the handler both exist from the
        // moment the process starts, however it was started.
        //
        // A question from the wrist runs through exactly the same path as one
        // asked on screen: same relay, same transcript, same spoken answer.
        phoneLink.onQuestion = { [weak viewModel] question in
            await viewModel?.answerFromWatch(question) ?? ""
        }
        phoneLink.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel, settings: settings)
                .tint(.indigo)
        }
    }
}
