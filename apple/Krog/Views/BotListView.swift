import SwiftUI

/// The sidebar. `.listStyle(.sidebar)` is what gives the Mac its real vibrancy and
/// selection styling for free, and gives iOS an inset-grouped list, from one
/// declaration.
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
                .contextMenu {
                    Button("Delete \(bot.name)", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteBot(bot.id) }
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
        .toolbar {
            ToolbarItem {
                Button("New Bot", systemImage: "square.and.pencil") { showingNewBot = true }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AccountFooter()
        }
    }
}

private struct BotRow: View {
    let bot: Bot
    let conversation: Conversation?
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            BotAvatar(color: bot.color, size: 34, isBusy: isBusy)

            VStack(alignment: .leading, spacing: 1) {
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
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    /// Time today, weekday this week, date beyond that — the iMessage convention.
    static func relative(_ millis: Double) -> String {
        let date = Date(timeIntervalSince1970: millis / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
    }
}

private struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    private var status: (String, Color) {
        switch model.connection {
        case .connected: return (model.account?.label ?? "Connected", .green)
        case .connecting: return ("Connecting…", .secondary)
        case .disconnected: return ("krogd offline", .red)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 9) {
                Text(model.account?.initials ?? "?")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: .circle)

                Text(model.account?.displayName ?? "Account")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Circle()
                    .fill(status.1)
                    .frame(width: 7, height: 7)
                    .help(status.0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}
