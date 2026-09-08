#if !os(macOS)
import SwiftUI
import UIKit

/// The bot's desktop on a phone or iPad, driven by touch.
///
/// The picture is letterboxed on black and can be pinched larger. Two ways to point
/// at it: directly — a tap clicks where the finger lands, one finger drags, two scroll,
/// a two-finger tap or a press-and-hold right-clicks — and trackpad mode, where the
/// finger moves the desktop's pointer and a tap clicks wherever it is, which is the
/// easier way to hit something small. Typing and the clipboard live in the bottom bar,
/// since a phone has no keyboard until asked and its clipboard is not the desktop's.
struct MobileScreen: View {
    @Environment(AppModel.self) private var model
    @State private var frameViewer = UUID()
    @State private var trackpadMode = false
    @State private var showingHelp = false
    @State private var showingKeyboard = false
    @State private var typed = ""
    @FocusState private var keyboardFocused: Bool
    /// The pointer as trackpad mode believes it, in desktop pixels.
    @State private var trackpadPointer: CGPoint?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    private var bot: Bot? { model.selectedBot }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let handover = model.handover(for: bot?.id) {
                HandoverBanner(handover: handover)
            }
            screen
            if showingKeyboard { keyboardBar }
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear { model.beginFrames(frameViewer, interval: .milliseconds(120)) }
        .onDisappear { model.endFrames(frameViewer) }
        .task {
            await model.refreshSurface()
            await model.startSurface()
        }
        .sheet(isPresented: $showingHelp) { ScreenHelpSheet() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            RoundButton(systemName: "chevron.left") { model.isShowingScreen = false }
            if let bot {
                HStack(spacing: 8) {
                    BotAvatar(color: bot.color, seed: bot.id, size: 24)
                    Text(bot.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.white.opacity(0.1), in: .capsule)
            }
            Spacer()
            RoundButton(systemName: "questionmark") { showingHelp = true }
            Menu {
                Toggle(isOn: $trackpadMode) { Label("Trackpad mode", systemImage: "cursorarrow.rays") }
                Button { recenter() } label: { Label("Recenter pointer", systemImage: "scope") }
                if zoom > 1 {
                    Button { withAnimation { zoom = 1; pan = .zero } } label: { Label("Reset zoom", systemImage: "arrow.down.right.and.arrow.up.left") }
                }
            } label: {
                RoundButtonLabel(systemName: "ellipsis")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button { Task { await model.copyFromSurface() } } label: { Label("Copy to Phone", systemImage: "arrow.down.doc") }
                Button { Task { await model.pasteIntoSurface() } } label: { Label("Paste from Phone", systemImage: "arrow.up.doc") }
            } label: {
                RoundButtonLabel(systemName: "clipboard")
            }
            Spacer()
            RoundButton(systemName: showingKeyboard ? "keyboard.chevron.compact.down" : "keyboard") {
                withAnimation(.snappy(duration: 0.2)) { showingKeyboard.toggle() }
                keyboardFocused = showingKeyboard
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    /// Text goes as typing; the keys a phone keyboard lacks go as themselves.
    private var keyboardBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpecialKey.all) { key in
                        Button(key.label) { Task { await model.sendSurfaceInput(["kind": "key", "keys": [key.keysym]]) } }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 8) {
                TextField("Type on the desktop", text: $typed, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                    .focused($keyboardFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { sendTyped(thenReturn: true) }
                Button { sendTyped(thenReturn: false) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .disabled(typed.isEmpty)
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    private func sendTyped(thenReturn: Bool) {
        let text = typed
        typed = ""
        guard !text.isEmpty || thenReturn else { return }
        Task {
            if !text.isEmpty { await model.sendSurfaceInput(["kind": "type", "text": text]) }
            if thenReturn { await model.sendSurfaceInput(["kind": "key", "keys": ["Return"]]) }
        }
    }

    // MARK: - The picture

    private var screen: some View {
        GeometryReader { proxy in
            let size = CGSize(width: model.surface.width, height: model.surface.height)
            let fitted = fittedSize(size, in: proxy.size)
            ZStack {
                Color.black
                Group {
                    if let frame = model.surfaceFrame, let image = UIImage(data: frame) {
                        Image(uiImage: image).resizable().interpolation(.medium)
                    } else {
                        ZStack {
                            Color.black
                            VStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text(model.surface.state == .running ? "Waiting for a frame…" : "Starting the desktop…")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .overlay(alignment: .topLeading) {
                    if let pointer = pointerToDraw, fitted.width > 0, size.width > 0 {
                        let scale = fitted.width / size.width
                        RemoteCursor()
                            .offset(x: pointer.x * scale, y: pointer.y * scale)
                            .allowsHitTesting(false)
                            .animation(.linear(duration: 0.08), value: pointer)
                    }
                }
                .overlay {
                    if fitted.width > 0, size.width > 0 {
                        TouchLayer(
                            desktopSize: size,
                            fittedSize: fitted,
                            trackpadMode: trackpadMode,
                            zoom: zoom,
                            pointer: { trackpadPointer ?? model.surfacePointer ?? CGPoint(x: size.width / 2, y: size.height / 2) },
                            onPointerMoved: { trackpadPointer = $0 },
                            onInput: { input in Task { await model.sendSurfaceInput(input) } },
                            onZoom: { delta, anchor in
                                let next = min(max(zoom * delta, 1), 4)
                                zoom = next
                                if next == 1 { pan = .zero }
                            },
                            onPan: { delta in
                                pan = clamp(CGSize(width: pan.width + delta.width, height: pan.height + delta.height), fitted: fitted, in: proxy.size)
                            }
                        )
                    }
                }
                .scaleEffect(zoom)
                .offset(pan)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var pointerToDraw: CGPoint? {
        trackpadMode ? (trackpadPointer ?? model.surfacePointer) : model.surfacePointer
    }

    private func recenter() {
        let center = CGPoint(x: Double(model.surface.width) / 2, y: Double(model.surface.height) / 2)
        trackpadPointer = center
        Task { await model.sendSurfaceInput(["kind": "move", "x": Int(center.x), "y": Int(center.y)]) }
    }

    private func fittedSize(_ size: CGSize, in available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Keeps the zoomed picture from being panned clean out of the pane.
    private func clamp(_ offset: CGSize, fitted: CGSize, in pane: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * zoom - pane.width) / 2 + (pane.width - fitted.width) / 2 * zoom)
        let maxY = max(0, (fitted.height * zoom - pane.height) / 2 + (pane.height - fitted.height) / 2 * zoom)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }
}

/// The keys a phone keyboard does not have, as xdotool names them.
private struct SpecialKey: Identifiable {
    let label: String
    let keysym: String
    var id: String { keysym }
    static let all: [SpecialKey] = [
        .init(label: "esc", keysym: "Escape"), .init(label: "tab", keysym: "Tab"),
        .init(label: "⌫", keysym: "BackSpace"), .init(label: "↵", keysym: "Return"),
        .init(label: "←", keysym: "Left"), .init(label: "↑", keysym: "Up"),
        .init(label: "↓", keysym: "Down"), .init(label: "→", keysym: "Right"),
        .init(label: "ctrl+a", keysym: "ctrl+a"), .init(label: "ctrl+l", keysym: "ctrl+l"),
    ]
}

private struct RoundButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { RoundButtonLabel(systemName: systemName) }
            .buttonStyle(.plain)
    }
}

private struct RoundButtonLabel: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.1), in: .circle)
            .contentShape(.circle)
    }
}

// MARK: - Touch

/// Every gesture the desktop understands, as UIKit recognisers.
///
/// UIKit rather than SwiftUI gestures because a two-finger pan, a two-finger tap and
/// a pinch have to coexist with a one-finger tap, drag and press, and SwiftUI cannot
/// tell fingers apart. Touch locations are the layer's own coordinates, which sit
/// over the fitted picture, so a point here is a point on the desktop, scaled.
private struct TouchLayer: UIViewRepresentable {
    let desktopSize: CGSize
    let fittedSize: CGSize
    let trackpadMode: Bool
    let zoom: CGFloat
    let pointer: () -> CGPoint
    let onPointerMoved: (CGPoint) -> Void
    let onInput: ([String: Any]) -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onPan: (CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        let c = context.coordinator

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let twoFingerTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 3_000
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.oneFingerPan(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerPan(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for g in [tap, doubleTap, twoFingerTap, press, drag, scroll, pinch] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchLayer
        private var dragStart: CGPoint?
        private var pressing = false
        private var scrollRemainder: CGFloat = 0
        private var lastMove = Date.distantPast

        init(_ parent: TouchLayer) { self.parent = parent }

        /// A point on the layer, as desktop pixels.
        private func desktopPoint(_ p: CGPoint) -> CGPoint {
            let scale = parent.desktopSize.width / max(parent.fittedSize.width, 1)
            return CGPoint(
                x: min(max(p.x * scale, 0), parent.desktopSize.width - 1),
                y: min(max(p.y * scale, 0), parent.desktopSize.height - 1)
            )
        }

        private func clickPoint(_ g: UIGestureRecognizer) -> CGPoint {
            parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            let p = clickPoint(g)
            parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y)])
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            let p = clickPoint(g)
            parent.onInput(["kind": "doubleClick", "x": Int(p.x), "y": Int(p.y)])
        }

        @objc func twoFingerTap(_ g: UITapGestureRecognizer) {
            let p = parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
            parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y), "button": 3])
        }

        /// Press and hold: a right-click. In trackpad mode a hold that then moves is a
        /// drag from the pointer, released where the finger lifts.
        @objc func press(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                pressing = true
                if parent.trackpadMode {
                    dragStart = parent.pointer()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    let p = desktopPoint(g.location(in: g.view))
                    parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y), "button": 3])
                }
            case .changed:
                guard parent.trackpadMode, dragStart != nil else { return }
                movePointer(by: g)
            case .ended, .cancelled:
                if parent.trackpadMode, let from = dragStart {
                    let to = parent.pointer()
                    if hypot(to.x - from.x, to.y - from.y) > 4 {
                        parent.onInput(["kind": "drag", "fromX": Int(from.x), "fromY": Int(from.y), "toX": Int(to.x), "toY": Int(to.y)])
                    }
                }
                dragStart = nil
                pressing = false
                lastPressLocation = nil
            default: break
            }
        }

        private var lastPressLocation: CGPoint?
        private func movePointer(by g: UIGestureRecognizer) {
            let here = g.location(in: g.view)
            defer { lastPressLocation = here }
            guard let last = lastPressLocation else { return }
            nudgePointer(dx: here.x - last.x, dy: here.y - last.y)
        }

        /// Trackpad: the finger's travel, scaled to the desktop, moves the pointer.
        private func nudgePointer(dx: CGFloat, dy: CGFloat) {
            let scale = parent.desktopSize.width / max(parent.fittedSize.width, 1) * 1.4 / parent.zoom
            var p = parent.pointer()
            p.x = min(max(p.x + dx * scale, 0), parent.desktopSize.width - 1)
            p.y = min(max(p.y + dy * scale, 0), parent.desktopSize.height - 1)
            parent.onPointerMoved(p)
            if Date().timeIntervalSince(lastMove) > 0.04 {
                lastMove = Date()
                parent.onInput(["kind": "move", "x": Int(p.x), "y": Int(p.y)])
            }
        }

        /// One finger moving: a drag, released where it ends. In trackpad mode, the
        /// pointer moving.
        @objc func oneFingerPan(_ g: UIPanGestureRecognizer) {
            if pressing { return }
            if parent.trackpadMode {
                let t = g.translation(in: g.view)
                g.setTranslation(.zero, in: g.view)
                nudgePointer(dx: t.x, dy: t.y)
                return
            }
            switch g.state {
            case .began:
                dragStart = desktopPoint(g.location(in: g.view))
            case .ended:
                guard let from = dragStart else { return }
                let to = desktopPoint(g.location(in: g.view))
                if hypot(to.x - from.x, to.y - from.y) > 4 {
                    parent.onInput(["kind": "drag", "fromX": Int(from.x), "fromY": Int(from.y), "toX": Int(to.x), "toY": Int(to.y)])
                }
                dragStart = nil
            case .cancelled, .failed:
                dragStart = nil
            default: break
            }
        }

        /// Two fingers: scroll the desktop, or pan the picture when it is zoomed in.
        @objc func twoFingerPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            if parent.zoom > 1 {
                parent.onPan(CGSize(width: t.x * parent.zoom, height: t.y * parent.zoom))
                return
            }
            // One wheel click per 28 points of travel, in the desktop's direction:
            // fingers up scrolls the page down, as on the phone itself.
            scrollRemainder += -t.y / 28
            let clicks = Int(scrollRemainder.rounded(.towardZero))
            guard clicks != 0 else { return }
            scrollRemainder -= CGFloat(clicks)
            let p = parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
            parent.onInput(["kind": "scroll", "x": Int(p.x), "y": Int(p.y), "amount": clicks])
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed else { return }
            parent.onZoom(g.scale, g.location(in: g.view))
            g.scale = 1
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            // Pinch and two-finger pan together; a press may turn into a move.
            (a is UIPinchGestureRecognizer || b is UIPinchGestureRecognizer)
                || (a is UILongPressGestureRecognizer || b is UILongPressGestureRecognizer)
        }
    }
}

// MARK: - Help

/// What the fingers do, said once, for the person who did not guess.
struct ScreenHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Moving around") {
                    HelpRow("arrow.up.arrow.down", "Scroll", "Drag with two fingers.")
                    HelpRow("cursorarrow.click", "Click and drag", "Tap to click where you tapped. One finger drags; it lets go where you lift.")
                    HelpRow("list.bullet", "Right-click", "Tap with two fingers, or press and hold.")
                    HelpRow("plus.magnifyingglass", "Zoom in", "Pinch to zoom. Zoomed in, two fingers pan instead of scrolling.")
                }
                Section("Typing and the clipboard") {
                    HelpRow("keyboard", "Type", "Tap the keyboard button in the bottom bar. Return sends the line; the row above it has the keys a phone lacks.")
                    HelpRow("clipboard", "Copy and paste", "The clipboard button in the bottom bar copies to this phone or pastes from it.")
                }
                Section("When a pointer is easier") {
                    HelpRow("cursorarrow.rays", "Trackpad mode", "Turn it on from the ··· menu. Your finger moves the pointer; tap to click there, press and hold then move to drag. Recenter pointer if it drifts.")
                }
            }
            .navigationTitle("Using the computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }

    private func HelpRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
