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
    /// The latest frame, decoded once when it arrives. Decoding in the body meant a
    /// 1280×800 JPEG was decoded on every render — sixty times a second while a finger
    /// moved the pointer — which was the stutter.
    @State private var frameImage: UIImage?
    #if DEBUG
    /// What the desktop was last sent, for the UI tests to read back.
    @State private var inputLog: [String] = []
    #endif

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
        #if DEBUG
        .overlay(alignment: .bottom) {
            Text(inputLog.suffix(8).joined(separator: " | "))
                .font(.system(size: 4))
                .foregroundStyle(.white.opacity(0.02))
                .accessibilityIdentifier("inputLog")
                .allowsHitTesting(false)
        }
        #endif
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear { model.beginFrames(frameViewer, interval: .milliseconds(120)) }
        .onDisappear { model.endFrames(frameViewer) }
        .onChange(of: model.surfaceFrame, initial: true) { _, data in
            frameImage = data.flatMap(UIImage.init(data:))
        }
        // Keyed on the bot: the view can appear a beat before the selection lands, and
        // asking once then would leave it on "Starting the desktop…" for good.
        .task(id: model.selectedBotID) {
            guard model.selectedBotID != nil else { return }
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
                    if let image = frameImage {
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
                        RemoteCursor(size: 26)
                            .offset(x: pointer.x * scale, y: pointer.y * scale)
                            .allowsHitTesting(false)
                            .animation(.linear(duration: 0.06), value: pointer)
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
                            onInput: { input in
                                #if DEBUG
                                inputLog.append(Self.describe(input))
                                #endif
                                Task { await model.sendSurfaceInput(input) }
                            },
                            sendMove: { p in
                                #if DEBUG
                                inputLog.append("move")
                                #endif
                                await model.sendSurfaceInput(["kind": "move", "x": Int(p.x), "y": Int(p.y)])
                            },
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

    /// The pointer the finger last put somewhere wins over the frame's, which lags it;
    /// with neither, the middle, so there is always an arrow to find.
    #if DEBUG
    /// "click(1)@640,400", "drag", "scroll", "key" — enough for a test to tell them apart.
    static func describe(_ input: [String: Any]) -> String {
        let kind = input["kind"] as? String ?? "?"
        switch kind {
        case "click": return "click(\(input["button"] as? Int ?? 1))@\(input["x"] ?? 0),\(input["y"] ?? 0)"
        case "doubleClick": return "doubleClick@\(input["x"] ?? 0),\(input["y"] ?? 0)"
        case "drag": return "drag@\(input["fromX"] ?? 0),\(input["fromY"] ?? 0)->\(input["toX"] ?? 0),\(input["toY"] ?? 0)"
        default: return kind
        }
    }
    #endif

    private var pointerToDraw: CGPoint? {
        trackpadPointer ?? model.surfacePointer
            ?? CGPoint(x: Double(model.surface.width) / 2, y: Double(model.surface.height) / 2)
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
    /// Pointer moves, awaited: the layer sends one at a time and keeps only the latest
    /// while one is away, so a drag never queues a backlog behind a slow round trip.
    let sendMove: (CGPoint) async -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onPan: (CGSize) -> Void

    /// How far above the fingertip the pointer's hotspot sits while a finger drags.
    /// The finger hides what is under it; the arrow rides just above, where it can be
    /// seen, and the drag acts on what the arrow is on. A tap is exact.
    static let dragLift: CGFloat = 36

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "desktop"
        view.accessibilityLabel = "Desktop"
        let c = context.coordinator

        // No double-tap recognizer: waiting to rule one out held every single tap for a
        // third of a second. Two quick taps are two quick clicks, which the desktop's
        // own toolkit reads as a double-click, as it would from a mouse.
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.45
        // A hold is a finger that stays put. With unlimited movement allowed, a slow
        // drag counted as a hold and let go as a right-click.
        press.allowableMovement = 12
        c.press = press
        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.oneFingerPan(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerPan(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for g in [tap, twoFingerTap, press, drag, scroll, pinch] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        // In trackpad mode a hold that then moves is the drag, so movement is allowed.
        context.coordinator.press?.allowableMovement = trackpadMode ? 3_000 : 12
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchLayer
        weak var press: UILongPressGestureRecognizer?
        private var dragStart: CGPoint?
        private var pressing = false
        private var scrollRemainder: CGFloat = 0
        private var lastMove = Date.distantPast
        /// The move to send next, and whether one is away. Latest wins.
        private var pendingMove: CGPoint?
        private var moveInFlight = false

        init(_ parent: TouchLayer) { self.parent = parent }

        private func queueMove(_ p: CGPoint) {
            pendingMove = p
            guard !moveInFlight else { return }
            moveInFlight = true
            Task { @MainActor [weak self] in
                while let self, let next = self.pendingMove {
                    self.pendingMove = nil
                    await self.parent.sendMove(next)
                }
                self?.moveInFlight = false
            }
        }

        /// The fingertip, lifted so the arrow is visible above it.
        private func liftedPoint(_ g: UIGestureRecognizer) -> CGPoint {
            var p = g.location(in: g.view)
            p.y = max(p.y - TouchLayer.dragLift, 0)
            return desktopPoint(p)
        }

        /// A point on the layer, as desktop pixels.
        private func desktopPoint(_ p: CGPoint) -> CGPoint {
            let scale = parent.desktopSize.width / max(parent.fittedSize.width, 1)
            return CGPoint(
                x: min(max(p.x * scale, 0), parent.desktopSize.width - 1),
                y: min(max(p.y * scale, 0), parent.desktopSize.height - 1)
            )
        }

        /// A tap clicks exactly where the finger lands. Nothing else: a rule that let a
        /// tap near the last lift-off click "what the arrow was on" second-guessed the
        /// finger, and a person aiming at the arrow tapped the arrow and got somewhere
        /// else. The arrow is visible above the finger while moving; tap the arrow.
        private func clickPoint(_ g: UIGestureRecognizer) -> CGPoint {
            parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            let p = clickPoint(g)
            parent.onPointerMoved(p)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y)])
        }

        @objc func twoFingerTap(_ g: UITapGestureRecognizer) {
            let p = parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
            parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y), "button": 3])
        }

        /// Press and hold, decided on release: a hold that never moved is a right-click
        /// where the finger was; a hold that moved is a drag, let go where it lifts. It
        /// used to right-click the moment the hold began, so a finger that rested for
        /// half a second before dragging got a context menu instead of a drag.
        private var pressOrigin: CGPoint = .zero
        private var holdMoved = false

        @objc func press(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                pressing = true
                holdMoved = false
                pressOrigin = g.location(in: g.view)
                lastPressLocation = pressOrigin
                dragStart = parent.trackpadMode ? parent.pointer() : nil
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                let here = g.location(in: g.view)
                if !holdMoved, hypot(here.x - pressOrigin.x, here.y - pressOrigin.y) > 12 {
                    holdMoved = true
                    if !parent.trackpadMode {
                        var origin = pressOrigin
                        origin.y = max(origin.y - TouchLayer.dragLift, 0)
                        dragStart = desktopPoint(origin)
                    }
                }
                guard holdMoved else { return }
                if parent.trackpadMode {
                    movePointer(by: g)
                } else {
                    let p = liftedPoint(g)
                    parent.onPointerMoved(p)
                    queueMove(p)
                }
            case .ended, .cancelled:
                if holdMoved, let from = dragStart {
                    let to = parent.trackpadMode ? parent.pointer() : liftedPoint(g)
                    if hypot(to.x - from.x, to.y - from.y) > 4 {
                        parent.onInput(["kind": "drag", "fromX": Int(from.x), "fromY": Int(from.y), "toX": Int(to.x), "toY": Int(to.y)])
                    }
                } else if g.state == .ended {
                    let p = parent.trackpadMode ? parent.pointer() : desktopPoint(pressOrigin)
                    parent.onPointerMoved(p)
                    parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y), "button": 3])
                }
                dragStart = nil
                pressing = false
                holdMoved = false
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
            queueMove(p)
        }

        /// One finger moving moves the pointer, and only the pointer: no button is
        /// held. It used to be a drag as well, so aiming at something dragged whatever
        /// was under the finger's starting point on the way — a window, a selection —
        /// and the tap that followed found the desktop changed. Dragging is press and
        /// hold, then move. In trackpad mode the finger's travel moves the pointer
        /// instead of placing it.
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
                // A finger on the move is not a hold; the hold must not fire on release.
                press?.isEnabled = false
                press?.isEnabled = true
                let p = liftedPoint(g)
                parent.onPointerMoved(p)
                queueMove(p)
            case .changed:
                let p = liftedPoint(g)
                parent.onPointerMoved(p)
                queueMove(p)
            case .ended:
                let p = liftedPoint(g)
                parent.onPointerMoved(p)
                queueMove(p)
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
                    HelpRow("cursorarrow.click", "Point and click", "Tap to click exactly where you tap. Drag one finger to move the pointer; the arrow rides just above your fingertip so you can see it. To hit something small, drag until the arrow is on it, then tap the arrow.")
                    HelpRow("hand.draw", "Drag", "Press and hold until you feel a tick, then move. It lets go where you lift.")
                    HelpRow("list.bullet", "Right-click", "Tap with two fingers, or press and hold without moving. A hold that moves drags instead, for a careful drag.")
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
