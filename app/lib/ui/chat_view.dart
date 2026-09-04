import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// The centre pane: header, transcript, composer.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key});

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  int _lastMessageSignature = 0;

  @override
  void dispose() {
    _scroll.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// Follows the tail as tokens stream in, but only when the user is already near
  /// the bottom — yanking the viewport while they're reading history is hostile.
  void _autoScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > 240) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final bot = chat.selectedBot;

    // Cheap change-detector: message count plus total block length.
    final signature = chat.messages.fold<int>(
      chat.messages.length,
      (acc, m) => acc + m.blocks.fold<int>(0, (a, b) => a + (b is TextBlock ? b.text.length : 1)),
    );
    if (signature != _lastMessageSignature) {
      _lastMessageSignature = signature;
      _autoScroll();
    }

    if (bot == null) {
      return Expanded(
        child: Container(
          color: context.canvasColor,
          child: Center(
            child: Text('Select a bot to start chatting.', style: TextStyle(color: context.textSecondary)),
          ),
        ),
      );
    }

    return Expanded(
      child: Container(
        color: context.canvasColor,
        child: Column(
          children: [
            _ChatHeader(bot: bot),
            if (chat.error != null) _ErrorBanner(message: chat.error!, onDismiss: () => ref.read(chatProvider.notifier).clearError()),
            Expanded(
              child: chat.loadingMessages
                  ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : chat.messages.isEmpty
                      ? _EmptyThread(bot: bot)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                          itemCount: chat.messages.length + (chat.isBusy ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= chat.messages.length) return const _TypingIndicator();
                            return _MessageRow(message: chat.messages[i]);
                          },
                        ),
            ),
            _Composer(
              controller: _composer,
              focusNode: _composerFocus,
              botName: bot.name,
              busy: chat.isBusy,
              onSend: _send,
              onInterrupt: () => ref.read(chatProvider.notifier).interrupt(),
            ),
          ],
        ),
      ),
    );
  }

  void _send() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    ref.read(chatProvider.notifier).send(text);
    _composerFocus.requestFocus();
  }
}

class _ChatHeader extends ConsumerWidget {
  const _ChatHeader({required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final current = models.where((m) => m.id == bot.model).firstOrNull;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: parseHexColor(bot.avatarColor),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(Icons.smart_toy_outlined, size: 13, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Text(bot.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.textPrimary)),
          const Spacer(),
          if (models.isNotEmpty)
            _ModelPicker(
              models: models,
              selected: bot.model,
              label: current?.displayName ?? bot.model,
              onSelected: (id) => ref.read(chatProvider.notifier).updateBot(bot.id, {'model': id}),
            ),
        ],
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.models,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<ModelInfo> models;
  final String selected;
  final String label;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Model',
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final m in models)
          PopupMenuItem(
            value: m.id,
            height: 38,
            child: Row(
              children: [
                Icon(
                  m.id == selected ? Icons.check : null,
                  size: 15,
                  color: KorgColors.accent,
                ),
                const SizedBox(width: 8),
                Text(m.displayName, style: const TextStyle(fontSize: 13)),
                if (m.resolvedModel != null) ...[
                  const SizedBox(width: 10),
                  Text(m.resolvedModel!, style: TextStyle(fontSize: 11, color: context.textSecondary)),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: context.borderColor),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: context.textSecondary)),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 14, color: context.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == Role.user;
    // Blocks render as siblings so a tool card can sit between two prose blocks,
    // exactly as the daemon streamed them.
    final children = <Widget>[];
    for (final block in message.blocks) {
      final w = _buildBlock(context, block, isUser);
      if (w != null) children.add(w);
    }
    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget? _buildBlock(BuildContext context, Block block, bool isUser) {
    switch (block) {
      case TextBlock(:final text):
        if (text.isEmpty) return null;
        return _Bubble(text: text, isUser: isUser);
      case ThinkingBlock(:final text):
        if (text.trim().isEmpty) return null;
        return _ThinkingBubble(text: text);
      case ToolUseBlock():
        return _ToolCard(block: block);
      case ImageBlock(:final dataUrl):
        if (dataUrl == null) return null;
        final base64Part = dataUrl.split(',').last;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(base64Decode(base64Part), width: 340, fit: BoxFit.cover),
          ),
        );
      case ToolResultBlock():
      case SurfaceEventBlock():
      case UnknownBlock():
        return null;
    }
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.isUser});
  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isUser ? KorgColors.bubbleOut : context.bubbleInColor,
            borderRadius: BorderRadius.circular(18),
          ),
          child: SelectableText(
            text,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: isUser ? Colors.white : context.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: context.borderColor),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_outlined, size: 12, color: context.textSecondary),
                  const SizedBox(width: 6),
                  Text('Thinking', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textSecondary)),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(text, style: TextStyle(fontSize: 13, height: 1.4, color: context.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Computer — Done" card from the reference app. Wired for M4.
class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.block});
  final ToolUseBlock block;

  @override
  Widget build(BuildContext context) {
    final (statusLabel, statusColor) = switch (block.status) {
      ToolStatus.running => ('Running', KorgColors.accent),
      ToolStatus.done => ('Done', KorgColors.online),
      ToolStatus.error => ('Failed', KorgColors.danger),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.bubbleInColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(block.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 5, height: 5, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        Text(statusLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor)),
                      ],
                    ),
                  ),
                ],
              ),
              if (block.title != null) ...[
                const SizedBox(height: 6),
                Text(block.title!, style: TextStyle(fontSize: 13, color: context.textPrimary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: context.bubbleInColor, borderRadius: BorderRadius.circular(18)),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Staggered sine pulse across the three dots.
              final phase = (_c.value * 3 - i).clamp(0.0, 1.0);
              final opacity = 0.3 + 0.7 * (1 - (phase * 2 - 1).abs());
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: context.textSecondary, shape: BoxShape.circle),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread({required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: parseHexColor(bot.avatarColor),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.smart_toy_outlined, size: 26, color: Colors.white),
          ),
          const SizedBox(height: 14),
          Text(bot.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: context.textPrimary)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(
              bot.systemPrompt.isEmpty ? 'Send a message to get started.' : bot.systemPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: KorgColors.danger.withValues(alpha: 0.1),
      padding: const EdgeInsets.fromLTRB(18, 9, 8, 9),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 15, color: KorgColors.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12.5, color: KorgColors.danger))),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 15),
            color: KorgColors.danger,
            splashRadius: 14,
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.botName,
    required this.busy,
    required this.onSend,
    required this.onInterrupt,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String botName;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: context.borderColor))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.bubbleInColor,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Shortcuts(
                shortcuts: {
                  // Enter sends; Shift+Enter inserts a newline.
                  LogicalKeySet(LogicalKeyboardKey.enter): const _SendIntent(),
                },
                child: Actions(
                  actions: {
                    _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
                      onSend();
                      return null;
                    }),
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 6,
                    style: TextStyle(fontSize: 14, color: context.textPrimary),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                      hintText: 'Message $botName',
                      hintStyle: TextStyle(fontSize: 14, color: context.textSecondary),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(busy: busy, onSend: onSend, onInterrupt: onInterrupt),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.onSend, required this.onInterrupt});
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: busy ? context.bubbleInColor : KorgColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? onInterrupt : onSend,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: 18,
            color: busy ? context.textPrimary : Colors.white,
          ),
        ),
      ),
    );
  }
}
