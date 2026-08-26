import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  var _humanOpponentLevel = LocalParticipantType.aiLevel1;
  var _blackAiLevel = LocalParticipantType.aiLevel1;
  var _whiteAiLevel = LocalParticipantType.aiLevel1;
  final _title = TextEditingController();
  final _blackName = TextEditingController(text: 'Black');
  final _whiteName = TextEditingController(text: 'White');
  var _creating = false;

  @override
  void dispose() {
    _title.dispose();
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
            eyebrow: 'Local play',
            title: 'Set the terms of life',
            description:
                'Play another person, AI level 1, or AI level 2. Local games need no account or connection.',
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
                      _matchup == _LocalMatchup.aiVsAi
                          ? 'AI levels'
                          : 'AI level',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Level 1 maximizes cell difference after one move. Level 2 also checks every opponent reply.',
                    ),
                    const SizedBox(height: 18),
                    if (_matchup == _LocalMatchup.humanVsAi)
                      _AiLevelPicker(
                        pickerKey: const Key('human-opponent-ai-level'),
                        selected: _humanOpponentLevel,
                        onChanged: _selectHumanOpponentLevel,
                      )
                    else ...[
                      _AiLevelPicker(
                        pickerKey: const Key('black-ai-level'),
                        label: 'Black',
                        selected: _blackAiLevel,
                        onChanged: (level) =>
                            _selectAiVsAiLevel(engine.Player.black, level),
                      ),
                      const SizedBox(height: 14),
                      _AiLevelPicker(
                        pickerKey: const Key('white-ai-level'),
                        label: 'White',
                        selected: _whiteAiLevel,
                        onChanged: (level) =>
                            _selectAiVsAiLevel(engine.Player.white, level),
                      ),
                    ],
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
                onPressed: _creating ? null : _startGame,
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
              : _humanOpponentLevel,
        _LocalMatchup.aiVsAi =>
          player == engine.Player.black ? _blackAiLevel : _whiteAiLevel,
      };

  String _participantLabel(engine.Player player) {
    final color = player == engine.Player.black ? 'Black' : 'White';
    final participant = _participantFor(player);
    return participant.isAi ? '$color ${participant.label}' : '$color player';
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
          _blackName.text = _blackAiLevel.label;
          _whiteName.text = _whiteAiLevel.label;
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
      _whiteName.text = _humanOpponentLevel.label;
    } else {
      _blackName.text = _humanOpponentLevel.label;
      _whiteName.text = 'You';
    }
  }

  void _selectHumanOpponentLevel(LocalParticipantType level) {
    setState(() {
      _humanOpponentLevel = level;
      _setHumanVsAiNames();
    });
  }

  void _selectAiVsAiLevel(engine.Player player, LocalParticipantType level) {
    setState(() {
      if (player == engine.Player.black) {
        _blackAiLevel = level;
        _blackName.text = level.label;
      } else {
        _whiteAiLevel = level;
        _whiteName.text = level.label;
      }
    });
  }

  Future<void> _startGame() async {
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

class _AiLevelPicker extends StatelessWidget {
  const _AiLevelPicker({
    required this.pickerKey,
    required this.selected,
    required this.onChanged,
    this.label,
  });

  final Key pickerKey;
  final String? label;
  final LocalParticipantType selected;
  final ValueChanged<LocalParticipantType> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (label != null) ...[
        SizedBox(width: 64, child: Text(label!)),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: SegmentedButton<LocalParticipantType>(
          key: pickerKey,
          segments: const [
            ButtonSegment(
              value: LocalParticipantType.aiLevel1,
              label: Text('AI level 1'),
            ),
            ButtonSegment(
              value: LocalParticipantType.aiLevel2,
              label: Text('AI level 2'),
            ),
          ],
          selected: {selected},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ),
    ],
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
