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
            trailingLabel: AnyView(InlineModelPicker(bot: bot))
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
        // Avatar + name at the leading edge, matching the reference header.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                BotAvatar(color: bot.color, size: 20)
                Text(bot.name).font(.system(size: 13, weight: .semibold))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Bot Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Screen", systemImage: "desktopcomputer") { showRail.toggle() }
                .symbolVariant(showRail ? .fill : .none)
        }
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

/// Model name as plain text inside the composer pill, the way ChatGPT shows it.
private struct InlineModelPicker: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    private var label: String {
        let full = model.models.first { $0.id == bot.model }?.displayName ?? bot.model
        // Trim the parenthetical the CLI adds ("Default (recommended)").
        return full.split(separator: "(").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? full
    }

    var body: some View {
        Menu {
            ForEach(model.models) { info in
                Button {
                    Task { await model.updateBot(bot.id, patch: ["model": info.id]) }
                } label: {
                    if info.id == bot.model {
                        Label(info.displayName, systemImage: "checkmark")
                    } else {
                        Text(info.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.models.isEmpty)
    }
}
