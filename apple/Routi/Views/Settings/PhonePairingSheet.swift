import SwiftUI

struct PhonePairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let invitation: RelayInvitation
    #if os(iOS)
    @State private var deviceName = UIDevice.current.model
    #else
    @State private var deviceName = "Device"
    #endif
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if busy {
                VStack(spacing: 20) {
                    ProgressView().controlSize(.large)
                    Text("Pairing with \(invitation.name)…")
                        .font(.title2.bold())
                    Text("Setting up your secure connection.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Routi Connect")
                .interactiveDismissDisabled()
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(.tint)
                    Text("Connect to \(invitation.name)").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("Chat with your bots and use their desktops away from home, without Tailscale. Your messages stay encrypted between this device and your Mac.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Only continue if you scanned this code from your own Mac.").font(.callout)
                    TextField("Device name", text: $deviceName).textFieldStyle(.roundedBorder)
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    Button("Pair with this Mac") {
                        error = nil
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let profile = try await RelayPairing.claim(invitation, deviceName: deviceName)
                                try model.useRelay(profile)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.count > 80)
                    Spacer()
                }
                .padding(28)
                .navigationTitle("Routi Connect")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }
}

struct PhoneConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false
    @State private var error: String?

    var body: some View {
        SettingsSection("Routi Connect", footnote: "Chat and desktop viewing are encrypted between this device and your Mac through Routi Connect.") {
            SettingsRow(title: "Status", isFirst: true) {
                HStack(spacing: 6) {
                    Circle().fill(model.connection == .connected ? Color.green : .secondary).frame(width: 7, height: 7)
                    SettingsValue(text: model.connection == .connected ? "Connected" : model.connection == .connecting ? "Connecting…" : "Disconnected")
                }
            }
            SettingsRow(title: "Mac") { SettingsValue(text: model.pairedMacName ?? "Paired Mac") }
            SettingsRow(title: "") { Button("Forget this Mac") { confirmForget = true } }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(14) }
        }
        .alert("Forget this Mac?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                do { try model.forgetRelay() } catch { self.error = error.localizedDescription }
            }
        } message: { Text("You can reconnect by scanning a new pairing code on your Mac.") }
    }
}
