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

    @FocusState private var isFocused: Bool

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
        .focusable(isInteractive)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard isInteractive else { return .ignored }
            if let input = KeySymbol.input(for: press) {
                onInput(input)
                return .handled
            }
            return .ignored
        }
        .onAppear { if isInteractive { isFocused = true } }
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
        .onTapGesture { location in
            guard isInteractive, fitted.width > 0 else { return }
            isFocused = true
            let scale = size.width / fitted.width
            onInput([
                "kind": "click",
                "x": Int((location.x * scale).rounded()),
                "y": Int((location.y * scale).rounded()),
            ])
        }
        #if os(macOS)
        // `.pointerStyle` is macOS 15 and the target is 14, so push the cursor.
        .onHover { inside in
            guard isInteractive else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
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
