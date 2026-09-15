#if os(macOS) && DEBUG
import SwiftUI

struct ConnectSettings: View {
    var body: some View {
        SettingsSection(
            "Routi Connect",
            footnote: "Securely connect to your bots when you’re away from your Mac. Coming soon."
        ) {
            SettingsRow(title: "Remote access", isFirst: true) {
                SettingsValue(text: "Coming Soon")
            }
            SettingsRow(
                title: "Relay address",
                detail: "Use Routi Connect or a relay you host yourself."
            ) {
                TextField("Relay address", text: .constant("wss://connect.routibot.com"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Relay address")
                    .disabled(true)
            }
        }
    }
}
#endif
