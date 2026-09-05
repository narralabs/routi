import SwiftUI

/// Right-hand rail: the bot's live screen, and its routines.
struct DetailRail: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showingSettings: Bool
    @State private var isHoveringScreen = false

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
        // Only pull frames while the rail is actually on screen.
        .onAppear { model.startFrames() }
        .onDisappear { model.stopFrames() }
    }

    @ViewBuilder
    private var surfacePanel: some View {
        VStack(spacing: 8) {
            switch model.surface.state {
            case .running:
                ScreenView(
                    frame: model.surfaceFrame,
                    size: CGSize(width: model.surface.width, height: model.surface.height)
                )
                .aspectRatio(model.surface.aspectRatio, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 0.5)
                }
                // The preview is small and non-interactive, so hovering offers the
                // one action worth having here rather than trying to make a
                // thumbnail clickable.
                .overlay {
                    if isHoveringScreen {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.black.opacity(0.35))
                            Button("Open") { model.isShowingScreen = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                        }
                        .transition(.opacity)
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHoveringScreen = hovering }
                }

                Text("\(bot.name)'s screen")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button("Stop Desktop") { Task { await model.stopSurface() } }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

            case .starting:
                placeholder(icon: "hourglass", title: "Starting the desktop…") {
                    ProgressView().controlSize(.small)
                }

            case .stopped:
                placeholder(icon: "display", title: "No desktop running") {
                    Button("Start Desktop") { Task { await model.startSurface() } }
                        .controlSize(.small)
                }

            case .unavailable:
                placeholder(icon: "display.trianglebadge.exclamationmark", title: "Desktop unavailable") {
                    if let detail = model.surface.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func placeholder<Content: View>(
        icon: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .background(.background, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
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
