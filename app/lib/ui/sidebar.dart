import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/avatar.dart';

/// Left sidebar. Sits on window vibrancy, so its own background is a tint rather
/// than an opaque fill.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, required this.onNewBot, this.width = K.sidebarWidth, this.showTitleBarInset = true});

  final VoidCallback onNewBot;
  final double? width;

  /// Leaves room for the traffic lights when the title bar is hidden.
  final bool showTitleBarInset;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
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
        color: context.sidebarTint,
        border: widget.width == null ? null : Border(right: BorderSide(color: context.hairline, width: 0.5)),
      ),
      child: Column(
        children: [
          if (widget.showTitleBarInset) const SizedBox(height: K.titleBarHeight),
          _SearchField(onChanged: (v) => setState(() => _query = v), onNewBot: widget.onNewBot),
          Expanded(
            child: bots.isEmpty
                ? _EmptyState(hasQuery: _query.isNotEmpty)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                    itemCount: bots.length,
                    itemBuilder: (context, i) {
                      final bot = bots[i];
                      final conv = chat.conversationForBot(bot.id);
                      return _BotRow(
                        bot: bot,
                        conversation: conv,
                        selected: bot.id == chat.selectedBotId,
                        busy: conv != null && chat.busyConversations.contains(conv.id),
                        onTap: () => ref.read(chatProvider.notifier).selectBot(bot.id),
                        onDelete: () => _confirmDelete(context, bot),
                      );
                    },
                  ),
          ),
          _Footer(connection: connection),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Bot bot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${bot.name}”?', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: const Text(
          'This permanently removes the bot and every conversation in it.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: K.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await ref.read(chatProvider.notifier).deleteBot(bot.id);
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged, required this.onNewBot});

  final ValueChanged<String> onChanged;
  final VoidCallback onNewBot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 28,
              child: TextField(
                onChanged: onChanged,
                cursorHeight: 14,
                style: TextStyle(fontSize: 13, color: context.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(fontSize: 13, color: context.textTertiary),
                  prefixIcon: Icon(Icons.search_rounded, size: 15, color: context.textTertiary),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  filled: true,
                  fillColor: context.isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.7),
                  isDense: true,
                  contentPadding: const EdgeInsets.only(bottom: 10),
                  border: _border(context),
                  enabledBorder: _border(context),
                  focusedBorder: _border(context, focused: true),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _IconButton(icon: Icons.add_rounded, tooltip: 'New bot', size: 19, onTap: onNewBot),
        ],
      ),
    );
  }

  OutlineInputBorder _border(BuildContext context, {bool focused = false}) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: focused ? K.accent.withValues(alpha: 0.6) : context.hairline,
          width: focused ? 1.5 : 0.5,
        ),
      );
}

class _BotRow extends StatefulWidget {
  const _BotRow({
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
  State<_BotRow> createState() => _BotRowState();
}

class _BotRowState extends State<_BotRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.conversation?.title ?? 'New chat';
    final stamp = _relativeStamp(widget.conversation?.lastMessageAt);

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTap: widget.onDelete,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? context.sidebarSelected
                : _hovered
                    ? context.sidebarHover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BotAvatar(
                color: parseHexColor(widget.bot.avatarColor),
                size: 34,
                online: widget.busy,
                ringColor: context.isDark ? const Color(0xFF2A2A2C) : const Color(0xFFECECEE),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.bot.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              color: context.textPrimary,
                            ),
                          ),
                        ),
                        if (stamp != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            stamp,
                            style: TextStyle(fontSize: 11, color: context.textTertiary),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.35, color: context.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iMessage-style stamps: time today, weekday this week, date beyond that.
String? _relativeStamp(int? ms) {
  if (ms == null) return null;
  final then = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(then.year, then.month, then.day);
  final daysAgo = today.difference(thatDay).inDays;

  if (daysAgo == 0) {
    final h = then.hour % 12 == 0 ? 12 : then.hour % 12;
    final m = then.minute.toString().padLeft(2, '0');
    return '$h:$m ${then.hour < 12 ? 'AM' : 'PM'}';
  }
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[then.weekday - 1];
  }
  return '${then.month}/${then.day}/${then.year % 100}';
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          hasQuery ? 'No matches.' : 'No bots yet.\nCreate one with +.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.5, color: context.textTertiary),
        ),
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.connection});
  final KorgConnectionState connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(clientProvider).account;
    final (statusLabel, statusColor) = switch (connection) {
      KorgConnectionState.connected => (account?.label ?? 'Connected', K.online),
      KorgConnectionState.connecting => ('Connecting…', K.textTertiary),
      KorgConnectionState.disconnected => ('korgd offline', K.danger),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FooterRow(
            leading: Icon(Icons.grid_view_rounded, size: 17, color: context.textSecondary),
            label: 'Marketplace',
            onTap: () {},
          ),
          _FooterRow(
            leading: InitialsAvatar(initials: _initials(account?.organization)),
            label: _displayName(account?.organization),
            trailing: Tooltip(
              message: statusLabel,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
            ),
            onTap: () {},
          ),
        ],
      ),
    );
  }

  static String _displayName(String? organization) {
    if (organization == null || organization.isEmpty) return 'Account';
    // Organizations come back as "someone@example.com's Organization".
    final email = organization.split("'").first;
    final local = email.contains('@') ? email.split('@').first : email;
    return local
        .split(RegExp(r'[._-]'))
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1))
        .join(' ');
  }

  static String _initials(String? organization) {
    final name = _displayName(organization);
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _FooterRow extends StatefulWidget {
  const _FooterRow({required this.leading, required this.label, this.trailing, required this.onTap});

  final Widget leading;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  State<_FooterRow> createState() => _FooterRowState();
}

class _FooterRowState extends State<_FooterRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? context.sidebarHover : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              SizedBox(width: 26, child: Center(child: widget.leading)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.textPrimary),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

/// Borderless hover-highlight icon button, the macOS toolbar idiom.
class _IconButton extends StatefulWidget {
  const _IconButton({required this.icon, required this.onTap, this.tooltip, this.size = 17});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hovered ? context.sidebarSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon, size: widget.size, color: context.textSecondary),
        ),
      ),
    );
    return widget.tooltip == null ? button : Tooltip(message: widget.tooltip!, child: button);
  }
}
