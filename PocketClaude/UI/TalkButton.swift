import SwiftUI

/// Press and hold to record, release to send.
///
/// Hold rather than tap-to-start/tap-to-stop: with the phone pocketed you know
/// you are still recording because your thumb is still down, and letting go is
/// a thing you cannot forget to do.
///
/// Two sizes. `.large` is the standalone button; `.compact` sits inside the
/// composer next to the model chips, where the label has no room and the
/// surrounding bar supplies the context instead.
struct TalkButton: View {
    enum Size {
        case large, compact

        var diameter: CGFloat { self == .large ? 168 : 52 }
        var icon: CGFloat { self == .large ? 46 : 22 }
        var showsLabel: Bool { self == .large }
    }

    var isListening: Bool
    var isEnabled: Bool
    var size: Size = .large
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: size.diameter, height: size.diameter)
                .shadow(
                    color: fillColor.opacity(0.45),
                    radius: isListening ? (size == .large ? 28 : 12) : (size == .large ? 10 : 4)
                )
                .scaleEffect(isListening ? 1.06 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isListening)

            VStack(spacing: 8) {
                Image(systemName: isListening ? "waveform" : "mic.fill")
                    .font(.system(size: size.icon, weight: .medium))
                if size.showsLabel {
                    Text(isListening ? "Listening" : "Hold to talk")
                        .font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isPressed else { return }
                    isPressed = true
                    onPress()
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Press and hold to record, release to send to Claude")
    }

    private var fillColor: Color {
        if !isEnabled { return .gray }
        return isListening ? .red : .accentColor
    }
}
