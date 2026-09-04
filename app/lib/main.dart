import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_state.dart';
import 'ui/bot_list.dart';
import 'ui/chat_view.dart';
import 'ui/new_bot_sheet.dart';
import 'ui/theme.dart';

void main() {
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
      home: const HomeShell(),
    );
  }
}

/// One shell for both platforms.
///
/// Wide (the Mac mini's desktop app): sidebar and thread side by side.
/// Narrow (the phone): the sidebar is the root screen and the thread is pushed on
/// top, which is the navigation model a phone user expects.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return wide ? const _WideLayout() : const _NarrowLayout();
      },
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          BotList(onNewBot: () => NewBotSheet.show(context)),
          const ChatView(),
        ],
      ),
    );
  }
}

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider);
    final bot = chat.selectedBot;

    return Scaffold(
      body: SafeArea(
        child: bot == null
            ? BotList(width: null, onNewBot: () => NewBotSheet.show(context))
            : Column(
                children: [
                  _MobileHeader(
                    title: bot.name,
                    onBack: () => ref.read(chatProvider.notifier).clearSelection(),
                  ),
                  const ChatView(),
                ],
              ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({required this.title, required this.onBack});
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
      child: Row(
        children: [
          IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back_ios_new, size: 17)),
          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.textPrimary)),
        ],
      ),
    );
  }
}
