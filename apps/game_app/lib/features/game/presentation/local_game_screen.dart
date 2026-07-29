import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../providers.dart';
import '../domain/game_session.dart';
import 'life_board.dart';

class LocalGameScreen extends ConsumerWidget {
  const LocalGameScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(localGameProvider);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Local game')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.grid_off, size: 56),
              const SizedBox(height: 16),
              const Text('Set up a game before opening the board.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/local/setup'),
                child: const Text('Game setup'),
              ),
            ],
          ),
        ),
      );
    }
    final game = session.game;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to setup',
          onPressed: () => context.go('/local/setup'),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(session.config.modeLabel),
        actions: [
          IconButton(
            tooltip: 'Restart game',
            onPressed: () => _confirmRestart(context, ref),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            final board = Padding(
              padding: EdgeInsets.all(wide ? 24 : 12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 760,
                    maxHeight: 760,
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: LifeBoard(
                      key: const Key('local-life-board'),
                      board: game.board,
                      enabled: game.isActive,
                      lastMove: session.lastMove,
                      births: session.lastBirths,
                      onCellTap: (row, column) {
                        final success = ref
                            .read(localGameProvider.notifier)
                            .place(row, column);
                        if (!success) {
                          final message = ref.read(localGameProvider)?.error;
                          if (message != null) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(SnackBar(content: Text(message)));
                          }
                        }
                      },
                    ),
                  ),
                ),
              ),
            );
            final panel = _GamePanel(session: session);
            if (wide) {
              return Row(
                children: [
                  Expanded(child: board),
                  SizedBox(
                    width: 340,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                      child: panel,
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                Expanded(flex: 3, child: board),
                Flexible(
                  flex: 2,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: panel,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmRestart(BuildContext context, WidgetRef ref) async {
    final restart = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart this game?'),
        content: const Text('The current position will be replaced.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restart'),
          ),
        ],
      ),
    );
    if (restart ?? false) ref.read(localGameProvider.notifier).restart();
  }
}

class _GamePanel extends StatelessWidget {
  const _GamePanel({required this.session});

  final LocalGameSession session;

  @override
  Widget build(BuildContext context) {
    final game = session.game;
    final outcome = game.outcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: outcome == null
              ? Theme.of(context).colorScheme.surfaceContainer
              : Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  outcome == null ? 'TURN ${game.ply + 1}' : 'GAME OVER',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    letterSpacing: 1.5,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  outcome == null
                      ? '${session.config.nameFor(game.toMove!)} to move'
                      : _outcomeTitle(outcome, session.config),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  outcome == null
                      ? 'Place one ${game.toMove!.name} cell on any empty square.'
                      : _reason(outcome.reason),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _PlayerScore(
                name: session.config.nameFor(engine.Player.black),
                color: engine.Player.black,
                score: game.blackPopulation,
                active: game.toMove == engine.Player.black,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _PlayerScore(
                name: session.config.nameFor(engine.Player.white),
                color: engine.Player.white,
                score: game.whitePopulation,
                active: game.toMove == engine.Player.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _DeltaStat(
                  icon: Icons.add,
                  label: 'Births',
                  value: session.lastBirths.length,
                  color: LifeColors.sprout,
                ),
                _DeltaStat(
                  icon: Icons.remove,
                  label: 'Deaths',
                  value: session.lastDeaths.length,
                  color: LifeColors.coral,
                ),
                _DeltaStat(
                  icon: Icons.history,
                  label: 'Moves',
                  value: game.ply,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _outcomeTitle(engine.GameOutcome outcome, LocalGameConfig config) {
    if (outcome.winner == null) return 'Draw';
    return '${config.nameFor(outcome.winner!)} wins';
  }

  String _reason(engine.OutcomeReason reason) => switch (reason) {
    engine.OutcomeReason.elimination => 'The other color has been eliminated.',
    engine.OutcomeReason.mutualExtinction =>
      'Both colors went extinct together.',
    engine.OutcomeReason.populationTarget =>
      'The population target was reached.',
    engine.OutcomeReason.simultaneousTarget =>
      'Both colors reached the target together.',
    engine.OutcomeReason.turnLimitPopulation =>
      'The larger population wins at the turn limit.',
    engine.OutcomeReason.turnLimitTie => 'The populations are tied.',
    engine.OutcomeReason.noLegalMoves => 'There are no empty cells left.',
  };
}

class _PlayerScore extends StatelessWidget {
  const _PlayerScore({
    required this.name,
    required this.color,
    required this.score,
    required this.active,
  });

  final String name;
  final engine.Player color;
  final int score;
  final bool active;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: active
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: active
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outlineVariant,
        width: active ? 2 : 1,
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color == engine.Player.black
                ? LifeColors.ink
                : LifeColors.paper,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, overflow: TextOverflow.ellipsis),
              Text('$score', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DeltaStat extends StatelessWidget {
  const _DeltaStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(height: 3),
      Text('$value', style: Theme.of(context).textTheme.titleMedium),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}
