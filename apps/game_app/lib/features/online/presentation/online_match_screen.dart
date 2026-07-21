import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../../core/api_client.dart';
import '../../../core/theme.dart';
import '../../../providers.dart';
import '../../game/presentation/life_board.dart';
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
  String? _error;
  var _loading = true;
  var _submitting = false;
  var _requestInFlight = false;

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
    if (_requestInFlight || !mounted) return;
    _requestInFlight = true;
    try {
      final updated = await ref
          .read(onlineRepositoryProvider)
          .getMatch(widget.matchId, etag: force ? null : _match?.etag);
      if (!mounted) return;
      setState(() {
        if (updated != null) _match = updated;
        _loading = false;
        _error = null;
      });
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

  Future<void> _place(int row, int column) async {
    final match = _match;
    if (match == null || !match.isYourTurn || _submitting) return;
    if (match.board.at(row, column) != engine.CellState.empty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Choose an empty cell.')));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(onlineRepositoryProvider)
          .submitMove(
            match.id,
            revision: match.revision,
            row: row,
            column: column,
          );
      if (mounted) setState(() => _match = updated);
    } on ApiException catch (error) {
      if (error.code == 'staleRevision' || error.code == 'REVISION_MISMATCH') {
        await _refresh(force: true);
      }
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Your move was not sent. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to lobby',
          onPressed: () => context.go('/online'),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text('vs ${opponent?.displayName ?? 'Opponent'}'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _refresh(force: true),
            icon: const Icon(Icons.refresh),
          ),
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 880;
            final board = Padding(
              padding: EdgeInsets.all(wide ? 24 : 12),
              child: Center(
                child: SizedBox.square(
                  dimension: math
                      .min(
                        constraints.maxWidth - (wide ? 380 : 24),
                        constraints.maxHeight - (wide ? 48 : 220),
                      )
                      .clamp(280, 760),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LifeBoard(
                          key: const Key('online-life-board'),
                          board: match.board,
                          enabled: match.isYourTurn && !_submitting,
                          onCellTap: _place,
                        ),
                      ),
                      if (_submitting)
                        Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: .2),
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
            final panel = _OnlineGamePanel(match: match, error: _error);
            if (wide) {
              return Row(
                children: [
                  Expanded(child: board),
                  SizedBox(
                    width: 360,
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
                Expanded(child: board),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: SizedBox(
                    width: math.max(540, constraints.maxWidth - 24),
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
      if (mounted) setState(() => _match = updated);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }
}

class _OnlineGamePanel extends StatelessWidget {
  const _OnlineGamePanel({required this.match, required this.error});

  final OnlineMatch match;
  final String? error;

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  match.status == 'waiting'
                      ? 'PRIVATE LOBBY'
                      : match.isActive
                      ? 'MOVE ${match.revision + 1}'
                      : 'MATCH COMPLETE',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(letterSpacing: 1.4),
                ),
                const SizedBox(height: 7),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 7),
                Text(
                  match.status == 'waiting'
                      ? 'Return to the lobby to share the join code.'
                      : match.isYourTurn
                      ? 'Choose any empty square. The server will evolve the board.'
                      : 'The board refreshes automatically.',
                ),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(error!),
          ),
        ],
        const SizedBox(height: 12),
        _OnlinePlayerTile(
          name: yourPlayer?.displayName ?? 'You',
          label: 'YOU',
          color: match.yourColor ?? engine.Player.black,
          cells: match.yourColor == engine.Player.white
              ? match.whitePopulation
              : match.blackPopulation,
          active: match.nextPlayer == match.yourColor,
        ),
        const SizedBox(height: 10),
        _OnlinePlayerTile(
          name: opponent?.displayName ?? 'Opponent',
          label: 'OPPONENT',
          color: opponent?.color ?? engine.Player.white,
          cells: opponent?.color == engine.Player.black
              ? match.blackPopulation
              : match.whitePopulation,
          active: match.nextPlayer == opponent?.color,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
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
  });

  final String name;
  final String label;
  final engine.Player color;
  final int cells;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
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
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color == engine.Player.black
                ? LifeColors.ink
                : LifeColors.paper,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey),
          ),
        ),
        const SizedBox(width: 12),
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

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
