import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../../core/api_client.dart';
import '../../../providers.dart';
import '../../../shared/game_play_layout.dart';
import '../../game/domain/move_preview.dart';
import '../../game/presentation/game_view_settings_dialog.dart';
import '../../game/presentation/life_board.dart';
import '../../game/presentation/player_turn_marker.dart';
import '../data/online_models.dart';

class OnlineMatchScreen extends ConsumerStatefulWidget {
  const OnlineMatchScreen({super.key, required this.matchId});

  final String matchId;

  @override
  ConsumerState<OnlineMatchScreen> createState() => _OnlineMatchScreenState();
}

class _OnlineMatchScreenState extends ConsumerState<OnlineMatchScreen> {
  Timer? _timer;
  OnlineMatch? _match;
  MovePreview? _preview;
  String? _error;
  var _loading = true;
  var _submitting = false;
  var _requestInFlight = false;
  var _completionRefreshSent = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_requestInFlight || !mounted || (_submitting && !force)) return;
    _requestInFlight = true;
    try {
      final updated = await ref
          .read(onlineRepositoryProvider)
          .getMatch(widget.matchId, etag: force ? null : _match?.etag);
      if (!mounted) return;
      var completedTransition = false;
      setState(() {
        final current = _match;
        if (updated != null &&
            (current == null || updated.revision >= current.revision)) {
          completedTransition = _becameTerminal(current, updated);
          if (!_previewStillValid(updated)) _preview = null;
          _match = updated;
        }
        _loading = false;
        _error = null;
      });
      if (completedTransition) _refreshRatedRecord();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : 'Connection lost. Retrying automatically…';
      });
    } finally {
      _requestInFlight = false;
    }
  }

  bool _previewStillValid(OnlineMatch updated) {
    final current = _match;
    return _preview != null &&
        current != null &&
        updated.isYourTurn &&
        updated.revision == current.revision &&
        updated.nextPlayer == current.nextPlayer &&
        updated.board == current.board;
  }

  void _consider(int row, int column) {
    final match = _match;
    if (match == null || !match.isYourTurn || _submitting) return;
    if (match.board.at(row, column) != engine.CellState.empty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Choose an empty cell.')));
      return;
    }
    try {
      final game = engine.GameState(
        rules: match.rules,
        board: match.board,
        ply: match.revision,
        revision: match.revision,
        toMove: match.nextPlayer,
        outcome: null,
      );
      setState(() {
        _preview = MovePreview.simulate(game, engine.Coordinate(row, column));
        _error = null;
      });
    } on engine.GameRuleViolation catch (error) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _commit() async {
    final match = _match;
    final preview = _preview;
    if (match == null ||
        preview == null ||
        !match.isYourTurn ||
        _submitting ||
        preview.move.expectedRevision != match.revision) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    var refreshAfterSubmit = false;
    try {
      final updated = await ref
          .read(onlineRepositoryProvider)
          .submitMove(
            match.id,
            revision: match.revision,
            row: preview.coordinate.row,
            column: preview.coordinate.column,
          );
      if (mounted) {
        final completedTransition = _becameTerminal(_match, updated);
        setState(() {
          _match = updated;
          _preview = null;
        });
        if (completedTransition) _refreshRatedRecord();
      }
    } on ApiException catch (error) {
      if (error.code == 'staleRevision' || error.code == 'REVISION_MISMATCH') {
        refreshAfterSubmit = true;
      }
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Your move was not sent. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (refreshAfterSubmit && mounted) await _refresh(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    if (_loading && match == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (match == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 52),
              const SizedBox(height: 14),
              Text(_error ?? 'Match not found.'),
              const SizedBox(height: 16),
              FilledButton(onPressed: _refresh, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    final opponent = match.players
        .where((player) => player.color != match.yourColor)
        .firstOrNull;
    final viewSettings = ref.watch(gameViewSettingsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to home',
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text('vs ${opponent?.displayName ?? 'Opponent'}'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _refresh(force: true),
            icon: const Icon(Icons.refresh),
          ),
          const GameViewSettingsButton(),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'resign') _confirmResign(match);
            },
            itemBuilder: (context) => [
              if (match.isActive)
                const PopupMenuItem(
                  value: 'resign',
                  child: Text('Resign match'),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: GamePlayLayout(
          board: Stack(
            children: [
              Positioned.fill(
                child: LifeBoard(
                  key: const Key('online-life-board'),
                  board: match.board,
                  enabled: match.isYourTurn && !_submitting,
                  lastMove: match.lastMove,
                  previewBoard: _preview?.board,
                  tentativeMove: _preview?.coordinate,
                  previewDeaths: _preview?.deathEvents ?? const [],
                  visualizePreviewDeaths: viewSettings.visualizeDeathsInPreview,
                  onCellTap: _consider,
                  onMoveConfirm: () => unawaited(_commit()),
                ),
              ),
              if (_submitting)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .2),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
          panel: _OnlineGamePanel(
            match: match,
            preview: _preview,
            error: _error,
            submitting: _submitting,
            onCommit: _commit,
          ),
        ),
      ),
    );
  }

  Future<void> _confirmResign(OnlineMatch match) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resign this match?'),
        content: const Text('Your opponent will win. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Resign'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    try {
      final updated = await ref
          .read(onlineRepositoryProvider)
          .resign(match.id, match.revision);
      if (mounted) {
        final completedTransition = _becameTerminal(_match, updated);
        setState(() => _match = updated);
        if (completedTransition) _refreshRatedRecord();
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  bool _becameTerminal(OnlineMatch? current, OnlineMatch updated) =>
      !updated.isActive &&
      updated.status != 'waiting' &&
      current?.isActive != false;

  void _refreshRatedRecord() {
    if (_completionRefreshSent) return;
    _completionRefreshSent = true;
    unawaited(ref.read(playerStatsControllerProvider.notifier).refresh());
    unawaited(ref.read(socialControllerProvider.notifier).refresh());
  }
}

class _OnlineGamePanel extends StatelessWidget {
  const _OnlineGamePanel({
    required this.match,
    required this.preview,
    required this.error,
    required this.submitting,
    required this.onCommit,
  });

  final OnlineMatch match;
  final MovePreview? preview;
  final String? error;
  final bool submitting;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final compact = GamePlayLayout.isCompact(context);
    final displayBoard = preview?.board ?? match.board;
    final yourPlayer = match.yourColor == null
        ? null
        : match.playerFor(match.yourColor!);
    final opponent = match.players
        .where((player) => player.color != match.yourColor)
        .firstOrNull;
    final title = match.status == 'waiting'
        ? 'Waiting for a player'
        : !match.isActive
        ? _resultTitle(match)
        : preview != null
        ? 'Previewing row ${preview!.coordinate.row + 1}, '
              'column ${preview!.coordinate.column + 1}'
        : match.isYourTurn
        ? 'Your move'
        : '${opponent?.displayName ?? 'Opponent'} is thinking';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: match.isYourTurn
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainer,
          child: Padding(
            padding: EdgeInsets.all(compact ? 16 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  match.status == 'waiting'
                      ? 'RATED · PRIVATE LOBBY'
                      : match.isActive
                      ? 'RATED · MOVE ${match.revision + 1}'
                      : 'RATED · MATCH COMPLETE',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(letterSpacing: 1.4),
                ),
                SizedBox(height: compact ? 5 : 7),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                SizedBox(height: compact ? 5 : 7),
                Text(
                  match.status == 'waiting'
                      ? 'Return to the lobby to share the join code.'
                      : match.isYourTurn
                      ? preview == null
                            ? 'Choose an empty square to preview the next round.'
                            : 'Tap the selected square again to confirm. Tap '
                                  'another square to compare, or press the check.'
                      : 'The board refreshes automatically.',
                ),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          SizedBox(height: compact ? 8 : 10),
          Container(
            padding: EdgeInsets.all(compact ? 10 : 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(error!),
          ),
        ],
        SizedBox(height: compact ? 8 : 12),
        _OnlinePlayerTile(
          name: yourPlayer?.displayName ?? 'You',
          label: 'YOU',
          color: match.yourColor ?? engine.Player.black,
          cells: match.yourColor == engine.Player.white
              ? displayBoard.population(engine.CellState.white)
              : displayBoard.population(engine.CellState.black),
          active: match.nextPlayer == match.yourColor,
          onCommit: preview != null && match.isYourTurn ? onCommit : null,
          busy: submitting && preview != null,
        ),
        SizedBox(height: compact ? 8 : 10),
        _OnlinePlayerTile(
          name: opponent?.displayName ?? 'Opponent',
          label: 'OPPONENT',
          color: opponent?.color ?? engine.Player.white,
          cells: opponent?.color == engine.Player.black
              ? displayBoard.population(engine.CellState.black)
              : displayBoard.population(engine.CellState.white),
          active: match.nextPlayer == opponent?.color,
        ),
        SizedBox(height: compact ? 8 : 12),
        Card(
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: Row(
              children: [
                const Icon(Icons.verified_user_outlined, size: 19),
                const SizedBox(width: 9),
                const Expanded(child: Text('Server-authoritative match')),
                Text('r${match.revision}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _resultTitle(OnlineMatch match) {
    final winner = match.result?['winner'] as String?;
    if (winner == null) return 'Draw';
    if (winner == match.yourColor?.name) return 'You win';
    return 'Opponent wins';
  }
}

class _OnlinePlayerTile extends StatelessWidget {
  const _OnlinePlayerTile({
    required this.name,
    required this.label,
    required this.color,
    required this.cells,
    required this.active,
    this.onCommit,
    this.busy = false,
  });

  final String name;
  final String label;
  final engine.Player color;
  final int cells;
  final bool active;
  final VoidCallback? onCommit;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final compact = GamePlayLayout.isCompact(context);
    final markerSize = compact ? 30.0 : 34.0;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
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
            busy: busy,
            markerSize: markerSize,
          ),
          SizedBox(width: compact ? 6 : 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
                ),
                Text(name, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          Text('$cells', style: Theme.of(context).textTheme.headlineSmall),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
