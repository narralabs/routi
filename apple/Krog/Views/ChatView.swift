import SwiftUI

/// The centre pane.
///
/// One surface, no dividers. An empty thread centres a greeting with the composer
/// directly beneath it; once messages exist the same composer floats at the bottom
/// over the scrolling transcript.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showBotSidebar: Bool

    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        // Just the chat. The screen is a sibling column now, not a panel nested here.
        content
            .navigationTitle(bot.name)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingSettings) {
                BotSettingsSheet(bot: bot)
            }
            .onChange(of: model.selectedConversationID) { draft = "" }
    }

    @ViewBuilder
    private var content: some View {
        if model.messages.isEmpty && !model.isLoadingMessages {
            emptyThread
        } else {
            transcript
        }
    }

    /// Greeting plus composer, vertically centred — the app's front door.
    private var emptyThread: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: 10) {
                Text("Where should we begin?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)

                if !bot.systemPrompt.isEmpty {
                    Text(bot.systemPrompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            VStack(spacing: 0) {
                composer
                configLine
            }
            .frame(maxWidth: 680)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            startsGroup: index == 0 || model.messages[index - 1].role != message.role
                        )
                        .id(message.id)
                    }
                    if model.isBusy {
                        TypingIndicator().padding(.top, 10)
                    }
                    if let failure = model.selectedError {
                        TurnErrorRow(message: failure) { model.dismissSelectedError() }
                            .padding(.top, 10)
                    }
                    // Clearance so the floating composer never covers the last message.
                    Color.clear.frame(height: 96).id(Self.tailAnchor)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messageSignature) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.selectedConversationID) {
                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                composer
                configLine
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    private var composer: some View {
        Composer(
            botName: bot.name,
            text: $draft,
            isBusy: model.isBusy,
            focused: $composerFocused,
            onSend: send,
            onInterrupt: { Task { await model.interrupt() } }
        )
    }

    /// Provider · Model · Effort, under the composer on the right.
    ///
    /// All three are fixed when the bot is created, so this is a standing statement of
    /// what the bot runs on rather than a control — which is why it sits below the bar
    /// as a caption instead of inside it as a picker.
    private var configLine: some View {
        Text(BotConfig(bot: bot, models: model.models(for: bot.provider)).summary)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.top, 6)
    }

    private static let tailAnchor = "krog.tail"

    /// Cheap change token: message count plus streamed text length.
    private var messageSignature: Int {
        model.messages.reduce(model.messages.count) { total, message in
            total + message.blocks.reduce(0) { sum, block in
                if case .text(let t) = block { return sum + t.count }
                if case .thinking(let t) = block { return sum + t.count }
                return sum + 1
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        // macOS 26 wraps every toolbar item in its own capsule, which makes the bot's
        // name read as a button and groups the two icons into one pill.
        // `sharedBackgroundVisibility(.hidden)` drops that chrome so the header sits
        // flat on the window; the buttons draw their own hover state instead.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                BotAvatar(color: bot.color, size: 20)
                Text(bot.name).font(.system(size: 13, weight: .semibold))
            }
        }
        .flatBackground()

        // Bot settings stays beside the name it belongs to.
        ToolbarItem(placement: .navigation) {
            ToolbarIcon(systemName: "slider.horizontal.3", help: "Bot Settings") {
                showingSettings = true
            }
        }
        .flatBackground()

        flexibleToolbarSpacer()

        // Opens and closes the bot right sidebar from one fixed slot at the trailing
        // edge, swapping the screen for a close mark. The panel opens directly beneath
        // it, so the button that dismissed it is where the pointer already is — no
        // separate control inside the panel to go hunting for.
        ToolbarItem(placement: .primaryAction) {
            ToolbarIcon(
                systemName: showBotSidebar ? "xmark" : "desktopcomputer",
                help: showBotSidebar ? "Hide Screen" : "Show Screen"
            ) {
                showBotSidebar.toggle()
            }
        }
        .flatBackground()
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button("Bot Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Screen", systemImage: "desktopcomputer") { showBotSidebar.toggle() }
        }
        #endif
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = true
        Task { await model.send(text) }
    }
}

/// Flat toolbar icon: no chrome at rest, a soft fill on hover, tinted when active.
private struct ToolbarIcon: View {
    let systemName: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(
                    isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Shown where the reply would have been, so a failed turn is visible in context.
private struct TurnErrorRow: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Renders a bot's fixed configuration as "Anthropic · Opus · High".
struct BotConfig {
    let bot: Bot
    let models: [ModelInfo]

    /// What the bot actually runs, not the alias that selects it.
    ///
    /// `default` is the CLI's own alias and resolves server-side — today to
    /// `claude-opus-5[1m]`, tomorrow to whatever Anthropic points it at. Printing
    /// "Default" would tell the reader nothing about the model in use, so the resolved
    /// id is shown instead whenever the provider reports one.
    ///
    /// `models` must be the bot's *own* provider's list. Ids are not unique across
    /// providers — every provider has a `default` — so looking one up in the wrong
    /// list silently resolves to the wrong vendor's model. That is how an OpenAI bot
    /// came to describe itself as running Opus.
    var modelName: String {
        let info = models.first { $0.id == bot.model }
        if let resolved = info?.resolvedModel { return ModelName.pretty(resolved) }
        let full = info?.displayName ?? bot.model
        return full.split(separator: "(").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? full
    }

    private var info: ModelInfo? { models.first { $0.id == bot.model } }

    /// The effort actually in force, or nil when nobody will say what it is.
    ///
    /// A bot that names no effort used to print "High" regardless of provider — true
    /// of Anthropic, invented for everyone else. The provider now states its own
    /// default, and where it declines to (Codex picks per plan and reports nothing),
    /// this stays nil rather than fabricating a level.
    private var effortLabel: String? {
        guard let info, !info.effortLevels.isEmpty else { return nil }
        if let chosen = bot.effort, !chosen.isEmpty { return Effort.parse(chosen).label }
        guard let implied = info.defaultEffort else { return nil }
        return "\(Effort.parse(implied).label) by default"
    }

    var summary: String {
        var parts = [ProviderInfo.find(bot.provider).name, modelName]
        if let effortLabel { parts.append(effortLabel) }
        return parts.joined(separator: " · ")
    }
}
