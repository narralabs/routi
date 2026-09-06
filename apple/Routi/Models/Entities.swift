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
        case .none:
            return "Chat only. This bot can talk, but cannot browse, click or look anything up."
        case .container:
            return "A shared Linux desktop with a browser. The bot can search, read pages and do the work itself."
        case .host:
            return "Your real Mac. The bot shares your mouse and sees everything on screen. Not yet available."
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
    var effort: String?
    var surfaceMode: SurfaceMode
    var updatedAt: Double
    var archivedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarColor, systemPrompt, provider, model, effort, surfaceMode, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatarColor = try c.decodeIfPresent(String.self, forKey: .avatarColor) ?? "#8E8E93"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "default"
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
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
    /// First line of the most recent message — what the sidebar shows under the name.
    var preview: String
    var lastMessageAt: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        botId = try c.decode(String.self, forKey: .botId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        lastMessageAt = try c.decodeIfPresent(Double.self, forKey: .lastMessageAt)
    }

    private enum CodingKeys: String, CodingKey { case id, botId, title, preview, lastMessageAt }
}

enum Role: String, Codable {
    case user, assistant, system
}

struct Message: Codable, Identifiable, Hashable {
    var id: String
    var conversationId: String
    var role: Role
    var blocks: [Block]
    /// Which bot wrote it. Null for a person, and in a one-bot chat where the
    /// conversation already says who is speaking.
    var botId: String?
    var createdAt: Double
    /// The routine that woke this turn, when one did. The transcript says so, since a
    /// bot speaking unprompted otherwise reads as a bot that lost the thread.
    var routineName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        botId = try c.decodeIfPresent(String.self, forKey: .botId)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        // Only this one key is read out of the provider's metadata; the rest is opaque.
        let meta = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .providerMeta)
        routineName = try? meta?.decodeIfPresent(String.self, forKey: .routineName)
    }

    private enum CodingKeys: String, CodingKey { case id, conversationId, role, blocks, createdAt, botId, providerMeta }
    private enum MetaKeys: String, CodingKey { case routineName }

    // Nothing in the app encodes a message today; this exists so the type stays
    // `Codable` for the containers that require it, and writes back what it read.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(role, forKey: .role)
        try c.encode(blocks, forKey: .blocks)
        try c.encodeIfPresent(botId, forKey: .botId)
        try c.encode(createdAt, forKey: .createdAt)
        if let routineName {
            var meta = c.nestedContainer(keyedBy: MetaKeys.self, forKey: .providerMeta)
            try meta.encode(routineName, forKey: .routineName)
        }
    }

    /// Plain-text projection for sidebar previews and copy.
    var plainText: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }
}

/// Swift mirror of the daemon's `Routine`.
struct Routine: Codable, Identifiable, Hashable {
    var id: String
    var botId: String
    var conversationId: String
    var name: String
    var prompt: String
    var scheduleText: String
    var enabled: Bool
    var lastRunAt: Double?
    var nextRunAt: Double?
}

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var description: String
    var resolvedModel: String?
    var effortLevels: [String]
    /// What the provider does when a bot names no effort. Nil means it will not say,
    /// and nothing should be claimed on its behalf.
    var defaultEffort: String?
    /// What to call this model when reporting what a bot runs, where that differs
    /// from its name in the picker.
    var statusName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        resolvedModel = try c.decodeIfPresent(String.self, forKey: .resolvedModel)
        effortLevels = try c.decodeIfPresent([String].self, forKey: .effortLevels) ?? []
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort)
        statusName = try c.decodeIfPresent(String.self, forKey: .statusName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, description, resolvedModel, effortLevels, defaultEffort, statusName
    }
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
