import 'package:flutter/material.dart';

/// Design tokens, kept in one place so the macOS and iOS builds stay identical.
/// Modelled on the reference app: near-white chrome, soft grey bubbles, one accent.
class KorgColors {
  static const sidebar = Color(0xFFF2F2F4);
  static const sidebarSelected = Color(0xFFE3E3E6);
  static const canvas = Color(0xFFFFFFFF);
  static const bubbleIn = Color(0xFFF1F1F3);
  static const bubbleOut = Color(0xFF007AFF);
  static const border = Color(0xFFE2E2E5);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF8A8A8E);
  static const accent = Color(0xFF007AFF);
  static const danger = Color(0xFFFF3B30);
  static const online = Color(0xFF34C759);

  static const sidebarDark = Color(0xFF1B1B1D);
  static const sidebarSelectedDark = Color(0xFF2C2C2F);
  static const canvasDark = Color(0xFF121213);
  static const bubbleInDark = Color(0xFF232326);
  static const borderDark = Color(0xFF2E2E31);
  static const textPrimaryDark = Color(0xFFF2F2F4);
  static const textSecondaryDark = Color(0xFF9A9AA0);
}

/// Resolves a bot's stored hex colour, falling back rather than throwing on bad data.
Color parseHexColor(String hex, {Color fallback = KorgColors.textSecondary}) {
  final cleaned = hex.replaceFirst('#', '').trim();
  if (cleaned.length != 6) return fallback;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? fallback : Color(0xFF000000 | value);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: KorgColors.accent,
    brightness: brightness,
  ).copyWith(
    surface: dark ? KorgColors.canvasDark : KorgColors.canvas,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? KorgColors.canvasDark : KorgColors.canvas,
    dividerColor: dark ? KorgColors.borderDark : KorgColors.border,
    fontFamily: '.SF Pro Text',
    textTheme: TextTheme(
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.45,
        color: dark ? KorgColors.textPrimaryDark : KorgColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: dark ? KorgColors.textPrimaryDark : KorgColors.textPrimary,
      ),
      bodySmall: TextStyle(
        fontSize: 12.5,
        color: dark ? KorgColors.textSecondaryDark : KorgColors.textSecondary,
      ),
    ),
  );
}

/// Theme-aware accessors, so widgets don't branch on brightness inline.
extension KorgTheme on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get sidebarColor => isDark ? KorgColors.sidebarDark : KorgColors.sidebar;
  Color get sidebarSelectedColor => isDark ? KorgColors.sidebarSelectedDark : KorgColors.sidebarSelected;
  Color get canvasColor => isDark ? KorgColors.canvasDark : KorgColors.canvas;
  Color get bubbleInColor => isDark ? KorgColors.bubbleInDark : KorgColors.bubbleIn;
  Color get borderColor => isDark ? KorgColors.borderDark : KorgColors.border;
  Color get textPrimary => isDark ? KorgColors.textPrimaryDark : KorgColors.textPrimary;
  Color get textSecondary => isDark ? KorgColors.textSecondaryDark : KorgColors.textSecondary;
}
