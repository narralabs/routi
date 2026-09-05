import SwiftUI

/// Right-hand rail: the bot's screen and its routines.
///
/// The surface panel is a placeholder until M3 lands the WebRTC pipeline; it exists
/// now so the three-column proportions are real rather than guessed at later.
struct DetailRail: View {
    let bot: Bot
    @Binding var showingSettings: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                surfacePanel
                routinesPanel
            }
            .padding(16)
        }
        .background(.background.secondary)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 0.5).ignoresSafeArea()
        }
    }

    private var surfacePanel: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: bot.surfaceMode == .none ? "display.trianglebadge.exclamationmark" : "display")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(bot.surfaceMode == .none ? "No surface" : "Waiting for stream")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 0.5)
                }

            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var caption: String {
        switch bot.surfaceMode {
        case .container: return "\(bot.name)'s container"
        case .host: return "\(bot.name) on this Mac"
        case .none: return "This bot has no screen"
        }
    }

    private var routinesPanel: some View {
        VStack(spacing: 14) {
            Text("Routines are recurring tasks this Bot runs on a schedule.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Routine") {}
                .buttonStyle(.bordered)
        }
    }
}
