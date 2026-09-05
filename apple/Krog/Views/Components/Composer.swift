import SwiftUI

/// Message input. `.vertical` axis + `lineLimit(1...8)` gives the growing field for
/// free on every platform; Return sends and Shift+Return inserts a newline, which is
/// the behaviour `onSubmit` already implements on macOS.
struct Composer: View {
    let botName: String
    @Binding var text: String
    let isBusy: Bool
    @FocusState.Binding var focused: Bool
    let onSend: () -> Void
    let onInterrupt: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(botName)", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(onSend)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: .rect(cornerRadius: 18, style: .continuous))

                Button {
                    isBusy ? onInterrupt() : onSend()
                } label: {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(isBusy ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!isBusy && !canSend)
                .opacity(!isBusy && !canSend ? 0.4 : 1)
                .animation(.easeOut(duration: 0.12), value: canSend)
                .keyboardShortcut(.return, modifiers: [])
                .help(isBusy ? "Stop" : "Send")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
