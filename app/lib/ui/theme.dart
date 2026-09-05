import 'dart:io';

import 'package:flutter/material.dart';

/// Design tokens.
///
/// Two rules that do most of the work here:
///
/// 1. Never set `fontFamily`. On Apple platforms Flutter already resolves to the
///    system UI font (SF Pro), correctly optical-sized and hinted. Naming a family
///    string opts out of that and is the single most common reason a Flutter app
///    reads as "not quite native" on macOS.
/// 2. Sizes and spacings are on a 2pt grid and deliberately small. macOS chrome is
///    tighter than Material's defaults; Material's stock sizing is what made the
///    first pass look like an Android app in a window.
class K {
  // Light -------------------------------------------------------------------
  /// Sidebar sits on top of NSVisualEffectView, so it is translucent by design.
  static const sidebarTint = Color(0x0A000000);
  static const sidebarSelected = Color(0x14000000);
  static const sidebarHover = Color(0x0A000000);
  static const canvas = Color(0xFFFFFFFF);
  static const bubbleIn = Color(0xFFF1F1F3);
  static const bubbleOut = Color(0xFF0A84FF);
  static const hairline = Color(0x14000000);
  static const textPrimary = Color(0xFF1D1D1F);
  static const textSecondary = Color(0xFF86868B);
  static const textTertiary = Color(0xFFA1A1A6);
  static const control = Color(0xFFF5F5F7);

  // Dark --------------------------------------------------------------------
  static const sidebarTintDark = Color(0x14FFFFFF);
  static const sidebarSelectedDark = Color(0x1FFFFFFF);
  static const sidebarHoverDark = Color(0x0FFFFFFF);
  static const canvasDark = Color(0xFF1A1A1C);
  static const bubbleInDark = Color(0xFF2A2A2D);
  static const hairlineDark = Color(0x1AFFFFFF);
  static const textPrimaryDark = Color(0xFFF5F5F7);
  static const textSecondaryDark = Color(0xFF98989D);
  static const textTertiaryDark = Color(0xFF6E6E73);
  static const controlDark = Color(0xFF2A2A2D);

  // Shared ------------------------------------------------------------------
  static const accent = Color(0xFF0A84FF);
  static const danger = Color(0xFFFF453A);
  static const online = Color(0xFF32D74B);
  static const violet = Color(0xFF7D5FFF);

  /// Avatar palette, matching the reference app's spread of hues.
  static const palette = [
    Color(0xFF8E8E93),
    Color(0xFFFF9F0A),
    Color(0xFFFF453A),
    Color(0xFF32D0A4),
    Color(0xFF64D2FF),
    Color(0xFF0A84FF),
    Color(0xFF32D74B),
    Color(0xFFFFD60A),
    Color(0xFFBF5AF2),
  ];

  // Metrics
  static const sidebarWidth = 268.0;
  static const railWidth = 300.0;
  static const radiusBubble = 18.0;
  static const radiusCard = 14.0;
  static const radiusControl = 8.0;
  /// Height of the draggable strip that replaces the hidden title bar.
  static const titleBarHeight = 38.0;
}

Color parseHexColor(String hex, {Color fallback = K.textSecondary}) {
  final cleaned = hex.replaceFirst('#', '').trim();
  if (cleaned.length != 6) return fallback;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? fallback : Color(0xFF000000 | value);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: K.accent, brightness: brightness).copyWith(
    surface: dark ? K.canvasDark : K.canvas,
    primary: K.accent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    // Deliberately unset — see the note at the top of this file.
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: Color(0x330A84FF),
      cursorColor: K.accent,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(fontSize: 11.5, color: dark ? K.textPrimaryDark : Colors.white),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3A3D) : const Color(0xE61D1D1F),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
  );
}

extension KorgTheme on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get sidebarTint => isDark ? K.sidebarTintDark : K.sidebarTint;
  Color get sidebarSelected => isDark ? K.sidebarSelectedDark : K.sidebarSelected;
  Color get sidebarHover => isDark ? K.sidebarHoverDark : K.sidebarHover;
  Color get canvas => isDark ? K.canvasDark : K.canvas;
  Color get bubbleIn => isDark ? K.bubbleInDark : K.bubbleIn;
  Color get hairline => isDark ? K.hairlineDark : K.hairline;
  Color get textPrimary => isDark ? K.textPrimaryDark : K.textPrimary;
  Color get textSecondary => isDark ? K.textSecondaryDark : K.textSecondary;
  Color get textTertiary => isDark ? K.textTertiaryDark : K.textTertiary;
  Color get control => isDark ? K.controlDark : K.control;
}

/// True when the platform gives us real window vibrancy to sit on.
bool get supportsVibrancy => !kIsWebLike && Platform.isMacOS;
const kIsWebLike = bool.fromEnvironment('dart.library.js_util');

/// macOS scroll feel. Flutter's default Android physics overscroll-glows, which
/// instantly reads as wrong on a Mac; bouncing matches every native scroll view.
class MacScrollBehavior extends MaterialScrollBehavior {
  const MacScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
