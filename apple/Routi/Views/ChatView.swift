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
    /// The AppKit scroll view under the transcript, for the two things SwiftUI will
    /// not tell us: whether the reader is scrolling, and how far from the end they are.
    @State private var scrollView: NSScrollView?
    /// Whether the transcript rides the end. The reader owns this: their own scrolling
    /// sets it, and the two moments that mean "show me the end" — opening a
    /// conversation and sending a message. Arriving content never gets a vote.
    @State private var isPinned = true
    /// True while AppKit owns the clip view, between the start and end of a live
    /// scroll. Nothing here moves the view while a hand is on it.
    @State private var isUserScrolling = false
    /// Where the current gesture began, so the whole drag is judged, not its last event.
    @State private var gestureStartOffset: CGFloat = 0
    #endif

    var body: some View {
        // Just the chat. The screen is a sibling column now, not a panel nested here.
        content
            .navigationTitle(bot.name)
            #if !os(macOS)
            // Inline, not large: a large title scrolls away with the first message and
            // then sits over the transcript. The name stays in the bar beside Back.
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingSettings) {
                BotSettingsSheet(bot: bot)
            }
            .onChange(of: model.selectedConversationID) { draft = "" }
    }

    @ViewBuilder
    private var content: some View {
        // A bot already at work — a greeting, a routine — gets the transcript even with
        // nothing in it yet, so the typing indicator has somewhere to be. Showing the
        // front door first and swapping it out a moment later read as a flicker.
        if model.messages.isEmpty && !model.isLoadingMessages && !model.isBusy {
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

    /**
     The transcript, and the whole of its scrolling.

     A plain stack, not a lazy one. The daemon caps a conversation at a hundred
     messages, so there is nothing here worth being lazy about — and laziness was the
     source of every scrolling bug this view has had: a lazy stack estimates the height
     of whatever is off screen, so a scroll to the end lands on an estimate, a view moved
     there by offset can sit over rows that were never laid out, and correcting either
     changes the estimate, which is a loop. With real heights, `scrollTo` simply lands.

     Two rules, then. The reader decides whether the view rides the end, by scrolling;
     and while it does, arriving content keeps the end in view. That is all.
     */
    private var transcript: some View {
        ScrollViewReader { proxy in
            // Measured so a transcript shorter than the view sits at its bottom, where a
            // chat's newest line belongs. Without this a new bot's first moments — an
            // empty row and the typing dots — were pinned to the top of an empty pane.
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            startsGroup: index == 0 || model.messages[index - 1].role != message.role
                        )
                        .id(message.id)
                    }
                    // A bot asking for the screen asks here, where the person is looking.
                    // The rail and the full-screen banner show it too, but the rail can be
                    // closed, and then the only sign was "Waiting for you" in the sidebar.
                    if let handover = model.handover(for: bot.id) {
                        HandoverCard(handover: handover).padding(.top, 12)
                    }
                    if model.isBusy {
                        VStack(alignment: .leading, spacing: 6) {
                            // A bot working on its own schedule says so, or it looks
                            // like a bot answering a question nobody asked.
                            if let name = model.runningRoutineName {
                                Text("Running routine · \(name)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            TypingIndicator()
                        }
                        .padding(.top, 10)
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
                .frame(minHeight: viewport.size.height, alignment: .bottom)
                #if os(macOS)
                .background { ScrollViewBridge { found in
                    // Keep the one on screen. A replacement is only wanted when ours
                    // has left the window, which is the case after the desktop swap.
                    if scrollView == nil || scrollView?.window == nil { scrollView = found }
                } }
                #endif
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(macOS)
            // The reader's own scrolling, which is the only thing that unpins the view.
            // These fire for a hand on the trackpad and never for a programmatic move,
            // and are identity-checked because the sidebar posts them too.
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
            #endif
            // Opening a conversation shows its end. Messages arrive after the selection
            // does, so the count change below is what actually lands it; this handles a
            // conversation that was already loaded.
            .task(id: model.selectedConversationID) {
                #if os(macOS)
                isUserScrolling = false
                isPinned = true
                #endif
                await showEnd(proxy)
            }
            .onAppear { Task { await showEnd(proxy) } }
            // Rows arriving: the conversation loading, a message, the typing indicator.
            .onChange(of: model.messages.count) { Task { await showEnd(proxy) } }
            .onChange(of: model.isBusy) { Task { await showEnd(proxy) } }
            // A reply grows inside a message that already exists, so nothing above
            // fires for it. Follow it while it streams — for a reader at the end.
            .task(id: "\(model.selectedConversationID ?? "")-\(model.isBusy)") {
                while model.isBusy && !Task.isCancelled {
                    followEnd(proxy)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
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

    /// Provider · Model · Effort, under the composer on the right — and the place to
    /// change the last two, the way /model does mid-conversation. The provider is the
    /// bot's for life; the model and effort are a menu on the statement itself, so
    /// switching is one click from where the answer is about to appear.
    private var configLine: some View {
        let models = model.models(for: bot.provider)
        let current = models.first { $0.id == bot.model }
        let efforts = (current?.effortLevels ?? []).compactMap(Effort.init(rawValue:))
        // The level in force gets the mark: the one chosen, or failing that the
        // provider's default — an unmarked list read as "none of these", which is never
        // true of a bot that is answering.
        let effective = bot.effort ?? current?.defaultEffort
        return HStack {
            Spacer()
            Menu {
                Section("Model") {
                    ForEach(models) { info in
                        Button {
                            Task { await model.updateBot(bot.id, patch: ["model": info.id]) }
                        } label: {
                            let title = info.presentedName(in: models)
                            if info.id == bot.model {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
                if !efforts.isEmpty {
                    Section("Effort") {
                        ForEach(efforts) { effort in
                            Button {
                                Task { await model.updateBot(bot.id, patch: ["effort": effort.rawValue]) }
                            } label: {
                                let title = effort.rawValue == current?.defaultEffort ? "\(effort.label) (default)" : effort.label
                                if effort.rawValue == effective {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(BotConfig(bot: bot, models: models).summary)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(models.isEmpty)
            .task { await model.loadModels(for: bot.provider) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private static let tailAnchor = "routi.tail"
    /// How far from the end still counts as being at the end: a little over a line, so
    /// a flick that stops just short does not read as walking away.
    private static let pinSlack: CGFloat = 40

    /**
     Shows the end of the transcript, for a reader who wants it.

     Three passes, because the rows that just arrived get their heights over the next
     frame or two and a screenshot can take longer still. Each pass is a plain `scrollTo`
     — exact on a non-lazy stack — and each is skipped the moment the reader has taken
     the view or scrolled away, so this never argues with a hand on the trackpad.
     */
    private func showEnd(_ proxy: ScrollViewProxy) async {
        for delay in [0, 50, 250] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, wantsEnd else { return }
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        }
    }

    /// One tick of following a streaming reply.
    private func followEnd(_ proxy: ScrollViewProxy) {
        guard wantsEnd else { return }
        #if os(macOS)
        // By offset, not by `scrollTo`: five times a second, a layout pass over the
        // thread would be felt, and an offset costs nothing.
        if let scroll = scrollView {
            let target = endOffset(of: scroll)
            guard abs(scroll.contentView.bounds.origin.y - target) > 0.5 else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        #endif
        proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
    }

    /// Whether the view should be at the end right now.
    private var wantsEnd: Bool {
        #if os(macOS)
        return isPinned && !isUserScrolling
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// The offset at which the transcript is at its very end. The composer is a bottom
    /// safe-area inset, which AppKit applies as `contentInsets` — shortening the clip
    /// view and lengthening the scrollable range — so it has to be counted.
    private func endOffset(of scroll: NSScrollView) -> CGFloat {
        let visible = scroll.contentView.bounds
        let height = scroll.documentView?.frame.height ?? visible.height
        return max(0, height - visible.height + scroll.contentInsets.bottom)
    }

    /// Whether the reader's gesture left them at the end. Dragging upwards means not,
    /// whatever the arithmetic says: you cannot reach the end by moving away from it.
    private var readerIsAtEnd: Bool {
        guard let scroll = scrollView else { return true }
        let offset = scroll.contentView.bounds.origin.y
        if offset - gestureStartOffset < -8 { return false }
        return endOffset(of: scroll) - offset <= Self.pinSlack
    }
    #endif

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        // macOS 26 wraps every toolbar item in its own capsule, which makes the bot's
        // name read as a button and groups the two icons into one pill.
        // `sharedBackgroundVisibility(.hidden)` drops that chrome so the header sits
        // flat on the window; the buttons draw their own hover state instead.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                BotAvatar(color: bot.color, seed: bot.id, size: 20)
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
        // The bot in the bar: its face and its name, where a chat app keeps them.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                BotAvatar(color: bot.color, seed: bot.id, size: 24)
                Text(bot.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Bot Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // A phone has no room for a side column: the screen takes the whole
            // display. An iPad has the room, and keeps the rail beside the chat.
            Button("Screen", systemImage: "desktopcomputer") {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    model.isShowingScreen = true
                } else {
                    showBotSidebar.toggle()
                }
            }
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
        if let resolved = info?.resolvedModel {
            // A provider that names its models (Codex: "GPT-6-Astra") is believed over
            // the prettifier, which was written for Claude ids and makes "Gpt 6.astra"
            // of anything else. Claude's own list resolves to ids, so those still go
            // through it.
            if !resolved.hasPrefix("claude"), let named = models.first(where: { $0.id == resolved }) {
                return named.displayName
            }
            return ModelName.pretty(resolved)
        }
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

    /**
     Captures once, after the view is in a window.

     This used to report on every SwiftUI update as well, and wrote state whenever the
     scroll view it saw differed from the one held. Coming back from the full-window
     desktop rebuilds the chat with an animated swap, during which two copies of it are
     alive with two scroll views — so each update found the other one, each write
     re-ran the body, and the swap animation restarted every frame, for as long as the
     app was left open. A transcript's scroll view does not change under it; asking once
     is enough, and a second answer is never a better one.
     */
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { report(from: view, attempt: 0) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private func report(from view: NSView, attempt: Int) {
        if let scroll = view.enclosingScrollView, scroll.window != nil {
            onFound(scroll)
        } else if attempt < 5 {
            // Not in the hierarchy yet; a few frames later it will be.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { report(from: view, attempt: attempt + 1) }
        }
    }
}
#endif

