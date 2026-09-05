import 'package:flutter/material.dart';

import '../theme.dart';

/// The rounded-square bot avatar with the two-dot face from the reference app.
///
/// Drawn rather than shipped as an asset so it tints to any bot colour and stays
/// crisp at every size and scale factor.
class BotAvatar extends StatelessWidget {
  const BotAvatar({
    super.key,
    required this.color,
    this.size = 34,
    this.online = false,
    this.ringColor,
  });

  final Color color;
  final double size;
  final bool online;

  /// Colour behind the online dot's cut-out; should match whatever it sits on.
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    final dot = size * 0.28;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              // Continuous curvature is the Apple corner shape; a plain circular
              // radius looks subtly boxy next to real macOS icons.
              borderRadius: BorderRadius.circular(size * 0.32),
            ),
            child: CustomPaint(painter: _FacePainter()),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: K.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor ?? context.canvas, width: size * 0.055),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.95);
    final eyeW = size.width * 0.1;
    final eyeH = size.height * 0.2;
    final y = size.height * 0.40;
    final gap = size.width * 0.20;

    for (final dx in [-gap, gap]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2 + dx, y + eyeH / 2),
            width: eyeW,
            height: eyeH,
          ),
          Radius.circular(eyeW),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FacePainter oldDelegate) => false;
}

/// Circular initials avatar, used for the account row.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.initials, this.size = 26});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: context.control, shape: BoxShape.circle),
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: context.textSecondary,
        ),
      ),
    );
  }
}
