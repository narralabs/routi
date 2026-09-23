#if os(iOS)
import SwiftUI

struct ConnectSubscriptionView: View {
    @Environment(ConnectSubscription.self) private var subscription
    let profile: RelayProfile

    var body: some View {
        VStack(spacing: 12) {
            if let billing = subscription.access?.billing {
                if billing.subscribed {
                    Text("Connect is active for \(profile.name).")
                    Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                } else {
                    Text("Routi Connect for \(profile.name)").font(.headline)
                    Text("Remote access to this Mac from your iPhone and iPad.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let product = subscription.product {
                        Button("Subscribe · \(product.displayPrice)/month") {
                            Task { await subscription.purchase(profile) }
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Subscriptions are currently unavailable.").font(.caption)
                        Button("Try again") { Task { await subscription.refresh(profile) } }
                    }
                    Text("Renews monthly until canceled. Manage or cancel in your Apple Account settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Restore Purchases") { Task { await subscription.restore(profile) } }
                HStack {
                    Link("Privacy", destination: URL(string: "https://routibot.com/privacy")!)
                    Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                }.font(.caption)
            }
            if let message = subscription.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .disabled(subscription.busy)
        .task(id: profile.token) { await subscription.refresh(profile) }

    }
}
#endif
