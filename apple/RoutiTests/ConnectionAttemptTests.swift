import XCTest
import Network
@testable import Routi_Bot

@MainActor
final class ConnectionAttemptTests: XCTestCase {
    func testUnresponsiveMacTimesOutAndWaitsForAnotherExplicitAttempt() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "manualCoreConnection")
        defaults.set(true, forKey: "manualCoreConnection")
        defer { defaults.set(previous, forKey: "manualCoreConnection") }

        // Accept TCP but never finish the WebSocket handshake.
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "Listening")
        var sockets: [NWConnection] = []
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                sockets.append(connection)
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); sockets.forEach { $0.cancel() } }
        await fulfillment(of: [listening], timeout: 3)
        let client = RoutiClient(host: "127.0.0.1", port: Int(try XCTUnwrap(listener.port).rawValue))
        defer { client.stop() }
        let timedOut = expectation(description: "Connection attempt ended")
        client.onStateChange = { if $0 == .disconnected { timedOut.fulfill() } }
        let started = Date()
        client.connectNow()
        await fulfillment(of: [timedOut], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2.8)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)

        let automaticRetry = expectation(description: "No automatic retry")
        automaticRetry.isInverted = true
        client.onStateChange = { if $0 == .connecting { automaticRetry.fulfill() } }
        await fulfillment(of: [automaticRetry], timeout: 2)
        XCTAssertEqual(client.state, .disconnected)

        var attempts = 0
        client.onStateChange = { if $0 == .connecting { attempts += 1 } }
        client.connectNow()
        client.connectNow()
        XCTAssertEqual(client.state, .connecting)
        XCTAssertEqual(attempts, 1, "Retry must not start overlapping attempts")
    }
}
