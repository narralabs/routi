import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../api/models.dart';
import '../theme.dart';

/// One assistant/user turn.
///
/// Blocks render as siblings, so a tool card can sit between two paragraphs exactly
/// as the daemon streamed them. Hover reveals the action row, matching the reference.
class MessageBubble extends StatefulWidget {
  const MessageBubble({super.key, required this.message, required this.isFirstInGroup});

  final Message message;

  /// False when the previous message had the same author, which tightens spacing.
  final bool isFirstInGroup;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == Role.user;
    final blocks = <Widget>[];
    for (final b in widget.message.blocks) {
      final w = _buildBlock(context, b, isUser);
      if (w != null) blocks.add(w);
    }
    if (blocks.isEmpty) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: EdgeInsets.only(top: widget.isFirstInGroup ? 10 : 2),
        child: Row(
          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (isUser) _Actions(visible: _hovered, message: widget.message, alignEnd: false),
            Flexible(
              child: Column(
                crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: blocks,
              ),
            ),
            if (!isUser) _Actions(visible: _hovered, message: widget.message, alignEnd: true),
          ],
        ),
      ),
    );
  }

  Widget? _buildBlock(BuildContext context, Block block, bool isUser) {
    switch (block) {
      case TextBlock(:final text):
        if (text.trim().isEmpty) return null;
        return _Bubble(text: text, isUser: isUser);
      case ThinkingBlock(:final text):
        if (text.trim().isEmpty) return null;
        return _ThinkingDisclosure(text: text);
      case ToolUseBlock():
        return ToolCard(block: block);
      case ImageBlock(:final dataUrl):
        if (dataUrl == null) return null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(K.radiusCard),
            child: Image.memory(base64Decode(dataUrl.split(',').last), width: 380, fit: BoxFit.cover),
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
    final fg = isUser ? Colors.white : context.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
          decoration: BoxDecoration(
            color: isUser ? K.bubbleOut : context.bubbleIn,
            borderRadius: BorderRadius.circular(K.radiusBubble),
          ),
          child: SelectionArea(
            child: GptMarkdown(
              text,
              style: TextStyle(fontSize: 14, height: 1.44, color: fg, letterSpacing: -0.05),
              // In a blue user bubble the default link blue is invisible, so links
              // there take the bubble's own foreground instead.
              followLinkColor: isUser,
            ),
          ),
        ),
      ),
    );
  }
}

/// Reasoning is collapsed by default — expanded by default it dominates the
/// transcript and buries the actual answer.
class _ThinkingDisclosure extends StatefulWidget {
  const _ThinkingDisclosure({required this.text});
  final String text;

  @override
  State<_ThinkingDisclosure> createState() => _ThinkingDisclosureState();
}

class _ThinkingDisclosureState extends State<_ThinkingDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => setState(() => _open = !_open),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: Icon(Icons.chevron_right_rounded, size: 15, color: context.textTertiary),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      'Thought process',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: context.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: Alignment.topLeft,
              child: _open
                  ? Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(left: 6, bottom: 2),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: context.hairline, width: 2)),
                      ),
                      child: SelectionArea(
                        child: Text(
                          widget.text,
                          style: TextStyle(fontSize: 12.5, height: 1.5, color: context.textSecondary),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Computer — Done" card from the reference app.
class ToolCard extends StatelessWidget {
  const ToolCard({super.key, required this.block});
  final ToolUseBlock block;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (block.status) {
      ToolStatus.running => ('Running', K.accent),
      ToolStatus.done => ('Done', K.online),
      ToolStatus.error => ('Failed', K.danger),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: context.bubbleIn, borderRadius: BorderRadius.circular(K.radiusCard)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    block.name,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color)),
                    ],
                  ),
                ],
              ),
              if (block.title != null) ...[
                const SizedBox(height: 7),
                Text(block.title!, style: TextStyle(fontSize: 13, height: 1.4, color: context.textPrimary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Hover action row: react, reply, more — as in the reference.
class _Actions extends StatelessWidget {
  const _Actions({required this.visible, required this.message, required this.alignEnd});

  final bool visible;
  final Message message;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: IgnorePointer(
        ignoring: !visible,
        child: Padding(
          padding: EdgeInsets.only(left: alignEnd ? 6 : 0, right: alignEnd ? 0 : 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniButton(
                icon: Icons.copy_rounded,
                tooltip: 'Copy',
                onTap: () => Clipboard.setData(ClipboardData(text: message.preview)),
              ),
              _MiniButton(icon: Icons.reply_rounded, tooltip: 'Reply', onTap: () {}),
              _MiniButton(icon: Icons.more_horiz_rounded, tooltip: 'More', onTap: () {}),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatefulWidget {
  const _MiniButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
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
            width: 24,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _hovered ? context.bubbleIn : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, size: 13, color: context.textTertiary),
          ),
        ),
      ),
    );
  }
}
