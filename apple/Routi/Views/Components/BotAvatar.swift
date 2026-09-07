import SwiftUI

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
struct BotAvatar: View {
    let color: Color
    /// Something stable per bot — its id — so the face is the same every time.
    var seed: String = ""
    var size: CGFloat = 34
    var isBusy: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A blink is the eyes closing for a beat. Driven by a per-avatar timer at a
    /// random interval, so a sidebar of bots never blinks in unison.
    @State private var blinking = false
    /// While the bot works, the eyes glance from side to side.
    @State private var glance: CGFloat = 0

    /// The cream of the mark's letterform; pure white reads as a sticker.
    private static let cream = Color(red: 0.97, green: 0.96, blue: 0.93)

    private var look: Look { Look(seed: seed) }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
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
            .overlay(alignment: .bottomTrailing) {
                if isBusy {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(.background, lineWidth: size * 0.055))
                        .offset(x: size * 0.04, y: size * 0.04)
                }
            }
    }

    private var face: some View {
        let s = size
        let look = look
        return ZStack {
            // Eyes: two dots, set a little low — the mark's, not a pair of bars.
            HStack(spacing: s * look.eyeGap) {
                Circle().fill(Self.cream).frame(width: s * look.eye, height: s * look.eye)
                Circle().fill(Self.cream).frame(width: s * look.eye, height: s * look.eye)
            }
            // A blink squashes the eyes to a line; a glance slides them a little.
            .scaleEffect(x: 1, y: blinking ? 0.12 : 1, anchor: .center)
            .offset(x: glance * s * 0.05, y: -s * 0.08)
            .task(id: reduceMotion) {
                // Cheap: one sleeping task per avatar, awake for 140ms every few
                // seconds. Nothing runs between blinks.
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 3...9)))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.07)) { blinking = true }
                    try? await Task.sleep(for: .milliseconds(140))
                    withAnimation(.easeOut(duration: 0.09)) { blinking = false }
                }
            }
            .onChange(of: isBusy, initial: true) { _, busy in
                if busy && !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glance = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { glance = 0 }
                }
            }

            // The smile: a shallow arc, its width the bot's own.
            Smile()
                .stroke(Self.cream, style: StrokeStyle(lineWidth: max(1, s * 0.075), lineCap: .round))
                .frame(width: s * look.smile, height: s * 0.12)
                .offset(y: s * 0.17)
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

/// A shallow upturned arc, drawn in a rect: the ends at the top corners, the middle
/// dipping to the bottom.
private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.6)
        )
        return p
    }
}
