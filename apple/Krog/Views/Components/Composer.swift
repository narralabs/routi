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

    /// Read here rather than only in Settings, which is where it was being ignored:
    /// the picker offered a choice the composer never consulted.
    @AppStorage("sendBehavior") private var sendBehavior = SendBehavior.returnKey.rawValue

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

            field
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .font(.system(size: 14))
                .focused($focused)
                .padding(.vertical, 7)

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

    /**
     The field, and who decides what Return means.

     `onSubmit` cannot express this: it fires on Return whatever is held with it, so
     shift-return sent the message. Reading the key press leaves the modifier visible,
     which is half the problem solved.

     The other half is what shift-return should then do, and both wrong answers have
     now been shipped. Declining the key hands it back to SwiftUI, whose default is to
     extend the selection — the whole draft highlights and no line is added. Replacing
     the field with an AppKit one that handles the key itself worked and then would not
     take focus from a click, which is worse, and was reverted.

     So the key is taken and the line break is inserted into the field editor, which is
     an `NSTextView` whether SwiftUI is backing this with a text field or a text view.
     `insertNewlineIgnoringFieldEditor` is AppKit's name for exactly this: a line break
     that does not end editing. It lands at the insertion point, so a newline added in
     the middle of a draft goes where the cursor is rather than at the end.
     */
    @ViewBuilder
    private var field: some View {
        let placeholder = "Message \(botName)"
        #if os(macOS)
        TextField(placeholder, text: $text, axis: .vertical)
            .onKeyPress(.return, phases: .down) { press in
                let sends = SendBehavior(rawValue: sendBehavior) == .commandReturn
                    ? press.modifiers.contains(.command)
                    : press.modifiers.isDisjoint(with: [.shift, .command, .option])
                if sends {
                    onSend()
                    return .handled
                }
                return Self.insertLineBreak() ? .handled : .ignored
            }
        #else
        // iOS has no modifier to hold: the keyboard's return key sends, and the
        // on-screen keyboard offers no second one to start a line with.
        TextField(placeholder, text: $text, axis: .vertical)
            .onSubmit(onSend)
        #endif
    }

    #if os(macOS)
    /// Breaks the line in whatever is editing right now. False when that is not a text
    /// view, in which case the key is better left to SwiftUI than swallowed.
    private static func insertLineBreak() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
    #endif

    private var sendForeground: some ShapeStyle {
        if isBusy { return AnyShapeStyle(.white) }
        return canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary)
    }

    private var sendBackground: some ShapeStyle {
        if isBusy { return AnyShapeStyle(.primary) }
        return canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }
}
