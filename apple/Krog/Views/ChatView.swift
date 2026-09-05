import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showRail: Bool

    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            transcript
            #if os(macOS)
            if showRail {
                Divider()
                DetailRail(bot: bot, showingSettings: $showingSettings)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
            #endif
        }
        .animation(.snappy(duration: 0.22), value: showRail)
        .navigationTitle(bot.name)
        #if os(macOS)
        .navigationSubtitle(model.isBusy ? "Typing…" : "")
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            BotSettingsSheet(bot: bot)
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
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
                            TypingIndicator()
                                .padding(.top, 10)
                                .id(Self.tailAnchor)
                        }
                        Color.clear.frame(height: 1).id(Self.tailAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                // Follow the tail as tokens arrive. `messageSignature` changes on every
                // delta, so this fires during streaming, not just on new messages.
                .onChange(of: messageSignature) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: model.selectedConversationID) {
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
            .overlay {
                if model.messages.isEmpty && !model.isLoadingMessages {
                    EmptyThread(bot: bot)
                }
            }

            Composer(
                botName: bot.name,
                text: $draft,
                isBusy: model.isBusy,
                focused: $composerFocused,
                onSend: send,
                onInterrupt: { Task { await model.interrupt() } }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private static let tailAnchor = "krog.tail"

    /// Cheap change token: message count plus total streamed text length.
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
        ToolbarItem(placement: .primaryAction) {
            ModelPicker(bot: bot)
        }
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button("Bot Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Screen", systemImage: showRail ? "sidebar.right" : "sidebar.right") {
                showRail.toggle()
            }
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

private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        Picker("Model", selection: Binding(
            get: { bot.model },
            set: { newValue in
                Task { await model.updateBot(bot.id, patch: ["model": newValue]) }
            }
        )) {
            ForEach(model.models) { info in
                Text(info.displayName).tag(info.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(model.models.isEmpty)
    }
}

private struct EmptyThread: View {
    let bot: Bot

    var body: some View {
        VStack(spacing: 12) {
            BotAvatar(color: bot.color, size: 56, isBusy: false)
            Text(bot.name)
                .font(.system(size: 16, weight: .semibold))
            Text(bot.systemPrompt.isEmpty ? "Send a message to get started." : bot.systemPrompt)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding()
    }
}
