import SwiftUI

/// One layout for all three devices.
///
/// `NavigationSplitView` does the adapting itself: three columns on the Mac, a
/// sidebar over content on iPad, and a push-navigation stack on iPhone. That is the
/// whole reason to be native here — the responsive behaviour is the framework's job,
/// not something reconstructed with width breakpoints.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showRail = false
    @State private var showingNewBot = false

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.authKnown {
                // Neither onboarding nor chat is correct until the handshake lands.
                ConnectingView()
            } else if model.needsOnboarding {
                OnboardingView()
            } else {
                main
            }
        }
        .animation(.snappy(duration: 0.3), value: model.needsOnboarding)
        .animation(.snappy(duration: 0.3), value: model.authKnown)
        .task { model.start() }
    }

    private var main: some View {
        @Bindable var model = model

        return NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisibility },
            // A minimum column width alone does not stop AppKit: dragging past roughly
            // half of it snaps the sidebar shut, and with no toolbar toggle there is
            // then no way back. Refusing `.detailOnly` makes the icon rail the real
            // floor rather than a suggestion.
            set: { model.sidebarVisibility = $0 == .detailOnly ? .all : $0 }
        )) {
            BotListView(showingNewBot: $showingNewBot)
                // The floor is an icon rail, not nothing: dragging the divider in
                // collapses the sidebar to avatars rather than closing it, so there is
                // always something left to grab and click.
                .navigationSplitViewColumnWidth(min: 78, ideal: 268, max: 360)
        } detail: {
            if let bot = model.selectedBot {
                ChatView(bot: bot, showRail: $showRail)
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
