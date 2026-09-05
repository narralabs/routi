import SwiftUI

/// The bot right sidebar: this bot's live screen, and its routines.
struct DetailRail: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showingSettings: Bool
    @State private var isHoveringScreen = false
    @State private var frameViewer = UUID()

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
        .onAppear { model.beginFrames(frameViewer) }
        .onDisappear { model.endFrames(frameViewer) }
        // A bot with a screen has one running, always. The daemon starts the container
        // when the bot is created; this covers every other way the panel can arrive at
        // a bot whose desktop is not up — an older bot, a restarted Docker, a daemon
        // that came back. `startSurface` is a no-op when one is already running.
        .task(id: bot.id) {
            await model.refreshSurface()
            await model.startSurface()
        }
        /**
         * Brings a screen back if it goes away while you are watching.
         *
         * A screen can stop without the panel moving: the machine is rebuilt, Docker
         * restarts, the container is replaced. Starting only on appear meant the panel
         * then sat on "stopped" indefinitely, since nothing was going to ask again.
         */
        .onChange(of: model.surface.state) { _, state in
            guard state == .stopped else { return }
            Task { await model.startSurface() }
        }
    }

    @ViewBuilder
    private var surfacePanel: some View {
        VStack(spacing: 8) {
            switch model.surface.state {
            case .running:
                ScreenView(
                    frame: model.surfaceFrame,
                    size: CGSize(width: model.surface.width, height: model.surface.height),
                    pointer: model.surfacePointer
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

            // Stopped and starting read the same to the eye, because a stopped desktop
            // is only ever on its way back: nothing here can leave one switched off, so
            // offering a Start button would be offering to do what is already happening.
            case .starting, .stopped:
                placeholder(icon: "display", title: "Starting the desktop…") {
                    ProgressView().controlSize(.small)
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

    /// Stands in for the screen at the screen's own shape.
    ///
    /// The ratio comes from the desktop rather than a constant, so the placeholder
    /// occupies exactly the space the picture will when it arrives and nothing below
    /// it shifts. It is a ZStack because `aspectRatio` has to act on the flexible
    /// background — applied to the text stack it inherits that stack's intrinsic
    /// height, which is where the near-square box came from.
    private func placeholder<Content: View>(
        icon: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)

            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tertiary)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                content()
            }
            .padding(18)
        }
        .aspectRatio(model.surface.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
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
