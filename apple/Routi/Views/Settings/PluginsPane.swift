import SwiftUI

struct PluginsPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect services and choose which bots can use them.")
                    .foregroundStyle(.secondary)
                ForEach(PluginInfo.all) { plugin in PluginRow(plugin: plugin) }
            }.padding(24)
        }.navigationTitle("Plugins")
    }
}

private struct PluginRow: View {
    let plugin: PluginInfo
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var loadedProfileID: String?
    @State private var status: PluginStatus?
    @State private var error: String?
    @State private var refreshError: String?
    @State private var busy = false
    @State private var showingDisconnectAlert = false
    @State private var callbackURL = ""
    @State private var loginURL: URL?

    private var pluginLogo: some View {
        Image(plugin.asset)
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                detail
            } label: {
                HStack(spacing: 14) {
                    pluginLogo
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.name).font(.headline)
                        Text(plugin.summary)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let status {
                            Text(status.connected
                                 ? "\(status.accountEmail ?? "Connected") · \(status.botIds.count) \(status.botIds.count == 1 ? "bot" : "bots") with access"
                                 : status.connecting ? "Connecting…" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if status?.connected == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("Connected")
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            if let refreshError {
                Text(refreshError).foregroundStyle(.red)
                Button("Retry") { Task { await refresh(profileID: model.currentProfileID) } }
            }
        }
        .task(id: model.currentProfileID) { await pollStatus() }
    }

    private var detail: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    pluginLogo
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.name).font(.title2.bold())
                        Text(plugin.summary)
                            .foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Connection") {
                Text("Connect your \(plugin.name) account for selected bots. \(plugin.accessDescription)")
                    .foregroundStyle(.secondary)
                if let status {
                    Label(status.connected ? "Connected" : "Not connected", systemImage: status.connected ? "checkmark.circle.fill" : "link")
                    if status.connected, let email = status.accountEmail {
                        Text(email).textSelection(.enabled)
                    } else if status.connected, plugin.id != "robinhood" {
                        Text("Email unavailable. Reconnect to allow Routi to identify this Google account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(status.connected ? "Reconnect" : "Connect") {
                            perform { profileID in
                                let result = try await model.pluginAction(plugin.id, "connect", profileID: profileID)
                                guard let text = result["url"] as? String, let url = URL(string: text) else { return }
                                loginURL = url
                                openURL(url)
                            }
                        }
                        if status.connected || status.connecting {
                            Button(status.connected ? "Disconnect" : "Cancel login", role: .destructive) {
                                if status.connected { showingDisconnectAlert = true }
                                else { disconnect() }
                            }
                        }
                    }
                    .disabled(busy)
                    if status.connecting {
                        Text("Waiting for \(plugin.name) sign-in…")
                        if let loginURL { Link("Open sign-in again", destination: loginURL) }
                        DisclosureGroup("Connecting to a core on another Mac?") {
                            Text("Complete sign-in in a desktop browser. If the browser cannot open the final localhost address, copy that full address and paste it here.")
                                .font(.caption).foregroundStyle(.secondary)
                            SecureField("Callback URL", text: $callbackURL)
                            Button("Finish connection") {
                                perform { profileID in
                                    _ = try await model.pluginAction(plugin.id, "finish", profileID: profileID, params: ["callbackUrl": callbackURL])
                                    callbackURL = ""
                                    loginURL = nil
                                }
                            }.disabled(busy || callbackURL.isEmpty)
                        }
                    }
                    if let message = error ?? refreshError ?? status.error {
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                } else if let error = error ?? refreshError {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await refresh(profileID: model.currentProfileID) } }
                } else { ProgressView() }
            }
            if let status, status.connected {
                Section("Bots with access") {
                    Text("\(plugin.accessDescription) Disabling access stops future requests; it does not undo completed actions.")
                        .font(.caption).foregroundStyle(.secondary)
                    if status.botIds.isEmpty { Text("No bots have access yet.").foregroundStyle(.secondary) }
                    ForEach(model.bots.filter { status.botIds.contains($0.id) }) { bot in
                        botAccessRow(bot, status: status)
                    }
                }
                Section("Add bot access") {
                    if model.bots.isEmpty { Text("Create a bot to enable \(plugin.name) access.") }
                    ForEach(model.bots.filter { !status.botIds.contains($0.id) }) { bot in
                        botAccessRow(bot, status: status)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
        .alert("Disconnect \(plugin.name)?", isPresented: $showingDisconnectAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { disconnect() }
        } message: {
            Text("This removes this profile’s saved login and bot access in Routi. \(plugin.name) may still show Routi as connected. To revoke authorization too, remove it in your account’s connected-app settings.")
        }
        .onChange(of: model.currentProfileID) { showingDisconnectAlert = false }
        .task(id: model.currentProfileID) { await pollStatus() }
    }

    private func disconnect() {
        perform { profileID in
            _ = try await model.pluginAction(plugin.id, "disconnect", profileID: profileID)
            loginURL = nil
            callbackURL = ""
        }
    }

    private func botAccessRow(_ bot: Bot, status: PluginStatus) -> some View {
        Toggle(isOn: Binding(
            get: { status.botIds.contains(bot.id) },
            set: { enabled in
                perform { profileID in
                    _ = try await model.pluginAction(plugin.id, "enable", profileID: profileID, params: ["botId": bot.id, "enabled": enabled])
                }
            }
        )) {
            HStack(spacing: 10) {
                BotAvatar(color: bot.color, seed: bot.id, size: 28)
                Text(bot.name)
            }
        }.disabled(busy)
    }

    @MainActor private func pollStatus() async {
        let profileID = model.currentProfileID
        if loadedProfileID != profileID {
            loadedProfileID = profileID
            status = nil
            error = nil
            refreshError = nil
            loginURL = nil
            callbackURL = ""
        }
        while !Task.isCancelled {
            await refresh(profileID: profileID)
            do { try await Task.sleep(for: .seconds(status?.connecting == true ? 2 : 10)) } catch { return }
        }
    }

    @MainActor private func refresh(profileID: String) async {
        do {
            let latest = try await model.pluginStatus(plugin.id, profileID: profileID)
            guard profileID == model.currentProfileID, !Task.isCancelled else { return }
            status = latest
            refreshError = nil
            if !latest.connecting { loginURL = nil; callbackURL = "" }
        } catch {
            guard profileID == model.currentProfileID, !Task.isCancelled else { return }
            refreshError = error.localizedDescription
        }
    }

    private func perform(_ action: @escaping @MainActor (String) async throws -> Void) {
        let profileID = model.currentProfileID
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action(profileID) }
            catch { if profileID == model.currentProfileID { self.error = error.localizedDescription } }
            await refresh(profileID: profileID)
        }
    }
}
