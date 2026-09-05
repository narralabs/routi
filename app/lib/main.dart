import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import 'state/app_state.dart';
import 'ui/chat_view.dart';
import 'ui/detail_rail.dart';
import 'ui/new_bot_sheet.dart';
import 'ui/sidebar.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isMacOS) {
    await WindowManipulator.initialize(enableWindowDelegate: true);
    // Sidebar vibrancy: the window's material shows through the translucent panes,
    // picking up the desktop behind it the way every native macOS sidebar does.
    await WindowManipulator.setMaterial(NSVisualEffectViewMaterial.sidebar);
    // Hide the title bar but keep the traffic lights, then inset them so they sit
    // in the sidebar's top padding rather than on top of the search field.
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
    await WindowManipulator.setWindowMinSize(const Size(420, 480));
  }

  runApp(const ProviderScope(child: KorgApp()));
}

class KorgApp extends StatelessWidget {
  const KorgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Korg',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      scrollBehavior: const MacScrollBehavior(),
      home: Platform.isMacOS
          ? const MacosToolbarPassthroughScope(child: HomeShell())
          : const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _railOpen = true;

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isMacOS;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        // The rail only earns its space once the thread still has room to breathe.
        final canShowRail = constraints.maxWidth >= 1100;

        return Stack(
          children: [
            wide
                ? _WideLayout(
                    railOpen: _railOpen && canShowRail,
                    canShowRail: canShowRail,
                    onToggleRail: () => setState(() => _railOpen = !_railOpen),
                    titleBarInset: isDesktop,
                  )
                : _NarrowLayout(titleBarInset: isDesktop),
            // A drag strip standing in for the hidden title bar, so the window can
            // still be moved by its top edge.
            if (isDesktop)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: K.titleBarHeight,
                child: _DragToMove(),
              ),
          ],
        );
      },
    );
  }
}

/// Hands the top strip's mouse events to the native titlebar underneath, which is
/// what restores drag-to-move and double-click-to-zoom after hiding the title bar.
/// Sized to clear the traffic lights so it never swallows their clicks.
class _DragToMove extends StatelessWidget {
  const _DragToMove();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 78),
      child: MacosToolbarPassthrough(child: SizedBox.expand()),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout({
    required this.railOpen,
    required this.canShowRail,
    required this.onToggleRail,
    required this.titleBarInset,
  });

  final bool railOpen;
  final bool canShowRail;
  final VoidCallback onToggleRail;
  final bool titleBarInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bot = ref.watch(chatProvider).selectedBot;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          Sidebar(
            onNewBot: () => NewBotSheet.show(context),
            showTitleBarInset: titleBarInset,
          ),
          ChatView(
            showTitleBarInset: titleBarInset,
            railOpen: railOpen,
            onToggleRail: canShowRail ? onToggleRail : null,
          ),
          // Animate the rail's width so toggling it slides rather than snaps.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: railOpen && bot != null
                ? DetailRail(bot: bot, onClose: onToggleRail, showTitleBarInset: titleBarInset)
                : const SizedBox(height: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout({required this.titleBarInset});
  final bool titleBarInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bot = ref.watch(chatProvider).selectedBot;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: !titleBarInset,
        child: bot == null
            ? Sidebar(
                width: null,
                onNewBot: () => NewBotSheet.show(context),
                showTitleBarInset: titleBarInset,
              )
            : Column(
                children: [
                  _MobileHeader(
                    title: bot.name,
                    topInset: titleBarInset,
                    onBack: () => ref.read(chatProvider.notifier).clearSelection(),
                  ),
                  ChatView(showTitleBarInset: false),
                ],
              ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({required this.title, required this.onBack, required this.topInset});

  final String title;
  final VoidCallback onBack;
  final bool topInset;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: topInset ? K.titleBarHeight + 44 : 44,
      padding: EdgeInsets.only(top: topInset ? K.titleBarHeight : 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Icon(Icons.arrow_back_ios_new_rounded, size: 17, color: K.accent),
            ),
          ),
          Text(
            title,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.textPrimary),
          ),
        ],
      ),
    );
  }
}
