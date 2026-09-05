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
            SettingsFooter()
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

private struct SettingsFooter: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .secondary
        case .disconnected: return .red
        }
    }

    private var statusHelp: String {
        switch model.connection {
        case .connected: return model.account?.label ?? "Connected"
        case .connecting: return "Connecting to krogd…"
        case .disconnected: return "krogd offline"
        }
    }

    var body: some View {
        Button {
            model.isShowingSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text("Settings").font(.system(size: 13))
                Spacer(minLength: 0)
                // Connection health stays visible here; it is the one thing worth
                // knowing at a glance without opening settings.
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .help(statusHelp)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
