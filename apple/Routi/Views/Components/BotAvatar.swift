import SwiftUI

/// What a bot is up to, as far as its face is concerned. Derived by `AppModel.mood`.
enum BotMood: Hashable {
    /// Awake and listening.
    case idle
    /// Nothing has happened in a while. Eyes shut, breathing slowly.
    case asleep
    /// Answering: composing, reasoning. Eyes wander from side to side.
    case thinking
    /// Inside a tool call — driving the desktop, saving a note. Eyes down on the
    /// work, a small bob of effort.
    case working
    /// Its last turn failed. Wide eyes, mouth an "o".
    case trouble
}

/// The bot's face, drawn rather than shipped as an asset so it tints to any bot colour
/// and stays crisp at every size.
///
/// It is the face from the app's own mark — two round eyes and a small smile in soft
/// cream — on a squircle of the bot's colour, lit from the top left. The choices are
/// the ones the evidence on faces supports: a face-like pattern is noticed before any
/// other shape; rounded contours read as friendly where angular ones read as threat
/// (Bar & Neta, 2006); eyes set large and low with a small mouth are the proportions
/// people find approachable (Lorenz's Kindchenschema); and an upturned mouth is the
/// strongest single cue for judged trustworthiness (Oosterhof & Todorov, 2008).
///
/// Each bot gets its own expression — eye size, spacing and smile width, fixed by its
/// id — so bots are told apart by shape as well as colour, which one person in twelve
/// cannot rely on.
///
/// The face also moves. Its `mood` sets the resting expression and one slow motion
/// (a glance, a bob, a breath), and it can be poked: a tap makes it flinch, a few taps
/// in a row make it cross, and a few more turn it red. It calms down on its own. All
/// of this is a handful of animatable numbers on the same two eyes and one mouth, so
/// it costs nothing while the bot sits still.
struct BotAvatar: View {
    let color: Color
    /// Something stable per bot — its id — so the face is the same every time.
    var seed: String = ""
    var size: CGFloat = 34
    var mood: BotMood = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A blink is the eyes closing for a beat. Driven by a per-avatar timer at a
    /// random interval, so a sidebar of bots never blinks in unison.
    @State private var blinking = false
    /// 0 → 1 and back, forever, while the mood has a motion. Each mood reads it as
    /// its own thing: the glance, the bob, the breath.
    @State private var phase: CGFloat = 0
    /// The sleeper's "z", drifting up and fading: 0 at the mouth, 1 gone.
    @State private var zzz: CGFloat = 0

    // The poke.
    /// Taps in quick succession. Cleared a few seconds after the last one.
    @State private var pokes = 0
    /// The instant after a poke: eyes wide, mouth open.
    @State private var startled = false
    /// 1 on the poke, springing back to 0: the tile squashes and bounces.
    @State private var squash: CGFloat = 0
    /// A sideways shudder for the angry poke.
    @State private var shake: CGFloat = 0
    @State private var pokeTask: Task<Void, Never>?

    /// The cream of the mark's letterform; pure white reads as a sticker.
    private static let cream = Color(red: 0.97, green: 0.96, blue: 0.93)

    private var look: Look { Look(seed: seed) }

    private enum Temper { case calm, annoyed, angry }

    private var temper: Temper {
        if pokes >= 7 { return .angry }
        if pokes >= 4 { return .annoyed }
        return .calm
    }

