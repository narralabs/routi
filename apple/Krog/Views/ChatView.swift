import SwiftUI

/// The centre pane.
///
/// One surface, no dividers. An empty thread centres a greeting with the composer
/// directly beneath it; once messages exist the same composer floats at the bottom
/// over the scrolling transcript.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showRail: Bool

    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            content
            #if os(macOS)
            if showRail {
                DetailRail(bot: bot, showingSettings: $showingSettings)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
            #endif
        }
        .animation(.snappy(duration: 0.22), value: showRail)
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

            composer
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
            composer
                .frame(maxWidth: 680)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
    }

    private var composer: some View {
        Composer(
            botName: bot.name,
            text: $draft,
            isBusy: model.isBusy,
            focused: $composerFocused,
            onSend: send,
            onInterrupt: { Task { await model.interrupt() } },
            trailingLabel: AnyView(ModelLabel(bot: bot))
        )
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

        ToolbarItem(placement: .primaryAction) {
            ToolbarIcon(systemName: "slider.horizontal.3", help: "Bot Settings") {
                showingSettings = true
            }
        }
        .flatBackground()

        ToolbarItem(placement: .primaryAction) {
            ToolbarIcon(
                systemName: "desktopcomputer",
                help: showRail ? "Hide Screen" : "Show Screen",
                isActive: showRail
            ) {
                showRail.toggle()
            }
        }
        .flatBackground()
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button("Bot Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
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

/// The bot's model, shown but not editable.
///
/// Provider and model are chosen once when the bot is created and fixed for its
/// lifetime, so this is a label rather than a picker — switching mid-thread would
/// reinterpret an existing conversation under different capabilities.
private struct ModelLabel: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    private var label: String {
        let full = model.models.first { $0.id == bot.model }?.displayName ?? bot.model
        // Trim the parenthetical the CLI adds ("Default (recommended)").
        return full.split(separator: "(").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? full
    }

    var body: some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize()
            .help("\(bot.provider.capitalized) · \(label). Fixed when this bot was created.")
    }
}
