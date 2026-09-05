import Foundation

/// WebSocket client for krogd, on `URLSessionWebSocketTask` — no third-party
/// dependency needed.
///
/// The phone drops this socket every time it backgrounds, so reconnect is a
/// first-class path rather than an error case: on reconnect we re-subscribe to
/// whatever we were watching and refetch.
@MainActor
final class KrogClient: NSObject {
    enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    struct RPCError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// A decoded server event, kept as raw JSON so the model layer decodes only the
    /// shapes it cares about.
    struct Event {
        let kind: String
        let payload: [String: Any]
    }

    static let protocolVersion = 1

    private(set) var state: ConnectionState = .disconnected {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    private(set) var account: AccountInfo?

    var onStateChange: ((ConnectionState) -> Void)?
    var onEvent: ((Event) -> Void)?
    /// Fires on every handshake so the app knows whether to onboard immediately,
    /// without waiting for a follow-up round trip.
    var onAuthStatus: ((AuthStatus) -> Void)?

    private var host: String
    private var port: Int
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var subscriptions: Set<String> = []
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var isStopped = false

    init(host: String = "127.0.0.1", port: Int = 7171) {
        self.host = host
        self.port = port
        super.init()
        self.session = URLSession(configuration: .default)
    }

    func updateEndpoint(host: String, port: Int) {
        guard host != self.host || port != self.port else { return }
        self.host = host
        self.port = port
        reconnect(immediately: true)
    }

    // MARK: - Lifecycle

    func connect() {
        guard !isStopped, state == .disconnected else { return }
        state = .connecting

        guard let url = URL(string: "ws://\(host):\(port)") else {
            state = .disconnected
            return
        }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)

        send([
            "t": "hello",
            "protocolVersion": Self.protocolVersion,
            "clientName": "Krog",
            "platform": Self.platformName,
        ])
    }

    func stop() {
        isStopped = true
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private static var platformName: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receiveLoop(task)
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleDisconnect() {
        guard state != .disconnected else { return }
        task = nil
        state = .disconnected

        // Fail every in-flight RPC rather than leaving callers hung.
        for (_, cont) in pending {
            cont.resume(throwing: RPCError(code: "disconnected", message: "Lost connection to krogd."))
        }
        pending.removeAll()

        guard !isStopped else { return }
        reconnect(immediately: false)
    }

    private func reconnect(immediately: Bool) {
        reconnectTask?.cancel()
        if immediately {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            state = .disconnected
            attempt = 0
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if !immediately {
                // Capped exponential backoff with jitter.
                let n = min(await self.attempt + 1, 6)
                await MainActor.run { self.attempt = n }
                let base = min(0.5 * pow(2, Double(n - 1)), 15)
                let delay = base + Double.random(in: 0...0.4)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self.connect() }
        }
    }

    // MARK: - Messaging

    private func send(_ dict: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["t"] as? String
        else { return }

        switch type {
        case "hello_ok":
            attempt = 0
            if let accountDict = root["account"],
               let accountData = try? JSONSerialization.data(withJSONObject: accountDict) {
                account = try? JSONDecoder().decode(AccountInfo.self, from: accountData)
            }
            if let authRaw = root["auth"],
               let authData = try? JSONSerialization.data(withJSONObject: authRaw),
               let status = try? JSONDecoder().decode(AuthStatus.self, from: authData) {
                onAuthStatus?(status)
            }
            if let serverVersion = root["protocolVersion"] as? Int, serverVersion != Self.protocolVersion {
                // Surface loudly rather than failing later with confusing empty fields.
                onEvent?(Event(kind: "error", payload: [
                    "code": "protocol_mismatch",
                    "message": "krogd speaks protocol v\(serverVersion); this app speaks v\(Self.protocolVersion).",
                ]))
            }
            state = .connected
            for id in subscriptions {
                send(["t": "subscribe", "conversationId": id])
            }

        case "rpc_ok":
            guard let id = root["id"] as? String, let cont = pending.removeValue(forKey: id) else { return }
            cont.resume(returning: root["result"] as? [String: Any] ?? [:])

        case "rpc_err":
            guard let id = root["id"] as? String, let cont = pending.removeValue(forKey: id) else { return }
            let err = root["error"] as? [String: Any] ?? [:]
            cont.resume(throwing: RPCError(
                code: err["code"] as? String ?? "unknown",
                message: err["message"] as? String ?? "Request failed."
            ))

        case "event":
            guard let ev = root["event"] as? [String: Any], let kind = ev["e"] as? String else { return }
            onEvent?(Event(kind: kind, payload: ev))

        default:
            break
        }
    }

    // MARK: - RPC

    @discardableResult
    func rpc(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard state == .connected else {
            throw RPCError(code: "disconnected", message: "Not connected to krogd.")
        }
        let id = UUID().uuidString

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let cont = self?.pending.removeValue(forKey: id) else { return }
            cont.resume(throwing: RPCError(code: "timeout", message: "The daemon did not respond."))
        }

        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                send(["t": "rpc", "id": id, "method": method, "params": params])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)
            }
        }
    }

    /// Decodes an RPC result field straight into a Codable type.
    func rpc<T: Decodable>(
        _ method: String, _ params: [String: Any] = [:], field: String, as _: T.Type, timeout: TimeInterval = 120
    ) async throws -> T {
        let result = try await rpc(method, params, timeout: timeout)
        guard let raw = result[field] else {
            throw RPCError(code: "bad_response", message: "Missing '\(field)' in response to \(method).")
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func subscribe(_ conversationID: String) {
        subscriptions.insert(conversationID)
        send(["t": "subscribe", "conversationId": conversationID])
    }

    func unsubscribe(_ conversationID: String) {
        subscriptions.remove(conversationID)
        send(["t": "unsubscribe", "conversationId": conversationID])
    }
}
