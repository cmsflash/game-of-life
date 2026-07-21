import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../../../shared/page_frame.dart';
import '../domain/game_session.dart';

class LocalSetupScreen extends ConsumerStatefulWidget {
  const LocalSetupScreen({super.key});

  @override
  ConsumerState<LocalSetupScreen> createState() => _LocalSetupScreenState();
}

class _LocalSetupScreenState extends ConsumerState<LocalSetupScreen> {
  var _mode = LocalGameMode.elimination;
  var _turnLimit = 100;
  var _target = 50;
  final _blackName = TextEditingController(text: 'Black');
  final _whiteName = TextEditingController(text: 'White');

  @override
  void dispose() {
    _blackName.dispose();
    _whiteName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      maxWidth: 920,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'Local hot-seat',
            title: 'Set the terms of life',
            description:
                'Share this screen and alternate turns. Local games need no account or connection.',
          ),
          const SizedBox(height: 30),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Victory condition',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return SegmentedButton<LocalGameMode>(
                        segments: const [
                          ButtonSegment(
                            value: LocalGameMode.elimination,
                            icon: Icon(Icons.remove_circle_outline),
                            label: Text('Elimination'),
                          ),
                          ButtonSegment(
                            value: LocalGameMode.turnLimit,
                            icon: Icon(Icons.timer_outlined),
                            label: Text('Turn limit'),
                          ),
                          ButtonSegment(
                            value: LocalGameMode.populationTarget,
                            icon: Icon(Icons.flag_outlined),
                            label: Text('Cell target'),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (selection) =>
                            setState(() => _mode = selection.first),
                        showSelectedIcon: constraints.maxWidth > 560,
                        expandedInsets: constraints.maxWidth > 560
                            ? EdgeInsets.zero
                            : null,
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: switch (_mode) {
                      LocalGameMode.elimination => const _ModeExplanation(
                        key: ValueKey('elimination'),
                        icon: Icons.blur_off,
                        title: 'Last color standing wins',
                        description:
                            'The match ends as soon as one player has no living cells after evolution.',
                      ),
                      LocalGameMode.turnLimit => Column(
                        key: const ValueKey('turn-limit'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$_turnLimit total turns'),
                          Slider(
                            value: _turnLimit.toDouble(),
                            min: 20,
                            max: 200,
                            divisions: 18,
                            label: '$_turnLimit',
                            onChanged: (value) => setState(
                              () => _turnLimit = value.round().isEven
                                  ? value.round()
                                  : value.round() + 1,
                            ),
                          ),
                          const Text(
                            'When time is up, the player with more living cells wins.',
                          ),
                        ],
                      ),
                      LocalGameMode.populationTarget => Column(
                        key: const ValueKey('population-target'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('First to $_target living cells'),
                          Slider(
                            value: _target.toDouble(),
                            min: 10,
                            max: 100,
                            divisions: 18,
                            label: '$_target',
                            onChanged: (value) =>
                                setState(() => _target = value.round()),
                          ),
                          const Text(
                            'Elimination still ends the game immediately.',
                          ),
                        ],
                      ),
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Players',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final fields = [
                        TextField(
                          controller: _blackName,
                          maxLength: 24,
                          decoration: const InputDecoration(
                            labelText: 'Black player',
                            counterText: '',
                            prefixIcon: Icon(Icons.dark_mode),
                          ),
                        ),
                        TextField(
                          controller: _whiteName,
                          maxLength: 24,
                          decoration: const InputDecoration(
                            labelText: 'White player',
                            counterText: '',
                            prefixIcon: Icon(Icons.light_mode),
                          ),
                        ),
                      ];
                      if (constraints.maxWidth >= 620) {
                        return Row(
                          children: [
                            Expanded(child: fields[0]),
                            const SizedBox(width: 14),
                            Expanded(child: fields[1]),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          fields[0],
                          const SizedBox(height: 14),
                          fields[1],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              final info = const Row(
                children: [
                  Icon(Icons.grid_4x4, size: 18),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text('20 × 20 finite board  •  Black moves first'),
                  ),
                ],
              );
              final button = FilledButton.icon(
                key: const Key('start-local-game'),
                onPressed: () {
                  ref
                      .read(localGameProvider.notifier)
                      .start(
                        LocalGameConfig(
                          mode: _mode,
                          turnLimit: _turnLimit,
                          populationTarget: _target,
                          blackName: _blackName.text,
                          whiteName: _whiteName.text,
                        ),
                      );
                  context.go('/local/game');
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start game'),
              );
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [info, const SizedBox(height: 16), button],
                );
              }
              return Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 16),
                  button,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ModeExplanation extends StatelessWidget {
  const _ModeExplanation({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      CircleAvatar(child: Icon(icon)),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 3),
            Text(description),
          ],
        ),
      ),
    ],
  );
}
