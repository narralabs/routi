import Foundation
import Observation
import SwiftUI

/// The app's single source of truth.
///
/// Streaming deltas are applied by block index, matching the wire protocol, so a
/// tool card arriving mid-turn lands in its own slot rather than being appended to
/// whatever text preceded it.
@MainActor
@Observable
final class AppModel {
    // Server state
    var bots: [Bot] = []
    var conversations: [String: Conversation] = [:]
    var messages: [Message] = []
    /// Model lists per provider. Each provider names its own, so the picker never
    /// offers a bot a model its provider cannot serve.
    var modelsByProvider: [String: [ModelInfo]] = [:]
    /// Providers whose harness will accept Routi's desktop tools. A bot on any other
    /// cannot be given a screen, however willing the container is to make one.
    var providersWithScreen: Set<String> = []

    // Selection
    var selectedBotID: String?
    var selectedConversationID: String?

    // Transient
    var busyConversations: Set<String> = []
    /// Which routine is running a busy conversation, by conversation id — so "busy"
    /// can be shown as what it is rather than as an unexplained "Thinking…".
    var busyRoutineNames: [String: String] = [:]
    /// The selected bot's routines. Loaded with the bot, reloaded after each run.
    var routines: [Routine] = []
    /// The selected bot's own notes. Loaded with the bot, reloaded whenever the daemon
    /// says they changed — the bot writes them mid-turn.
    var memories: [Memory] = []
    /// What every bot knows about the person. Not tied to a selection; shown in Settings.
    var sharedMemories: [Memory] = []
    /// Last failure per conversation, shown inline in that thread rather than only
    /// as an alert — an alert that fires while you are looking elsewhere is lost.
    var conversationErrors: [String: String] = [:]
    var connection: RoutiClient.ConnectionState = .disconnected
    /// Local notifications for bots the person is not watching.
    let notifier = Notifier()
    var errorMessage: String?
    var isLoadingMessages = false
    /// True while a profile's bots are on their way: after a switch, and on the first
    /// load. An empty list in that moment is not "no bots", and must not say so.
    var isLoadingBots = true

    /// Settings replaces the whole window rather than opening a panel, so its
    /// visibility is app state, not view state — the ⌘, menu command toggles it too.
    var isShowingSettings = false
    /// A pane Settings should open on, asked for by whoever opened it. Read once.
    var requestedSettingsPane: String?

    /// Opens Settings on a named pane — "screens", "core", or a provider id.
    func showSettings(pane: String) {
        requestedSettingsPane = pane
        isShowingSettings = true
    }

    /// The desktop fills the whole app window rather than opening a sheet, so its
    /// visibility lives beside the other window-level modes.
    var isShowingScreen = false

    /// Held here rather than in the view so the View menu can restore a sidebar the
    /// user has dragged shut — without a toolbar toggle there is otherwise no way back.
    var sidebarVisibility: NavigationSplitViewVisibility = .all

    // Shared desktop
    var surface: SurfaceStatus = .unknown
    /// Latest frame as JPEG bytes. Nil until the first capture arrives.
    var surfaceFrame: Data?
    /// Bots waiting on you, by bot id. A bot with one is paused until it is answered.
    var handovers: [String: Handover] = [:]
    /// Where the desktop's own pointer is, in its pixels. Absent until a frame says.
    var surfacePointer: CGPoint?
    @ObservationIgnored private var frameTask: Task<Void, Never>?

    // Onboarding
    var auth: AuthStatus = .unknown
    /// Nil until the first handshake, so the window shows neither onboarding nor an
    /// empty chat while we're still finding out which is right.
    var authKnown = false
    private var onboardingDismissed = false

    /// True once a connection attempt has come back refused or dropped. The client
    /// starts out disconnected too, so the state alone cannot say "tried and failed";
    /// this can, and it is what lets the no-core screen appear the moment the port
    /// refuses instead of after a timer.
    var connectionFailed = false

    /// Whether this device has been through setup once. Kept on the device, not the
    /// core: the question it answers is "has this app ever found a core", which is
    /// exactly the thing a fresh install cannot ask a core about.
    private(set) var hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")

    /// Setup is done when the daemon has a working credential and, on a first run,
    /// the user has seen the closing step.
    ///
    /// A first launch on this device goes into setup before any connection exists —
    /// setup is where installing the core, or pointing at one, is offered — so that
    /// a spinner is never the first thing a new person sees.
    var needsOnboarding: Bool {
        if !hasCompletedSetup && !authKnown { return true }
        guard authKnown else { return false }
        return !coreConfigured || !onboardingDismissed
    }

    /// Whether the core has any connection at all, in its first profile. Setup is about
    /// the core; a second profile with nothing connected yet is not a reason to run it.
    private(set) var coreConfigured = false

    /// The first few hundred milliseconds of a first launch, while the socket is
    /// deciding between a core that answers and a port that refuses. Either lands
    /// well inside this on a Mac, and showing the welcome screen only to swap it for
    /// the chat a frame later would be a flash — so the window stays empty until
    /// the answer is in, or the wait has been long enough that it is worth a screen.
    private(set) var isSettling = false

    @ObservationIgnored private let client: RoutiClient

