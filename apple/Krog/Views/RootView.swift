import SwiftUI

/// One layout for all three devices.
///
/// `NavigationSplitView` does the adapting itself: three columns on the Mac, a
/// sidebar over content on iPad, and a push-navigation stack on iPhone. That is the
/// whole reason to be native here — the responsive behaviour is the framework's job,
/// not something reconstructed with width breakpoints.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingRailSettings = false
    @State private var showingNewBot = false

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
            // A minimum column width alone does not stop AppKit: dragging past roughly
            // half of it snaps the sidebar shut, and with no toolbar toggle there is
            // then no way back. Refusing `.detailOnly` keeps the bot list present.
            set: { model.sidebarVisibility = $0 == .detailOnly ? .doubleColumn : $0 }
        )) {
            BotListView(showingNewBot: $showingNewBot)
                // A firm stop rather than a shrinking rail. The divider refuses to go
                // below a width the sidebar is still readable at.
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 360)
        } content: {
            if let bot = model.selectedBot {
                // The screen toggle is now a column-visibility control: `.all` shows
                // all three, `.doubleColumn` keeps the sidebar and chat and drops the
                // screen. That is the split view's own vocabulary rather than a view
                // conditionally inserted into the chat pane.
                ChatView(bot: bot, showRail: Binding(
                    get: { model.sidebarVisibility == .all },
                    set: { model.sidebarVisibility = $0 ? .all : .doubleColumn }
                ))
                .navigationSplitViewColumnWidth(min: 420, ideal: 620, max: .infinity)
            } else {
                ContentUnavailableView(
                    "No Bot Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a bot from the sidebar, or create one.")
                )
            }
        } detail: {
            // The third column is the bot's screen. Three peers rather than a panel
            // smuggled inside the chat pane: each gets its own toolbar and its own
            // divider, which is what the two-column version kept fighting.
            if let bot = model.selectedBot {
                DetailRail(bot: bot, showingSettings: $showingRailSettings)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            } else {
                Color.clear
            }
        }
        .navigationSplitViewStyle(.balanced)
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
