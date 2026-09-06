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
    #if os(macOS)
    /// The AppKit scroll view under the transcript. SwiftUI will not say how tall a lazy
    /// stack is or where the reader is inside it; this does, exactly.
    @State private var scrollView: NSScrollView?
    /// Whether the transcript is riding the end.
    ///
    /// The reader owns this. It is set by their own scrolling, and by the two moments
    /// that mean "show me the end": opening a conversation, and sending a message.
    /// Nothing else may set it — that was the bug in every earlier version, where
    /// arriving content decided where the reader should be looking.
    @State private var isPinned = true
    /// True while AppKit owns the clip view, between the start and end of a live scroll.
    /// Moving it underneath a hand on the trackpad is what "it kept pushing me up" was.
    @State private var isUserScrolling = false
    /// Where the reader's current gesture began, so the whole drag can be judged rather
    /// than the last few points of it.
    @State private var gestureStartOffset: CGFloat = 0
    #endif

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
                #if os(macOS)
                // In the content's background, because that is inside the scroll view —
                // and unlike a preference, a captured reference does reach out of one.
                .background { ScrollViewBridge { found in
                    if scrollView !== found { scrollView = found }
                } }
                #endif
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(macOS)
            /**
             * The reader's own scrolling, which is the only thing that unpins the view.
             *
             * `didLiveScroll` fires for a hand on the trackpad and never for a
             * programmatic move, so this cannot mistake the app's own scrolling for the
             * reader's. Identity-checked against our scroll view, because the sidebar
             * posts these too.
             */
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { note in
                guard let scroll = note.object as? NSScrollView, scroll === scrollView else { return }
                isUserScrolling = true
                gestureStartOffset = scroll.contentView.bounds.origin.y
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didLiveScrollNotification)) { note in
                guard (note.object as? NSScrollView) === scrollView else { return }
                isPinned = readerIsAtEnd
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { note in
                guard (note.object as? NSScrollView) === scrollView else { return }
                isUserScrolling = false
                isPinned = readerIsAtEnd
            }
            /// Follows a reply as it streams, but only for a reader who is at the end.
            /// A reply grows inside a message that already exists, so no count changes
            /// and nothing else here would fire.
            .task(id: "\(model.selectedConversationID ?? "")-\(model.isBusy)") {
                while model.isBusy && !Task.isCancelled {
                    if isPinned { pinToEnd() }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            /// A new row, or the typing indicator appearing and going, both change the
            /// height under the reader. Settle rather than pin once: the row is not laid
            /// out at the moment the count changes.
            .onChange(of: model.messages.count) { Task { await settleAtEnd() } }
            .onChange(of: model.isBusy) { Task { await settleAtEnd() } }
            /**
             * Opening a conversation lands at the end, and stays there.
             *
             * Messages arrive after the selection changes and a lazy stack gives its rows
             * their real heights over several frames, so a single scroll — or four, which
             * is what this used to do — lands halfway down and then drifts as the rows
             * above it grow. Holding the offset at the end until the height stops moving
             * is the only version of this that survives both.
             */
            .task(id: model.selectedConversationID) {
                isPinned = true
                await settleAtEnd()
            }
            .onAppear {
                isPinned = true
                Task { await settleAtEnd() }
            }
            #else
            // iOS has no scroll view to ask, so it keeps the simpler behaviour: the end
            // is where a transcript belongs, and a phone rarely reads back mid-reply.
            .onChange(of: model.messages.count) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.isBusy) { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
            .task(id: model.selectedConversationID) { await settleThenScroll(proxy) }
            .onAppear { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
            #endif
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
    /// How far from the end still counts as being at the end. A little over one line, so
    /// a flick that stops just short does not read as walking away.
    private static let pinSlack: CGFloat = 40

    #if os(macOS)
    /**
     How far the end of the transcript is below what the reader can see.

     Only trustworthy near the end, and that is not a nitpick: a lazy stack *estimates*
     the height of everything off screen, so once the reader scrolls away the document
     height stops tracking the reply — measured at 1086pt, then 979pt, then unchanged
     while text kept arriving. Near the end the rows in question are laid out and the
     number is real, which is the only place this is asked.
     */
    private var distanceFromEnd: CGFloat {
        guard let scroll = scrollView else { return 0 }
        return max(0, endOffset(of: scroll) - scroll.contentView.bounds.origin.y)
    }

    /**
     The offset at which the transcript is truly at its end.

     The composer is a bottom safe-area inset, which AppKit applies to the scroll view as
     `contentInsets` — it shortens the clip view *and* lengthens the scrollable range, so
     leaving it out of this stops short by twice the inset. Measured with an 80pt inset:
     160pt of transcript still below the fold, on a view that reported itself as being at
     the end.
     */
    private func endOffset(of scroll: NSScrollView) -> CGFloat {
        let visible = scroll.contentView.bounds
        let height = scroll.documentView?.frame.height ?? visible.height
        return max(0, height - visible.height + scroll.contentInsets.bottom)
    }

    /**
     Whether the reader's own gesture left them at the end.

     Two conditions, because the measurement alone can lie in the dangerous direction —
     an under-reported height reads as "at the end" and would drag someone back down.
     Dragging upwards means not at the end whatever the arithmetic says; you cannot
     arrive at the end by moving away from it. Judged across the whole gesture rather
     than the last few points, so a slow drag does not creep past a per-event threshold.
     */
    private var readerIsAtEnd: Bool {
        guard let scroll = scrollView else { return true }
        let travelled = scroll.contentView.bounds.origin.y - gestureStartOffset
        if travelled < -8 { return false }
        return distanceFromEnd <= Self.pinSlack
    }

    /**
     Puts the view at the end, by offset rather than by anchor.

     `scrollTo(id)` cannot do this reliably: the anchor sits at the end of a lazy stack,
     so it usually is not laid out, and the rows above it take their real heights a frame
     or two later. That is exactly how opening a conversation landed in the middle and
     then drifted upwards. An offset is arithmetic, not a guess.
     */
    private func pinToEnd() {
        guard !isUserScrolling, let scroll = scrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: endOffset(of: scroll)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Holds the end in view while the transcript is still arriving and laying out.
    /// Gives up the moment the reader scrolls away, and as soon as the height is stable.
    private func settleAtEnd() async {
        var lastHeight: CGFloat = -1
        var stable = 0
        for _ in 0..<40 {
            guard isPinned, !Task.isCancelled else { return }
            pinToEnd()
            let height = scrollView?.documentView?.frame.height ?? 0
            stable = abs(height - lastHeight) < 0.5 ? stable + 1 : 0
            lastHeight = height
            if stable >= 4 && height > 0 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    #endif

    /// Waits for a conversation's messages to arrive, then goes to the end.
    private func settleThenScroll(_ proxy: ScrollViewProxy) async {
        proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
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
        #if os(macOS)
        // Sending means "show me the answer", whatever was being read a moment ago.
        isPinned = true
        #endif
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
        // A model that reads differently as a statement than as a menu item says so.
        if let status = info?.statusName, !status.isEmpty { return status }
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


#if os(macOS)
/// Hands back the AppKit scroll view SwiftUI drew, since SwiftUI will not say.
private struct ScrollViewBridge: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // After the view is in the hierarchy, or there is no scroll view to find yet.
        DispatchQueue.main.async { if let scroll = view.enclosingScrollView { onFound(scroll) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let scroll = view.enclosingScrollView { onFound(scroll) } }
    }
}
#endif

