import SwiftUI

/// App preferences, stored per-device.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The settings screen.
///
/// Replaces the whole window rather than opening a separate preferences panel, with a
/// "Back to app" affordance — the pattern the ChatGPT/Codex app uses, and the one that
/// works identically on a phone. `NavigationSplitView` does the adapting: two columns
/// on Mac and iPad, a push stack on iPhone, from the same code.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    /// Providers each get their own entry, so the section reads as a roster rather
    /// than a single lumped "Connections" row. Routi Core is deliberately *not* in
    /// there — it is the daemon this app talks to, not a model provider.
    enum Pane: Hashable, Identifiable {
        case general
        case provider(String)
        case core
        case screens
        case about

        var id: String {
            switch self {
            case .general: return "general"
            case .provider(let id): return "provider.\(id)"
            case .core: return "core"
            case .screens: return "screens"
            case .about: return "about"
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .provider(let id): return ProviderInfo.find(id).name
            case .core: return "Routi Core"
            case .screens: return "Screens"
            case .about: return "About"
            }
        }

        var symbol: String? {
            switch self {
            case .general: return "gearshape"
            case .provider: return nil // uses ProviderIcon instead
            case .core: return "externaldrive.connected.to.line.below"
            case .screens: return "desktopcomputer"
            case .about: return "info.circle"
            }
        }
    }

    private static let sections: [(String, [Pane])] = [
        ("App", [.general]),
        ("Providers", ProviderInfo.all.map { .provider($0.id) }),
        ("Core", [.core, .screens]),
        ("About", [.about]),
    ]

    @State private var selection: Pane? = .general

    /// The pane the opener asked for, if any, else General.
    private func openRequestedPane() {
        guard let requested = model.requestedSettingsPane else { return }
        model.requestedSettingsPane = nil
        switch requested {
        case "general": selection = .general
        case "core": selection = .core
        case "screens": selection = .screens
        case "about": selection = .about
        default: selection = .provider(requested)
        }
    }

    var body: some View {
        #if os(macOS)
        // A floating panel over the dimmed app, not a full-window takeover: the nav
        // list is plain rows rather than a split view, so the sheet keeps a fixed
        // size and never grows a sidebar toggle of its own.
        HStack(spacing: 0) {
            navList
                .frame(width: 232)
                .background(.background.secondary)
                .onAppear(perform: openRequestedPane)

            ZStack(alignment: .topTrailing) {
                pane
                Button {
                    model.isShowingSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(14)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 880, height: 620)
        #else
        NavigationStack {
            navList
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.isShowingSettings = false }
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var pane: some View {
        switch selection ?? .general {
        case .general: GeneralPane()
        case .provider(let id): ProviderPane(provider: ProviderInfo.find(id))
        case .core: ConnectionPane()
        case .screens: ScreensPane()
        case .about: AboutPane()
        }
    }

    private var navList: some View {
        List(selection: $selection) {
            ForEach(Self.sections, id: \.0) { group, panes in
                Section(group) {
                    ForEach(panes) { pane in
                        #if os(macOS)
                        PaneRow(pane: pane)
                            .tag(pane)
                            .listRowSeparator(.hidden)
                        #else
                        NavigationLink { paneView(pane) } label: { PaneRow(pane: pane) }
                        #endif
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    #if !os(macOS)
    @ViewBuilder
    private func paneView(_ pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .provider(let id): ProviderPane(provider: ProviderInfo.find(id))
        case .core: ConnectionPane()
        case .screens: ScreensPane()
        case .about: AboutPane()
        }
    }
    #endif
}

/// One sidebar row. Providers render their brand mark on a tinted tile; everything else uses an
/// SF Symbol, sized to line up with it.
private struct PaneRow: View {
    let pane: SettingsScreen.Pane

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if case .provider(let id) = pane {
                    ProviderIcon(provider: ProviderInfo.find(id), size: 20)
                } else if let symbol = pane.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(width: 20, height: 20)
                }
            }
            Text(pane.title).font(.system(size: 13))
            Spacer(minLength: 0)
            if case .provider(let id) = pane, !ProviderInfo.find(id).isAvailable {
                Text("Soon")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolActivity") private var showToolActivity = false
    @AppStorage("notifyOnFinish") private var notifyOnFinish = true
    @AppStorage("notifyOnHandover") private var notifyOnHandover = true

    var body: some View {
        SettingsPane(title: "General") {
            SettingsSection(
                "Profile",
                footnote: "A profile keeps its own bots and its own accounts. Switch or add one from the menu behind your name."
            ) {
                ProfileCard()
            }

            // What every bot knows about the person. Here rather than in a bot's rail
            // because it is not any one bot's: the same list reaches all of them.
            SettingsSection(
                "About you",
                footnote: "Read by every bot before it answers — your name, your timezone, how you like things done. Bots add to this as they learn; you can too."
            ) {
                AboutYouRows()
            }

            SettingsSection("Appearance") {
                SettingsRow(title: "Theme", detail: "How Routi looks on this device.", isFirst: true) {
                    Picker("", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection(
                "Notifications",
                footnote: "Only for conversations you are not looking at. Nothing leaves this device."
            ) {
                SettingsRow(
                    title: "When a bot finishes",
                    detail: "A reply lands, or a routine has run.",
                    isFirst: true
                ) {
                    Toggle("", isOn: $notifyOnFinish).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(
                    title: "When a bot needs you",
                    detail: "It has stopped at a sign-in, a code or a payment and is waiting."
                ) {
                    Toggle("", isOn: $notifyOnHandover).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsSection("Transcript") {
                SettingsRow(
                    title: "Show reasoning",
                    detail: "Adds a collapsed \"Thought process\" section to replies that include it.",
                    isFirst: true
                ) {
                    Toggle("", isOn: $showThinking).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(
                    title: "Show tool activity",
                    detail: "Every page opened, click made and screenshot taken, as cards in the transcript. Off, the bot just says what it did."
                ) {
                    Toggle("", isOn: $showToolActivity).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

/// The Mac app's own update, in the same pane as the core's: downloaded on its own,
/// installed by a relaunch. The phone has nothing here; TestFlight does that.
private struct AppUpdateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        let updater = model.appUpdater
        switch updater.phase {
        case .ready(let version):
            SettingsRow(
                title: "App",
                detail: "Routi Bot \(version) is downloaded and verified. Restarting installs it; this is \(model.appVersion)."
            ) {
                Button("Restart to Update") { model.restartToUpdate() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("restartToUpdate")
            }
        case .downloading(let fraction):
            SettingsRow(title: "App", detail: "Downloading Routi Bot \(updater.latestVersion ?? "")…") {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .checking:
            SettingsRow(title: "App", detail: "Checking for a newer Routi Bot…") {
                ProgressView().controlSize(.small)
            }
        case .failed(let why):
            SettingsRow(title: "App", detail: "The app could not update itself: \(why) The disk image is the way round it.") {
                Link("Download", destination: AppModel.dmgURL)
            }
        case .idle, .upToDate:
            if model.appUpdateAvailable {
                SettingsRow(
                    title: "App",
                    detail: updater.isEnabled
                        ? "Routi Bot \(model.coreUpdate?.latest ?? "") is out; this is \(model.appVersion). It downloads on its own; checking now hurries it along."
                        : "Routi Bot \(model.coreUpdate?.latest ?? "") is out; this is \(model.appVersion). A debug build does not update itself."
                ) {
                    if updater.isEnabled {
                        Button("Check Now") { updater.check() }
                    } else {
                        Link("Download", destination: AppModel.dmgURL)
                    }
                }
            }
        }
        #else
        EmptyView()
        #endif
    }
}

/// Avatar, the profile's editable name, and what it holds. There is no account here:
/// Routi has no accounts of its own, and the Claude or ChatGPT sign-ins live with
/// their providers, where each can be disconnected on its own.
private struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    @State private var draftName = ""
    /// Which profile the draft belongs to. The rename is committed when the card
    /// goes away, and by then the profile showing can be a different one: deleting
    /// this profile switches to the first, which must not inherit the name.
    @State private var profileID = ""
    @State private var showingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Text(model.userInitials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Profile name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .onSubmit { commit() }
                    .accessibilityIdentifier("profileName")
                Text(holdings)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.currentProfileID != Profile.defaultID {
                Button("Delete Profile") { showingDelete = true }
                    .disabled(!model.canDeleteCurrentProfile)
                    .help(model.canDeleteCurrentProfile ? "" : "Delete its bots first.")
            }
        }
        .padding(14)
        .onAppear {
            draftName = model.userName
            profileID = model.currentProfileID
        }
        // Commit on focus loss as well as Return; a name typed and abandoned should
        // still stick, the way every other settings field behaves.
        .onDisappear { commit() }
        .confirmationDialog("Delete \(model.userName)?", isPresented: $showingDelete) {
            Button("Delete Profile", role: .destructive) {
                Task {
                    if await model.deleteProfile(model.currentProfileID) {
                        model.isShowingSettings = false
                    }
                }
            }
        } message: {
            Text("Its accounts are disconnected. Bots are never deleted this way.")
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let profile = model.profiles.first(where: { $0.id == profileID }),
              profile.name != trimmed else { return }
        Task { await model.renameProfile(profileID, to: trimmed) }
    }

    private var holdings: String {
        let bots = model.bots.count
        let accounts = model.auth.providers.values.filter(\.configured).count
        let botPart = bots == 1 ? "1 bot" : "\(bots) bots"
        let accountPart = accounts == 0 ? "nothing connected" : accounts == 1 ? "1 account" : "\(accounts) accounts"
        return "\(botPart), \(accountPart)"
    }
}

/// The shared notes as rows. A row opens the note; the last row adds one.
private struct AboutYouRows: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Memory?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.sharedMemories.enumerated()), id: \.element.id) { index, memory in
                if index > 0 { Divider().padding(.leading, 14) }
                Button { editing = memory } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(memory.text)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !model.sharedMemories.isEmpty { Divider().padding(.leading, 14) }
            Button { adding = true } label: {
                Label("Add a fact", systemImage: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(item: $editing) { memory in
            NoteEditor(title: "About you", memory: memory)
        }
        .sheet(isPresented: $adding) {
            NoteEditor(title: "About you", memory: nil) { text in
                await model.addSharedMemory(text)
            }
        }
        .task { await model.loadSharedMemories() }
    }
}

// MARK: - Routi Core

struct ConnectionPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @AppStorage("daemonPort") private var port = 7171
    @State private var draftHost = ""
    @State private var draftPort = 7171

    private var status: (String, Color) {
        switch model.connection {
        case .connected: return ("Connected", .green)
        case .connecting: return ("Connecting…", .secondary)
        case .disconnected: return ("Not connected", .red)
        }
    }

    var body: some View {
        SettingsPane(title: "Routi Core") {
            SettingsSection("Connection") {
                SettingsRow(title: "Status", isFirst: true) {
                    HStack(spacing: 6) {
                        Circle().fill(status.1).frame(width: 7, height: 7)
                        SettingsValue(text: status.0)
                    }
                }
                SettingsRow(title: "Host", detail: "A Tailscale name works here too.") {
                    TextField("127.0.0.1", text: $draftHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                SettingsRow(title: "Port") {
                    TextField("7171", value: $draftPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                SettingsRow(title: "", detail: nil) {
                    HStack {
                        Spacer()
                        Button("Reconnect") { apply() }
                            .disabled(draftHost.isEmpty || (draftHost == host && draftPort == port))
                    }
                }
            }

            SettingsSection("Server") {
                SettingsRow(title: "Version", isFirst: true) {
                    SettingsValue(text: model.coreVersion.map { "v\($0)" } ?? "—")
                }
                if showsCoreUpdate {
                    SettingsRow(title: "Update", detail: coreUpdateDetail) {
                        if model.isUpdatingCore {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.coreUpdateStage ?? "Updating…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: 260, alignment: .trailing)
                            }
                        } else if model.coreUpdate?.available == true {
                            Button("Update Routi Core") { Task { await model.startCoreUpdate() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(!(model.coreUpdate?.canUpdate ?? false))
                        }
                    }
                }
                AppUpdateRow()
                SettingsRow(title: "Protocol") {
                    SettingsValue(text: "v\(RoutiClient.protocolVersion)")
                }
            }

            // How a phone or iPad reaches this core. Tailscale is the recommended way:
            // the same address works at home and away, and only that person's own
            // devices can use it. The core listens there the moment Tailscale is up.
            SettingsSection(
                "Phone and iPad",
                footnote: "Routi Core answers on this Mac and, when Tailscale is running, on its Tailscale address — reachable only from your own devices, wherever they are."
            ) {
                if let addresses = model.coreAddresses, let tailscale = addresses.tailscale {
                    // A userspace Tailscale has the address without an interface: the core
                    // cannot bind it, and is reached there only if `tailscale serve`
                    // forwards the port. Say which, rather than showing an address that
                    // may not answer — or none, as if Tailscale were missing.
                    let served = addresses.tailscaleMode == "userspace"
                    let unreachable = addresses.reachable == false && (served || addresses.listening == false)
                    SettingsRow(
                        title: "Address",
                        detail: unreachable
                            ? (served
                                ? "Tailscale is running without a network interface here, and nothing forwards this port. On \(addresses.hostname), run: tailscale serve --bg --tcp \(port) tcp://127.0.0.1:\(port)"
                                : "Routi Core is not answering on this address yet. It listens there within half a minute of Tailscale coming up.")
                            : (served
                                ? "Reached through Tailscale serve. Enter this in the Routi app on your phone or iPad when it asks where Routi Core is."
                                : "Enter this in the Routi app on your phone or iPad when it asks where Routi Core is."),
                        isFirst: true
                    ) {
                        SettingsValue(text: "\(tailscale):\(port)", monospaced: true)
                    }
                } else if model.coreAddresses?.tailscaleMode == "down" {
                    SettingsRow(
                        title: "Tailscale",
                        detail: "Tailscale is installed on \(model.coreAddresses?.hostname ?? "the Mac running Routi Core") but not running. Start it there, and the address to use appears here.",
                        isFirst: true
                    ) {
                        Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                    }
                } else {
                    SettingsRow(
                        title: "Tailscale",
                        detail: "Install Tailscale on \(model.coreAddresses?.hostname ?? "the Mac running Routi Core") and on your phone, sign both into the same account, and the address to use appears here.",
                        isFirst: true
                    ) {
                        Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                    }
                }
                SettingsRow(title: "Data") {
                    SettingsValue(text: "~/.routi on the host Mac", monospaced: true)
                }
            }
        }
        .onAppear {
            draftHost = host
            draftPort = port
        }
        .task {
            await model.checkCoreUpdate()
            await model.loadCoreAddresses()
        }
    }

    private var showsCoreUpdate: Bool {
        model.isUpdatingCore || model.coreUpdateOutcome != nil || model.coreUpdate?.available == true
    }

    /// What the Update row says: the outcome of the last run, else the offer.
    private var coreUpdateDetail: String? {
        if model.isUpdatingCore { return "Bots pause while the core is rebuilt and restarted. This window reconnects by itself." }
        if let outcome = model.coreUpdateOutcome { return outcome }
        guard let update = model.coreUpdate, update.available, let latest = update.latest else { return nil }
        if !update.canUpdate, let reason = update.reason { return "Routi Core \(latest) is out. \(reason)" }
        return "Routi Core \(latest) is out; this core is \(update.current). Downloads and builds it, then restarts the core — a few minutes, during which bots pause."
    }

    private func apply() {
        host = draftHost
        port = draftPort
        model.updateEndpoint(host: draftHost, port: draftPort)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        #if DEBUG
        // Which source this build came from, since a phone has no sidebar stamp.
        if let commit = Bundle.main.infoDictionary?["RoutiBuildCommit"] as? String,
           let time = Bundle.main.infoDictionary?["RoutiBuildTime"] as? String {
            return "\(v) (\(b)) · build \(time) · \(commit)"
        }
        #endif
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPane(title: "About") {
            HStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Routi Bot")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Version \(version)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("Copyright © 2026 Narra Labs, LLC")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            SettingsSection("Open source") {
                SettingsRow(
                    title: "License",
                    detail: "Apache-2.0. The code is free to use, change and share; the copyright stays with Narra Labs.",
                    isFirst: true
                ) {
                    Link("routi on GitHub", destination: URL(string: "https://github.com/narralabs/routi")!)
                        .font(.system(size: 12.5))
                }
                SettingsRow(
                    title: "Provider marks",
                    detail: "From LobeHub's icon set, MIT. See NOTICE in the repository."
                ) {
                    Link("lobe-icons", destination: URL(string: "https://github.com/lobehub/lobe-icons")!)
                        .font(.system(size: 12.5))
                }
            }
        }
    }
}

// MARK: - Screens

/// The machine the container screens live on: what state it is in and what to do.
/// Refreshed while it is on screen, since the thing it describes changes in another app.
struct ScreensPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPane(title: "Screens") {
            SettingsSection(
                "Desktop",
                footnote: "Bots set to Container get a screen on a shared Linux machine, one display each, with a browser. It runs in Docker on the Mac running Routi Core; bots set to None or This Mac do not need it."
            ) {
                DesktopHostView()
                    .padding(12)
            }

        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refreshDesktopHost()
            }
        }
    }
}
