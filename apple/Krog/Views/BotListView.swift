import SwiftUI

/// The sidebar, following the original Grok Bot layout.
///
/// Deliberately plain: a search field, a row per bot with avatar, name, timestamp and
/// preview line, then Marketplace and the account row pinned at the bottom. There is
/// no sidebar toggle — the reference has none, and its absence is what keeps the
/// window chrome still.
struct BotListView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewBot: Bool
    @State private var search = ""

    private var filtered: [Bot] {
        guard !search.isEmpty else { return model.bots }
        let q = search.lowercased()
        return model.bots.filter { bot in
            bot.name.lowercased().contains(q)
                || (model.conversation(for: bot.id)?.title.lowercased().contains(q) ?? false)
        }
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
            ForEach(filtered) { bot in
                BotRow(
                    bot: bot,
                    conversation: model.conversation(for: bot.id),
                    isBusy: model.isBusy(botID: bot.id)
                )
                .tag(bot.id)
                .listRowSeparator(.hidden)
                .contextMenu {
                    Button("Delete \(bot.name)", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteBot(bot.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        #if os(macOS)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        // No toggle: the sidebar is always present, so nothing in the chrome moves.
        .toolbar(removing: .sidebarToggle)
        #else
        .searchable(text: $search, prompt: "Search")
        #endif
        .navigationTitle("Krog")
        .toolbar {
            ToolbarItem {
                Button("New Bot", systemImage: "plus") { showingNewBot = true }
            }
        }
        .overlay {
            if model.bots.isEmpty {
                ContentUnavailableView(
                    "No Bots",
                    systemImage: "sparkles",
                    description: Text("Create one with + to get started.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
    }
}

private struct BotRow: View {
    let bot: Bot
    let conversation: Conversation?
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(color: bot.color, size: 36, isBusy: isBusy)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bot.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let stamp = conversation?.lastMessageAt {
                        Text(Self.relative(stamp))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(conversation?.title.isEmpty == false ? conversation!.title : "New chat")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Time today, weekday this week, date beyond that.
    static func relative(_ millis: Double) -> String {
        let date = Date(timeIntervalSince1970: millis / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .secondary
        case .disconnected: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FooterRow(title: "Marketplace") {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15))
                    .frame(width: 22)
            } action: {}

            // The account row opens Settings — the name is the affordance, as in the
            // reference, rather than the word "Settings".
            FooterRow(title: model.userName, statusColor: statusColor) {
                Text(model.userInitials)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: .circle)
            } action: {
                model.isShowingSettings = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

private struct FooterRow<Leading: View>: View {
    let title: String
    var statusColor: Color?
    @ViewBuilder let leading: Leading
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if let statusColor {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 7, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
