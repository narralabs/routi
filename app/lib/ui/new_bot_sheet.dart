import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Create-a-bot dialog. Deliberately minimal: name, personality, model.
class NewBotSheet extends ConsumerStatefulWidget {
  const NewBotSheet({super.key});

  static Future<void> show(BuildContext context) => showDialog(
        context: context,
        builder: (_) => const NewBotSheet(),
      );

  @override
  ConsumerState<NewBotSheet> createState() => _NewBotSheetState();
}

class _NewBotSheetState extends ConsumerState<NewBotSheet> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  String _model = 'default';
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    await ref.read(chatProvider.notifier).createBot(
          name: name,
          systemPrompt: _prompt.text.trim(),
          model: _model,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];

    return AlertDialog(
      title: const Text('New Bot', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Research Bot'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Personality',
                hintText: 'You are a sharp research assistant. Be concise and cite sources.',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            if (models.isEmpty)
              Text('Loading models…', style: TextStyle(fontSize: 12, color: context.textSecondary))
            else
              DropdownButtonFormField<String>(
                initialValue: models.any((m) => m.id == _model) ? _model : models.first.id,
                decoration: const InputDecoration(labelText: 'Model'),
                items: [
                  for (final m in models)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text(m.displayName, style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) => setState(() => _model = v ?? 'default'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
      ],
    );
  }
}
