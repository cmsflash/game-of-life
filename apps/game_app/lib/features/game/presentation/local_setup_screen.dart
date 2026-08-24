import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart' as engine;
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
  var _matchup = _LocalMatchup.humanVsHuman;
  var _humanColor = engine.Player.black;
  var _turnLimit = 100;
  var _target = 50;
  final _title = TextEditingController();
  final _blackName = TextEditingController(text: 'Black');
  final _whiteName = TextEditingController(text: 'White');
  final _maxSelfCells = TextEditingController(text: '34');
  final _minOpponentCells = TextEditingController(text: '33');
  final _maxCellAdvantage = TextEditingController(text: '33');
  var _creating = false;

  @override
  void dispose() {
    _title.dispose();
    _blackName.dispose();
    _whiteName.dispose();
    _maxSelfCells.dispose();
    _minOpponentCells.dispose();
    _maxCellAdvantage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strategyTotal = _strategyTotal;
    final strategyValid = !_hasAi || _aiStrategyPercentages != null;
    return PageFrame(
      maxWidth: 920,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'Local play',
            title: 'Set the terms of life',
            description:
                'Play another person or a one-step greedy AI. Local games need no account or connection.',
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
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topLeft,
                    clipBehavior: Clip.hardEdge,
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
                    builder: (context, constraints) =>
                        SegmentedButton<_LocalMatchup>(
                          segments: const [
                            ButtonSegment(
                              value: _LocalMatchup.humanVsHuman,
                              icon: Icon(Icons.people_outline),
                              label: Text('Two players'),
                            ),
                            ButtonSegment(
                              value: _LocalMatchup.humanVsAi,
                              icon: Icon(Icons.smart_toy_outlined),
                              label: Text('Player vs AI'),
                            ),
                            ButtonSegment(
                              value: _LocalMatchup.aiVsAi,
                              icon: Icon(
                                Icons.precision_manufacturing_outlined,
                              ),
                              label: Text('AI vs AI'),
                            ),
                          ],
                          selected: {_matchup},
                          onSelectionChanged: (selection) =>
                              _selectMatchup(selection.first),
                          showSelectedIcon: constraints.maxWidth > 560,
                          expandedInsets: constraints.maxWidth > 560
                              ? EdgeInsets.zero
                              : null,
                        ),
                  ),
                  if (_matchup == _LocalMatchup.humanVsAi) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Text('You play'),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SegmentedButton<engine.Player>(
                            segments: const [
                              ButtonSegment(
                                value: engine.Player.black,
                                label: Text('Black'),
                              ),
                              ButtonSegment(
                                value: engine.Player.white,
                                label: Text('White'),
                              ),
                            ],
                            selected: {_humanColor},
                            onSelectionChanged: (selection) =>
                                _selectHumanColor(selection.first),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextField(
                    key: const Key('local-game-title'),
                    controller: _title,
                    maxLength: 48,
                    decoration: const InputDecoration(
                      labelText: 'Game name (optional)',
                      counterText: '',
                      prefixIcon: Icon(Icons.edit_outlined),
                      hintText: 'Black vs White',
                    ),
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final fields = [
                        TextField(
                          key: const Key('local-black-name'),
                          controller: _blackName,
                          maxLength: 24,
                          decoration: InputDecoration(
                            labelText: _participantLabel(engine.Player.black),
                            counterText: '',
                            prefixIcon: const Icon(Icons.dark_mode),
                          ),
                        ),
                        TextField(
                          key: const Key('local-white-name'),
                          controller: _whiteName,
                          maxLength: 24,
                          decoration: InputDecoration(
                            labelText: _participantLabel(engine.Player.white),
                            counterText: '',
                            prefixIcon: const Icon(Icons.light_mode),
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
          if (_hasAi) ...[
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI strategy mix',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Each AI turn selects one strategy using these percentages, then takes the best one-step move.',
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          _StrategyPercentageField(
                            fieldKey: const Key('ai-max-self-cells'),
                            label: 'Max own cells',
                            controller: _maxSelfCells,
                            onChanged: (_) => setState(() {}),
                          ),
                          _StrategyPercentageField(
                            fieldKey: const Key('ai-min-opponent-cells'),
                            label: 'Min their cells',
                            controller: _minOpponentCells,
                            onChanged: (_) => setState(() {}),
                          ),
                          _StrategyPercentageField(
                            fieldKey: const Key('ai-max-cell-advantage'),
                            label: 'Max own − theirs',
                            controller: _maxCellAdvantage,
                            onChanged: (_) => setState(() {}),
                          ),
                        ];
                        if (constraints.maxWidth >= 660) {
                          return Row(
                            children: [
                              for (
                                var index = 0;
                                index < fields.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: 14),
                                Expanded(child: fields[index]),
                              ],
                            ],
                          );
                        }
                        return Column(
                          children: [
                            for (
                              var index = 0;
                              index < fields.length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(height: 12),
                              fields[index],
                            ],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      strategyTotal == 100
                          ? 'Total: 100%'
                          : 'Total: $strategyTotal% · must equal 100%',
                      key: const Key('ai-strategy-total'),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: strategyTotal == 100
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
                onPressed: _creating || !strategyValid ? null : _startGame,
                icon: _creating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_creating ? 'Creating…' : 'Start game'),
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

  bool get _hasAi => _matchup != _LocalMatchup.humanVsHuman;

  LocalParticipantType _participantFor(engine.Player player) =>
      switch (_matchup) {
        _LocalMatchup.humanVsHuman => LocalParticipantType.human,
        _LocalMatchup.humanVsAi =>
          player == _humanColor
              ? LocalParticipantType.human
              : LocalParticipantType.ai,
        _LocalMatchup.aiVsAi => LocalParticipantType.ai,
      };

  String _participantLabel(engine.Player player) {
    final color = player == engine.Player.black ? 'Black' : 'White';
    return _participantFor(player) == LocalParticipantType.ai
        ? '$color AI'
        : '$color player';
  }

  int get _strategyTotal =>
      [_maxSelfCells, _minOpponentCells, _maxCellAdvantage].fold(0, (
        total,
        controller,
      ) {
        return total + (int.tryParse(controller.text) ?? 0);
      });

  OneStepStrategyPercentages? get _aiStrategyPercentages {
    final maxSelf = int.tryParse(_maxSelfCells.text);
    final minOpponent = int.tryParse(_minOpponentCells.text);
    final maxAdvantage = int.tryParse(_maxCellAdvantage.text);
    if (maxSelf == null || minOpponent == null || maxAdvantage == null) {
      return null;
    }
    try {
      return OneStepStrategyPercentages.checked(
        maxSelfCells: maxSelf,
        minOpponentCells: minOpponent,
        maxCellAdvantage: maxAdvantage,
      );
    } on ArgumentError {
      return null;
    }
  }

  void _selectMatchup(_LocalMatchup matchup) {
    setState(() {
      _matchup = matchup;
      switch (matchup) {
        case _LocalMatchup.humanVsHuman:
          _blackName.text = 'Black';
          _whiteName.text = 'White';
        case _LocalMatchup.humanVsAi:
          _setHumanVsAiNames();
        case _LocalMatchup.aiVsAi:
          _blackName.text = 'Black AI';
          _whiteName.text = 'White AI';
      }
    });
  }

  void _selectHumanColor(engine.Player player) {
    setState(() {
      _humanColor = player;
      _setHumanVsAiNames();
    });
  }

  void _setHumanVsAiNames() {
    if (_humanColor == engine.Player.black) {
      _blackName.text = 'You';
      _whiteName.text = 'Greedy AI';
    } else {
      _blackName.text = 'Greedy AI';
      _whiteName.text = 'You';
    }
  }

  Future<void> _startGame() async {
    final strategyPercentages = _aiStrategyPercentages;
    if (_hasAi && strategyPercentages == null) return;
    setState(() => _creating = true);
    try {
      final game = await ref
          .read(localGamesProvider.notifier)
          .create(
            LocalGameConfig(
              mode: _mode,
              turnLimit: _turnLimit,
              populationTarget: _target,
              blackName: _blackName.text,
              whiteName: _whiteName.text,
              blackParticipant: _participantFor(engine.Player.black),
              whiteParticipant: _participantFor(engine.Player.white),
              aiStrategyPercentages:
                  strategyPercentages ??
                  const OneStepStrategyPercentages.balanced(),
            ),
            title: _title.text,
            opponentLabel: _matchup == _LocalMatchup.aiVsAi
                ? 'AI vs AI'
                : _participantFor(engine.Player.black) ==
                      LocalParticipantType.human
                ? _whiteName.text
                : _blackName.text,
          );
      if (mounted) context.go('/local/game/${game.id}');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('The local game could not be saved. Try again.'),
          ),
        );
      setState(() => _creating = false);
    }
  }
}

enum _LocalMatchup { humanVsHuman, humanVsAi, aiVsAi }

class _StrategyPercentageField extends StatelessWidget {
  const _StrategyPercentageField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(3),
    ],
    onChanged: onChanged,
    decoration: InputDecoration(labelText: label, suffixText: '%'),
  );
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