    // Default arguments are evaluated in a nonisolated context, so the client is
    // constructed inside the initializer rather than in the signature.
    init(client: RoutiClient? = nil) {
        // The address lives in defaults (Settings → Routi Core writes it), and the
        // client has to start from it: a host set once used to hold until the next
        // launch, when the app quietly went back to this Mac.
        let defaults = UserDefaults.standard
        let storedPort = defaults.integer(forKey: "daemonPort")
        let client = client ?? RoutiClient(
            host: defaults.string(forKey: "daemonHost") ?? "127.0.0.1",
            port: storedPort == 0 ? 7171 : storedPort
        )
        self.client = client
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connection = state
            switch state {
            case .connected: self.connectionFailed = false; self.isSettling = false
            case .disconnected: self.connectionFailed = true; self.isSettling = false
            case .connecting: break
            }
            if state == .connected {
                Task {
                    await self.refreshAuth()
                    await self.refreshAll()
                    // Asked once, after setup — a permission prompt in the middle of
                    // onboarding is one question too many.
                    if self.hasCompletedSetup { self.notifier.requestAuthorizationIfNeeded() }
                }
            }
        }
        client.onAuthStatus = { [weak self] status in
            guard let self else { return }
            // The handshake speaks for the first profile; another profile's status is
            // fetched by `refreshAuth` once connected.
            if self.currentProfileID == Profile.defaultID { self.auth = status }
            self.coreConfigured = status.configured
            self.authKnown = true
            // A daemon that already has a credential shouldn't re-run setup — an app
            // reinstalled on a Mac that was set up before lands straight in the chat.
            if status.configured {
                self.onboardingDismissed = true
                self.markSetupComplete()
            }
        }
        client.onEvent = { [weak self] event in
            self?.apply(event)
        }

