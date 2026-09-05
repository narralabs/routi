#if os(macOS)
import AppKit
import SwiftUI

/**
 A text field that knows the difference between sending and starting a line.

 SwiftUI's `TextField` cannot express this. `onSubmit` fires on Return whatever is held
 with it, so shift-return sent the message; declining the key instead let the field do
 its default thing, which is to extend the selection. Neither is a newline.

 Decided on the key event itself rather than on which command AppKit turns it into.
 `insertNewlineIgnoringFieldEditor` looked like the right selector for shift-return and
 is not what this field receives — it got `insertNewline` either way, so shift-return
 sent. Reading the modifier off the event leaves nothing to be wrong about.

 The newline lands at the insertion point rather than at the end of the string, which is
 the difference between editing a message and only appending to it.
 */
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void
    /// Grows with the text, then scrolls rather than pushing the window open.
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerTextView.scrollable()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none

        guard let view = scroll.documentView as? ComposerTextView else { return scroll }
        view.delegate = context.coordinator
        view.onSend = onSend
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 14)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Substitutions belong in prose, not in something that may contain a URL or a
        // command: smart quotes have broken more pasted links than they have improved.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.string = text
        context.coordinator.textView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.onSend = onSend
        if view.string != text { view.string = text }
        context.coordinator.updateHeight(for: view)
        context.coordinator.drawPlaceholder(in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: NSTextView?

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            updateHeight(for: view)
            drawPlaceholder(in: view)
        }

        /// One line to ten, then it scrolls.
        func updateHeight(for view: NSTextView) {
            guard let container = view.textContainer, let manager = view.layoutManager else { return }
            manager.ensureLayout(for: container)
            let measured = manager.usedRect(for: container).height
            let clamped = min(max(measured, 18), 18 * 10)
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }

        /// AppKit has no placeholder on NSTextView, so it is drawn as a subview.
        func drawPlaceholder(in view: NSTextView) {
            let tag = 8_201
            let existing = view.subviews.first { $0.tag == tag } as? NSTextField
            guard view.string.isEmpty else { existing?.removeFromSuperview(); return }
            if existing != nil { return }

            let label = NSTextField(labelWithString: parent.placeholder)
            label.tag = tag
            label.font = .systemFont(ofSize: 14)
            label.textColor = .placeholderTextColor
            label.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 18)
            label.autoresizingMask = [.width]
            view.addSubview(label)
        }
    }
}
#endif

/// Return and shift-return, told apart by the event rather than by a selector.
private final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}

    static func scrollable() -> NSScrollView {
        let scroll = NSScrollView()
        let view = ComposerTextView()
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude,
        )
        scroll.documentView = view
        return scroll
    }

    override func keyDown(with event: NSEvent) {
        // 36 is Return. Shift means a new line; anything else sends.
        if event.keyCode == 36 && !event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSend()
            }
            return
        }
        super.keyDown(with: event)
    }
}
