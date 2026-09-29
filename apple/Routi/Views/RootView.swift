import SwiftUI

/// One layout for all three devices.
///
/// Three columns, in the order they read on screen:
///
/// - **left main sidebar** — the bot list
/// - **main content** — the conversation
/// - **bot right sidebar** — that bot's screen and routines, hidden until asked for
///
/// The first two are a `NavigationSplitView`; the third is a fixed column beside the
/// chat. A three-column `NavigationSplitView` cannot hide its trailing column —
/// `columnVisibility` only ever reaches the leading ones — and `.inspector` inflated
/// the window's minimum width wherever it was attached (see `detail`).
///
/// `NavigationSplitView` does the adapting itself: columns on the Mac, a sidebar over
/// content on iPad, and a push-navigation stack on iPhone. That is the whole reason to
/// be native here — the responsive behaviour is the framework's job, not something
/// reconstructed with width breakpoints.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var subscription = ConnectSubscription()
    #endif
    @State private var showingRailSettings = false
    @State private var showingNewBot = false

    /// The bot right sidebar starts closed: most conversations never need the screen,
    /// and opening onto three columns makes the chat itself feel cramped.
    @State private var showBotSidebar = false

    var body: some View {
        @Bindable var model = model

        Group {
            if model.isSettling {
                // A first launch, for the few hundred milliseconds it takes the port
                // to answer or refuse. Nothing yet beats a screen that is replaced.
                Color.clear
            } else if model.needsOnboarding {
                // Setup comes first on a fresh install — before any connection, since
                // finding or installing a core is what setup is for.
                OnboardingView()
            } else if !model.authKnown {
                // Neither chat nor an error is correct until the handshake lands.
                ConnectingView()
            } else {
                #if os(macOS)
                if model.isShowingScreen {
                    ScreenWindow()
                } else {
                    main
                }
                #else
                // Keep the cover's presenter alive when isShowingScreen changes.
                main.modifier(PhoneConnectionCover())
                #endif
            }
        }
        #if DEBUG && os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { BuildStamp() }
        #endif
        .sheet(isPresented: Binding(
            get: { model.isShowingSettings },
            set: { model.isShowingSettings = $0 }
        )) {
            SettingsScreen()
                #if DEBUG && os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) { BuildStamp() }
                #endif
        }
        #if os(iOS)
        .environment(subscription)
        .task(id: model.relayAccess) {
            subscription = ConnectSubscription()
            if let profile = model.relayViewerProfile, let access = model.relayAccess {
                await subscription.observe(profile, access: access)
            }
        }
        .onChange(of: subscription.access?.billing?.subscribed) { _, paid in
            if paid == true { model.connectNow() }
        }
        #endif
        .animation(.snappy(duration: 0.3), value: model.needsOnboarding)
        .animation(.snappy(duration: 0.3), value: model.authKnown)
        .animation(.snappy(duration: 0.3), value: model.isSettling)
        .animation(.snappy(duration: 0.25), value: model.isShowingScreen)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.connectNow() }
        }
        .task {
            model.start()
            #if DEBUG
            // Straight to the desktop, for looking at it without tapping there.
            if ProcessInfo.processInfo.arguments.contains("-showScreen") {
                try? await Task.sleep(for: .seconds(3))
                if let botID = UserDefaults.standard.string(forKey: "previewBotID") {
                    await model.select(bot: botID)
                }
                model.isShowingScreen = true
            }
            #endif
        }
    }

    private var main: some View {
        @Bindable var model = model

        return NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisibility },
            // Governs the *left main sidebar* only. Refusing `.detailOnly` keeps the
            // bot list present — a divider dragged past it used to shut it for good.
            set: { model.sidebarVisibility = $0 == .detailOnly ? .doubleColumn : $0 }
        )) {
            BotListView(showingNewBot: $showingNewBot)
                // Down to a rail: below about 170pt the list drops its text and shows
                // avatars only, so a narrow window keeps every bot reachable.
                .navigationSplitViewColumnWidth(min: 76, ideal: 268, max: 360)
        } detail: {
            detail
        }
        #if !os(macOS)
        // Side by side on an iPad, in portrait too. The automatic style treats the
        // detail as prominent there and floats the sidebar over it, dimming the chat
        // behind; the toggle in the bar still hides the sidebar for anyone who wants
        // the room.
        .navigationSplitViewStyle(.balanced)
        #endif
        .sheet(isPresented: $showingNewBot) {
            NewBotSheet()
        }
        .sheet(isPresented: Binding(
            get: { model.isShowingNewProfile },
            set: { model.isShowingNewProfile = $0 }
        )) {
            NewProfileSheet()
        }
        #if !os(macOS)
        // Over the chat rather than in place of it: the navigation underneath keeps
        // its state, so closing the desktop lands back exactly where it was opened.
        .fullScreenCover(isPresented: Binding(
            get: { model.isShowingScreen },
            set: { model.isShowingScreen = $0 }
        )) {
            MobileScreen().modifier(PhoneConnectionCover())
        }
        #endif
        .sheet(isPresented: Binding(
            get: { model.isShowingPlugins },
            set: { model.isShowingPlugins = $0 }
        )) {
            NavigationStack {
                PluginsPane()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isShowingPlugins = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 640, height: 560)
            #endif
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.connection == .connected && model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }

    /// The chat, and beside it the bot right sidebar when asked for.
    ///
    /// A plain trailing column, not an `.inspector`. The inspector was tried in both
    /// places it can go — inside the detail column and on the split view — and each
    /// added hundreds of points to the window's minimum width that no content asked
    /// for (1189 with the panel open, against 464 without). A fixed 300pt column
    /// costs resizability nobody used and gives back a window that shrinks to what
    /// the chat and the panel actually need.
    @ViewBuilder
    private var detail: some View {
        @Bindable var model = model
            if let bot = model.selectedBot {
                HStack(spacing: 0) {
                    ChatView(bot: bot, showBotSidebar: $showBotSidebar)
                        .frame(minWidth: 340)
                    if showBotSidebar {
                        DetailRail(bot: bot, showingSettings: $showingRailSettings)
                            .frame(width: 300)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: showBotSidebar)
                .navigationSplitViewColumnWidth(min: 340, ideal: 760)
            } else if model.isLoadingBots {
                // The list is on its way; saying "no bots" now would be wrong for a
                // moment and then replaced, which reads as a flicker.
                ProgressView().controlSize(.small)
            } else if model.bots.isEmpty {
                // Nothing is seeded, so the first thing a new install shows is this,
                // with the one action that matters on it.
                ContentUnavailableView {
                    Label("No bots yet", systemImage: "sparkles")
                } description: {
                    Text("A bot is a personality, a model and a screen of its own. Make your first one.")
                } actions: {
                    Button("New Bot") { showingNewBot = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                ContentUnavailableView(
                    "No Bot Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a bot from the sidebar.")
                )
            }
    }
}

#if os(iOS)
/// Cover unavailable actions without discarding the chat's navigation or draft.
private struct PhoneConnectionCover: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let offline = model.connection != .connected || model.isLoadingBots
        content
            .allowsHitTesting(!offline)
            .accessibilityHidden(offline)
            .onChange(of: offline, initial: true) { _, offline in
                if offline {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .overlay {
                if offline {
                    ConnectingView(reconnecting: true)
                        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                }
            }
    }
}
#endif

/// Shown while a configured device cannot reach its Mac.
/// Retry or returning to the app starts a new attempt.
private struct ConnectingView: View {
    var reconnecting = false
    @Environment(AppModel.self) private var model
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @State private var slow = false
    #if os(iOS)
    @State private var showingScanner = false
    @State private var showingManualConnection = false
    @State private var pairingError: String?
    @AppStorage("manualCoreConnection") private var manualConnection = false
    #endif

    private var isLocal: Bool { host == "127.0.0.1" || host == "localhost" }

    var body: some View {
        Group {
            #if os(iOS)
            GeometryReader { geometry in
                ScrollView {
                    phoneContent(minHeight: max(0, geometry.size.height - 48))
                        .frame(maxWidth: 420)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                }
            }
            #else
            VStack(spacing: 14) {
                if model.connectionFailed {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(model.connectionMessage != nil ? "Routi Connect" : model.usesRelay ? "Can’t reach your paired Mac" : isLocal ? "Routi Core isn't running on this Mac" : "Can't reach Routi Core at \(host)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.connectionMessage ?? (model.usesRelay ? "Check that your Mac is awake, online, and connected to Routi Connect."
                         : isLocal
                         ? "The core keeps your bots and does the work, and normally starts at login. If it was removed, install it again with the command below; then click Try again."
                         : "Check that Mac is on, that Routi Core is running there, and that this device can see it — a Tailscale name works."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    if isLocal && !model.usesRelay {
                        InstallCommand()
                    }
                    Button("Try again") { model.connectNow() }
                        .disabled(model.connection == .connecting)
                    Button("Connect to a different Mac…") { model.isShowingSettings = true }
                        .controlSize(.small)
                        .padding(.top, 4)
                } else if slow {
                    ProgressView().controlSize(.large)
                    Text("Connecting to Routi Core…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(minWidth: 460, minHeight: 320)
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) { PhonePairingScanner() }
        .sheet(isPresented: $showingManualConnection) {
            EndpointStep(onBack: { showingManualConnection = false }, onConnected: { showingManualConnection = false })
        }
        .alert("Could not remove pairing", isPresented: Binding(get: { pairingError != nil }, set: { if !$0 { pairingError = nil } })) {
            Button("OK") { pairingError = nil }
        } message: { Text(pairingError ?? "") }
        #endif
        .animation(.snappy(duration: 0.25), value: model.connectionFailed)
        .task {
            // A local core answers before a spinner could be seen; only a wait that
            // is actually felt — a remote host, a slow network — gets one.
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            slow = true
        }
    }

    #if os(iOS)
    private func phoneContent(minHeight: CGFloat) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            VStack(spacing: 20) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                if model.relayViewerProfile != nil || !manualConnection {
                    Text("Routi Connect").font(.largeTitle.bold())
                }
                if model.connection == .connected && model.isLoadingBots {
                    ProgressView().controlSize(.large)
                    Text("Loading your bots…").font(.title3.weight(.semibold))
                } else if let profile = model.relayViewerProfile {
                    if model.relayRevoked {
                        Text("This device’s access was revoked").font(.title3.weight(.semibold))
                        Text("Scan a new pairing code from your Mac to reconnect, or pair with another Mac.")
                            .foregroundStyle(.secondary)
                        Button("Pair a Mac") {
                            do {
                                try model.forgetRelay()
                                showingScanner = true
                            } catch { pairingError = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if model.connection == .connecting {
                        ProgressView().controlSize(.large)
                        Text(reconnecting ? "Reconnecting to \(profile.name)…" : "Connecting to \(profile.name)…")
                            .font(.title3.weight(.semibold))
                        Text(reconnecting ? "Your conversation will resume automatically." : "Opening your bots.").foregroundStyle(.secondary)
                    } else {
                        if model.relayAccess?.expired == true {
                            VStack(spacing: 12) {
                                Text("Connect access has ended").font(.title3.weight(.semibold))
                                Text("Your bots are still running on your Mac. Subscribe to access them from here.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 12)
                            ConnectSubscriptionView(profile: profile)
                        } else {
                            Text(model.relayAccess == nil ? "Connection unavailable" : "Can’t reach \(profile.name)")
                                .font(.title3.weight(.semibold))
                            Text(model.relayAccess == nil
                                 ? "Check your internet connection and try again."
                                 : "Make sure your Mac is awake, connected to the internet, and Routi Bot is running.")
                                .foregroundStyle(.secondary)
                            retryButton("Retry Routi Connect")
                        }
                    }
                } else if manualConnection {
                    Text(model.connection == .connecting && !model.connectionFailed ? "Reconnecting to your Mac…" : "Can’t reach \(host)")
                        .font(.title3.weight(.semibold))
                    Text("Make sure your Mac is awake, Routi Bot is running, and you’re connected to the same network or Tailscale.")
                        .foregroundStyle(.secondary)
                    retryButton("Try again")
                } else {
                    Text("Connect to your Mac").font(.title3.weight(.semibold))
                    Text("Use Routi Connect to chat with your bots and view their desktops from anywhere.")
                        .foregroundStyle(.secondary)
                    Text("On your Mac, open Settings → Routi Core → Routi Connect → Pair iPhone or iPad.")
                        .font(.callout)
                    Button { showingScanner = true } label: {
                        Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            Spacer(minLength: 40)
            VStack(spacing: 12) {
                Divider()
                Text("Other connection options")
                    .font(.footnote).foregroundStyle(.secondary)
                manualConnectionButton.font(.subheadline)
            }
        }
        .frame(minHeight: minHeight)
        .multilineTextAlignment(.center)
    }

    private func retryButton(_ title: String) -> some View {
        let connecting = model.connection == .connecting
        return Button { model.connectNow() } label: {
            ZStack {
                // Keep the button's size stable while its progress changes.
                Text(title).opacity(connecting ? 0 : 1)
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                }
                .opacity(connecting ? 1 : 0)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(connecting)
        .accessibilityLabel(connecting ? "Connecting" : title)
    }

    private var manualConnectionButton: some View {
        Button { showingManualConnection = true } label: {
            Text("Connect using Tailscale or IP address")
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("manualCoreConnection")
    }
    #endif
}
