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
    @State private var useVNC = true
    /// Relative pointing, like a trackpad, is the default: the pointer starts in the
    /// middle and a finger anywhere on the screen moves it by its travel. Measured
    /// against how a hand actually uses a phone, and how Grok Bot's app behaves.
    @State private var trackpadMode = true
    @State private var showingHelp = false
    @State private var showingKeyboard = false
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
    @State private var vncCursor: VNCCursor?
    #endif

    private var bot: Bot? { model.selectedBot }

    private var vncURL: URL? {
        #if DEBUG
        guard bot?.surfaceMode == .container,
              let botID = bot?.id,
              let base = UserDefaults.standard.string(forKey: "vncPreviewURL"),
              let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1"
        else { return nil }
        return url.appendingPathComponent(botID)
        #else
        return nil
        #endif
    }

    private var showingVNC: Bool { useVNC && vncURL != nil }

    private func updateFramePolling() {
        if showingVNC { model.endFrames(frameViewer) }
        else { model.beginFrames(frameViewer, interval: .milliseconds(120)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let handover = model.handover(for: bot?.id) {
                HandoverBanner(handover: handover)
            }
            screen
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .bottom) {
            Text(inputLog.suffix(40).joined(separator: " | "))
                .font(.system(size: 4))
                .foregroundStyle(.white.opacity(0.02))
                .accessibilityIdentifier("inputLog")
                .allowsHitTesting(false)
        }
        #endif
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear { updateFramePolling() }
        .onChange(of: showingVNC) { updateFramePolling() }
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
            // Start in the middle, and say so to the desktop, so the arrow drawn and the
            // pointer the desktop has agree from the first touch.
            if trackpadPointer == nil, model.surface.width > 0 { recenter() }
        }
        .sheet(isPresented: $showingHelp) { ScreenHelpSheet() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            RoundButton(systemName: "chevron.left") { model.isShowingScreen = false }
                .accessibilityIdentifier("closeScreen")
            if let bot {
                HStack(spacing: 8) {
                    BotAvatar(color: bot.color, seed: bot.id, size: 24, mood: model.mood(for: bot.id))
                    Text(bot.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.white.opacity(0.1), in: .capsule)
            }
            Spacer()
            RoundButton(systemName: "questionmark") { showingHelp = true }
            Menu {
                if vncURL != nil {
                    Picker("Viewer", selection: $useVNC) {
                        Text("VNC").tag(true)
                        Text("JPEG").tag(false)
                    }
                }
                Toggle(isOn: $trackpadMode) { Label("Trackpad mode", systemImage: "cursorarrow.rays") }
                Toggle(isOn: Binding(get: { !trackpadMode }, set: { trackpadMode = !$0 })) {
                    Label("Tap where you touch", systemImage: "hand.tap")
                }
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
            // No field: the keyboard types straight onto the desktop, key by key, and
            // Return is Return there. The keys a phone lacks ride above the keyboard.
            KeyInput(isActive: $showingKeyboard, onInput: { input in
                #if DEBUG
                inputLog.append(Self.describe(input))
                #endif
                Task { await model.sendSurfaceInput(input) }
            })
            .frame(width: 1, height: 1)
            RoundButton(systemName: showingKeyboard ? "keyboard.chevron.compact.down" : "keyboard") {
                showingKeyboard.toggle()
            }
            .accessibilityIdentifier("keyboard")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    // MARK: - The picture

    private var screen: some View {
        GeometryReader { proxy in
            let size = CGSize(width: model.surface.width, height: model.surface.height)
            let fitted = fittedSize(size, in: proxy.size)
            ZStack {
                Color.black
                picture(size: size, fitted: fitted)
                    .scaleEffect(zoom)
                    .offset(pan)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // Touch is the whole pane, black margins included: a finger moving the
            // pointer should not stop working at the picture's edge.
            .overlay {
                if fitted.width > 0, size.width > 0 {
                    TouchLayer(
                        paneSize: proxy.size,
                        desktopSize: size,
                        fittedSize: fitted,
                        trackpadMode: trackpadMode,
                        zoom: zoom,
                        pan: pan,
                        pointer: { trackpadPointer ?? model.surfacePointer ?? CGPoint(x: size.width / 2, y: size.height / 2) },
                        onPointerMoved: { p in
                            #if DEBUG
                            if ProcessInfo.processInfo.arguments.contains("-logPointer") {
                                inputLog.append("ptr@\(Int(p.x)),\(Int(p.y))")
                            }
                            #endif
                            trackpadPointer = p
                        },
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
                        onZoom: { delta, _ in
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
        }
    }

    @ViewBuilder
    private func picture(size: CGSize, fitted: CGSize) -> some View {
        framebuffer
            .frame(width: fitted.width, height: fitted.height)
            .overlay(alignment: .topLeading) {
                if let pointer = pointerToDraw, fitted.width > 0, size.width > 0 {
                    let scale = fitted.width / size.width
                    mobileCursor
                        .offset(x: pointer.x * scale, y: pointer.y * scale)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var mobileCursor: some View {
        #if DEBUG
        if showingVNC, let cursor = vncCursor {
            let scale = 26 / max(cursor.image.size.width, cursor.image.size.height)
            Image(uiImage: cursor.image).resizable()
                .frame(width: cursor.image.size.width * scale, height: cursor.image.size.height * scale)
                .offset(x: -cursor.hotspot.x * scale, y: -cursor.hotspot.y * scale)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        } else {
            RemoteCursor(size: 26)
        }
        #else
        RemoteCursor(size: 26)
        #endif
    }

    @ViewBuilder
    private var framebuffer: some View {
        #if DEBUG
        if showingVNC, let url = vncURL {
            // VNC supplies pixels; TouchLayer owns the whole pane and input.
            VNCPreview(url: url, onCursor: { vncCursor = $0 })
                .id(url)
                .allowsHitTesting(false)
                .onDisappear { vncCursor = nil }
        } else {
            jpegFrame
        }
        #else
        jpegFrame
        #endif
    }

    private var jpegFrame: some View {
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
        case "press": return "press@\(input["x"] ?? 0),\(input["y"] ?? 0)"
        case "release": return "release@\(input["x"] ?? 0),\(input["y"] ?? 0)"
        case "type": return "type(\(input["text"] ?? ""))"
        case "key": return "key(\((input["keys"] as? [String])?.joined(separator: "+") ?? ""))"
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

// MARK: - Keyboard

/// An invisible first responder: the keyboard's keystrokes, sent to the desktop as
/// they happen. Text goes through `type`, which handles any character; Return and
/// backspace go through `key`, since typing the word "Return" is not the same thing.
/// Sent in order, one call at a time, with a run of characters merged into one.
private struct KeyInput: UIViewRepresentable {
    @Binding var isActive: Bool
    let onInput: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.coordinator = context.coordinator
        view.inputAccessoryView = context.coordinator.accessory()
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        context.coordinator.parent = self
        if isActive, !view.isFirstResponder { view.becomeFirstResponder() }
        if !isActive, view.isFirstResponder { view.resignFirstResponder() }
    }

    final class Coordinator: NSObject {
        var parent: KeyInput
        private var queue: [[String: Any]] = []
        private var flushing = false
        init(_ parent: KeyInput) { self.parent = parent }

        func text(_ s: String) {
            if s == "\n" { key("Return"); return }
            if var last = queue.last, last["kind"] as? String == "type" {
                last["text"] = (last["text"] as? String ?? "") + s
                queue[queue.count - 1] = last
            } else {
                queue.append(["kind": "type", "text": s])
            }
            flush()
        }

        func key(_ keysym: String) {
            queue.append(["kind": "key", "keys": [keysym]])
            flush()
        }

        private func flush() {
            guard !flushing, !queue.isEmpty else { return }
            flushing = true
            let next = queue.removeFirst()
            parent.onInput(next)
            // Order over speed: the next keystroke goes after this one has been handed
            // off, so "hi" then Return cannot arrive as Return then "hi".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.flushing = false
                self?.flush()
            }
        }

        func dismissed() {
            DispatchQueue.main.async { self.parent.isActive = false }
        }

        /// The keys a phone keyboard lacks, above it.
        func accessory() -> UIView {
            let bar = UIScrollView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            bar.backgroundColor = UIColor(white: 0.12, alpha: 1)
            bar.showsHorizontalScrollIndicator = false
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            for k in SpecialKey.all {
                var config = UIButton.Configuration.filled()
                config.title = k.label
                config.baseBackgroundColor = UIColor(white: 0.25, alpha: 1)
                config.baseForegroundColor = .white
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
                let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.key(k.keysym) })
                button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
                stack.addArrangedSubview(button)
            }
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.contentLayoutGuide.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: bar.contentLayoutGuide.trailingAnchor, constant: -12),
                stack.centerYAnchor.constraint(equalTo: bar.frameLayoutGuide.centerYAnchor),
                stack.heightAnchor.constraint(equalTo: bar.frameLayoutGuide.heightAnchor, constant: -12),
            ])
            return bar
        }
    }

    final class KeyView: UIView, UIKeyInput {
        weak var coordinator: Coordinator?
        private var accessory: UIView?
        override var canBecomeFirstResponder: Bool { true }
        override var inputAccessoryView: UIView? {
            get { accessory }
            set { accessory = newValue }
        }
        var hasText: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        func insertText(_ text: String) { coordinator?.text(text) }
        func deleteBackward() { coordinator?.key("BackSpace") }
        override func resignFirstResponder() -> Bool {
            let did = super.resignFirstResponder()
            if did { coordinator?.dismissed() }
            return did
        }
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
    let paneSize: CGSize
    let desktopSize: CGSize
    let fittedSize: CGSize
    let trackpadMode: Bool
    let zoom: CGFloat
    let pan: CGSize
    let pointer: () -> CGPoint
    let onPointerMoved: (CGPoint) -> Void
    let onInput: ([String: Any]) -> Void
    /// Pointer moves, awaited: the layer sends one at a time and keeps only the latest
    /// while one is away, so a drag never queues a backlog behind a slow round trip.
    let sendMove: (CGPoint) async -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onPan: (CGSize) -> Void

    /// The pointer's hotspot sits exactly under the fingertip. It rode 36 points above
    /// for a while, to stay visible past the finger, and that made the arrow and the
    /// finger disagree about where the pointer was: a tap on the spot the finger had
    /// lifted from landed under the arrow, and read as the tap moving the pointer.
    /// Lift the finger to see the arrow; tap that spot to click it.
    static let dragLift: CGFloat = 0

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
        // In trackpad mode a hold may keep moving the pointer afterwards, so movement
        // is allowed; in tap-where-you-touch a moving finger is not a hold at all.
        context.coordinator.press?.allowableMovement = trackpadMode ? 3_000 : 12
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchLayer
        weak var press: UILongPressGestureRecognizer?
        private var dragStart: CGPoint?
        private var pressing = false
        private var scrollRemainder: CGFloat = 0
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

        /// A point on the pane, as desktop pixels: undo the zoom and pan about the
        /// pane's centre, take off the letterbox, then scale to the desktop.
        private func desktopPoint(_ p: CGPoint) -> CGPoint {
            let c = CGPoint(x: parent.paneSize.width / 2, y: parent.paneSize.height / 2)
            let ux = (p.x - c.x - parent.pan.width) / parent.zoom + c.x - (parent.paneSize.width - parent.fittedSize.width) / 2
            let uy = (p.y - c.y - parent.pan.height) / parent.zoom + c.y - (parent.paneSize.height - parent.fittedSize.height) / 2
            let scale = parent.desktopSize.width / max(parent.fittedSize.width, 1)
            return CGPoint(
                x: min(max(ux * scale, 0), parent.desktopSize.width - 1),
                y: min(max(uy * scale, 0), parent.desktopSize.height - 1)
            )
        }

        /// A tap clicks exactly where the finger lands. Nothing else: a rule that let a
        /// tap near the last lift-off click "what the arrow was on" second-guessed the
        /// finger, and a person aiming at the arrow tapped the arrow and got somewhere
        /// else. The arrow is visible above the finger while moving; tap the arrow.
        private func clickPoint(_ g: UIGestureRecognizer) -> CGPoint {
            parent.trackpadMode ? parent.pointer() : desktopPoint(g.location(in: g.view))
        }

        /// When the last tap was, so a hold that follows one closely is a drag.
        private var lastTapAt = Date.distantPast

        @objc func tap(_ g: UITapGestureRecognizer) {
            let p = clickPoint(g)
            lastTapAt = Date()
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
        /// A hold that came right after a tap: the trackpad drag. The button goes down
        /// at the pointer when the hold takes and comes up where the finger lifts.
        /// Decided from the tap's time rather than by a tap-counting recogniser, whose
        /// system double-tap window a finger — or a test — misses too easily.
        private var dragging = false

        @objc func press(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                pressing = true
                holdMoved = false
                pressOrigin = g.location(in: g.view)
                lastPressLocation = pressOrigin
                dragStart = parent.trackpadMode ? parent.pointer() : nil
                dragging = parent.trackpadMode && Date().timeIntervalSince(lastTapAt) < 1.0
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if dragging, let from = dragStart {
                    parent.onInput(["kind": "press", "x": Int(from.x), "y": Int(from.y), "button": 1])
                }
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
                if dragging {
                    let to = parent.pointer()
                    parent.onInput(["kind": "release", "x": Int(to.x), "y": Int(to.y), "button": 1])
                } else if holdMoved, !parent.trackpadMode, let from = dragStart {
                    // Tap-where-you-touch has no other drag; in trackpad mode a hold that
                    // moved only moved the pointer, and the drag is tap-then-hold.
                    let to = liftedPoint(g)
                    if hypot(to.x - from.x, to.y - from.y) > 4 {
                        parent.onInput(["kind": "drag", "fromX": Int(from.x), "fromY": Int(from.y), "toX": Int(to.x), "toY": Int(to.y)])
                    }
                } else if holdMoved {
                    // Moved: nothing to send, the pointer already followed.
                } else if g.state == .ended {
                    let p = parent.trackpadMode ? parent.pointer() : desktopPoint(pressOrigin)
                    parent.onPointerMoved(p)
                    parent.onInput(["kind": "click", "x": Int(p.x), "y": Int(p.y), "button": 3])
                }
                dragStart = nil
                pressing = false
                holdMoved = false
                dragging = false
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
            // One to one with the picture: the pointer crosses the desktop as the finger
            // crosses the phone. No acceleration; a steady hand wants a steady arrow.
            let scale = parent.desktopSize.width / max(parent.fittedSize.width, 1) / parent.zoom
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
            if pressing {
                // A hold owns the movement. The pan keeps running underneath, and its
                // travel has to be thrown away as it happens: left to accumulate, its
                // final event applied the whole of the hold's movement a second time
                // on release, and the pointer leapt away from where the finger lifted.
                g.setTranslation(.zero, in: g.view)
                return
            }
            if parent.trackpadMode {
                // The final event's delta is the tail of the last one; applying it
                // once more is the nudge nobody made.
                guard g.state == .changed else { g.setTranslation(.zero, in: g.view); return }
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
                    HelpRow("cursorarrow.motionlines", "Point", "The pointer starts in the middle. Drag one finger anywhere on the screen, black edges included, and it moves with your finger, like a trackpad.")
                    HelpRow("cursorarrow.click", "Click", "Tap anywhere to click where the pointer is. Two quick taps double-click.")
                    HelpRow("hand.draw", "Drag", "Tap, then press and hold until you feel a tick, then move. It lets go where you lift.")
                    HelpRow("list.bullet", "Right-click", "Tap with two fingers, or press and hold without moving. A hold that moves just keeps pointing.")
                    HelpRow("arrow.up.arrow.down", "Scroll", "Drag with two fingers.")
                    HelpRow("plus.magnifyingglass", "Zoom in", "Pinch to zoom. Zoomed in, two fingers pan instead of scrolling.")
                }
                Section("Typing and the clipboard") {
                    HelpRow("keyboard", "Type", "Tap the keyboard button in the bottom bar and type; every key goes straight to the desktop. The row above the keyboard has the keys a phone lacks.")
                    HelpRow("clipboard", "Copy and paste", "The clipboard button in the bottom bar copies to this phone or pastes from it.")
                }
                Section("The other way") {
                    HelpRow("hand.tap", "Tap where you touch", "From the ··· menu. A tap then clicks the exact spot under your finger, and a drag moves the pointer to where your finger is. Recenter pointer puts it back in the middle in either mode.")
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
