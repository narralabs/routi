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
            if model.isSettling {
                // A first launch, for the few hundred milliseconds it takes the port
                // to answer or refuse. Nothing yet beats a screen that is replaced.
                Color.clear
            } else if model.needsOnboarding {
                // Setup comes first on a fresh install — before any connection, since
                // finding or installing a core is what setup is for.
                OnboardingView()
            } else if !model.authKnown {
                // Neither chat nor an error is correct until the handshake lands.
                ConnectingView()
            } else if model.isShowingScreen {
                ScreenWindow()
            } else {
                main
            }
        }
        .animation(.snappy(duration: 0.3), value: model.needsOnboarding)
        .animation(.snappy(duration: 0.3), value: model.authKnown)
        .animation(.snappy(duration: 0.3), value: model.isSettling)
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
                // Down to a rail: below about 170pt the list drops its text and shows
                // avatars only, so a narrow window keeps every bot reachable.
                .navigationSplitViewColumnWidth(min: 76, ideal: 268, max: 360)
        } detail: {
            detail
        }
        // The bot right sidebar hangs off the split view, not the chat inside it. Inside
        // the detail column it hosted its own split view, whose content pane carried an
        // implicit minimum near 330pt on top of the chat's — the window could not go
        // below ~900pt however narrow the chat was willing to be. Out here it is the
        // same panel in the same place, and the window shrinks to what the columns ask.
        .inspector(isPresented: Binding(
            get: { showBotSidebar },
            // Opening only ever happens through the toolbar button, which writes the
            // state directly. AppKit also writes through here when it restores the
            // window's saved split-view state, which would reopen the panel at launch
            // after any session that left it open — so an uninvited `true` is dropped
            // and the panel keeps its promise to start closed.
            set: { if !$0 { showBotSidebar = false } }
        )) {
            if let bot = model.selectedBot {
                DetailRail(bot: bot, showingSettings: $showingRailSettings)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
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

    @ViewBuilder
    private var detail: some View {
        @Bindable var model = model
            if let bot = model.selectedBot {
                ChatView(bot: bot, showBotSidebar: $showBotSidebar)
                    .navigationSplitViewColumnWidth(min: 380, ideal: 760)
            } else {
                ContentUnavailableView(
                    "No Bot Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a bot from the sidebar, or create one.")
                )
            }
    }
}

/// Shown between launch and the first handshake on a device that has been set up.
///
/// A spinner only while the socket is genuinely in flight. A refused port comes back
/// in milliseconds on this Mac, and the moment it does this says so — with the way to
/// bring the core back — rather than spinning through a timer first. It keeps trying
/// underneath, so it leaves by itself once the core answers.
private struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @State private var slow = false

    private var isLocal: Bool { host == "127.0.0.1" || host == "localhost" }

    var body: some View {
        VStack(spacing: 14) {
            if model.connectionFailed {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(isLocal ? "Routi Core isn't running on this Mac" : "Can't reach Routi Core at \(host)")
                    .font(.system(size: 15, weight: .semibold))
                Text(isLocal
                     ? "The core keeps your bots and does the work, and normally starts at login. If it was removed, install it again with the command below; this screen carries on by itself once the core answers."
                     : "Check that Mac is on, that Routi Core is running there, and that this device can see it — a Tailscale name works.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                if isLocal {
                    InstallCommand()
                }
                Button("Connect to a different Mac…") { model.isShowingSettings = true }
                    .controlSize(.small)
                    .padding(.top, 4)
            } else if slow {
                ProgressView().controlSize(.large)
                Text("Connecting to Routi Core…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 460, minHeight: 320)
        .animation(.snappy(duration: 0.25), value: model.connectionFailed)
        .task { await model.watchForCore() }
        .task {
            // A local core answers before a spinner could be seen; only a wait that
            // is actually felt — a remote host, a slow network — gets one.
            try? await Task.sleep(for: .milliseconds(400))
            slow = true
        }
    }
}
