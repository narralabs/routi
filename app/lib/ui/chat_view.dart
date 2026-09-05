import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/message_bubble.dart';

class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, this.showTitleBarInset = true, this.onToggleRail, this.railOpen = false});

  final bool showTitleBarInset;
  final VoidCallback? onToggleRail;
  final bool railOpen;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  int _signature = 0;

  @override
  void dispose() {
    _scroll.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// Stick to the tail while tokens stream, but only if the reader is already
  /// near the bottom — moving the viewport out from under someone reading history
  /// is the fastest way to make a chat app feel broken.
  void _followTail() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent - _scroll.position.pixels > 260) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final bot = chat.selectedBot;

    final signature = chat.messages.fold<int>(
      chat.messages.length,
      (acc, m) => acc + m.blocks.fold<int>(0, (a, b) => a + (b is TextBlock ? b.text.length : 1)),
    );
    if (signature != _signature) {
      _signature = signature;
      _followTail();
    }

    if (bot == null) {
      return Expanded(
        child: Container(
          color: context.canvas,
          child: Center(
            child: Text('Select a bot', style: TextStyle(fontSize: 13, color: context.textTertiary)),
          ),
        ),
      );
    }

    return Expanded(
      child: Container(
        color: context.canvas,
        child: Column(
          children: [
            _Header(
              bot: bot,
              showTitleBarInset: widget.showTitleBarInset,
              onToggleRail: widget.onToggleRail,
              railOpen: widget.railOpen,
            ),
            if (chat.error != null)
              _ErrorBanner(message: chat.error!, onDismiss: () => ref.read(chatProvider.notifier).clearError()),
            Expanded(
              child: chat.loadingMessages
                  ? const SizedBox.shrink()
                  : chat.messages.isEmpty
                      ? _EmptyThread(bot: bot)
                      : ScrollConfiguration(
                          behavior: const MacScrollBehavior(),
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
                            itemCount: chat.messages.length + (chat.isBusy ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (i >= chat.messages.length) {
                                return const Padding(
                                  padding: EdgeInsets.only(top: 10),
                                  child: _TypingBubble(),
                                );
                              }
                              final m = chat.messages[i];
                              final prev = i > 0 ? chat.messages[i - 1] : null;
                              return MessageBubble(
                                message: m,
                                isFirstInGroup: prev == null || prev.role != m.role,
                              );
                            },
                          ),
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

class _Header extends ConsumerWidget {
  const _Header({required this.bot, required this.showTitleBarInset, this.onToggleRail, this.railOpen = false});

  final Bot bot;
  final bool showTitleBarInset;
  final VoidCallback? onToggleRail;
  final bool railOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final current = models.where((m) => m.id == bot.model).firstOrNull;

    return Container(
      height: showTitleBarInset ? 52 : 46,
      padding: EdgeInsets.fromLTRB(18, showTitleBarInset ? 8 : 0, 12, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          BotAvatar(color: parseHexColor(bot.avatarColor), size: 22),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              bot.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.15,
                color: context.textPrimary,
              ),
            ),
          ),
          const Spacer(),
          if (models.isNotEmpty)
            _ModelPill(
              models: models,
              selected: bot.model,
              label: current?.displayName ?? bot.model,
              onSelected: (id) => ref.read(chatProvider.notifier).updateBot(bot.id, {'model': id}),
            ),
          const SizedBox(width: 4),
          _HeaderIcon(icon: Icons.ios_share_rounded, tooltip: 'Share', onTap: () {}),
          if (onToggleRail != null) ...[
            const SizedBox(width: 4),
            // Filled violet pill for the screen panel, as in the reference — the one
            // saturated control in the chrome, so it reads as the primary action.
            _ScreenToggle(active: railOpen, onTap: onToggleRail!),
          ],
        ],
      ),
    );
  }
}

class _ModelPill extends StatefulWidget {
  const _ModelPill({required this.models, required this.selected, required this.label, required this.onSelected});

  final List<ModelInfo> models;
  final String selected;
  final String label;
  final ValueChanged<String> onSelected;

  @override
  State<_ModelPill> createState() => _ModelPillState();
}

