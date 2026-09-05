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
            ZStack {
                Rectangle().fill(.black.opacity(0.92))

                if let frame, let image = decode(frame) {
                    image
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .contentShape(.rect)
            .onTapGesture { location in
                guard isInteractive else { return }
                isFocused = true
                if let point = desktopPoint(from: location, in: proxy.size) {
                    onInput(["kind": "click", "x": point.x, "y": point.y])
                }
            }
            #if os(macOS)
            // The pointer should say "this is clickable". `.pointerStyle` is macOS 15,
            // and the deployment target is 14, so this pushes the cursor directly.
            .onHover { inside in
                guard isInteractive else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif
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

    /// Maps a point in the view onto the desktop, accounting for the letterboxing
    /// `aspectRatio(contentMode: .fit)` introduces.
    private func desktopPoint(from location: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: (viewSize.width - drawn.width) / 2,
            y: (viewSize.height - drawn.height) / 2
        )
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard local.x >= 0, local.y >= 0, local.x <= drawn.width, local.y <= drawn.height else {
            return nil  // the letterbox, not the screen
        }
        return (Int(local.x / scale), Int(local.y / scale))
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
