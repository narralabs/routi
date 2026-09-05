import SwiftUI

/// A bot asking you to take the screen.
///
/// Deliberately loud. The bot is paused mid-turn while this sits unanswered, so the
/// cost of missing it is a bot that does nothing until it times out — unlike every
/// other card in the transcript, which reports something already finished.
struct HandoverCard: View {
    @Environment(AppModel.self) private var model
    let handover: Handover

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                Text("Needs you")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)

            Text(handover.reason)
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Take over") { model.isShowingScreen = true }
                    .buttonStyle(.borderedProminent)
                Button("I'm done") {
                    Task { await model.resolveHandover(handover.botId, outcome: "done") }
                }
                Button("Skip") {
                    Task { await model.resolveHandover(handover.botId, outcome: "skipped") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.orange.opacity(0.35), lineWidth: 0.5)
        }
    }
}

/// The same ask, across the top of the desktop you were handed.
///
/// Shown where the work happens: someone who has clicked "Take over" is looking at a
/// browser, not at the transcript, and needs the way back from there.
struct HandoverBanner: View {
    @Environment(AppModel.self) private var model
    let handover: Handover

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(handover.reason)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Button("Skip this step") {
                Task { await model.resolveHandover(handover.botId, outcome: "skipped") }
            }
            Button("I'm done, continue") {
                Task { await model.resolveHandover(handover.botId, outcome: "done") }
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.14))
    }
}
