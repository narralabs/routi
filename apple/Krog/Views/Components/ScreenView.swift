import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Renders the desktop's latest frame and, when interactive, forwards input to it.
///
/// Coordinates are converted from the view's geometry into the desktop's pixel space,
/// so a click lands where the user aimed no matter how the frame is scaled — the rail
/// thumbnail and the full-window view share this one implementation.
struct ScreenView: View {
    let frame: Data?
    let size: CGSize
    var isInteractive = false
    var onInput: ([String: Any]) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)

            ZStack {
                // The screen sits centred on its own ground rather than being stretched
                // to the pane; a desktop letterboxed against black reads as a display,
                // and it keeps the aspect honest at any window size.
                Color.black.opacity(0.92)

                screen(fitted: fitted)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func screen(fitted: CGSize) -> some View {
        Group {
            if let frame, let image = decode(frame) {
                image.resizable().interpolation(.medium)
            } else {
                ZStack {
                    Color.black
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
        }
        // Sizing the image to the fitted rect means the gesture's own local
        // coordinates *are* screen coordinates, scaled. The previous version laid a
        // tap over the whole pane and subtracted the letterbox by hand, so any click
        // in the margin silently did nothing.
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(.rect(cornerRadius: isInteractive ? 6 : 0, style: .continuous))
        .shadow(color: .black.opacity(isInteractive ? 0.5 : 0), radius: 18, y: 6)
        .contentShape(.rect)
        // Input rides on top of the picture, sized to it, so a point in the layer's
        // own coordinates is a point on the screen — scaled, with nothing to subtract.
        .overlay {
            #if os(macOS)
            if isInteractive {
                DesktopInputLayer(size: size, onInput: onInput)
            }
            #endif
        }
    }

    /// Largest rect with the desktop's aspect ratio that fits the available space.
    private func fittedSize(in available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func decode(_ data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// Translates a SwiftUI key press into something `xdotool` understands.
///
/// Two different verbs, because they are genuinely different operations: text goes
/// through `type`, which handles arbitrary characters and layouts, while named keys
/// and chords go through `key`, which takes X keysyms. Sending "Return" to `type`
/// would literally type the word.
enum KeySymbol {
    /// Named keys, in xdotool's keysym vocabulary.
    private static let named: [KeyEquivalent: String] = [
        .return: "Return",
        .tab: "Tab",
        .delete: "BackSpace",
        .deleteForward: "Delete",
        .escape: "Escape",
        .upArrow: "Up",
        .downArrow: "Down",
        .leftArrow: "Left",
        .rightArrow: "Right",
        .home: "Home",
        .end: "End",
        .pageUp: "Page_Up",
        .pageDown: "Page_Down",
        .space: "space",
    ]

    static func input(for press: KeyPress) -> [String: Any]? {
        let mods = press.modifiers
        var prefix: [String] = []
        if mods.contains(.control) { prefix.append("ctrl") }
        if mods.contains(.option) { prefix.append("alt") }
        // The Mac's Command maps to Ctrl on Linux: ⌘C in this window should copy in
        // the desktop, not send a Super chord nothing listens for.
        if mods.contains(.command) && !prefix.contains("ctrl") { prefix.append("ctrl") }
        if mods.contains(.shift) { prefix.append("shift") }

        if let symbol = named[press.key] {
            return ["kind": "key", "keys": [(prefix + [symbol]).joined(separator: "+")]]
        }

        let characters = press.characters
        guard !characters.isEmpty else { return nil }

        // A chord needs the keysym form; plain text is typed as text.
        if !prefix.isEmpty {
            guard let scalar = characters.unicodeScalars.first else { return nil }
            let key = String(scalar).lowercased()
            return ["kind": "key", "keys": [(prefix + [key]).joined(separator: "+")]]
        }
        return ["kind": "type", "text": characters]
    }
}

#if os(macOS)
/// Mouse and keyboard for the desktop, in AppKit.
///
/// SwiftUI's `onTapGesture` and `onKeyPress` were doing this and were unreliable: the
/// view rebuilds on every frame — five times a second here, and more in the
/// full-window view — and a gesture that spans a rebuild is dropped, so clicks landed
/// only if they happened to fall between redraws. An `NSView` owns its event handling
/// regardless of how often SwiftUI re-renders around it.
///
/// It also carries what SwiftUI had no way to send: right-click, the scroll wheel, and
/// double-clicks, all of which a real desktop expects.
struct DesktopInputLayer: NSViewRepresentable {
    /// The desktop's own pixel size, for converting view points into screen pixels.
    let size: CGSize
    let onInput: ([String: Any]) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.size = size
        view.onInput = onInput
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.size = size
        view.onInput = onInput
    }

    final class InputView: NSView {
        var size: CGSize = .zero
        var onInput: ([String: Any]) -> Void = { _ in }

        override var acceptsFirstResponder: Bool { true }
        /// A click that focuses the window should also land on the desktop, rather
        /// than being swallowed as the click that woke the app up.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Typing works immediately, without a click to claim the keyboard first.
            window?.makeFirstResponder(self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        /// View point to desktop pixel. AppKit's origin is bottom-left and X11's is
        /// top-left, so the vertical axis flips.
        private func screenPoint(_ event: NSEvent) -> (x: Int, y: Int)? {
            guard bounds.width > 0, bounds.height > 0, size.width > 0 else { return nil }
            let local = convert(event.locationInWindow, from: nil)
            let scale = size.width / bounds.width
            return (
                Int((local.x * scale).rounded()),
                Int(((bounds.height - local.y) * scale).rounded())
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 {
                onInput(["kind": "doubleClick", "x": p.x, "y": p.y])
            } else {
                onInput(["kind": "click", "x": p.x, "y": p.y, "button": 1])
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            onInput(["kind": "click", "x": p.x, "y": p.y, "button": 3])
        }

        override func scrollWheel(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            // xdotool scrolls in clicks, not pixels; a trackpad reports far more
            // movement than a wheel, so this coarsens it to something usable.
            let steps = Int((event.scrollingDeltaY / 12).rounded())
            guard steps != 0 else { return }
            onInput(["kind": "scroll", "x": p.x, "y": p.y, "amount": -steps])
        }

        override func keyDown(with event: NSEvent) {
            if let input = KeySymbol.input(for: event) {
                onInput(input)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

extension KeySymbol {
    /// Named keys by virtual key code, for the AppKit path.
    private static let namedByKeyCode: [UInt16: String] = [
        36: "Return", 76: "KP_Enter", 48: "Tab", 51: "BackSpace", 117: "Delete",
        53: "Escape", 126: "Up", 125: "Down", 123: "Left", 124: "Right",
        115: "Home", 119: "End", 116: "Page_Up", 121: "Page_Down", 49: "space",
    ]

    static func input(for event: NSEvent) -> [String: Any]? {
        let flags = event.modifierFlags
        var prefix: [String] = []
        if flags.contains(.control) { prefix.append("ctrl") }
        if flags.contains(.option) { prefix.append("alt") }
        // The Mac's Command maps to Ctrl on Linux: ⌘L in this window should focus the
        // browser's address bar, not send a Super chord nothing listens for.
        if flags.contains(.command) && !prefix.contains("ctrl") { prefix.append("ctrl") }
        if flags.contains(.shift) { prefix.append("shift") }

        if let symbol = namedByKeyCode[event.keyCode] {
            return ["kind": "key", "keys": [(prefix + [symbol]).joined(separator: "+")]]
        }

        // A chord needs the keysym form; plain text is typed as text, which handles
        // arbitrary characters and layouts without a table.
        if !prefix.isEmpty {
            guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first else {
                return nil
            }
            return ["kind": "key", "keys": [(prefix + [String(scalar).lowercased()]).joined(separator: "+")]]
        }

        let characters = event.characters ?? ""
        guard !characters.isEmpty, !characters.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        return ["kind": "type", "text": characters]
    }
}
#endif
