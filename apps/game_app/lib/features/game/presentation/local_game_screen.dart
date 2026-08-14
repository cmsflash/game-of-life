import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../providers.dart';
import '../../../shared/game_play_layout.dart';
import '../domain/game_session.dart';
import 'game_view_settings_dialog.dart';
import 'life_board.dart';
import 'local_games_controller.dart';
import 'player_turn_marker.dart';

class LocalGameScreen extends ConsumerWidget {
  const LocalGameScreen({super.key, this.gameId});

  /// Null preserves the legacy `/local/game` link by resuming the most recent
  /// saved game on this device.
  final String? gameId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final games = ref.watch(localGamesProvider);
    if (games.status == LocalGamesLoadStatus.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (games.status == LocalGamesLoadStatus.failed) {
      return _UnavailableLocalGame(
        message: games.error ?? 'Local games could not be loaded.',
        onRetry: () => ref.read(localGamesProvider.notifier).retryLoad(),
      );
    }
    final session = gameId == null
        ? games.selectedGame
        : games.gameById(gameId!);
    if (session == null) {
      return _UnavailableLocalGame(
        message: gameId == null
            ? 'Create a local game to open the board.'
            : 'This local game is not saved on this device.',
      );
    }
    final game = session.game;
    final viewSettings = ref.watch(gameViewSettingsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to games',
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(session.title),
        actions: [
          const GameViewSettingsButton(),
          IconButton(
            tooltip: 'Restart game',
            onPressed: () => _confirmRestart(context, ref, session.id),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Delete local game',
            onPressed: () => _confirmDelete(context, ref, session),
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: GamePlayLayout(
          board: LifeBoard(
            key: const Key('local-life-board'),
            board: game.board,
            enabled: game.isActive,
            lastMove: session.lastMove,
            previewBoard: session.preview?.board,
            tentativeMove: session.preview?.coordinate,
            previewDeaths: session.preview?.deathEvents ?? const [],
            visualizePreviewDeaths: viewSettings.visualizeDeathsInPreview,
            births: session.lastBirths,
            onMoveConfirm: () => _commit(context, ref, session.id),
            onCellTap: (row, column) {
              final success = ref
                  .read(localGamesProvider.notifier)
                  .consider(session.id, row, column);
              if (!success) {
                final message = ref
                    .read(localGamesProvider)
                    .gameById(session.id)
                    ?.error;
                if (message != null) {
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(content: Text(message)));
                }
              }
            },
          ),
          panel: _GamePanel(
            session: session,
            onCommit: () => _commit(context, ref, session.id),
          ),
        ),
      ),
    );
  }

  Future<void> _commit(BuildContext context, WidgetRef ref, String id) async {
    try {
      await ref.read(localGamesProvider.notifier).commit(id);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('The move could not be saved on this device.'),
          ),
        );
    }
  }

  Future<void> _confirmRestart(
    BuildContext context,
    WidgetRef ref,
    String id,
  ) async {
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
    if (restart ?? false) {
      try {
        await ref.read(localGamesProvider.notifier).restart(id);
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The restarted game could not be saved.'),
          ),
        );
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    LocalGameSession session,
  ) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this local game?'),
        content: Text(
          '“${session.title}” and its current position will be removed from '
          'this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep game'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete game'),
          ),
        ],
      ),
    );
    if (!(delete ?? false) || !context.mounted) return;
    try {
      await ref.read(localGamesProvider.notifier).delete(session.id);
      if (context.mounted) context.go('/');
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The local game could not be deleted.')),
      );
    }
  }
}

class _UnavailableLocalGame extends StatelessWidget {
  const _UnavailableLocalGame({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Local game')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_off, size: 56),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (onRetry != null)
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                OutlinedButton(
                  onPressed: () => context.go('/'),
                  child: const Text('Home'),
                ),
                if (onRetry == null)
                  FilledButton(
                    onPressed: () => context.go('/local/setup'),
                    child: const Text('New local game'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _GamePanel extends StatelessWidget {
  const _GamePanel({required this.session, required this.onCommit});

  final LocalGameSession session;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final game = session.game;
    final outcome = game.outcome;
    final preview = session.preview;
    final displayBoard = preview?.board ?? game.board;
    final compact = GamePlayLayout.isCompact(context);
    final sectionGap = compact ? 8.0 : 12.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: outcome == null
              ? Theme.of(context).colorScheme.surfaceContainer
              : Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: EdgeInsets.all(compact ? 16 : 20),
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
                SizedBox(height: compact ? 6 : 8),
                Text(
                  outcome == null
                      ? preview == null
                            ? '${session.config.nameFor(game.toMove!)} to move'
                            : 'Previewing row ${preview.coordinate.row + 1}, '
                                  'column ${preview.coordinate.column + 1}'
                      : _outcomeTitle(outcome, session.config),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: compact ? 5 : 7),
                Text(
                  outcome == null
                      ? preview == null
                            ? 'Choose an empty square to preview the next round.'
                            : 'Tap the selected square again to confirm. Tap '
                                  'another square to compare, or press the check.'
                      : _reason(outcome.reason),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: sectionGap),
        Row(
          children: [
            Expanded(
              child: _PlayerScore(
                name: session.config.nameFor(engine.Player.black),
                color: engine.Player.black,
                score: displayBoard.population(engine.CellState.black),
                active: game.toMove == engine.Player.black,
                onCommit: preview != null && game.toMove == engine.Player.black
                    ? onCommit
                    : null,
              ),
            ),
            SizedBox(width: compact ? 8 : 10),
            Expanded(
              child: _PlayerScore(
                name: session.config.nameFor(engine.Player.white),
                color: engine.Player.white,
                score: displayBoard.population(engine.CellState.white),
                active: game.toMove == engine.Player.white,
                onCommit: preview != null && game.toMove == engine.Player.white
                    ? onCommit
                    : null,
              ),
            ),
          ],
        ),
        SizedBox(height: sectionGap),
        Card(
          child: Padding(
            padding: EdgeInsets.all(compact ? 14 : 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _DeltaStat(
                  icon: Icons.add,
                  label: 'Births',
                  value: preview?.births.length ?? session.lastBirths.length,
                  color: LifeColors.sprout,
                ),
                _DeltaStat(
                  icon: Icons.remove,
                  label: 'Deaths',
                  value: preview?.deaths.length ?? session.lastDeaths.length,
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
    this.onCommit,
  });

  final String name;
  final engine.Player color;
  final int score;
  final bool active;
  final VoidCallback? onCommit;

  @override
  Widget build(BuildContext context) {
    final compact = GamePlayLayout.isCompact(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: EdgeInsets.all(compact ? 12 : 15),
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
          PlayerTurnMarker(
            player: color,
            active: active,
            onCommit: onCommit,
            markerSize: 24,
          ),
          SizedBox(width: compact ? 3 : 5),
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
