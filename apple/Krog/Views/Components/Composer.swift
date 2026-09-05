import SwiftUI

/// The message field.
///
/// A floating rounded pill rather than a bar pinned behind a divider — that shape is
/// what makes the ChatGPT window read as one clean surface instead of three stacked
/// panels. It sits centred under the greeting on an empty thread and drops to the
/// bottom once there are messages; same view either way.
struct Composer: View {
    let botName: String
    @Binding var text: String
    let isBusy: Bool
    @FocusState.Binding var focused: Bool
    let onSend: () -> Void
    let onInterrupt: () -> Void

    /// Rendered inline on the right of the pill, the way ChatGPT shows the model.
    var trailingLabel: AnyView?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                // Attachments land with the surface work in M3.
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 3)

            TextField("Message \(botName)", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(onSend)
                .padding(.vertical, 7)

            if let trailingLabel {
                trailingLabel.padding(.bottom, 3)
            }

            Button {
                isBusy ? onInterrupt() : onSend()
            } label: {
                Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(sendForeground)
                    .frame(width: 28, height: 28)
                    .background(sendBackground, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!isBusy && !canSend)
            .padding(.bottom, 2)
            .animation(.easeOut(duration: 0.15), value: canSend)
            .help(isBusy ? "Stop" : "Send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            // Soft, wide, low-opacity shadow — the pill should look like it's resting
            // on the page, not cut out of it.
            Capsule(style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.10), radius: 14, y: 3)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .overlay {
            Capsule(style: .continuous).stroke(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }

    private var sendForeground: some ShapeStyle {
        if isBusy { return AnyShapeStyle(.white) }
        return canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary)
    }

    private var sendBackground: some ShapeStyle {
        if isBusy { return AnyShapeStyle(.primary) }
        return canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }
}
