#if os(iOS)
import SwiftUI

struct ConnectSubscriptionView: View {
    @Environment(ConnectSubscription.self) private var subscription
    let profile: RelayProfile

    var body: some View {
        VStack(spacing: 24) {
            if let billing = subscription.access?.billing {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(billing.subscribed ? "Connect is active" : "Routi Connect")
                            .font(.headline)
                        Label(profile.name, systemImage: "laptopcomputer")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 12) {
                        if billing.subscribed {
                            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                                Text("Manage Subscription").frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .buttonStyle(.borderedProminent)
                        } else if let product = subscription.product {
                            Button {
                                Task { await subscription.purchase(profile) }
                            } label: {
                                Text("Subscribe · \(product.displayPrice)/month")
                                    .frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Text("Subscriptions are currently unavailable.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Try again") { Task { await subscription.refresh(profile) } }
                                .frame(minHeight: 44)
                        }
                        Button {
                            Task { await subscription.restore(profile) }
                        } label: {
                            Text("Restore Purchases").frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    if let message = subscription.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08), lineWidth: 1)
                }

                VStack(spacing: 8) {
                    if !billing.subscribed {
                        Text("Renews monthly until canceled. Manage or cancel in your Apple Account settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 24) {
                        Link(destination: URL(string: "https://routibot.com/privacy")!) {
                            Text("Privacy").frame(minWidth: 44, minHeight: 44)
                        }
                        Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                            Text("Terms").frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
            } else if let message = subscription.message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .disabled(subscription.busy)
        .task(id: profile.token) { await subscription.refresh(profile) }
    }
}
#endif
