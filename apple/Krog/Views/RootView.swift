import SwiftUI

/// One layout for all three devices.
///
/// `NavigationSplitView` does the adapting itself: three columns on the Mac, a
/// sidebar over content on iPad, and a push-navigation stack on iPhone. That is the
/// whole reason to be native here — the responsive behaviour is the framework's job,
/// not something reconstructed with width breakpoints.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showRail = true
    @State private var showingNewBot = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            BotListView(showingNewBot: $showingNewBot)
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 340)
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
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .task { model.start() }
    }
}
