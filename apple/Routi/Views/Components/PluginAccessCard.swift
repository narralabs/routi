import SwiftUI

struct PluginAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let request: PluginAccessRequest
    var onRequestChanges: () -> Void = {}
    @State private var busy = false
    @State private var error: String?
    @State private var loginURL: URL?
    @State private var callbackURL = ""

    private var plugin: PluginInfo { PluginInfo.find(request.pluginId ?? "robinhood") ?? PluginInfo.all[0] }
    private var botName: String { model.bots.first { $0.id == request.botId }?.name ?? "This bot" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.action.map { "\($0.title)?" } ?? "\(plugin.name) access", systemImage: "link")
                .font(.headline)
            if let action = request.action {
                Text("\(botName) · \(plugin.name)").foregroundStyle(.secondary)
                if let details = action.details {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(detail.label).font(.caption).foregroundStyle(.secondary)
                                        #if os(macOS)
                                        .onContinuousHover { phase in
                                            if case .active = phase { NSCursor.arrow.set() }
                                        }
                                        #endif
                                    Text(detail.value).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }.frame(maxHeight: 340)
                } else {
                    Text("Couldn’t load the details. Ask the bot to try again.")
                }
                Text("This approves only this action.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(request.connected
                     ? "Allow \(botName) to use your \(plugin.name) connection?"
                     : "Connect \(plugin.name) for \(botName)")
                Text("\(plugin.accessDescription) Access applies to this bot only and can be removed in Plugins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if request.connecting {
                Text("Waiting for \(plugin.name) sign-in…").font(.callout)
                if let loginURL { Link("Open sign-in again", destination: loginURL) }
                DisclosureGroup("Signing in from another computer?") {
                    Text("After signing in, paste the final localhost address here if the browser cannot open it.")
                        .font(.caption)
                    SecureField("Callback URL", text: $callbackURL)
                    Button("Finish connection") {
                        perform {
                            _ = try await model.pluginAction(plugin.id, "finish", profileID: request.profileId, params: ["callbackUrl": callbackURL])
                            callbackURL = ""
                        }
                    }.disabled(busy || callbackURL.isEmpty)
                }
            }
            HStack {
                if !request.connecting {
                    Button((request.action?.isEmailSend == true ? "Send" : request.action?.title) ?? (request.connected ? "Allow" : "Connect")) {
                        perform {
                            let result = try await model.pluginAction(plugin.id, "access.respond", profileID: request.profileId, params: ["id": request.id, "allow": true])
                            if let text = result["url"] as? String, let url = URL(string: text) {
                                loginURL = url
                                openURL(url)
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                    .disabled(request.action != nil && request.action?.details == nil)
                }
                if request.action != nil {
                    Button("Request changes") {
                        perform {
                            _ = try await model.pluginAction(plugin.id, "access.respond", profileID: request.profileId, params: ["id": request.id, "allow": false])
                            onRequestChanges()
                        }
                    }
                }
                Button("Not now") {
                    perform {
                        _ = try await model.pluginAction(plugin.id, "access.respond", profileID: request.profileId, params: ["id": request.id, "allow": false])
                    }
                }
            }
            .disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary).allowsHitTesting(false) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
            await model.refreshPluginAccess()
        }
    }
}