        // A banner is for a conversation the person cannot see: another bot's, or this
        // one's while the app is in the background or behind Settings or the screen.
        notifier.isWatching = { [weak self] conversationId in
            guard let self, self.selectedConversationID == conversationId else { return false }
            guard !self.isShowingSettings, !self.isShowingScreen else { return false }
            #if os(macOS)
            return NSApp.isActive
            #else
            return UIApplication.shared.applicationState == .active
            #endif
        }
        notifier.onOpen = { [weak self] botId in
            guard let self else { return }
            self.isShowingSettings = false
            self.isShowingScreen = false
            Task { await self.select(bot: botId) }
        }
    }

    var account: AccountInfo? { client.account }
    var coreVersion: String? { client.serverVersion }

    /// Where feedback goes: the repository's issue form, with the versions and the
    /// machine filled in from here, since those are what a report is missing most.
    var feedbackURL: URL {
        var parts = URLComponents(string: "https://github.com/narralabs/routi/issues/new")!
        parts.queryItems = [
            .init(name: "template", value: "bug_report.yml"),
            .init(name: "app_version", value: appVersion),
            .init(name: "core_version", value: coreVersion ?? "not connected"),
            .init(name: "system", value: Self.systemDescription),
        ]
        return parts.url!
    }

    private static var systemDescription: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if os(macOS)
        return "macOS \(version)"
        #else
        return "\(UIDevice.current.systemName) \(version) on \(UIDevice.current.model)"
        #endif
    }

    /// Whether the list and a thread are on screen together, so one should be open.
    static var startsOnThread: Bool {
        #if os(macOS)
        return true
        #else
        #if DEBUG
        // A phone launched straight onto the desktop needs a bot selected first.
        if ProcessInfo.processInfo.arguments.contains("-showScreen") { return true }
        #endif
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    // MARK: - Addresses

    /// Where this core can be reached from another device, as the core sees it.
    struct CoreAddresses: Codable, Hashable {
        var hostname: String
        var tailscale: String?
        var listening: Bool
    }

    var coreAddresses: CoreAddresses?

    func loadCoreAddresses() async {
        coreAddresses = try? await client.rpc("core.addresses", field: "addresses", as: CoreAddresses.self)
    }

    // MARK: - Updates

    /// What the core says about newer releases. Nil until asked; asked on every connect.
    struct CoreUpdate: Codable, Hashable {
        var current: String
        var latest: String?
        var available: Bool
        var canUpdate: Bool
        var reason: String?
        var checkedAt: Double
    }

    var coreUpdate: CoreUpdate?
    /// The stage line the core last reported, while an update runs.
    var coreUpdateStage: String?
    var isUpdatingCore = false
    /// How the last update ended, for the pane to show once.
    var coreUpdateOutcome: String?
    /// The version the running update is meant to land on, and whether the core has
    /// gone away and come back since it started — which is how a rollback is told
    /// apart from a core that has simply not restarted yet.
    private var updatingTo: String?
    private var sawRestart = false

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    #if os(macOS)
    /// The Mac app's own updater: downloads in the background, offers a relaunch.
    let appUpdater = AppUpdater()
    #endif

    /// The app is behind the latest release, by the core's account of what is out.
    var appUpdateAvailable: Bool {
        guard let latest = coreUpdate?.latest else { return false }
        return Self.compareVersions(latest, appVersion) > 0
    }

    #if os(macOS)
    /// Installs the downloaded release and relaunches. Any sheet goes first: AppKit
    /// refuses to quit an app with a modal sheet up ("App termination blocked by
    /// modal sheet"), and Settings is where the button lives.
    func restartToUpdate() {
        isShowingSettings = false
        isShowingNewProfile = false
        isShowingScreen = false
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            appUpdater.installAndRelaunch()
        }
    }
    #endif

    /// A release of the app is downloaded and waiting for the relaunch.
    var appUpdateReady: Bool {
        #if os(macOS)
        return appUpdater.isReady
        #else
        return false
        #endif
    }

    static let dmgURL = URL(string: "https://github.com/narralabs/routi/releases/latest/download/RoutiBot.dmg")!

    /// Dotted versions, numerically: 0.1.10 is newer than 0.1.9.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }

    func checkCoreUpdate(force: Bool = false) async {
        if let update = try? await client.rpc("core.update.check", ["force": force], field: "update", as: CoreUpdate.self) {
            coreUpdate = update
        }
    }

    /**
     Asks the core to update itself, then watches it go.

     The core downloads and verifies the release, hands over to the release's own
     update script, and is restarted by it — so the socket drops partway through, on
     purpose. Reconnecting to the new version is success; reconnecting after a restart
     to the old one means the script put it back; nothing within ten minutes is a
     failure to say out loud, with the installer as the way out.
     */
    func startCoreUpdate() async {
        guard let target = coreUpdate?.latest, !isUpdatingCore else { return }
        coreUpdateOutcome = nil
        do {
            let result = try await client.rpc("core.update.start")
            guard result["ok"] as? Bool == true else {
                coreUpdateOutcome = result["why"] as? String ?? "The update could not start."
                return
            }
        } catch {
            coreUpdateOutcome = error.localizedDescription
            return
        }
        isUpdatingCore = true
        updatingTo = target
        sawRestart = false
        coreUpdateStage = "Starting…"
        Task { await watchCoreUpdate() }
    }

    private func watchCoreUpdate() async {
        let started = coreUpdate?.current
        let deadline = Date().addingTimeInterval(10 * 60)
        while isUpdatingCore && Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            switch connection {
            case .connected:
                guard sawRestart, let version = coreVersion else { continue }
                if version == updatingTo {
                    finishCoreUpdate("Updated to Routi Core \(version).")
                } else if version == started {
                    finishCoreUpdate("Routi Core \(version) is back: the new one did not start, so it was put back. See ~/.routi/logs/update.log on the host Mac.")
                }
            case .disconnected, .connecting:
                sawRestart = true
                coreUpdateStage = "Restarting Routi Core…"
                client.connectNow()
            }
        }
        if isUpdatingCore {
            finishCoreUpdate("The update did not finish. On the Mac running Routi Core, run the installer again:\ncurl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/install.sh | sh")
        }
    }

    private func finishCoreUpdate(_ outcome: String) {
        isUpdatingCore = false
        coreUpdateStage = nil
        updatingTo = nil
        coreUpdateOutcome = outcome
        Task { await checkCoreUpdate(force: true) }
    }

    // MARK: - Profiles

    /// Every profile on the core. The one showing is `currentProfileID`, remembered per
    /// device: the phone can sit on work while the Mac sits on personal.
    var profiles: [Profile] = []
    private(set) var currentProfileID: String = UserDefaults.standard.string(forKey: "currentProfile") ?? Profile.defaultID
    /// The new-profile sheet, reachable from the profile menu wherever it appears.
    var isShowingNewProfile = false

    var currentProfile: Profile? { profiles.first { $0.id == currentProfileID } }

    /// The name at the foot of the sidebar: the profile's. The core greets the person
    /// by it too, minus any label in brackets — "William (Narra Labs)" is greeted as
    /// William. Stored on the core rather than in local defaults, so the phone and
    /// every bot it creates know the same name.
    var userName: String {
        if let name = currentProfile?.name, !name.isEmpty { return name }
        if !storedUserName.isEmpty { return storedUserName }
        return account?.firstName ?? "Profile"
    }

    private(set) var storedUserName = ""

    /// Renames the profile showing. Kept under its old name because the sidebar and
    /// onboarding still call it that: the name they ask for is the profile's.
    func setUserName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentProfile?.name else { return }
        await renameProfile(currentProfileID, to: trimmed)
    }

    var userInitials: String { Self.initials(of: userName) }

    /// One or two letters for a profile's disc. The label in brackets is not part of
    /// the name: "William (Narra Labs)" is W, "Narra Labs" is NL.
    static func initials(of name: String) -> String {
        let bare = name.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        let parts = bare.split(separator: " ")
        guard let first = parts.first else { return "?" }
        if parts.count == 1 { return String(first.prefix(1)).uppercased() }
        return (String(first.prefix(1)) + String(parts[parts.count - 1].prefix(1))).uppercased()
    }

    func refreshProfiles() async {
        guard let list = try? await client.rpc("profiles.list", field: "profiles", as: [Profile].self) else { return }
        profiles = list
        // A profile deleted from another device, or a core reset, leaves this device
        // pointing at nothing; it falls back to the first rather than an empty list.
        if !list.contains(where: { $0.id == currentProfileID }), let first = list.first {
            currentProfileID = first.id
            UserDefaults.standard.set(first.id, forKey: "currentProfile")
        }
    }

    /// Shows another profile: its bots, its connections. Nothing about the previous one
    /// is lost — its bots keep running on the core, which knows no "current" profile.
    func switchProfile(to id: String) async {
        guard id != currentProfileID, profiles.contains(where: { $0.id == id }) else { return }
        currentProfileID = id
        UserDefaults.standard.set(id, forKey: "currentProfile")
        isLoadingBots = true
        clearSelection()
        bots = []
        messages = []
        modelsByProvider = [:]
        await refreshAuth()
        await refreshAll()
        isLoadingBots = false
        // Open onto the first bot where the list and thread share the screen, as at launch.
        if Self.startsOnThread, let first = bots.first { await select(bot: first.id) }
    }

    /// Makes a profile and switches to it. It starts with nothing connected: the
    /// person connects an account for it under Settings, exactly as for the first.
    func createProfile(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let profile = try await client.rpc("profiles.create", ["name": trimmed], field: "profile", as: Profile.self)
            profiles.append(profile)
            await switchProfile(to: profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameProfile(_ id: String, to name: String) async {
        do {
            let profile = try await client.rpc("profiles.rename", ["id": id, "name": name], field: "profile", as: Profile.self)
            if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = profile }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes an empty profile and shows the first one. The core refuses a profile
    /// with bots, and the first profile altogether; the error is shown as it comes.
    func deleteProfile(_ id: String) async -> Bool {
        do {
            try await client.rpc("profiles.delete", ["id": id])
            profiles.removeAll { $0.id == id }
            if id == currentProfileID, let first = profiles.first { await switchProfile(to: first.id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Whether the profile showing can be deleted: not the first, and holding no bots.
    var canDeleteCurrentProfile: Bool {
        currentProfileID != Profile.defaultID && bots.isEmpty
    }

    var selectedBot: Bot? {
        bots.first { $0.id == selectedBotID }
    }

    var isBusy: Bool {
        guard let id = selectedConversationID else { return false }
        return busyConversations.contains(id)
    }

    /// Failure in the thread on screen, if any.
    var selectedError: String? {
        selectedConversationID.flatMap { conversationErrors[$0] }
    }

    func dismissSelectedError() {
        guard let id = selectedConversationID else { return }
        conversationErrors[id] = nil
    }

    func isBusy(botID: String) -> Bool {
        guard let conv = conversation(for: botID) else { return false }
        return busyConversations.contains(conv.id)
    }

    /// Most recently active conversation for a bot — what the sidebar previews.
    func conversation(for botID: String) -> Conversation? {
        conversations.values
            .filter { $0.botId == botID }
            .max { ($0.lastMessageAt ?? 0) < ($1.lastMessageAt ?? 0) }
    }

    func start() {
        if !hasCompletedSetup {
            isSettling = true
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                isSettling = false
            }
        }
        client.connect()
    }

    func updateEndpoint(host: String, port: Int) {
        client.updateEndpoint(host: host, port: port)
    }

    /// Retries the core without waiting out the backoff. For screens that are
    /// watching for one to appear.
    func connectNow() {
        client.connectNow()
    }

    /// Keeps knocking on the port every couple of seconds until the view goes away.
    /// For the screens that exist because there is no core yet.
    func watchForCore() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if connection == .disconnected { connectNow() }
        }
    }

    /// The whole thread as text, labelled by speaker.
    ///
    /// Exists because selection cannot cross message bubbles, so "copy what I dragged
    /// over" is not available to offer. Bot names rather than "assistant", since a room
    /// has several and a reader needs to know who said what.
    func transcript() -> String {
        messages
            .map { message in
                let who = message.role == .user
                    ? (storedUserName.isEmpty ? "You" : storedUserName)
                    : (bots.first { $0.id == message.botId }?.name ?? selectedBot?.name ?? "Bot")
                return "\(who): \(message.plainText)"
            }
            .filter { !$0.hasSuffix(": ") }
            .joined(separator: "\n\n")
    }

    // MARK: - Handovers

    /// Answers a bot that is waiting. `done` resumes it; `skipped` tells it to go on without.
    ///
    /// Handing the screen back also leaves it. Answering is the end of the user's turn
    /// at the desktop — the bot picks it up from here and the reply lands in the
    /// transcript — so staying in the full-window view left people watching a still
    /// picture with the answer happening behind it.
    func resolveHandover(_ botId: String, outcome: String) async {
        handovers[botId] = nil
        isShowingScreen = false
        _ = try? await client.rpc("handover.resolve", ["botId": botId, "outcome": outcome])
    }

    func handover(for botId: String?) -> Handover? {
        guard let botId else { return nil }
        return handovers[botId]
    }

    // MARK: - The machine the screens live on

    /// Nil until asked; setup and Settings ask.
    var desktopHost: DesktopHostStatus?

    func refreshDesktopHost() async {
        desktopHost = try? await client.rpc("desktop.status", field: "desktop", as: DesktopHostStatus.self)
    }

    /// Builds the desktop image if it is missing and starts the machine. Minutes, the
    /// first time — the timeout is sized for an apt-get, not a round trip.
    func prepareDesktopHost() async throws {
        desktopHost = try await client.rpc("desktop.prepare", field: "desktop", as: DesktopHostStatus.self, timeout: 20 * 60)
    }

    // MARK: - Desktop

    /// Every desktop call names its bot: a desktop belongs to one bot, so there is no
    /// "the" desktop to ask about.
    private var surfaceBotID: String? { selectedBot?.id }

    func refreshSurface() async {
        guard let botID = surfaceBotID else { return }
        guard let status = try? await client.rpc(
            "surface.status", ["botId": botID], field: "surface", as: SurfaceStatus.self
        ) else { return }
        surface = status
    }

    /// Brings up this bot's desktop, and does nothing if it is already up.
    ///
    /// Called wherever the screen becomes visible. A bot with a screen is meant to
    /// have one running — nobody should have to ask for it — and the daemon starts the
    /// same container on bot creation, so this is usually a confirmation.
    func startSurface() async {
        guard let botID = surfaceBotID else { return }
        if surface.state == .running { return }

        // Already on its way up — creating a bot warms its screen — so there is
        // nothing to ask for, only something to wait for.
        if surface.state != .starting {
            surface = SurfaceStatus(state: .starting, width: surface.width, height: surface.height)
            // Starting can wait on a container as well as a display, so allow well
            // past the default.
            if let status = try? await client.rpc(
                "surface.start", ["botId": botID], field: "surface", as: SurfaceStatus.self, timeout: 180
            ) {
                surface = status
            }
        }
        await waitWhileStarting()
    }

    /// Polls until a starting screen resolves.
    ///
    /// Nothing pushes surface state, so a client that arrives while a screen is coming
    /// up has to ask again — otherwise it sits on "Starting the desktop" forever while
    /// the screen has been running for a minute. The frame loop cannot cover this: it
    /// only pulls once the state already says running.
    private func waitWhileStarting() async {
        for _ in 0..<90 {
            guard surface.state == .starting else { return }
            try? await Task.sleep(for: .seconds(1))
            await refreshSurface()
        }
    }

    func stopSurface() async {
        guard let botID = surfaceBotID else { return }
        surfaceFrame = nil
        guard let status = try? await client.rpc(
            "surface.stop", ["botId": botID], field: "surface", as: SurfaceStatus.self, timeout: 60
        ) else { return }
        surface = status
    }

    /// Everyone currently showing the screen, and how often each needs a frame.
    ///
    /// Registered rather than started and stopped, because the two views hand over in
    /// an order nobody controls: SwiftUI runs the arriving view's `onAppear` before the
    /// departing view's `onDisappear`, so the panel's teardown was cancelling the
    /// stream the full-window view had just started — leaving the expanded desktop
    /// frozen on a single frame, which looked for all the world like broken input.
    /// With viewers counted, a handover in either order leaves one watcher standing.
    private var frameViewers: [UUID: Duration] = [:]

    /// Pull rather than push, and only while something is watching: a preview nobody
    /// is looking at should cost nothing, and the client asks again only once it has
    /// drawn the previous frame, so a slow link degrades to a lower rate instead of
    /// queueing frames it will never show.
    func beginFrames(_ viewer: UUID, interval: Duration = .milliseconds(500)) {
        frameViewers[viewer] = interval
        restartFrames()
    }

    func endFrames(_ viewer: UUID) {
        frameViewers.removeValue(forKey: viewer)
        restartFrames()
    }

    private func restartFrames() {
        frameTask?.cancel()
        frameTask = nil
        // The fastest watcher sets the pace; the others simply see fresher frames.
        guard let interval = frameViewers.values.min() else { return }

        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.surface.state == .running,
                   let botID = self.surfaceBotID,
                   let result = try? await self.client.rpc("surface.frame", ["botId": botID, "quality": 6]),
                   let base64 = result["jpeg"] as? String,
                   let data = Data(base64Encoded: base64) {
                    self.surfaceFrame = data
                    if let x = result["pointerX"] as? Double, let y = result["pointerY"] as? Double {
                        self.surfacePointer = CGPoint(x: x, y: y)
                    } else if let x = result["pointerX"] as? Int, let y = result["pointerY"] as? Int {
                        self.surfacePointer = CGPoint(x: x, y: y)
                    }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Puts the Mac's clipboard on the desktop and pastes it.
    ///
    /// The two clipboards are separate — one lives on this Mac, the other inside a
    /// container — so ⌘V has to carry the text across rather than being forwarded as a
    /// keystroke that would paste whatever the desktop already held.
    func pasteIntoSurface() async {
        #if os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        #else
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        #endif
        await sendSurfaceInput(["kind": "paste", "text": text])
    }

    /// Copies from the desktop onto the Mac's clipboard.
    ///
    /// Presses the desktop's own copy shortcut first, then reads what landed on its
    /// clipboard — there is no way to know what was selected without asking it to copy.
    func copyFromSurface() async {
        guard let botID = surfaceBotID else { return }
        await sendSurfaceInput(["kind": "key", "keys": ["ctrl+c"]])
        try? await Task.sleep(for: .milliseconds(250))
        guard let result = try? await client.rpc("surface.clipboard", ["botId": botID]),
              let text = result["text"] as? String, !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func sendSurfaceInput(_ input: [String: Any]) async {
        guard let botID = surfaceBotID else { return }
        try? await client.rpc("surface.input", ["botId": botID, "input": input])
    }

    // MARK: - Auth

    func refreshAuth() async {
        let profileId = currentProfileID
        guard let status = try? await client.rpc("auth.status", ["profileId": profileId], field: "auth", as: AuthStatus.self),
              profileId == currentProfileID else { return }
        auth = status
        if profileId == Profile.defaultID { coreConfigured = status.configured }
        authKnown = true
    }

    /// Drives `claude auth login` on the daemon's machine. Long-running: the user has
    /// to approve in a browser, so this can sit for minutes.
    func signInWithClaude() async throws {
        try await providerLogin("anthropic-claude")
        authKnown = true
    }

    func setApiKey(_ key: String) async throws {
        _ = try await providerSetApiKey("anthropic", key: key)
        authKnown = true
        await refreshAll()
    }

    func models(for provider: String) -> [ModelInfo] {
        modelsByProvider[provider] ?? []
    }

    func loadModels(for provider: String) async {
        guard let result = try? await client.rpc("models.list", ["provider": provider, "profileId": currentProfileID]) else { return }
        let raw = result["models"] ?? []
        let list = (try? JSONDecoder().decode(
            [ModelInfo].self, from: JSONSerialization.data(withJSONObject: raw)
        )) ?? []
        modelsByProvider[provider] = list

        if result["supportsSurface"] as? Bool ?? true {
            providersWithScreen.insert(provider)
        } else {
            providersWithScreen.remove(provider)
        }
    }

    func supportsScreen(_ provider: String) -> Bool { providersWithScreen.contains(provider) }

    /// Providers a new bot can actually be built on.
    /// In roster order, so the chips read vendor by vendor rather than alphabetically.
    var availableProviders: [String] {
        let configured = Set(auth.providers.filter { $0.value.configured }.keys)
        return ProviderInfo.all.map(\.id).filter { configured.contains($0) }
    }

    // MARK: - Providers beyond the first

    /// Signs a provider in through its vendor's CLI, on the Mac running the core.
    ///
    /// The browser opens there, not here — the credential belongs to the machine that
    /// holds the bots, which is the whole premise of the split.
    func providerLogin(_ provider: String) async throws {
        let status = try await client.rpc(
            "auth.providerLogin", ["provider": provider, "profileId": currentProfileID],
            field: "auth", as: AuthStatus.self, timeout: 360
        )
        auth = status
        if currentProfileID == Profile.defaultID { coreConfigured = status.configured }
        await refreshAll()
    }

    /// Connects a provider and reports what the check actually proved.
    ///
    /// The provider's own models are reloaded here rather than left to the next general
    /// refresh: a key that has just been accepted should put its models in the picker
    /// immediately, and waiting made a provider look like it offered only one.
    @discardableResult
    func providerSetApiKey(_ provider: String, key: String) async throws -> String? {
        let result = try await client.rpc(
            "auth.providerSetApiKey", ["provider": provider, "key": key, "profileId": currentProfileID], timeout: 90
        )
        if let raw = result["auth"],
           let decoded = try? JSONDecoder().decode(
               AuthStatus.self, from: JSONSerialization.data(withJSONObject: raw)
           ) {
            auth = decoded
            if currentProfileID == Profile.defaultID { coreConfigured = decoded.configured }
        }
        await loadModels(for: provider)
        await refreshAll()
        return result["verified"] as? String
    }

    func providerSignOut(_ provider: String) async {
        guard let status = try? await client.rpc(
            "auth.providerSignOut", ["provider": provider, "profileId": currentProfileID], field: "auth", as: AuthStatus.self
        ) else { return }
        auth = status
        if currentProfileID == Profile.defaultID { coreConfigured = status.configured }
    }

    func completeOnboarding() {
        onboardingDismissed = true
        markSetupComplete()
        notifier.requestAuthorizationIfNeeded()
    }

    private func markSetupComplete() {
        guard !hasCompletedSetup else { return }
        hasCompletedSetup = true
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    // MARK: - Loading

    func refreshAll() async {
        do {
            await refreshProfiles()
            let profileId = currentProfileID
            let listed = try await client.rpc("bots.list", ["profileId": profileId], field: "bots", as: [Bot].self)
            // The profile can have changed under a slow reply; a stale list is dropped.
            guard profileId == currentProfileID else { return }
            bots = listed
            isLoadingBots = false
            let list = try await client.rpc("conversations.list", field: "conversations", as: [Conversation].self)
            conversations = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            errorMessage = nil

            await refreshSurface()

            if let settings = try? await client.rpc("settings.get"),
               let values = settings["settings"] as? [String: Any] {
                storedUserName = (values["userName"] as? String) ?? ""
            }

            await loadSharedMemories()
            await checkCoreUpdate()

            // A client that connects late still needs to see what is being waited on.
            if let pending = try? await client.rpc("handover.list", field: "handovers", as: [Handover].self) {
                handovers = Dictionary(uniqueKeysWithValues: pending.map { ($0.botId, $0) })
            }

            // Only providers with a working credential: the daemon answers with an
            // empty list otherwise, and an empty picker is worse than no picker.
            for (id, provider) in auth.providers where provider.configured {
                await loadModels(for: id)
            }

            let selectionStillValid = selectedBotID.map { id in bots.contains { $0.id == id } } ?? false
            if !selectionStillValid {
                // The Mac and the iPad show a thread beside the list; a phone starts
                // on the list, since the thread would cover it.
                if Self.startsOnThread, let first = bots.first { await select(bot: first.id) }
            } else if let convID = selectedConversationID {
                await loadMessages(convID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(bot botID: String) async {
        if let previous = selectedConversationID { client.unsubscribe(previous) }

        var conv = conversation(for: botID)
        if conv == nil { conv = await createConversation(botID: botID) }
        guard let conversation = conv else { return }

        selectedBotID = botID
        selectedConversationID = conversation.id
        messages = []
        routines = []
        memories = []
        isLoadingMessages = true
        client.subscribe(conversation.id)
        await loadMessages(conversation.id)
        await loadRoutines()
        await loadMemories()
    }

    /// What is running on the selected bot's behalf, and how far along it is.
    var runningRoutineName: String? {
        guard let id = selectedConversationID else { return nil }
        return busyRoutineNames[id]
    }

    // MARK: - Routines

    func loadRoutines() async {
        guard let botID = selectedBotID else { return }
        if let list = try? await client.rpc("routines.list", ["botId": botID], field: "routines", as: [Routine].self),
           botID == selectedBotID {
            routines = list
        }
    }

    func setRoutineEnabled(_ id: String, _ enabled: Bool) async {
        _ = try? await client.rpc("routines.setEnabled", ["id": id, "enabled": enabled])
        await loadRoutines()
    }

    func deleteRoutine(_ id: String) async {
        _ = try? await client.rpc("routines.delete", ["id": id])
        await loadRoutines()
    }

    // MARK: - Memory

    func loadMemories() async {
        guard let botID = selectedBotID else { return }
        if let list = try? await client.rpc("memory.list", ["botId": botID], field: "memories", as: [Memory].self),
           botID == selectedBotID {
            memories = list.filter { $0.scope == "bot" }
            sharedMemories = list.filter { $0.scope == "user" }
        }
    }

    func loadSharedMemories() async {
        if let list = try? await client.rpc("memory.list", field: "memories", as: [Memory].self) {
            sharedMemories = list.filter { $0.scope == "user" }
        }
    }

    /// The one note a person writes themselves: a fact about them, for every bot.
    func addSharedMemory(_ text: String) async {
        do {
            try await client.rpc("memory.add", ["text": text, "scope": "user"])
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadSharedMemories()
    }

    func updateMemory(_ id: String, _ text: String) async {
        do {
            try await client.rpc("memory.update", ["id": id, "text": text])
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadMemories()
        await loadSharedMemories()
    }

    func deleteMemory(_ id: String) async {
        _ = try? await client.rpc("memory.delete", ["id": id])
        await loadMemories()
        await loadSharedMemories()
    }

    func clearSelection() {
        if let id = selectedConversationID { client.unsubscribe(id) }
        selectedBotID = nil
        selectedConversationID = nil
        messages = []
    }

    private func createConversation(botID: String) async -> Conversation? {
        do {
            let conv = try await client.rpc(
                "conversations.create", ["botId": botID], field: "conversation", as: Conversation.self
            )
            conversations[conv.id] = conv
            return conv
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func loadMessages(_ conversationID: String) async {
        do {
            let list = try await client.rpc(
                "messages.list", ["conversationId": conversationID], field: "messages", as: [Message].self
            )
            guard selectedConversationID == conversationID else { return } // selection moved on
            messages = list
            isLoadingMessages = false
            errorMessage = nil
        } catch {
            isLoadingMessages = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = selectedConversationID, !trimmed.isEmpty else { return }
        do {
            try await client.rpc("messages.send", [
                "conversationId": conversationID,
                "blocks": [["type": "text", "text": trimmed]],
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard let id = selectedConversationID else { return }
        // Best-effort: the turn may have finished on its own.
        try? await client.rpc("messages.interrupt", ["conversationId": id])
    }

    func createBot(
        name: String,
        systemPrompt: String,
        provider: String = "anthropic",
        model: String,
        effort: Effort?,
        surfaceMode: SurfaceMode
    ) async {
        do {
            var params: [String: Any] = [
                "name": name,
                "systemPrompt": systemPrompt,
                "model": model,
                "provider": provider,
                "profileId": currentProfileID,
                "surfaceMode": surfaceMode.rawValue,
            ]
            if let effort { params["effort"] = effort.rawValue }
            let result = try await client.rpc("bots.create", params)
            if let botRaw = result["bot"],
               let data = try? JSONSerialization.data(withJSONObject: botRaw),
               let bot = try? JSONDecoder().decode(Bot.self, from: data) {
                bots.insert(bot, at: 0)
                if let convRaw = result["conversation"],
                   let convData = try? JSONSerialization.data(withJSONObject: convRaw),
                   let conv = try? JSONDecoder().decode(Conversation.self, from: convData) {
                    conversations[conv.id] = conv
                }
                await select(bot: bot.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateBot(_ id: String, patch: [String: Any]) async {
        do {
            let bot = try await client.rpc("bots.update", ["id": id, "patch": patch], field: "bot", as: Bot.self)
            if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBot(_ id: String) async {
        do {
            try await client.rpc("bots.delete", ["id": id])
            bots.removeAll { $0.id == id }
            conversations = conversations.filter { $0.value.botId != id }
            if selectedBotID == id {
                clearSelection()
                if let first = bots.first { await select(bot: first.id) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Events

    private func apply(_ event: RoutiClient.Event) {
        switch event.kind {
        case "message.created":
            guard let raw = event.payload["message"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let message = try? JSONDecoder().decode(Message.self, from: data),
                  message.conversationId == selectedConversationID
            else { return }
            // The daemon echoes our own sends back; replace rather than duplicate.
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }

        case "message.delta":
            guard event.payload["conversationId"] as? String == selectedConversationID,
                  let messageID = event.payload["messageId"] as? String,
                  let index = event.payload["blockIndex"] as? Int,
                  let delta = event.payload["delta"] as? [String: Any],
                  let text = delta["text"] as? String
            else { return }
            let isThinking = delta["type"] as? String == "thinking"
            mutateBlocks(messageID) { blocks in
                Self.pad(&blocks, to: index)
                switch (blocks[index], isThinking) {
                case (.text(let existing), false): blocks[index] = .text(existing + text)
                case (.thinking(let existing), true): blocks[index] = .thinking(existing + text)
                default: blocks[index] = isThinking ? .thinking(text) : .text(text)
                }
            }

        case "message.block":
            guard event.payload["conversationId"] as? String == selectedConversationID,
                  let messageID = event.payload["messageId"] as? String,
                  let index = event.payload["blockIndex"] as? Int,
                  let raw = event.payload["block"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let block = try? JSONDecoder().decode(Block.self, from: data)
            else { return }
            mutateBlocks(messageID) { blocks in
                Self.pad(&blocks, to: index)
                blocks[index] = block
            }

        case "conversation.busy":
            guard let id = event.payload["conversationId"] as? String,
                  let busy = event.payload["busy"] as? Bool else { return }
            if busy {
                busyConversations.insert(id)
                if let name = event.payload["routineName"] as? String { busyRoutineNames[id] = name }
            } else {
                busyConversations.remove(id)
                // A run just finished: its last-run and next-run times moved.
                if busyRoutineNames.removeValue(forKey: id) != nil, id == selectedConversationID {
                    Task { await loadRoutines() }
                }
            }

        case "conversation.updated":
            guard let raw = event.payload["conversation"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { return }
            conversations[conv.id] = conv

        case "bot.updated":
            guard let raw = event.payload["bot"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let bot = try? JSONDecoder().decode(Bot.self, from: data) else { return }
            // Another profile's bot is not on this screen.
            if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }

        case "core.update.progress":
            guard let line = event.payload["line"] as? String else { return }
            if event.payload["stage"] as? String == "failed" {
                finishCoreUpdate(line)
            } else {
                coreUpdateStage = line
            }

        case "routines.updated":
            // A bot saved or removed a routine mid-turn, or another device toggled one.
            guard event.payload["botId"] as? String == selectedBotID else { return }
            Task { await loadRoutines() }

        case "memory.updated":
            // The bot wrote or dropped a note mid-turn, or another device edited one.
            // A shared note carries no bot.
            let owner = event.payload["botId"] as? String
            if owner == nil {
                Task { await loadSharedMemories() }
            } else if owner == selectedBotID {
                Task { await loadMemories() }
            }

        case "message.completed":
            // Broadcast to every client, so this fires for conversations not on screen —
            // which is the case a notification is for. The watching check is the notifier's.
            guard let conversationId = event.payload["conversationId"] as? String,
                  event.payload["stopReason"] as? String != "error",
                  let botId = conversations[conversationId]?.botId,
                  let bot = bots.first(where: { $0.id == botId })
            else { return }
            let meta = event.payload["providerMeta"] as? [String: Any]
            notifier.botFinished(
                botId: bot.id,
                botName: bot.name,
                conversationId: conversationId,
                preview: event.payload["preview"] as? String,
                routineName: meta?["routineName"] as? String
            )

        case "handover.requested":
            if let raw = event.payload["handover"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let handover = try? JSONDecoder().decode(Handover.self, from: data) {
                handovers[handover.botId] = handover
                if let bot = bots.first(where: { $0.id == handover.botId }) {
                    notifier.botWaiting(
                        botId: bot.id, botName: bot.name,
                        conversationId: handover.conversationId, reason: handover.reason
                    )
                }
            }

        case "handover.resolved":
            if let botId = event.payload["botId"] as? String { handovers[botId] = nil }

        case "surface.state":
            // Desktops are per-bot and this event is broadcast, so anything about a
            // bot other than the one on screen is not ours to display.
            if let botID = event.payload["botId"] as? String, botID != selectedBot?.id { return }
            if let raw = event.payload["surface"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let status = try? JSONDecoder().decode(SurfaceStatus.self, from: data) {
                surface = status
            }

        case "error":
            let text = event.payload["message"] as? String
            if let conversationID = event.payload["conversationId"] as? String, let text {
                conversationErrors[conversationID] = text
            } else {
                errorMessage = text
            }

        default:
            break
        }
    }

    private func mutateBlocks(_ messageID: String, _ mutate: (inout [Block]) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(&messages[index].blocks)
    }

    /// Providers address blocks by index and may skip ahead; keep the array dense.
    private static func pad(_ blocks: inout [Block], to index: Int) {
        while blocks.count <= index { blocks.append(.text("")) }
    }
}
