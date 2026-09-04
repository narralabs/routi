/// Dart mirror of `protocol/src/*.ts`.
///
/// Hand-written rather than code-generated: at this size a codegen pipeline costs
/// more than it saves. The rule is that this file and the zod schemas change in the
/// same commit. `PROTOCOL_VERSION` is checked at handshake so a mismatch surfaces
/// immediately rather than as mysterious null fields.
library;

const kProtocolVersion = 1;

// ----------------------------------------------------------------- blocks

sealed class Block {
  const Block();

  static Block fromJson(Map<String, dynamic> j) => switch (j['type'] as String) {
        'text' => TextBlock(j['text'] as String? ?? ''),
        'thinking' => ThinkingBlock(j['text'] as String? ?? ''),
        'image' => ImageBlock(
            mediaType: j['mediaType'] as String? ?? 'image/png',
            dataUrl: j['dataUrl'] as String?,
            assetId: j['assetId'] as String?,
          ),
        'tool_use' => ToolUseBlock(
            id: j['id'] as String? ?? '',
            name: j['name'] as String? ?? '',
            title: j['title'] as String?,
            status: ToolStatus.parse(j['status'] as String?),
          ),
        'tool_result' => ToolResultBlock(
            toolUseId: j['toolUseId'] as String? ?? '',
            isError: j['isError'] as bool? ?? false,
            content: ((j['content'] as List?) ?? const [])
                .map((e) => Block.fromJson(e as Map<String, dynamic>))
                .toList(),
          ),
        'surface_event' => SurfaceEventBlock(
            sessionId: j['sessionId'] as String? ?? '',
            kind: j['kind'] as String? ?? 'attached',
            assetId: j['assetId'] as String?,
          ),
        // Forward compatibility: a newer daemon may send blocks this build predates.
        _ => const UnknownBlock(),
      };

  Map<String, dynamic> toJson();
}

class TextBlock extends Block {
  final String text;
  const TextBlock(this.text);
  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ThinkingBlock extends Block {
  final String text;
  const ThinkingBlock(this.text);
  @override
  Map<String, dynamic> toJson() => {'type': 'thinking', 'text': text};
}

class ImageBlock extends Block {
  final String mediaType;
  final String? dataUrl;
  final String? assetId;
  const ImageBlock({required this.mediaType, this.dataUrl, this.assetId});
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'image', 'mediaType': mediaType, if (dataUrl != null) 'dataUrl': dataUrl, if (assetId != null) 'assetId': assetId};
}

enum ToolStatus {
  running,
  done,
  error;

  static ToolStatus parse(String? s) => switch (s) {
        'done' => ToolStatus.done,
        'error' => ToolStatus.error,
        _ => ToolStatus.running,
      };
}

class ToolUseBlock extends Block {
  final String id;
  final String name;
  final String? title;
  final ToolStatus status;
  const ToolUseBlock({required this.id, required this.name, this.title, required this.status});
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'tool_use', 'id': id, 'name': name, 'title': title, 'status': status.name};
}

class ToolResultBlock extends Block {
  final String toolUseId;
  final bool isError;
  final List<Block> content;
  const ToolResultBlock({required this.toolUseId, required this.isError, required this.content});
  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'toolUseId': toolUseId,
        'isError': isError,
        'content': content.map((b) => b.toJson()).toList(),
      };
}

class SurfaceEventBlock extends Block {
  final String sessionId;
  final String kind;
  final String? assetId;
  const SurfaceEventBlock({required this.sessionId, required this.kind, this.assetId});
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'surface_event', 'sessionId': sessionId, 'kind': kind, 'assetId': assetId};
}

class UnknownBlock extends Block {
  const UnknownBlock();
  @override
  Map<String, dynamic> toJson() => {'type': 'unknown'};
}

// ---------------------------------------------------------------- entities

enum SurfaceMode {
  none,
  container,
  host;

  static SurfaceMode parse(String? s) => switch (s) {
        'container' => SurfaceMode.container,
        'host' => SurfaceMode.host,
        _ => SurfaceMode.none,
      };
}

class Bot {
  final String id;
  final String name;
  final String avatarColor;
  final String systemPrompt;
  final String provider;
  final String model;
  final SurfaceMode surfaceMode;
  final int updatedAt;
  final int? archivedAt;

  const Bot({
    required this.id,
    required this.name,
    required this.avatarColor,
    required this.systemPrompt,
    required this.provider,
    required this.model,
    required this.surfaceMode,
    required this.updatedAt,
    this.archivedAt,
  });

  factory Bot.fromJson(Map<String, dynamic> j) => Bot(
        id: j['id'] as String,
        name: j['name'] as String,
        avatarColor: j['avatarColor'] as String? ?? '#8E8E93',
        systemPrompt: j['systemPrompt'] as String? ?? '',
        provider: j['provider'] as String? ?? 'anthropic',
        model: j['model'] as String? ?? 'default',
        surfaceMode: SurfaceMode.parse(j['surfaceMode'] as String?),
        updatedAt: j['updatedAt'] as int? ?? 0,
        archivedAt: j['archivedAt'] as int?,
      );
}

class Conversation {
  final String id;
  final String botId;
  final String title;
  final int? lastMessageAt;

  const Conversation({required this.id, required this.botId, required this.title, this.lastMessageAt});

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        botId: j['botId'] as String,
        title: j['title'] as String? ?? '',
        lastMessageAt: j['lastMessageAt'] as int?,
      );
}

enum Role { user, assistant, system }

class Message {
  final String id;
  final String conversationId;
  final Role role;
  final List<Block> blocks;
  final int createdAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.blocks,
    required this.createdAt,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        conversationId: j['conversationId'] as String,
        role: switch (j['role'] as String?) {
          'user' => Role.user,
          'system' => Role.system,
          _ => Role.assistant,
        },
        blocks: ((j['blocks'] as List?) ?? const [])
            .map((e) => Block.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: j['createdAt'] as int? ?? 0,
      );

  Message copyWith({List<Block>? blocks}) => Message(
        id: id,
        conversationId: conversationId,
        role: role,
        blocks: blocks ?? this.blocks,
        createdAt: createdAt,
      );

  /// Plain-text projection, used for sidebar previews.
  String get preview {
    for (final b in blocks) {
      if (b is TextBlock && b.text.trim().isNotEmpty) return b.text.trim().replaceAll('\n', ' ');
    }
    return '';
  }
}

class ModelInfo {
  final String id;
  final String displayName;
  final String description;
  final String? resolvedModel;

  const ModelInfo({required this.id, required this.displayName, required this.description, this.resolvedModel});

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        displayName: j['displayName'] as String? ?? j['id'] as String,
        description: j['description'] as String? ?? '',
        resolvedModel: j['resolvedModel'] as String?,
      );
}

class AccountInfo {
  final String authMode;
  final String? subscriptionType;
  final String? organization;

  const AccountInfo({required this.authMode, this.subscriptionType, this.organization});

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
        authMode: j['authMode'] as String? ?? 'subscription',
        subscriptionType: j['subscriptionType'] as String?,
        organization: j['organization'] as String?,
      );

  String get label => switch (authMode) {
        'api_key' => 'Anthropic API key',
        _ => subscriptionType ?? 'Claude subscription',
      };
}
