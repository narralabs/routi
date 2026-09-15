#if os(macOS)
import SwiftUI

struct ConnectSettings: View {
    @AppStorage("routiConnectRelayURL") private var relayURL = RelayAddress.defaultValue
    @State private var draft = RelayAddress.defaultValue

    private var normalized: String? { RelayAddress.normalize(draft) }

    var body: some View {
        SettingsSection(
            "Routi Connect",
            footnote: "Remote access is not available in this build. You can save an address now; connecting this Mac and pairing devices will follow in a future update."
        ) {
            SettingsRow(title: "Remote access", isFirst: true) {
                SettingsValue(text: "Off")
            }
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Relay address")
                    .font(.system(size: 13, weight: .medium))
                Text("Use Routi Connect or a relay you host yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField(RelayAddress.defaultValue, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Relay address")
                        .accessibilityIdentifier("connectRelayAddress")
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(normalized == nil || normalized == relayURL)
                        .accessibilityIdentifier("saveConnectRelayAddress")
                }
                if normalized == nil {
                    Text("Enter a wss:// address with a hostname and optional port, without a path, query, or sign-in details.")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                Button("Use default address") { draft = RelayAddress.defaultValue }
                    .buttonStyle(.link)
                    .disabled(draft == RelayAddress.defaultValue)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
        }
        .onAppear { draft = relayURL }
    }

    private func save() {
        guard let normalized else { return }
        relayURL = normalized
        draft = normalized
    }
}
#endif
