import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/avatar.dart';

/// Right-hand detail rail: the bot's live surface, and its routines.
///
/// The surface panel is a placeholder until M3 lands the WebRTC pipeline; it is here
/// now so the three-pane proportions are real rather than guessed at later.
class DetailRail extends ConsumerWidget {
  const DetailRail({super.key, required this.bot, required this.onClose, this.showTitleBarInset = true});

  final Bot bot;
  final VoidCallback onClose;
  final bool showTitleBarInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: K.railWidth,
      decoration: BoxDecoration(
        color: context.sidebarTint,
        border: Border(left: BorderSide(color: context.hairline, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: showTitleBarInset ? 52 : 46,
            child: Padding(
              padding: EdgeInsets.fromLTRB(10, showTitleBarInset ? 8 : 0, 10, 0),
              child: Row(
                children: [
                  _RailIcon(
                    icon: Icons.tune_rounded,
                    tooltip: 'Bot settings',
                    onTap: () => _showSettings(context, ref),
                  ),
                  const Spacer(),
                  _RailIcon(icon: Icons.keyboard_double_arrow_right_rounded, tooltip: 'Hide', onTap: onClose),
                ],
              ),
            ),
          ),
          Expanded(
            child: ScrollConfiguration(
              behavior: const MacScrollBehavior(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                children: [
                  _SurfacePanel(bot: bot),
                  const SizedBox(height: 26),
                  _RoutinesPanel(botName: bot.name),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context, WidgetRef ref) {
    showDialog(context: context, builder: (_) => _BotSettingsDialog(bot: bot));
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final enabled = bot.surfaceMode != SurfaceMode.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 10,
          child: Container(
            decoration: BoxDecoration(
              color: context.isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.hairline, width: 0.5),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    enabled ? Icons.desktop_windows_outlined : Icons.desktop_access_disabled_outlined,
                    size: 26,
                    color: context.textTertiary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    enabled ? 'Waiting for stream' : 'No surface',
                    style: TextStyle(fontSize: 12, color: context.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          switch (bot.surfaceMode) {
            SurfaceMode.container => "${bot.name}'s container",
            SurfaceMode.host => "${bot.name} on this Mac",
            SurfaceMode.none => 'This bot has no screen',
          },
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: context.textSecondary),
        ),
      ],
    );
  }
}

class _RoutinesPanel extends StatelessWidget {
  const _RoutinesPanel({required this.botName});
  final String botName;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'Routines are recurring tasks this Bot runs on a schedule.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.55, color: context.textSecondary),
        ),
        const SizedBox(height: 14),
        _OutlineButton(label: 'Create Routine', onTap: () {}),
      ],
    );
  }
}

class _OutlineButton extends StatefulWidget {
  const _OutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_OutlineButton> createState() => _OutlineButtonState();
}

class _OutlineButtonState extends State<_OutlineButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: _hovered
                ? (context.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white)
                : (context.isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white.withValues(alpha: 0.65)),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: context.hairline, width: 0.5),
          ),
          child: Text(
            widget.label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _RailIcon extends StatefulWidget {
  const _RailIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_RailIcon> createState() => _RailIconState();
}

class _RailIconState extends State<_RailIcon> {
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
              color: _hovered ? context.sidebarSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(widget.icon, size: 17, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// Edit a bot's name, personality, and surface.
class _BotSettingsDialog extends ConsumerStatefulWidget {
  const _BotSettingsDialog({required this.bot});
  final Bot bot;

  @override
  ConsumerState<_BotSettingsDialog> createState() => _BotSettingsDialogState();
}

class _BotSettingsDialogState extends ConsumerState<_BotSettingsDialog> {
  late final _name = TextEditingController(text: widget.bot.name);
  late final _prompt = TextEditingController(text: widget.bot.systemPrompt);
  late SurfaceMode _surface = widget.bot.surfaceMode;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(chatProvider.notifier).updateBot(widget.bot.id, {
      'name': _name.text.trim(),
      'systemPrompt': _prompt.text.trim(),
      'surfaceMode': _surface.name,
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          BotAvatar(color: parseHexColor(widget.bot.avatarColor), size: 26),
          const SizedBox(width: 10),
          const Text('Bot settings', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 16),
            TextField(
              controller: _prompt,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Personality', alignLabelWithHint: true),
            ),
            const SizedBox(height: 20),
            Text('Screen', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.textSecondary)),
            const SizedBox(height: 8),
            SegmentedButton<SurfaceMode>(
              segments: const [
                ButtonSegment(value: SurfaceMode.none, label: Text('None')),
                ButtonSegment(value: SurfaceMode.container, label: Text('Container')),
                ButtonSegment(value: SurfaceMode.host, label: Text('This Mac')),
              ],
              selected: {_surface},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (s) => setState(() => _surface = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              switch (_surface) {
                SurfaceMode.none => 'Chat only. The bot has no screen to look at.',
                SurfaceMode.container => 'An isolated Linux container. Safe to reset, and several can run at once.',
                SurfaceMode.host => 'Your real desktop. The bot shares your mouse and sees everything on screen.',
              },
              style: TextStyle(fontSize: 12, height: 1.45, color: context.textTertiary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
