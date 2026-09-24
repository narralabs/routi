import Foundation
import Network
import Security

struct ConnectAccess: Decodable, Equatable {
    struct Billing: Decodable, Equatable {
        let productId: String
        let appAccountToken: UUID
        let subscribed: Bool
    }
    let expired: Bool
    let billing: Billing?
}

/// Adapts an opaque relay WebSocket to a loopback byte stream. URLSession still
/// performs end-to-end TLS; this bridge only sees encrypted records.
final class RelayTunnel: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let relay: URL
    private let token: String
    private let configuration: URLSessionConfiguration
    private(set) var access: ConnectAccess?
    private let queue = DispatchQueue(label: "Routi.RelayTunnel")
    private var listener: NWListener?
    private var stopped = false
    private var pipes: [UUID: RelayPipe] = [:]
    private var session: URLSession?

    init(relay: URL, token: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.relay = relay
        self.token = token
        self.configuration = configuration
    }

    func checkAccess() async throws -> ConnectAccess? {
        var components = URLComponents(url: relay.appendingPathComponent("v1/access"), resolvingAgainstBaseURL: false)!
        components.scheme = relay.scheme == "wss" ? "https" : "http"
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let accessSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { accessSession.invalidateAndCancel() }
        let (data, response) = try await accessSession.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            return try JSONDecoder().decode(ConnectAccess.self, from: data)
        } else if [403, 404].contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
            // Older relay proxies authenticate on the WebSocket instead.
            return nil
        }
        throw URLError(.userAuthenticationRequired)
    }

    func start(pairing: Bool = false) async throws -> URL {
        access = try await checkAccess()
        if !pairing && access?.expired == true {
            throw NSError(domain: "RoutiConnect", code: 402, userInfo: [NSLocalizedDescriptionKey:
                "Connect access has ended."])
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        self.session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                        // Six WebKit asset connections plus chat and the VNC WebSocket.
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, !self.stopped, let session = self.session,
                                  self.pipes.count < 8 else { connection.cancel(); return }
                            let id = UUID()
                            let url = self.relay.appendingPathComponent("v1/sessions/\(id.uuidString)")
                            var request = URLRequest(url: url)
                            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
                            let socket = session.webSocketTask(with: request)
                            socket.maximumMessageSize = 1024 * 1024
                            let pipe = RelayPipe(connection: connection, socket: socket, queue: self.queue) { [weak self] in
                                self?.pipes.removeValue(forKey: id)
                            }
                            self.pipes[id] = pipe
                            pipe.start()
                        }
                        listener.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                listener.stateUpdateHandler = nil
                                continuation.resume(returning: URL(string: "https://127.0.0.1:\(listener.port!.rawValue)")!)
                            case .failed(let error):
                                listener.stateUpdateHandler = nil
                                continuation.resume(throwing: error)
                            case .cancelled:
                                listener.stateUpdateHandler = nil
                                continuation.resume(throwing: CancellationError())
                            default: break
                            }
                        }
                        listener.start(queue: self.queue)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            for pipe in Array(self.pipes.values) { pipe.stop() }
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class RelayPipe: @unchecked Sendable {
    let connection: NWConnection
    let socket: URLSessionWebSocketTask
    let queue: DispatchQueue
    let onClose: () -> Void
    private var stopped = false
    private var ready = false

    init(connection: NWConnection, socket: URLSessionWebSocketTask, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.connection = connection; self.socket = socket; self.queue = queue; self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        connection.start(queue: queue)
        socket.resume()
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, case .success(.string("{\"type\":\"ready\"}")) = result else { self.stop(); return }
                self.ready = true
                self.readLocal()
                self.readRelay()
            }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            // URLSession's TLS handshake has its own timeout; this bounds a relay
            // that never completes its ready exchange.
            if self?.ready == false { self?.stop() }
        }
    }

    private func readLocal() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil, let data, !data.isEmpty else { self.stop(); return }
            self.socket.send(.data(data)) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error != nil || complete { self.stop() } else { self.readLocal() }
                }
            }
        }
    }

    private func readRelay() {
        guard !stopped else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, case .success(.data(let data)) = result else { self.stop(); return }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.stop() } else { self?.readRelay() }
                })
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        connection.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        onClose()
    }
}

/// Trust only the Mac certificate scanned during pairing. Outer relay TLS uses
/// normal system trust; this delegate applies solely to the inner connection.
final class RelayTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: SecCertificate
    private let identity: SecIdentity?

    init(certificate: Data, pkcs12: Data? = nil) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificate as CFData) else { throw URLError(.serverCertificateUntrusted) }
        self.certificate = certificate
        if let pkcs12 {
            var items: CFArray?
            var options: [CFString: Any] = [kSecImportExportPassphrase: "routi"]
            #if os(macOS)
            if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly] = true }
            #endif
            let result = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
            guard result == errSecSuccess, let item = (items as? [[String: Any]])?.first,
                  let value = item[kSecImportItemIdentity as String] else { throw URLError(.clientCertificateRejected) }
            identity = (value as! SecIdentity)
        } else { identity = nil }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func respond(to challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let peer = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let first = peer.first,
                  SecCertificateCopyData(first) as Data == SecCertificateCopyData(certificate) as Data else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "routi-host" as CFString))
            guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            if let identity { completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession)) }
            else { completionHandler(.performDefaultHandling, nil) }
        default: completionHandler(.performDefaultHandling, nil)
        }
    }
}
