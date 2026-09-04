import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';

final clientProvider = Provider<KorgClient>((ref) {
  final c = KorgClient();
  ref.onDispose(c.dispose);
  return c;
});

final connectionProvider = StreamProvider<KorgConnectionState>((ref) {
  final c = ref.watch(clientProvider);
  return c.connection;
});

/// The single mutable store for the chat UI.
///
/// Deltas are applied by block index, matching the wire protocol, so a tool card
/// arriving mid-stream lands in the right slot instead of being concatenated onto
/// whatever text preceded it.
class ChatState {
  final List<Bot> bots;
  final Map<String, Conversation> conversations;
  final String? selectedBotId;
  final String? selectedConversationId;
  final List<Message> messages;
  final Set<String> busyConversations;
  final bool loadingMessages;
  final String? error;

  const ChatState({
    this.bots = const [],
    this.conversations = const {},
    this.selectedBotId,
    this.selectedConversationId,
    this.messages = const [],
    this.busyConversations = const {},
    this.loadingMessages = false,
    this.error,
  });

  bool get isBusy =>
      selectedConversationId != null && busyConversations.contains(selectedConversationId);

  Bot? get selectedBot {
    for (final b in bots) {
      if (b.id == selectedBotId) return b;
    }
    return null;
  }

  /// Newest conversation per bot, for the sidebar preview line.
  Conversation? conversationForBot(String botId) {
    Conversation? best;
    for (final c in conversations.values) {
      if (c.botId != botId) continue;
      if (best == null || (c.lastMessageAt ?? 0) > (best.lastMessageAt ?? 0)) best = c;
    }
    return best;
  }

  ChatState copyWith({
    List<Bot>? bots,
    Map<String, Conversation>? conversations,
    String? selectedBotId,
    String? selectedConversationId,
    List<Message>? messages,
    Set<String>? busyConversations,
    bool? loadingMessages,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        bots: bots ?? this.bots,
        conversations: conversations ?? this.conversations,
        selectedBotId: selectedBotId ?? this.selectedBotId,
        selectedConversationId: selectedConversationId ?? this.selectedConversationId,
        messages: messages ?? this.messages,
        busyConversations: busyConversations ?? this.busyConversations,
        loadingMessages: loadingMessages ?? this.loadingMessages,
        error: clearError ? null : (error ?? this.error),
      );
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ref) : super(const ChatState()) {
    final client = _ref.read(clientProvider);
    _eventSub = client.events.listen(_onEvent);
    _connSub = client.connection.listen((s) {
      if (s == KorgConnectionState.connected) unawaited(refreshAll());
    });
    unawaited(client.connect());
  }

  final Ref _ref;
  StreamSubscription<ServerEventMsg>? _eventSub;
  StreamSubscription<KorgConnectionState>? _connSub;

  KorgClient get _client => _ref.read(clientProvider);

