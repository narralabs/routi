import SwiftUI

/// One layout for all three devices.
///
/// Three columns, in the order they read on screen:
///
/// - **left main sidebar** — the bot list
/// - **main content** — the conversation
/// - **bot right sidebar** — that bot's screen and routines, hidden until asked for
///
/// The first two are a `NavigationSplitView`; the third is an `.inspector`. That is
/// not an arbitrary split. A three-column `NavigationSplitView` cannot hide its
/// trailing column — `columnVisibility` only ever reaches the leading ones — whereas
/// hiding and showing is exactly what an inspector is for, and it still renders as a
/// real resizable column rather than an overlay.
///
/// `NavigationSplitView` does the adapting itself: columns on the Mac, a sidebar over
/// content on iPad, and a push-navigation stack on iPhone. That is the whole reason to
/// be native here — the responsive behaviour is the framework's job, not something
/// reconstructed with width breakpoints.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingRailSettings = false
    @State private var showingNewBot = false

    /// The bot right sidebar starts closed: most conversations never need the screen,
    /// and opening onto three columns makes the chat itself feel cramped.
    @State private var showBotSidebar = false

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.authKnown {
                // Neither onboarding nor chat is correct until the handshake lands.
                ConnectingView()
            } else if model.needsOnboarding {
                OnboardingView()
            } else if model.isShowingScreen {
                ScreenWindow()
            } else {
                main
            }
        }
        .animation(.snappy(duration: 0.3), value: model.needsOnboarding)
        .animation(.snappy(duration: 0.3), value: model.authKnown)
        .animation(.snappy(duration: 0.25), value: model.isShowingScreen)
        .task { model.start() }
    }

    private var main: some View {
        @Bindable var model = model

        return NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisibility },
            // Governs the *left main sidebar* only. Refusing `.detailOnly` keeps the
            // bot list present — a divider dragged past it used to shut it for good.
            set: { model.sidebarVisibility = $0 == .detailOnly ? .doubleColumn : $0 }
        )) {
            BotListView(showingNewBot: $showingNewBot)
                // A firm stop rather than a shrinking rail. The divider refuses to go
                // below a width the sidebar is still readable at.
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 360)
        } detail: {
            if let bot = model.selectedBot {
                ChatView(bot: bot, showBotSidebar: $showBotSidebar)
                    .inspector(isPresented: Binding(
                        get: { showBotSidebar },
                        // Opening only ever happens through the toolbar button, which
                        // writes the state directly. AppKit also writes through here
                        // when it restores the window's saved split-view state, which
                        // would reopen the panel at launch after any session that left
                        // it open — so an uninvited `true` is dropped and the panel
                        // keeps its promise to start closed.
                        set: { if !$0 { showBotSidebar = false } }
                    )) {
                        DetailRail(bot: bot, showingSettings: $showingRailSettings)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                    }
            } else {
                ContentUnavailableView(
                    "No Bot Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a bot from the sidebar, or create one.")
                )
            }
        }
        .sheet(isPresented: $showingNewBot) {
            NewBotSheet()
        }
        .sheet(isPresented: Binding(
            get: { model.isShowingSettings },
            set: { model.isShowingSettings = $0 }
        )) {
            SettingsScreen()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }
}

/// Shown for the moment between launch and the first handshake.
private struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    @State private var slow = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Connecting to Krog…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if slow {
                Text("Taking longer than usual. Is krogd running?")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .task {
            try? await Task.sleep(for: .seconds(4))
            slow = true
        }
    }
}
