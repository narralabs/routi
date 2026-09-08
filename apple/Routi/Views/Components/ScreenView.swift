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
    var onPaste: () -> Void = {}
    var onCopy: () -> Void = {}

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
                // No frame yet — a desktop just started, or the selection just moved
                // to another bot's — so a dark pane and a spinner, never a stale picture.
                ZStack {
                    Color.black
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
        }
        // The first frame fades in over the loader rather than snapping.
        .animation(.easeOut(duration: 0.2), value: frame == nil)
        // Sizing the image to the fitted rect means the gesture's own local
        // coordinates *are* screen coordinates, scaled. The previous version laid a
        // tap over the whole pane and subtracted the letterbox by hand, so any click
        // in the margin silently did nothing.
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(.rect(cornerRadius: isInteractive ? 6 : 0, style: .continuous))
        .shadow(color: .black.opacity(isInteractive ? 0.5 : 0), radius: 18, y: 6)
        .contentShape(.rect)
        #if os(macOS)
        // The thumbnail is a single click target that opens the desktop, so it says so.
        // `.pointerStyle` is macOS 15 and the target is 14, hence pushing the cursor.
        .onHover { inside in
            guard !isInteractive else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
        // No drawn cursor here. X screenshots contain no pointer — the server
        // composites it above the root window — and on the Mac the person's own
        // pointer is the pointer: in the window a second arrow a frame behind it read
        // as a laggy cursor, and on the thumbnail it was one more thing moving in the
        // corner of the eye. The phone draws one (`MobileScreen`), because there the
        // finger moves a pointer it cannot otherwise see.
        // Input rides on top of the picture, sized to it, so a point in the layer's
        // own coordinates is a point on the screen — scaled, with nothing to subtract.
        .overlay {
            #if os(macOS)
            if isInteractive {
                DesktopInputLayer(size: size, onInput: onInput, onPaste: onPaste, onCopy: onCopy)
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
    let onPaste: () -> Void
    let onCopy: () -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.size = size
        view.onInput = onInput
        view.onPaste = onPaste
        view.onCopy = onCopy
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.size = size
        view.onInput = onInput
        view.onPaste = onPaste
        view.onCopy = onCopy
    }

    final class InputView: NSView {
        var size: CGSize = .zero
        var onInput: ([String: Any]) -> Void = { _ in }
        var onPaste: () -> Void = {}
        var onCopy: () -> Void = {}

        private var trackingArea: NSTrackingArea?
        private var lastMoveSent = Date.distantPast
        private var lastMovePoint: (x: Int, y: Int)?

        override var acceptsFirstResponder: Bool { true }
        /// A click that focuses the window should also land on the desktop, rather
        /// than being swallowed as the click that woke the app up.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Typing works immediately, without a click to claim the keyboard first.
            window?.makeFirstResponder(self)
        }

        /// A plain arrow, not the pointing hand the thumbnail uses.
        ///
        /// The thumbnail is one big button, so a hand is right there. This is the
        /// desktop itself — something you point into rather than click on — and a hand
        /// over all of it makes every part of the screen look like a link.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        /// Movement has to be asked for; an NSView gets `mouseMoved` only inside a
        /// tracking area.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        /// Moves the desktop's own pointer to follow yours.
        ///
        /// Without this the remote cursor never moved: only clicks were sent, so the
        /// desktop had no idea where you were pointing and nothing ever highlighted
        /// under the pointer. Sending movement means the streamed picture shows its
        /// cursor tracking yours, which is the honest version of a shadow cursor — and
        /// it makes hover states work, which a drawn-on overlay could never do.
        ///
        /// Throttled hard, because each move is a round trip that ends in a `docker
        /// exec`: about twelve a second, and only when the pointer has actually gone
        /// somewhere. Buttons and typing are never throttled.
        override func mouseMoved(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            if let last = lastMovePoint, abs(last.x - p.x) < 3, abs(last.y - p.y) < 3 { return }
            guard Date().timeIntervalSince(lastMoveSent) > 0.08 else { return }
            lastMoveSent = Date()
            lastMovePoint = p
            onInput(["kind": "move", "x": p.x, "y": p.y])
        }

        override func mouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
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

        /// Down on mouse-down, up on mouse-up, moves in between: a real drag, with the
        /// desktop reacting as it goes. This used to send a whole click on mouse-down,
        /// so nothing on the desktop could be dragged — a window, a selection, a
        /// scrollbar — however far the mouse then moved. Two quick presses are two
        /// quick clicks, which the desktop reads as a double-click by itself.
        override func mouseDown(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            window?.makeFirstResponder(self)
            onInput(["kind": "press", "x": p.x, "y": p.y, "button": 1])
        }

        override func mouseUp(with event: NSEvent) {
            guard let p = screenPoint(event) else { return }
            onInput(["kind": "release", "x": p.x, "y": p.y, "button": 1])
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
            // Copy and paste are the Mac's shortcuts on this side and the desktop's own
            // on the other, so they are handled rather than forwarded: the clipboards
            // are two different clipboards, and bridging them is the point.
            if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers {
                if key == "v" { onPaste(); return }
                if key == "c" { onCopy(); return }
            }
            if let input = KeySymbol.input(for: event) {
                onInput(input)
            } else {
                super.keyDown(with: event)
            }
        }

        /// A right-click has to be released as well as pressed, or menus never appear.
        override func rightMouseUp(with event: NSEvent) {
            // The press already sent the whole click; this stops AppKit opening a menu
            // of its own on top of the desktop's.
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // No Mac context menu over the desktop — the right-click belongs to whatever
            // is on the screen, which will draw its own.
            nil
        }
    }
}

