import SwiftUI

/// The one control that matters: press and hold to talk, release to send.
///
/// Deliberately enormous and centred low on the screen so it can be found by
/// thumb without looking. `DragGesture(minimumDistance: 0)` is the SwiftUI idiom
/// for press-and-hold — `onTapGesture` only fires after release, and
/// `LongPressGesture` has a built-in delay we don't want.
struct TalkButton: View {
    var isListening: Bool
    var isEnabled: Bool
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: 168, height: 168)
                .shadow(color: fillColor.opacity(0.45), radius: isListening ? 28 : 10)
                .scaleEffect(isListening ? 1.06 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isListening)

            VStack(spacing: 8) {
                Image(systemName: isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 46, weight: .medium))
                Text(isListening ? "Listening" : "Hold to talk")
                    .font(.footnote.weight(.semibold))
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
