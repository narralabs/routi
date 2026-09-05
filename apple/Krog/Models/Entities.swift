import Foundation
import SwiftUI

/// Swift mirror of `protocol/src/entities.ts`.

enum SurfaceMode: String, Codable, CaseIterable, Identifiable {
    case none, container, host
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .container: return "Container"
        case .host: return "This Mac"
        }
    }

    var explanation: String {
        switch self {
        case .none: return "Chat only. The bot has no screen to look at."
        case .container: return "An isolated Linux container. Safe to reset, and several can run at once."
        case .host: return "Your real desktop. The bot shares your mouse and sees everything on screen."
        }
    }
}

struct Bot: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var avatarColor: String
    var systemPrompt: String
    var provider: String
    var model: String
    var surfaceMode: SurfaceMode
    var updatedAt: Double
    var archivedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarColor, systemPrompt, provider, model, surfaceMode, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor) ?? "#8E8E93"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "default"
        surfaceMode = (try? c.decode(SurfaceMode.self, forKey: .surfaceMode)) ?? .none
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt)
    }

    var color: Color { Color(hex: avatarColor) }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: String
    var botId: String
    var title: String
    var lastMessageAt: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        botId = try c.decode(String.self, forKey: .botId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        lastMessageAt = try c.decodeIfPresent(Double.self, forKey: .lastMessageAt)
    }

    private enum CodingKeys: String, CodingKey { case id, botId, title, lastMessageAt }
}

enum Role: String, Codable {
    case user, assistant, system
}

struct Message: Codable, Identifiable, Hashable {
    var id: String
    var conversationId: String
    var role: Role
    var blocks: [Block]
    var createdAt: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case id, conversationId, role, blocks, createdAt }

    /// Plain-text projection for sidebar previews and copy.
    var plainText: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }
}

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var description: String
    var resolvedModel: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        resolvedModel = try c.decodeIfPresent(String.self, forKey: .resolvedModel)
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, description, resolvedModel }
}

struct AccountInfo: Codable, Hashable {
    var authMode: String
    var subscriptionType: String?
    var organization: String?
    var email: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "subscription"
        subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        email = try c.decodeIfPresent(String.self, forKey: .email)
    }

    private enum CodingKeys: String, CodingKey { case authMode, subscriptionType, organization, email }

    var label: String {
        authMode == "api_key" ? "Anthropic API key" : (subscriptionType ?? "Claude subscription")
    }

    /// Organizations arrive as "someone@example.com's Organization"; show a person.
    var displayName: String {
        guard let org = organization, !org.isEmpty else { return "Account" }
        let email = org.split(separator: "'").first.map(String.init) ?? org
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { ".-_".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// "William" from "William Estoque" — the sidebar footer wants a first name.
    var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
        guard let first = parts.first else { return "?" }
        if parts.count == 1 { return String(first.prefix(1)).uppercased() }
        return (String(first.prefix(1)) + String(parts[parts.count - 1].prefix(1))).uppercased()
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