  @override
  void dispose() {
    _eventSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ loading

  Future<void> refreshAll() async {
    try {
      final botsRes = await _client.rpc('bots.list');
      final bots = (botsRes['bots'] as List).map((e) => Bot.fromJson(e as Map<String, dynamic>)).toList();

      final convRes = await _client.rpc('conversations.list');
      final conversations = {
        for (final e in convRes['conversations'] as List)
          (e as Map<String, dynamic>)['id'] as String: Conversation.fromJson(e),
      };

      state = state.copyWith(bots: bots, conversations: conversations, clearError: true);

      final keepSelection = state.selectedBotId != null && bots.any((b) => b.id == state.selectedBotId);
      if (!keepSelection && bots.isNotEmpty) {
        await selectBot(bots.first.id);
      } else if (state.selectedConversationId != null) {
        await _loadMessages(state.selectedConversationId!);
      }
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  Future<void> selectBot(String botId) async {
    final previous = state.selectedConversationId;
    if (previous != null) _client.unsubscribe(previous);

    var conversation = state.conversationForBot(botId);
    conversation ??= await _createConversation(botId);
    if (conversation == null) return;

    state = state.copyWith(
      selectedBotId: botId,
      selectedConversationId: conversation.id,
      messages: const [],
      loadingMessages: true,
    );
    _client.subscribe(conversation.id);
    await _loadMessages(conversation.id);
  }

  Future<Conversation?> _createConversation(String botId) async {
    try {
      final res = await _client.rpc('conversations.create', {'botId': botId});
      final conv = Conversation.fromJson(res['conversation'] as Map<String, dynamic>);
      state = state.copyWith(conversations: {...state.conversations, conv.id: conv});
      return conv;
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
      return null;
    }
  }

  Future<void> _loadMessages(String conversationId) async {
    try {
      final res = await _client.rpc('messages.list', {'conversationId': conversationId});
      final messages = (res['messages'] as List).map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
      if (state.selectedConversationId != conversationId) return; // selection moved on
      state = state.copyWith(messages: messages, loadingMessages: false, clearError: true);
    } on KorgRpcException catch (e) {
      state = state.copyWith(loadingMessages: false, error: e.message);
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> send(String text) async {
    final conversationId = state.selectedConversationId;
    if (conversationId == null || text.trim().isEmpty) return;
    try {
      await _client.rpc('messages.send', {
        'conversationId': conversationId,
        'blocks': [
          {'type': 'text', 'text': text}
        ],
      });
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  Future<void> interrupt() async {
    final id = state.selectedConversationId;
    if (id == null) return;
    try {
      await _client.rpc('messages.interrupt', {'conversationId': id});
    } on KorgRpcException catch (_) {
      // Interrupt is best-effort; the turn may have finished on its own.
    }
  }

  Future<void> createBot({required String name, required String systemPrompt, required String model}) async {
    try {
      final res = await _client.rpc('bots.create', {
        'name': name,
        'systemPrompt': systemPrompt,
        'model': model,
      });
      final bot = Bot.fromJson(res['bot'] as Map<String, dynamic>);
      final conv = Conversation.fromJson(res['conversation'] as Map<String, dynamic>);
      state = state.copyWith(
        bots: [bot, ...state.bots],
        conversations: {...state.conversations, conv.id: conv},
      );
      await selectBot(bot.id);
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  Future<void> updateBot(String id, Map<String, dynamic> patch) async {
    try {
      final res = await _client.rpc('bots.update', {'id': id, 'patch': patch});
      final bot = Bot.fromJson(res['bot'] as Map<String, dynamic>);
      state = state.copyWith(bots: [for (final b in state.bots) if (b.id == bot.id) bot else b]);
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  Future<void> deleteBot(String id) async {
    try {
      await _client.rpc('bots.delete', {'id': id});
      final remaining = state.bots.where((b) => b.id != id).toList();
      state = state.copyWith(
        bots: remaining,
        conversations: {
          for (final e in state.conversations.entries)
            if (e.value.botId != id) e.key: e.value,
        },
      );
      if (state.selectedBotId == id && remaining.isNotEmpty) await selectBot(remaining.first.id);
    } on KorgRpcException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  /// Phone back-navigation: drop the selection so the shell shows the bot list.
  void clearSelection() {
    final id = state.selectedConversationId;
    if (id != null) _client.unsubscribe(id);
    state = ChatState(
      bots: state.bots,
      conversations: state.conversations,
      busyConversations: state.busyConversations,
    );
  }

  // ------------------------------------------------------------------- events

  void _onEvent(ServerEventMsg ev) {
    switch (ev.kind) {
      case 'message.created':
        final msg = Message.fromJson(ev.data['message'] as Map<String, dynamic>);
        if (msg.conversationId != state.selectedConversationId) return;
        // The daemon echoes our own sends back; replace rather than duplicate.
        final existing = state.messages.indexWhere((m) => m.id == msg.id);
        final next = [...state.messages];
        if (existing >= 0) {
          next[existing] = msg;
        } else {
          next.add(msg);
        }
        state = state.copyWith(messages: next);

      case 'message.delta':
        if (ev.data['conversationId'] != state.selectedConversationId) return;
        _applyDelta(
          ev.data['messageId'] as String,
          ev.data['blockIndex'] as int,
          (ev.data['delta'] as Map<String, dynamic>),
        );

      case 'message.block':
        if (ev.data['conversationId'] != state.selectedConversationId) return;
        _applyBlock(
          ev.data['messageId'] as String,
          ev.data['blockIndex'] as int,
          Block.fromJson(ev.data['block'] as Map<String, dynamic>),
        );

      case 'conversation.busy':
        final id = ev.data['conversationId'] as String;
        final busy = ev.data['busy'] as bool;
        final next = {...state.busyConversations};
        busy ? next.add(id) : next.remove(id);
        state = state.copyWith(busyConversations: next);

      case 'conversation.updated':
        final conv = Conversation.fromJson(ev.data['conversation'] as Map<String, dynamic>);
        state = state.copyWith(conversations: {...state.conversations, conv.id: conv});

      case 'bot.updated':
        final bot = Bot.fromJson(ev.data['bot'] as Map<String, dynamic>);
        state = state.copyWith(bots: [for (final b in state.bots) if (b.id == bot.id) bot else b]);

      case 'error':
        state = state.copyWith(error: ev.data['message'] as String?);
    }
  }

  void _applyDelta(String messageId, int index, Map<String, dynamic> delta) {
    final text = delta['text'] as String? ?? '';
    final isThinking = delta['type'] == 'thinking';
    _mutateBlocks(messageId, (blocks) {
      _ensureLength(blocks, index);
      final existing = blocks[index];
      if (isThinking) {
        blocks[index] = ThinkingBlock((existing is ThinkingBlock ? existing.text : '') + text);
      } else {
        blocks[index] = TextBlock((existing is TextBlock ? existing.text : '') + text);
      }
    });
  }

  void _applyBlock(String messageId, int index, Block block) {
    _mutateBlocks(messageId, (blocks) {
      _ensureLength(blocks, index);
      blocks[index] = block;
    });
  }

  void _mutateBlocks(String messageId, void Function(List<Block>) mutate) {
    final i = state.messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;
    final blocks = [...state.messages[i].blocks];
    mutate(blocks);
    final messages = [...state.messages];
    messages[i] = messages[i].copyWith(blocks: blocks);
    state = state.copyWith(messages: messages);
  }

  /// Providers may address a block index ahead of what we've seen; keep it dense.
  static void _ensureLength(List<Block> blocks, int index) {
    while (blocks.length <= index) {
      blocks.add(const TextBlock(''));
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) => ChatNotifier(ref));

final modelsProvider = FutureProvider<List<ModelInfo>>((ref) async {
  final conn = await ref.watch(connectionProvider.future);
  if (conn != KorgConnectionState.connected) return const [];
  final res = await ref.read(clientProvider).rpc('models.list', {'provider': 'anthropic'});
  return (res['models'] as List).map((e) => ModelInfo.fromJson(e as Map<String, dynamic>)).toList();
});

/// Debug helper, used by the connection banner.
@visibleForTesting
String describeConnection(KorgConnectionState s) => switch (s) {
      KorgConnectionState.connected => 'Connected',
      KorgConnectionState.connecting => 'Connecting…',
      KorgConnectionState.disconnected => 'Offline',
    };
