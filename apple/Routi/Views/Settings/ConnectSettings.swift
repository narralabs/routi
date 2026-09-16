#if os(macOS)
import SwiftUI
import CoreImage.CIFilterBuiltins

struct ConnectStatus: Decodable {
    let canPair: Bool
    struct Device: Decodable, Identifiable { let id: String; let name: String; let createdAt: Double }
    let devices: [Device]
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
    @State private var pairingCode: String?
    @State private var pairingExpiresAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            // Only provisioned pilot installations have a usable connection to configure.
            if let status, status.configured || status.enabled {
                SettingsSection(
                    "Routi Connect",
                    footnote: "Chat from your paired phone without Tailscale. Desktop viewing still requires a direct connection."
                ) {
                    SettingsRow(title: "Relay connection", isFirst: true) {
                        let available = model.connection == .connected && refreshError == nil
                        let label = available ? status.indicator.label : "Core unavailable"
                        HStack(spacing: 6) {
                            Circle()
                                .fill(available ? status.indicator.color : .red)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            SettingsValue(text: label)
                        }
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
                    if status.canPair {
                        SettingsRow(title: "Paired devices", detail: "Each device has its own access.") {
                            Button("Pair device") { Task { await pair() } }
                                .disabled(busy || status.state != "connected")
                        }
                        ForEach(status.devices) { device in
                            SettingsRow(title: device.name) {
                                Button("Revoke") { Task { await revoke(device.id) } }.disabled(busy)
                            }
                        }
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
        .sheet(isPresented: Binding(get: { pairingCode != nil }, set: { if !$0 { cancelPairing() } })) {
            VStack(spacing: 18) {
                Text("Pair a device").font(.title2.bold())
                Text("On your iPhone or iPad, choose Scan pairing code in Routi Bot, then scan this code and confirm.")
                    .multilineTextAlignment(.center)
                if let pairingCode, let image = qrCode(pairingCode) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 320, height: 320)
                }
                Text("Valid for five minutes. Your other paired devices stay connected.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { cancelPairing() }
            }.padding(28).frame(width: 410)
            .task {
                guard let pairingExpiresAt else { return }
                try? await Task.sleep(for: .seconds(max(0, pairingExpiresAt.timeIntervalSinceNow)))
                if !Task.isCancelled { cancelPairing() }
            }
        }
        .task(id: model.connection) {
            if model.connection == .connected { await refresh() }
        }
    }

    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    private func pair() async {
        busy = true
        defer { busy = false }
        do {
            let code = try await model.pairPhone()
            pairingExpiresAt = Date(timeIntervalSince1970: code.expiresAt / 1000)
            pairingCode = code.url
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func cancelPairing() {
        pairingCode = nil
        Task { try? await model.cancelPhonePairing() }
    }

    private func revoke(_ id: String) async {
        busy = true
        defer { busy = false }
        do { try await model.revokeDevice(id); status = try await model.connectStatus(); error = nil }
        catch { self.error = error.localizedDescription }
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
