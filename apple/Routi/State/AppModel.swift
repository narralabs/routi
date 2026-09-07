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
    /// Last failure per conversation, shown inline in that thread rather than only
    /// as an alert — an alert that fires while you are looking elsewhere is lost.
    var conversationErrors: [String: String] = [:]
    var connection: RoutiClient.ConnectionState = .disconnected
    var errorMessage: String?
    var isLoadingMessages = false

    /// Settings replaces the whole window rather than opening a panel, so its
    /// visibility is app state, not view state — the ⌘, menu command toggles it too.
    var isShowingSettings = false

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
        return !auth.configured || !onboardingDismissed
    }

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
                }
            }
        }
        client.onAuthStatus = { [weak self] status in
            guard let self else { return }
            self.auth = status
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
    }

    var account: AccountInfo? { client.account }
    var coreVersion: String? { client.serverVersion }

    /// Shown in the sidebar footer, and used by the daemon to greet the user by name
    /// when a bot is created.
    ///
    /// Stored on the daemon rather than in local defaults: the greeting is written
    /// server-side, and a name that lived only on this Mac would leave the phone — and
    /// every bot it created — addressing a stranger.
    var userName: String {
        if !storedUserName.isEmpty { return storedUserName }
        return account?.firstName ?? "Account"
    }

    private(set) var storedUserName = ""

    func setUserName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != storedUserName else { return }
        storedUserName = trimmed
        try? await client.rpc("settings.set", ["patch": ["userName": trimmed]])
    }

    var userInitials: String {
        let parts = userName.split(separator: " ")
        guard let first = parts.first else { return "?" }
        if parts.count == 1 { return String(first.prefix(1)).uppercased() }
        return (String(first.prefix(1)) + String(parts[parts.count - 1].prefix(1))).uppercased()
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
        await sendSurfaceInput(["kind": "paste", "text": text])
        #endif
    }

    /// Copies from the desktop onto the Mac's clipboard.
    ///
    /// Presses the desktop's own copy shortcut first, then reads what landed on its
    /// clipboard — there is no way to know what was selected without asking it to copy.
    func copyFromSurface() async {
        #if os(macOS)
        guard let botID = surfaceBotID else { return }
        await sendSurfaceInput(["kind": "key", "keys": ["ctrl+c"]])
        try? await Task.sleep(for: .milliseconds(250))
        guard let result = try? await client.rpc("surface.clipboard", ["botId": botID]),
              let text = result["text"] as? String, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    func sendSurfaceInput(_ input: [String: Any]) async {
        guard let botID = surfaceBotID else { return }
        try? await client.rpc("surface.input", ["botId": botID, "input": input])
    }

    // MARK: - Auth

    func refreshAuth() async {
        guard let status = try? await client.rpc("auth.status", field: "auth", as: AuthStatus.self) else { return }
        auth = status
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
        guard let result = try? await client.rpc("models.list", ["provider": provider]) else { return }
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
            "auth.providerLogin", ["provider": provider], field: "auth", as: AuthStatus.self, timeout: 360
        )
        auth = status
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
            "auth.providerSetApiKey", ["provider": provider, "key": key], timeout: 90
        )
        if let raw = result["auth"],
           let decoded = try? JSONDecoder().decode(
               AuthStatus.self, from: JSONSerialization.data(withJSONObject: raw)
           ) {
            auth = decoded
        }
        await loadModels(for: provider)
        await refreshAll()
        return result["verified"] as? String
    }

    func providerSignOut(_ provider: String) async {
        guard let status = try? await client.rpc(
            "auth.providerSignOut", ["provider": provider], field: "auth", as: AuthStatus.self
        ) else { return }
        auth = status
    }

    func signOut() async {
        guard let status = try? await client.rpc("auth.signOut", field: "auth", as: AuthStatus.self) else { return }
        auth = status
        onboardingDismissed = false
        bots = []
        conversations = [:]
        messages = []
        clearSelection()
    }

    func completeOnboarding() {
        onboardingDismissed = true
        markSetupComplete()
    }

    private func markSetupComplete() {
        guard !hasCompletedSetup else { return }
        hasCompletedSetup = true
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    // MARK: - Loading

    func refreshAll() async {
        do {
            bots = try await client.rpc("bots.list", field: "bots", as: [Bot].self)
            let list = try await client.rpc("conversations.list", field: "conversations", as: [Conversation].self)
            conversations = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            errorMessage = nil

            await refreshSurface()

            if let settings = try? await client.rpc("settings.get"),
               let values = settings["settings"] as? [String: Any] {
                storedUserName = (values["userName"] as? String) ?? ""
                // Self-healing: the greeting is written server-side, so a daemon that
                // has lost the name would address nobody. The client still knows it
                // from the Anthropic account, so push it back up.
                if storedUserName.isEmpty, let derived = account?.firstName, !derived.isEmpty {
                    await setUserName(derived)
                }
            }

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
                #if os(macOS)
                // The Mac always shows a thread; a phone starts on the list.
                if let first = bots.first { await select(bot: first.id) }
                #endif
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
        isLoadingMessages = true
        client.subscribe(conversation.id)
        await loadMessages(conversation.id)
        await loadRoutines()
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
            if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }

        case "handover.requested":
            if let raw = event.payload["handover"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let handover = try? JSONDecoder().decode(Handover.self, from: data) {
                handovers[handover.botId] = handover
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