    /// The mood's motion runs only while the bot is on speaking terms with you.
    private var motion: BotMood? { temper == .calm ? mood : nil }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .overlay {
                // Anger, as a wash of red over the bot's own colour.
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Color(red: 0.86, green: 0.16, blue: 0.14).opacity(expression.anger * 0.85))
            }
            .overlay {
                // The light the mark has: a little brighter at the top left, so the
                // tile reads as a soft object rather than a flat swatch.
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.0), .black.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: size, height: size)
            .overlay { face }
            .overlay(alignment: .topTrailing) {
                if motion == .asleep {
                    Text("z")
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.cream)
                        .offset(x: -size * 0.1 + zzz * size * 0.08, y: size * 0.08 - zzz * size * 0.22)
                        .opacity(0.9 - zzz * 0.9)
                        .scaleEffect(0.7 + zzz * 0.5)
                }
            }
            // Breathing, asleep: the whole tile swells a touch.
            .scaleEffect(motion == .asleep ? 1 + phase * 0.03 : 1)
            // The poke: squash on the tap, spring back.
            .scaleEffect(x: 1 + squash * 0.16, y: 1 - squash * 0.2, anchor: .bottom)
            .offset(x: shake, y: motion == .working ? phase * size * 0.05 : 0)
            .overlay(alignment: .bottomTrailing) {
                if mood == .thinking || mood == .working {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(.background, lineWidth: size * 0.055))
                        .offset(x: size * 0.04, y: size * 0.04)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: expression)
            .contentShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            // Simultaneous, so a poke in a list row still selects the row.
            .simultaneousGesture(TapGesture().onEnded { poke() })
            .onChange(of: motion, initial: true) { _, m in restartMotion(m) }
            .onChange(of: reduceMotion) { _, _ in restartMotion(motion) }
            .task(id: reduceMotion) {
                // Cheap: one sleeping task per avatar, awake for 140ms every few
                // seconds. Nothing runs between blinks.
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 3...9)))
                    guard !Task.isCancelled else { return }
                    blinking = true
                    try? await Task.sleep(for: .milliseconds(140))
                    blinking = false
                }
            }
    }

    // MARK: - The expression

    /// Everything the face can vary, as numbers, so any change between two of them
    /// is one short animation of the same shapes.
    private struct Expression: Equatable {
        /// 1 open, 0.12 shut.
        var eyeOpen: CGFloat = 1
        /// Wide-eyed above 1.
        var eyeScale: CGFloat = 1
        /// Where the eyes look, in units of the tile.
        var gaze = CGSize.zero
        /// 0 no brow, 1 furrowed.
        var brow: CGFloat = 0
        /// +1 the smile, 0 flat, −1 the frown.
        var mouthCurve: CGFloat = 1
        /// × the bot's own smile width.
        var mouthWidth: CGFloat = 1
        /// 1 is the round "o", drawn in place of the arc.
        var mouthO: CGFloat = 0
        /// 0 the bot's colour, 1 red.
        var anger: CGFloat = 0
    }

    private var expression: Expression {
        var e = Expression()
        switch temper {
        case .angry:
            e.brow = 1
            e.eyeOpen = 0.55
            e.mouthCurve = -0.9
            e.mouthWidth = 0.85
            e.anger = 1
        case .annoyed:
            e.brow = 0.5
            e.eyeOpen = 0.6
            e.mouthCurve = 0
            e.mouthWidth = 0.8
            e.anger = 0.3
        case .calm:
            switch mood {
            case .idle:
                break
            case .asleep:
                e.eyeOpen = 0.12
                e.gaze.height = 0.02
                e.mouthCurve = 0.4
                e.mouthWidth = 0.55
            case .thinking:
                e.gaze.height = -0.03
                e.mouthCurve = 0.25
                e.mouthWidth = 0.7
            case .working:
                e.eyeOpen = 0.7
                e.gaze.height = 0.03
                e.mouthCurve = 0
                e.mouthWidth = 0.6
            case .trouble:
                e.eyeScale = 1.3
                e.mouthO = 1
            }
        }
        if startled {
            e.eyeOpen = 1
            e.eyeScale = 1.35
            e.mouthO = 1
            e.gaze = .zero
        }
        if blinking { e.eyeOpen = 0.12 }
        return e
    }

    private var face: some View {
        let s = size
        let look = look
        let e = expression
        return ZStack {
            // Eyes: two dots, set a little low — the mark's, not a pair of bars.
            HStack(spacing: s * look.eyeGap) {
                eye(s * look.eye, brow: 1)
                eye(s * look.eye, brow: -1)
            }
            .scaleEffect(e.eyeScale)
            // A glance slides them a little; thinking wanders on its own.
            .offset(
                x: (e.gaze.width + (motion == .thinking ? (phase * 2 - 1) * 0.05 : 0)) * s,
                y: (-0.08 + e.gaze.height) * s
            )

            // The mouth: the arc, or the "o" in its place.
            Mouth(curve: e.mouthCurve, width: e.mouthWidth)
                .stroke(Self.cream, style: StrokeStyle(lineWidth: max(1, s * 0.075), lineCap: .round))
                .frame(width: s * look.smile, height: s * 0.12)
                .opacity(1 - e.mouthO)
                .offset(y: s * 0.17)
            Circle()
                .stroke(Self.cream, lineWidth: max(1, s * 0.075))
                .frame(width: s * 0.15, height: s * 0.15)
                .opacity(e.mouthO)
                .offset(y: s * 0.19)
        }
    }

    /// One eye, with its brow above: a short bar that tilts inward as the brow
    /// furrows. `brow` is +1 for the left eye, −1 for the right.
    private func eye(_ diameter: CGFloat, brow side: CGFloat) -> some View {
        let e = expression
        return Circle()
            .fill(Self.cream)
            .frame(width: diameter, height: diameter)
            // A blink squashes the eye to a line.
            .scaleEffect(x: 1, y: e.eyeOpen, anchor: .center)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Self.cream)
                    .frame(width: diameter * 1.15, height: max(1, size * 0.055))
                    .rotationEffect(.degrees(Double(side) * 28 * e.brow))
                    .offset(x: side * diameter * 0.1, y: -diameter * 0.55 + (1 - e.brow) * diameter * 0.3)
                    .opacity(e.brow)
            }
    }

    // MARK: - Motion

    /// The mood's own tempo, in seconds each way. Nil is still.
    private func beat(_ m: BotMood?) -> Double? {
        switch m {
        case .thinking: return 1.4
        case .working: return 0.5
        case .asleep: return 2.2
        default: return nil
        }
    }

    private func restartMotion(_ m: BotMood?) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            phase = 0
            zzz = 0
        }
        guard !reduceMotion, let d = beat(m) else { return }
        withAnimation(.easeInOut(duration: d).repeatForever(autoreverses: true)) { phase = 1 }
        if m == .asleep {
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) { zzz = 1 }
        }
    }

    // MARK: - The poke

    private func poke() {
        pokes += 1
        startled = true
        pokeTask?.cancel()

        // The flinch: squash, then spring back up.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { squash = 1 }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.55)) {
            squash = 0
        }

        let angry = temper == .angry
        pokeTask = Task {
            if angry, !reduceMotion {
                for dx in [3.0, -3.0, 2.0, -2.0, 0.0] {
                    withAnimation(.linear(duration: 0.05)) { shake = dx * size / 36 }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            startled = false
            // It calms down on its own; a red one takes a little longer.
            try? await Task.sleep(for: .seconds(angry ? 6 : 3.5))
            guard !Task.isCancelled else { return }
            pokes = 0
        }
    }

    /// The per-bot expression, from a stable hash of the seed.
    private struct Look {
        let eye: CGFloat
        let eyeGap: CGFloat
        let smile: CGFloat

        init(seed: String) {
            // FNV-1a: cheap, stable across launches and platforms, unlike `hashValue`.
            var h: UInt32 = 2166136261
            for byte in seed.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
            let eyes: [CGFloat] = [0.13, 0.15, 0.17]
            let gaps: [CGFloat] = [0.16, 0.20, 0.24]
            let smiles: [CGFloat] = [0.26, 0.34, 0.42]
            eye = eyes[Int(h % 3)]
            eyeGap = gaps[Int((h >> 8) % 3)]
            smile = smiles[Int((h >> 16) % 3)]
        }
    }
}

/// The mouth, drawn in a rect: an arc between two points on the middle line, its
/// middle pulled down for a smile and up for a frown. `curve` runs −1…+1, `width`
/// scales the rect's width, and both animate.
private struct Mouth: Shape {
    var curve: CGFloat
    var width: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(curve, width) }
        set { curve = newValue.first; width = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let half = rect.width * width / 2
        // The arc's ends sit at the top for a smile and the bottom for a frown, so
        // the mouth stays centred on the same line as it changes.
        let y = rect.minY + (1 - max(0, curve)) * rect.height * 0.5 + max(0, -curve) * rect.height * 0.5
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - half, y: y))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX + half, y: y),
            control: CGPoint(x: rect.midX, y: y + curve * rect.height * 1.6)
        )
        return p
    }
}
