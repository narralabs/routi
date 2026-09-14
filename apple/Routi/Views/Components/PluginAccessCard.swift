import SwiftUI

struct PluginAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let request: PluginAccessRequest
    @State private var busy = false
    @State private var error: String?
    @State private var loginURL: URL?
    @State private var callbackURL = ""

    private var botName: String { model.bots.first { $0.id == request.botId }?.name ?? "This bot" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Robinhood access", systemImage: "link")
                .font(.headline)
            Text(request.connected
                 ? "Allow \(botName) to use your Robinhood connection?"
                 : "Connect Robinhood for \(botName)")
            Text("Includes account information and trading tools. Access applies to this bot only and can be removed in Plugins. Connecting does not place a trade.")
                .font(.caption).foregroundStyle(.secondary)
            if request.connecting {
                Text("Waiting for Robinhood sign-in…").font(.callout)
                if let loginURL { Link("Open sign-in again", destination: loginURL) }
                DisclosureGroup("Signing in from another computer?") {
                    Text("After signing in, paste the final localhost address here if the browser cannot open it.")
                        .font(.caption)
                    SecureField("Callback URL", text: $callbackURL)
                    Button("Finish connection") {
                        perform {
                            _ = try await model.robinhoodAction("finish", profileID: request.profileId, params: ["callbackUrl": callbackURL])
                            callbackURL = ""
                        }
                    }.disabled(busy || callbackURL.isEmpty)
                }
            }
            HStack {
                if !request.connecting {
                    Button(request.connected ? "Allow" : "Connect Robinhood") {
                        perform {
                            let result = try await model.robinhoodAction("access.respond", profileID: request.profileId, params: ["id": request.id, "allow": true])
                            if let text = result["url"] as? String, let url = URL(string: text) {
                                loginURL = url
                                openURL(url)
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                }
                Button("Not now") {
                    perform {
                        _ = try await model.robinhoodAction("access.respond", profileID: request.profileId, params: ["id": request.id, "allow": false])
                    }
                }
            }
            .disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary) }
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
