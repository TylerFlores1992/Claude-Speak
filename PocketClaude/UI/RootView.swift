import SwiftUI

/// Sessions first, conversation second.
///
/// The dashboard is the home screen because the question you usually arrive
/// with is "where was I?" rather than "let me start something new". Tapping a
/// session pushes the conversation view, which is the voice loop unchanged —
/// the talk button, the transcript, the model chips.
struct RootView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject var settings: AppSettings

    @State private var path: [Route] = []

    enum Route: Hashable { case conversation }

    var body: some View {
        NavigationStack(path: $path) {
            DashboardView(viewModel: viewModel)
                .navigationDestination(for: Route.self) { _ in
                    ConversationScreen(viewModel: viewModel, settings: settings)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        // Straight back into whatever is open, without picking
                        // a session first.
                        Button {
                            path = [.conversation]
                        } label: {
                            Image(systemName: "waveform")
                        }
                        .accessibilityLabel("Current conversation")
                    }
                }
        }
        // Opening or resuming a session should land you in it.
        .onChange(of: viewModel.session.id) { _, _ in
            if path.isEmpty { path = [.conversation] }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(settings: settings)
        }
    }
}
