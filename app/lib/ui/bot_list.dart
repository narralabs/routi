import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// The left sidebar: search, the bot list, and account state at the bottom.
class BotList extends ConsumerStatefulWidget {
  const BotList({super.key, required this.onNewBot, this.width = 260});

  final VoidCallback onNewBot;

  /// Fixed on desktop where it sits beside the thread; null on phone to fill.
  final double? width;

  @override
  ConsumerState<BotList> createState() => _BotListState();
}

class _BotListState extends ConsumerState<BotList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final connection = ref.watch(connectionProvider).value ?? KorgConnectionState.disconnected;

    final bots = chat.bots.where((b) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      final conv = chat.conversationForBot(b.id);
      return b.name.toLowerCase().contains(q) || (conv?.title.toLowerCase().contains(q) ?? false);
    }).toList();

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: context.sidebarColor,
        border: widget.width == null
            ? null
            : Border(right: BorderSide(color: context.borderColor)),
      ),
      child: Column(
        children: [
          _Header(onNewBot: widget.onNewBot),
          _SearchField(onChanged: (v) => setState(() => _query = v)),
          Expanded(
            child: bots.isEmpty
                ? _EmptySidebar(hasQuery: _query.isNotEmpty)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: bots.length,
                    itemBuilder: (context, i) {
                      final bot = bots[i];
                      return _BotTile(
                        bot: bot,
                        conversation: chat.conversationForBot(bot.id),
                        selected: bot.id == chat.selectedBotId,
                        busy: _isBotBusy(chat, bot.id),
                        onTap: () => ref.read(chatProvider.notifier).selectBot(bot.id),
                        onDelete: () => _confirmDelete(context, bot),
                      );
                    },
                  ),
          ),
          _AccountFooter(connection: connection),
        ],
      ),
    );
  }

  static bool _isBotBusy(ChatState chat, String botId) {
    final conv = chat.conversationForBot(botId);
    return conv != null && chat.busyConversations.contains(conv.id);
  }

  Future<void> _confirmDelete(BuildContext context, Bot bot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${bot.name}?'),
        content: const Text('This permanently removes the bot and all of its conversations.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: KorgColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(chatProvider.notifier).deleteBot(bot.id);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onNewBot});
  final VoidCallback onNewBot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Leaves room for the macOS traffic lights.
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Row(
        children: [
          Text('Korg', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: context.textPrimary)),
          const Spacer(),
          IconButton(
            onPressed: onNewBot,
            icon: const Icon(Icons.add, size: 20),
            tooltip: 'New bot',
            color: context.textSecondary,
            splashRadius: 16,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: SizedBox(
        height: 30,
        child: TextField(
          onChanged: onChanged,
          style: TextStyle(fontSize: 13, color: context.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search',
            hintStyle: TextStyle(fontSize: 13, color: context.textSecondary),
            prefixIcon: Icon(Icons.search, size: 16, color: context.textSecondary),
            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            filled: true,
            fillColor: context.canvasColor.withValues(alpha: context.isDark ? 0.5 : 1),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.borderColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _BotTile extends StatefulWidget {
  const _BotTile({
    required this.bot,
    required this.conversation,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onDelete,
  });

  final Bot bot;
  final Conversation? conversation;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_BotTile> createState() => _BotTileState();
}

class _BotTileState extends State<_BotTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.conversation?.title ?? 'New chat';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTap: widget.onDelete,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: widget.selected
                    ? context.sidebarSelectedColor
                    : _hovered
                        ? context.sidebarSelectedColor.withValues(alpha: 0.5)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Avatar(color: parseHexColor(widget.bot.avatarColor), busy: widget.busy),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.bot.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.color, this.busy = false});
  final Color color;
  final bool busy;
  static const size = 30.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size / 3)),
            child: Icon(Icons.smart_toy_outlined, size: size * 0.5, color: Colors.white.withValues(alpha: 0.92)),
          ),
          if (busy)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: KorgColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.sidebarColor, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptySidebar extends StatelessWidget {
  const _EmptySidebar({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          hasQuery ? 'No bots match that search.' : 'No bots yet.\nCreate one with +.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.textSecondary, height: 1.5),
        ),
      ),
    );
  }
}

class _AccountFooter extends ConsumerWidget {
  const _AccountFooter({required this.connection});
  final KorgConnectionState connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(clientProvider).account;
    final (label, color) = switch (connection) {
      KorgConnectionState.connected => (account?.label ?? 'Connected', KorgColors.online),
      KorgConnectionState.connecting => ('Connecting…', KorgColors.textSecondary),
      KorgConnectionState.disconnected => ('korgd offline', KorgColors.danger),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: context.borderColor))),
      child: Row(
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
