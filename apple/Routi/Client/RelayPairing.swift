import Foundation
import Security

struct RelayInvitation: Decodable, Identifiable {
    let v: Int
    let relay: String
    let token: String
    let certificate: Data
    let secret: String
    let expiresAt: Double
    let name: String
    var id: String { secret }

    static func parse(_ url: URL) throws -> RelayInvitation {
        guard url.scheme == "routibot", url.host == "pair", url.absoluteString.count < 8192,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw PairingError("Scan a Routi Connect pairing code from your Mac.")
        }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw PairingError("This pairing code is invalid.") }
        let invite = try JSONDecoder().decode(RelayInvitation.self, from: data)
        guard invite.v == 1, validRelay(invite.relay), validToken(invite.token), validToken(invite.secret),
              invite.certificate.count < 4096, invite.name.count < 256 else { throw PairingError("This pairing code is invalid.") }
        guard invite.expiresAt > Date().timeIntervalSince1970 * 1000 else { throw PairingError("This code expired. Create a new one on your Mac.") }
        return invite
    }
}

struct RelayProfile: Codable {
    let relay: String
    let token: String
    let certificate: Data
    let pkcs12: Data
    let name: String
}

struct PairingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func validToken(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
}
private func validRelay(_ value: String) -> Bool {
    guard let url = URLComponents(string: value) else { return false }
    return url.scheme == "wss" && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
        && url.query == nil && url.fragment == nil && (url.path.isEmpty || url.path == "/")
}

enum RelayPairing {
    static func claim(_ invitation: RelayInvitation, deviceName: String = "iPhone") async throws -> RelayProfile {
        let tunnel = RelayTunnel(relay: URL(string: invitation.relay)!, token: invitation.token)
        defer { tunnel.stop() }
        let base = try await tunnel.start(pairing: true)
        let trust = try RelayTrust(certificate: invitation.certificate)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": deviceName])
        request.timeoutInterval = 20
        request.setValue("Bearer \(invitation.secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            if status == 400, let body = try? JSONDecoder().decode([String: String].self, from: data), let error = body["error"] {
                throw PairingError(error)
            }
            throw PairingError(status == 403
                ? "This code expired or was already used. Create a new one on your Mac."
                : "Your Mac could not complete pairing. Create a new code and try again.")
        }
        struct Identity: Decodable { let pkcs12: Data; let token: String }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard validToken(identity.token) else { throw PairingError("The Mac returned an invalid device credential.") }
        _ = try RelayTrust(certificate: invitation.certificate, pkcs12: identity.pkcs12)
        return RelayProfile(relay: invitation.relay, token: identity.token, certificate: invitation.certificate,
                            pkcs12: identity.pkcs12, name: invitation.name)
    }

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "Routi Connect", kSecAttrAccount: "paired-mac"]
    }
    static func load() throws -> RelayProfile? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PairingError("Could not read this Mac’s pairing from Keychain.") }
        let profile = try JSONDecoder().decode(RelayProfile.self, from: data)
        guard validRelay(profile.relay), validToken(profile.token) else { throw PairingError("The saved pairing is invalid. Pair again from your Mac.") }
        return profile
    }
    static func save(_ profile: RelayProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw PairingError("Could not save this pairing in Keychain.") }
    }
    static func forget() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PairingError("Could not remove the pairing from Keychain.") }
    }
}
