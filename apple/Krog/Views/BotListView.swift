import SwiftUI

/// The sidebar.
///
/// Modelled on the ChatGPT app: a flat list of names under quiet section headers, no
/// dividers, no timestamps, no preview lines. The one thing kept from the old design
/// is a small avatar — in Krog a row is a *bot*, not a conversation, and the colour is
/// how you tell them apart at a glance.
struct BotListView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewBot: Bool
    @State private var search = ""

    private var filtered: [Bot] {
        guard !search.isEmpty else { return model.bots }
        let q = search.lowercased()
        return model.bots.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        @Bindable var model = model

        List(selection: Binding(
            get: { model.selectedBotID },
            set: { newValue in
                guard let id = newValue else { return }
                Task { await model.select(bot: id) }
            }
        )) {
            Section {
                NavRow(icon: "square.and.pencil", title: "New Bot") { showingNewBot = true }
                    .listRowSeparator(.hidden)
            }

            Section("Bots") {
                ForEach(filtered) { bot in
                    BotRow(bot: bot, isBusy: model.isBusy(botID: bot.id))
                        .tag(bot.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Delete \(bot.name)", systemImage: "trash", role: .destructive) {
                                Task { await model.deleteBot(bot.id) }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .navigationTitle("Krog")
        .overlay {
            if model.bots.isEmpty {
                ContentUnavailableView(
                    "No Bots",
                    systemImage: "sparkles",
                    description: Text("Create one to get started.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AccountFooter()
        }
    }
}

/// A borderless action row that reads like the rest of the list rather than a button.
private struct NavRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }
}

private struct BotRow: View {
    let bot: Bot
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(color: bot.color, size: 20, isBusy: false)
            Text(bot.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isBusy {
                // A quiet pulse beats a spinner: it says "working" without demanding
                // attention from across the sidebar.
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.2), value: isBusy)
    }
}

private struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @State private var showingSignOut = false

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .secondary
        case .disconnected: return .red
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(model.account?.initials ?? "?")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: .circle)

            Text(model.account?.displayName ?? "Account")
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 0)

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .help(model.connection == .connected ? (model.account?.label ?? "Connected") : "krogd offline")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { showingSignOut = true }
        .confirmationDialog("Disconnect Claude?", isPresented: $showingSignOut) {
            Button("Disconnect", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("You'll go back through setup to reconnect.")
        }
    }
}
