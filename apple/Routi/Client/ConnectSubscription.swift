#if os(iOS)
import Foundation
import StoreKit

@MainActor @Observable
final class ConnectSubscription {
    static let productId = "com.routibot.connect.monthly"
    @ObservationIgnored private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    private(set) var access: ConnectAccess?
    private(set) var product: Product?
    private(set) var busy = false
    private(set) var message: String?

    private func request(_ profile: RelayProfile, signedPayload: String) async throws -> ConnectAccess {
        var url = URLComponents(string: profile.relay)!
        url.scheme = "https"
        url.path = "/v1/subscription"
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["signedPayload": signedPayload])
        // Reuse the relay's redirect rejection so credentials never follow redirects.
        let delegate = RelayTunnel(relay: URL(string: profile.relay)!, token: profile.token)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw PairingError(error ?? "Could not confirm Connect access. Please try again.")
        }
        return try JSONDecoder().decode(ConnectAccess.self, from: data)
    }

    func updateAccess(_ access: ConnectAccess?) async {
        self.access = access
        product = nil; message = nil
        do {
            if let billing = access?.billing {
                guard billing.productId == Self.productId else { throw PairingError("This relay does not offer Routi Connect subscriptions.") }
                product = try await Product.products(for: [billing.productId]).first
                if let product, product.type != .autoRenewable || (product.subscription?.subscriptionPeriod.value != 1 || product.subscription?.subscriptionPeriod.unit != .month) {
                    self.product = nil
                    throw PairingError("The Connect subscription is not configured correctly.")
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func submit(_ result: VerificationResult<Transaction>, profile: RelayProfile) async throws -> Bool {
        guard case .verified(let transaction) = result else { throw PairingError("Apple could not verify this purchase.") }
        guard transaction.productID == access?.billing?.productId else { return false }
        access = try await request(profile, signedPayload: result.jwsRepresentation)
        await transaction.finish()
        guard access?.billing?.subscribed == true else {
            throw PairingError("Connect access is still inactive. Check your Apple subscription status and try Restore Purchases.")
        }
        return true
    }

    func purchase(_ profile: RelayProfile) async {
        guard !busy, let product, let billing = access?.billing else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            // An existing subscription must be restored, never silently assigned to another Mac.
            for await result in Transaction.currentEntitlements {
                if case .verified(let tx) = result, tx.productID == product.id {
                    _ = try await submit(result, profile: profile)
                    return
                }
            }
            switch try await product.purchase(options: [.appAccountToken(billing.appAccountToken)]) {
            case .success(let result): _ = try await submit(result, profile: profile)
            case .pending: message = "Your purchase is awaiting Apple’s approval."
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore(_ profile: RelayProfile) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            for await result in Transaction.currentEntitlements {
                if try await submit(result, profile: profile) { return }
            }
            message = "No active Connect subscription was found for this Mac."
        } catch { message = error.localizedDescription }
    }

    func observe(_ profile: RelayProfile, access: ConnectAccess) async {
        await updateAccess(access)
        for await result in Transaction.currentEntitlements {
            if Task.isCancelled { return }
            if case .verified(let tx) = result, tx.appAccountToken == access.billing?.appAccountToken {
                do { _ = try await submit(result, profile: profile) }
                catch { message = error.localizedDescription }
            }
        }
        for await result in Transaction.updates {
            if Task.isCancelled { return }
            do { _ = try await submit(result, profile: profile) }
            catch { message = error.localizedDescription }
        }
    }
}
#endif