class _ModelPillState extends State<_ModelPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      onSelected: widget.onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: context.isDark ? const Color(0xFF2C2C2E) : Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: context.hairline, width: 0.5),
      ),
      itemBuilder: (context) => [
        for (final m in widget.models)
          PopupMenuItem(
            value: m.id,
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: m.id == widget.selected
                      ? const Icon(Icons.check_rounded, size: 14, color: K.accent)
                      : null,
                ),
                Text(
                  m.displayName,
                  style: TextStyle(fontSize: 13, color: context.textPrimary),
                ),
                if (m.resolvedModel != null) ...[
                  const SizedBox(width: 12),
                  Text(m.resolvedModel!, style: TextStyle(fontSize: 11, color: context.textTertiary)),
                ],
              ],
            ),
          ),
      ],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
          decoration: BoxDecoration(
            color: _hovered ? context.control : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: context.hairline, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.label, style: TextStyle(fontSize: 12, color: context.textSecondary)),
              const SizedBox(width: 3),
              Icon(Icons.unfold_more_rounded, size: 13, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatefulWidget {
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_HeaderIcon> createState() => _HeaderIconState();
}

class _HeaderIconState extends State<_HeaderIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? context.control : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(widget.icon, size: 17, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _ScreenToggle extends StatefulWidget {
  const _ScreenToggle({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_ScreenToggle> createState() => _ScreenToggleState();
}

class _ScreenToggleState extends State<_ScreenToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.active;
    return Tooltip(
      message: on ? 'Hide screen' : 'Show screen',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: on
                  ? K.violet.withValues(alpha: _hovered ? 1 : 0.92)
                  : (_hovered ? context.control : Colors.transparent),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.desktop_windows_rounded,
              size: 15,
              color: on ? Colors.white : context.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        decoration: BoxDecoration(
          color: context.bubbleIn,
          borderRadius: BorderRadius.circular(K.radiusBubble),
        ),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Each dot lags the previous by a third of the cycle.
              final t = (_c.value - i * 0.16) % 1.0;
              final lift = t < 0.4 ? Curves.easeOut.transform(t / 0.4) : 1 - Curves.easeIn.transform(((t - 0.4) / 0.6).clamp(0, 1));
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                child: Transform.translate(
                  offset: Offset(0, -2.5 * lift),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: context.textTertiary.withValues(alpha: 0.5 + 0.5 * lift),
                      shape: BoxShape.circle,
                    ),
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
          BotAvatar(color: parseHexColor(bot.avatarColor), size: 56),
          const SizedBox(height: 14),
          Text(
            bot.name,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: context.textPrimary),
          ),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              bot.systemPrompt.isEmpty ? 'Send a message to get started.' : bot.systemPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: context.textTertiary),
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
      color: K.danger.withValues(alpha: 0.09),
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: K.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12.5, color: K.danger))),
          GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 14, color: K.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
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
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() => _focused = widget.focusNode.hasFocus);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _RoundIcon(icon: Icons.add_rounded, tooltip: 'Attach', onTap: () {}),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              decoration: BoxDecoration(
                color: context.bubbleIn,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _focused ? K.accent.withValues(alpha: 0.55) : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Shortcuts(
                shortcuts: const {
                  // Enter sends. Shift+Enter falls through to the field and inserts
                  // a newline, which is the convention every chat app uses.
                  SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                },
                child: Actions(
                  actions: {
                    _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
                      widget.onSend();
                      return null;
                    }),
                  },
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: widget.controller,
                          focusNode: widget.focusNode,
                          minLines: 1,
                          maxLines: 8,
                          cursorHeight: 16,
                          style: TextStyle(fontSize: 14, height: 1.4, color: context.textPrimary),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 11),
                            hintText: 'Message ${widget.botName}',
                            hintStyle: TextStyle(fontSize: 14, color: context.textTertiary),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7, left: 6),
                        child: Icon(Icons.mic_none_rounded, size: 17, color: context.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(busy: widget.busy, onSend: widget.onSend, onInterrupt: widget.onInterrupt),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _RoundIcon extends StatefulWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_RoundIcon> createState() => _RoundIconState();
}

class _RoundIconState extends State<_RoundIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hovered ? context.control : context.bubbleIn,
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, size: 18, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.busy, required this.onSend, required this.onInterrupt});

  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.busy ? context.bubbleIn : K.accent;
    return Tooltip(
      message: widget.busy ? 'Stop' : 'Send',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.busy ? widget.onInterrupt : widget.onSend,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            scale: _hovered ? 1.06 : 1,
            duration: const Duration(milliseconds: 110),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(
                widget.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                size: 17,
                color: widget.busy ? context.textPrimary : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