extension KeySymbol {
    /// Named keys by virtual key code, for the AppKit path.
    private static let namedByKeyCode: [UInt16: String] = [
        36: "Return", 76: "KP_Enter", 48: "Tab", 51: "BackSpace", 117: "Delete", 53: "Escape",
        126: "Up", 125: "Down", 123: "Left", 124: "Right",
        115: "Home", 119: "End", 116: "Page_Up", 121: "Page_Down", 49: "space",
    ]

    static func input(for event: NSEvent) -> [String: Any]? {
        // Escape goes to the desktop like every other key: it is how a page's dialog
        // or a browser menu is dismissed. Leaving the view is the close button's job.
        let flags = event.modifierFlags
        var prefix: [String] = []
        if flags.contains(.control) { prefix.append("ctrl") }
        if flags.contains(.option) { prefix.append("alt") }
        // The Mac's Command maps to Ctrl on Linux: ⌘L in this window should focus the
        // browser's address bar, not send a Super chord nothing listens for.
        if flags.contains(.command) && !prefix.contains("ctrl") { prefix.append("ctrl") }

        if let symbol = namedByKeyCode[event.keyCode] {
            let all = flags.contains(.shift) ? prefix + ["shift"] : prefix
            return ["kind": "key", "keys": [(all + [symbol]).joined(separator: "+")]]
        }

        /**
         * Shift alone is not a chord — it is how you type a character.
         *
         * Shift-2 was being sent as the chord "shift+2", which the desktop resolves
         * against its own keymap and may or may not turn into "@". The Mac already
         * knows what the key produced: `characters` is "@". Typing that is correct on
         * every layout, and it is why the symbols row stopped working.
         */
        if prefix.isEmpty {
            let characters = event.characters ?? ""
            guard !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
            return ["kind": "type", "text": characters]
        }

        // A real chord — ctrl, alt or command — needs the keysym form.
        guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first else {
            return nil
        }
        let all = flags.contains(.shift) ? prefix + ["shift"] : prefix
        return ["kind": "key", "keys": [(all + [String(scalar).lowercased()]).joined(separator: "+")]]
    }
}
#endif

/// The desktop's pointer, drawn at the frame's reported position.
///
/// A plain arrow with a light outline so it stays visible on dark and light windows
/// alike, anchored at its tip the way a real cursor is.
struct RemoteCursor: View {
    var size: CGFloat = 15
    var body: some View {
        // Drawn, not a symbol: the cursor symbols are Mac-only, and on iOS an absent
        // symbol renders as nothing at all — which read as "there is no pointer".
        // The tip is the shape's origin, so no offset is needed.
        ArrowCursor()
            .fill(.white)
            .stroke(.black, lineWidth: 1)
            .frame(width: size * 0.65, height: size)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// The classic arrow, tip at the top-left, in a unit box.
struct ArrowCursor: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: h * 0.82))
        p.addLine(to: CGPoint(x: w * 0.28, y: h * 0.64))
        p.addLine(to: CGPoint(x: w * 0.5, y: h))
        p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.92))
        p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.58))
        p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.58))
        p.closeSubpath()
        return p
    }
}
