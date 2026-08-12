import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';

class GameViewSettingsButton extends StatelessWidget {
  const GameViewSettingsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('game-view-settings'),
    tooltip: 'Game view settings',
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => const GameViewSettingsDialog(),
    ),
    icon: const Icon(Icons.settings_outlined),
  );
}

class GameViewSettingsDialog extends ConsumerWidget {
  const GameViewSettingsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(gameViewSettingsProvider);
    return AlertDialog(
      key: const Key('game-view-settings-dialog'),
      title: const Text('Game view settings'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SwitchListTile.adaptive(
          key: const Key('visualize-deaths-in-preview'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Visualize deaths in preview'),
          subtitle: Text(
            settings.visualizeDeathsInPreview
                ? 'Show cells that will die as faded stones with a coral ×.'
                : 'Let cells that will die disappear from the preview.',
          ),
          value: settings.visualizeDeathsInPreview,
          onChanged: ref
              .read(gameViewSettingsProvider.notifier)
              .setVisualizeDeathsInPreview,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
