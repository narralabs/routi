#if os(macOS)
import SwiftUI

struct ConnectStatus: Decodable {
    let configured: Bool
    let url: String
    let enabled: Bool
    let state: String
    let error: String?

    var indicator: (label: String, color: Color) {
        switch state {
        case "connected": ("Connected", .green)
        case "connecting": ("Connecting…", .orange)
        case "reconnecting": ("Reconnecting…", .orange)
        case "rejected", "error": ("Connection failed", .red)
        default: ("Disconnected", .secondary)
        }
    }
}

struct ConnectSettings: View {
    @Environment(AppModel.self) private var model
    @State private var status: ConnectStatus?
    @State private var address = ""
    @State private var error: String?
    @State private var refreshError: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            // Only provisioned pilot installations have a usable connection to configure.
            if let status, status.configured || status.enabled {
                SettingsSection(
                    "Routi Connect",
                    footnote: "Pilot connection to this Mac. Device pairing, chat, and desktop access are not available yet."
                ) {
                    SettingsRow(title: "Relay connection", isFirst: true) {
                        let available = model.connection == .connected && refreshError == nil
                        let label = available ? status.indicator.label : "Core unavailable"
                        Circle()
                            .fill(available ? status.indicator.color : .red)
                            .frame(width: 7, height: 7)
                            .help(label)
                            .accessibilityLabel(label)
                    }
                    SettingsRow(title: "Relay address") {
                        TextField("wss://connect.routibot.com", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Relay address")
                            .disabled(status.enabled || busy)
                    }
                    if let message = error ?? refreshError ?? status.error {
                        Text(message).font(.caption).foregroundStyle(.red).padding(14)
                    }
                    SettingsRow(title: "") {
                        Button(status.enabled ? "Disconnect" : "Connect") {
                            Task { await configure(status) }
                        }
                        .disabled(busy || model.connection != .connected)
                    }
                }
            }
        }
        .task(id: model.connection) {
            if model.connection == .connected { await refresh() }
        }
    }

    private func refresh() async {
        while !Task.isCancelled {
            do {
                let latest = try await model.connectStatus()
                if status == nil || latest.enabled { address = latest.url }
                status = latest
                refreshError = nil
                if !latest.configured && !latest.enabled { return }
            } catch {
                refreshError = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func configure(_ previous: ConnectStatus) async {
        busy = true
        defer { busy = false }
        do {
            let latest = try await model.configureConnect(url: previous.enabled ? previous.url : address, enabled: !previous.enabled)
            status = latest
            address = latest.url
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
#endif
