import XCTest
import StoreKit
import StoreKitTest
@testable import Routi_Bot

private final class BillingProtocol: URLProtocol, @unchecked Sendable {
    static var accountToken = UUID()
    static var subscribed = false
    static var rejectClaim = false
    static var claims = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let claim = request.url!.path == "/v1/subscription"
        if claim { Self.claims += 1; if !Self.rejectClaim { Self.subscribed = true } }
        let rejected = claim && Self.rejectClaim
        let body: [String: Any] = rejected
            ? ["error": "This subscription covers another Mac. Restore it on that Mac."]
            : ["expired": !Self.subscribed, "billing": ["productId": ConnectSubscription.productId,
                "appAccountToken": Self.accountToken.uuidString, "subscribed": Self.subscribed]]
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 409 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ConnectSubscriptionTests: XCTestCase {
    func testPurchaseRestoreAndWrongMac() async throws {
        let store = try SKTestSession(configurationFileNamed: "Connect")
        store.disableDialogs = true
        store.clearTransactions()
        defer { store.clearTransactions() }
        BillingProtocol.accountToken = UUID()
        BillingProtocol.subscribed = false
        BillingProtocol.rejectClaim = false
        BillingProtocol.claims = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BillingProtocol.self]
        let profile = RelayProfile(relay: "wss://relay.example", token: String(repeating: "x", count: 43),
            certificate: Data(), pkcs12: Data(), name: "Test Mac")
        let billing = ConnectSubscription(configuration: config)
        await billing.refresh(profile)
        _ = try XCTUnwrap(billing.product, billing.message ?? "StoreKit returned no product")
        await billing.purchase(profile)
        XCTAssertNil(billing.message)
        XCTAssertEqual(billing.access?.billing?.subscribed, true)
        XCTAssertEqual(BillingProtocol.claims, 1)
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { XCTFail("Unverified transaction"); continue }
            XCTAssertEqual(transaction.appAccountToken, BillingProtocol.accountToken)
        }
        // Another install restores the existing purchase; it doesn't charge again.
        let restored = ConnectSubscription(configuration: config)
        await restored.refresh(profile)
        await restored.restore(profile)
        XCTAssertEqual(restored.access?.billing?.subscribed, true)
        XCTAssertNil(restored.message)
        XCTAssertEqual(store.allTransactions().count, 1)
        // The server binding, rather than local StoreKit ownership, decides which Mac is covered.
        BillingProtocol.rejectClaim = true
        BillingProtocol.subscribed = false
        await restored.refresh(profile)
        await restored.purchase(profile)
        XCTAssertEqual(restored.access?.billing?.subscribed, false)
        XCTAssertTrue(restored.message?.contains("another Mac") == true)
        XCTAssertEqual(store.allTransactions().count, 1)
    }
}
