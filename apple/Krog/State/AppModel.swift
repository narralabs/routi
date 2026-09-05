import Foundation
import Observation

/// The app's single source of truth.
///
/// Streaming deltas are applied by block index, matching the wire protocol, so a
/// tool card arriving mid-turn lands in its own slot rather than being appended to
/// whatever text preceded it.
@MainActor
@Observable
final class AppModel {
    // Server state
    var bots: [Bot] = []
    var conversations: [String: Conversation] = [:]
    var messages: [Message] = []
    var models: [ModelInfo] = []

    // Selection
    var selectedBotID: String?
    var selectedConversationID: String?

    // Transient
    var busyConversations: Set<String> = []
    var connection: KrogClient.ConnectionState = .disconnected
    var errorMessage: String?
    var isLoadingMessages = false

    @ObservationIgnored private let client: KrogClient

    // Default arguments are evaluated in a nonisolated context, so the client is
    // constructed inside the initializer rather than in the signature.
    init(client: KrogClient? = nil) {
        let client = client ?? KrogClient()
        self.client = client
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connection = state
            if state == .connected {
                Task { await self.refreshAll() }
            }
        }
        client.onEvent = { [weak self] event in
            self?.apply(event)
        }
    }

    var account: AccountInfo? { client.account }

    var selectedBot: Bot? {
        bots.first { $0.id == selectedBotID }
    }

    var isBusy: Bool {
        guard let id = selectedConversationID else { return false }
        return busyConversations.contains(id)
    }

    func isBusy(botID: String) -> Bool {
        guard let conv = conversation(for: botID) else { return false }
        return busyConversations.contains(conv.id)
    }

    /// Most recently active conversation for a bot — what the sidebar previews.
    func conversation(for botID: String) -> Conversation? {
        conversations.values
            .filter { $0.botId == botID }
            .max { ($0.lastMessageAt ?? 0) < ($1.lastMessageAt ?? 0) }
    }

    func start() {
        client.connect()
    }

    func updateEndpoint(host: String, port: Int) {
        client.updateEndpoint(host: host, port: port)
    }

    // MARK: - Loading

    func refreshAll() async {
        do {
            bots = try await client.rpc("bots.list", field: "bots", as: [Bot].self)
            let list = try await client.rpc("conversations.list", field: "conversations", as: [Conversation].self)
            conversations = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            errorMessage = nil

            if models.isEmpty {
                models = (try? await client.rpc(
                    "models.list", ["provider": "anthropic"], field: "models", as: [ModelInfo].self
                )) ?? []
            }

            let selectionStillValid = selectedBotID.map { id in bots.contains { $0.id == id } } ?? false
            if !selectionStillValid {
                #if os(macOS)
                // The Mac always shows a thread; a phone starts on the list.
                if let first = bots.first { await select(bot: first.id) }
                #endif
            } else if let convID = selectedConversationID {
                await loadMessages(convID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(bot botID: String) async {
        if let previous = selectedConversationID { client.unsubscribe(previous) }

        var conv = conversation(for: botID)
        if conv == nil { conv = await createConversation(botID: botID) }
        guard let conversation = conv else { return }

        selectedBotID = botID
        selectedConversationID = conversation.id
        messages = []
        isLoadingMessages = true
        client.subscribe(conversation.id)
        await loadMessages(conversation.id)
    }

    func clearSelection() {
        if let id = selectedConversationID { client.unsubscribe(id) }
        selectedBotID = nil
        selectedConversationID = nil
        messages = []
    }

    private func createConversation(botID: String) async -> Conversation? {
        do {
            let conv = try await client.rpc(
                "conversations.create", ["botId": botID], field: "conversation", as: Conversation.self
            )
            conversations[conv.id] = conv
            return conv
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func loadMessages(_ conversationID: String) async {
        do {
            let list = try await client.rpc(
                "messages.list", ["conversationId": conversationID], field: "messages", as: [Message].self
            )
            guard selectedConversationID == conversationID else { return } // selection moved on
            messages = list
            isLoadingMessages = false
            errorMessage = nil
        } catch {
            isLoadingMessages = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = selectedConversationID, !trimmed.isEmpty else { return }
        do {
            try await client.rpc("messages.send", [
                "conversationId": conversationID,
                "blocks": [["type": "text", "text": trimmed]],
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard let id = selectedConversationID else { return }
        // Best-effort: the turn may have finished on its own.
        try? await client.rpc("messages.interrupt", ["conversationId": id])
    }

    func createBot(name: String, systemPrompt: String, model: String) async {
        do {
            let result = try await client.rpc("bots.create", [
                "name": name, "systemPrompt": systemPrompt, "model": model,
            ])
            if let botRaw = result["bot"],
               let data = try? JSONSerialization.data(withJSONObject: botRaw),
               let bot = try? JSONDecoder().decode(Bot.self, from: data) {
                bots.insert(bot, at: 0)
                if let convRaw = result["conversation"],
                   let convData = try? JSONSerialization.data(withJSONObject: convRaw),
                   let conv = try? JSONDecoder().decode(Conversation.self, from: convData) {
                    conversations[conv.id] = conv
                }
                await select(bot: bot.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateBot(_ id: String, patch: [String: Any]) async {
        do {
            let bot = try await client.rpc("bots.update", ["id": id, "patch": patch], field: "bot", as: Bot.self)
            if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBot(_ id: String) async {
        do {
            try await client.rpc("bots.delete", ["id": id])
            bots.removeAll { $0.id == id }
            conversations = conversations.filter { $0.value.botId != id }
            if selectedBotID == id {
                clearSelection()
                if let first = bots.first { await select(bot: first.id) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Events

    private func apply(_ event: KrogClient.Event) {
        switch event.kind {
        case "message.created":
            guard let raw = event.payload["message"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let message = try? JSONDecoder().decode(Message.self, from: data),
                  message.conversationId == selectedConversationID
            else { return }
            // The daemon echoes our own sends back; replace rather than duplicate.
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }

        case "message.delta":
            guard event.payload["conversationId"] as? String == selectedConversationID,
                  let messageID = event.payload["messageId"] as? String,
                  let index = event.payload["blockIndex"] as? Int,
                  let delta = event.payload["delta"] as? [String: Any],
                  let text = delta["text"] as? String
            else { return }
            let isThinking = delta["type"] as? String == "thinking"
            mutateBlocks(messageID) { blocks in
                Self.pad(&blocks, to: index)
                switch (blocks[index], isThinking) {
                case (.text(let existing), false): blocks[index] = .text(existing + text)
                case (.thinking(let existing), true): blocks[index] = .thinking(existing + text)
                default: blocks[index] = isThinking ? .thinking(text) : .text(text)
                }
            }

        case "message.block":
            guard event.payload["conversationId"] as? String == selectedConversationID,
                  let messageID = event.payload["messageId"] as? String,
                  let index = event.payload["blockIndex"] as? Int,
                  let raw = event.payload["block"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let block = try? JSONDecoder().decode(Block.self, from: data)
            else { return }
            mutateBlocks(messageID) { blocks in
                Self.pad(&blocks, to: index)
                blocks[index] = block
            }

        case "conversation.busy":
            guard let id = event.payload["conversationId"] as? String,
                  let busy = event.payload["busy"] as? Bool else { return }
            if busy { busyConversations.insert(id) } else { busyConversations.remove(id) }

        case "conversation.updated":
            guard let raw = event.payload["conversation"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { return }
            conversations[conv.id] = conv

        case "bot.updated":
            guard let raw = event.payload["bot"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let bot = try? JSONDecoder().decode(Bot.self, from: data) else { return }
            if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }

        case "error":
            errorMessage = event.payload["message"] as? String

        default:
            break
        }
    }

    private func mutateBlocks(_ messageID: String, _ mutate: (inout [Block]) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(&messages[index].blocks)
    }

    /// Providers address blocks by index and may skip ahead; keep the array dense.
    private static func pad(_ blocks: inout [Block], to index: Int) {
        while blocks.count <= index { blocks.append(.text("")) }
    }
}
