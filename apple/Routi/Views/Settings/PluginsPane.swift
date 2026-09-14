import SwiftUI

struct PluginsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var loadedProfileID: String?
    @State private var status: RobinhoodStatus?
    @State private var error: String?
    @State private var refreshError: String?
    @State private var busy = false
    @State private var callbackURL = ""
    @State private var loginURL: URL?

    private var pluginLogo: some View {
        Image("PluginRobinhood")
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect services and choose which bots can use them.")
                    .foregroundStyle(.secondary)
                NavigationLink {
                    detail
                } label: {
                    HStack(spacing: 14) {
                        pluginLogo
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Robinhood").font(.headline)
                            Text("Account information, market data, and trading")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let status {
                                Text(status.connected
                                     ? "Connected · \(status.botIds.count) \(status.botIds.count == 1 ? "bot" : "bots") with access"
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
            }.padding(24)
        }
        .navigationTitle("Plugins")
        .task(id: model.currentProfileID) { await pollStatus() }
    }

    private var detail: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    pluginLogo
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Robinhood").font(.title2.bold())
                        Text("Account information, market data, and trading")
                            .foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Connection") {
                Text("Connect your Robinhood account to give selected bots access to account information, market data, and trading tools.")
                    .foregroundStyle(.secondary)
                if let status {
                    Label(status.connected ? "Connected" : "Not connected", systemImage: status.connected ? "checkmark.circle.fill" : "link")
                    HStack {
                        Button(status.connected ? "Reconnect" : "Connect Robinhood") {
                            perform { profileID in
                                let result = try await model.robinhoodAction("connect", profileID: profileID)
                                guard let text = result["url"] as? String, let url = URL(string: text) else { return }
                                loginURL = url
                                openURL(url)
                            }
                        }
                        if status.connected || status.connecting {
                            Button(status.connected ? "Disconnect" : "Cancel login", role: .destructive) {
                                perform { profileID in
                                    _ = try await model.robinhoodAction("disconnect", profileID: profileID)
                                    loginURL = nil
                                    callbackURL = ""
                                }
                            }
                        }
                    }
                    .disabled(busy)
                    if status.connecting {
                        Text("Waiting for Robinhood sign-in…")
                        if let loginURL { Link("Open sign-in again", destination: loginURL) }
                        DisclosureGroup("Connecting to a core on another Mac?") {
                            Text("Complete sign-in in a desktop browser. If the browser cannot open the final localhost address, copy that full address and paste it here.")
                                .font(.caption).foregroundStyle(.secondary)
                            SecureField("Callback URL", text: $callbackURL)
                            Button("Finish connection") {
                                perform { profileID in
                                    _ = try await model.robinhoodAction("finish", profileID: profileID, params: ["callbackUrl": callbackURL])
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
                    Text("Enabled bots can use Robinhood, including placing trades when instructed. Disabling access stops future requests; it does not cancel orders already submitted.")
                        .font(.caption).foregroundStyle(.secondary)
                    if status.botIds.isEmpty { Text("No bots have access yet.").foregroundStyle(.secondary) }
                    ForEach(model.bots.filter { status.botIds.contains($0.id) }) { bot in
                        botAccessRow(bot, status: status)
                    }
                }
                Section("Add bot access") {
                    if model.bots.isEmpty { Text("Create a bot to enable Robinhood access.") }
                    ForEach(model.bots.filter { !status.botIds.contains($0.id) }) { bot in
                        botAccessRow(bot, status: status)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Robinhood")
        .task(id: model.currentProfileID) { await pollStatus() }
    }

    private func botAccessRow(_ bot: Bot, status: RobinhoodStatus) -> some View {
        Toggle(isOn: Binding(
            get: { status.botIds.contains(bot.id) },
            set: { enabled in
                perform { profileID in
                    _ = try await model.robinhoodAction("enable", profileID: profileID, params: ["botId": bot.id, "enabled": enabled])
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
            let latest = try await model.robinhoodStatus(profileID: profileID)
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
