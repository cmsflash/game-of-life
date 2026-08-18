import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/player_stats.dart';
import 'player_stats_controller.dart';

class PlayerMetricsPanel extends ConsumerStatefulWidget {
  const PlayerMetricsPanel({super.key});

  @override
  ConsumerState<PlayerMetricsPanel> createState() => _PlayerMetricsPanelState();
}

class _PlayerMetricsPanelState extends ConsumerState<PlayerMetricsPanel> {
  String? _loadedAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  void _ensureLoaded() {
    if (!mounted) return;
    final auth = ref.read(authControllerProvider);
    final user = auth.user;
    final controller = ref.read(playerStatsControllerProvider.notifier);
    if (auth.status != AuthStatus.signedIn || user == null) {
      _loadedAccountId = null;
      controller.disconnectAccount();
      return;
    }
    final accountChanged = _loadedAccountId != user.id;
    _loadedAccountId = user.id;
    controller.connectAccount(user.id);
    unawaited(controller.load(force: accountChanged));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (previous?.user?.id != next.user?.id ||
          previous?.status != next.status) {
        _ensureLoaded();
      }
    });
    if (auth.status != AuthStatus.signedIn || auth.user == null) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(playerStatsControllerProvider);
    final stats = state.stats;
    return Column(
      key: const Key('player-metrics'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rated performance',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Elo, wins, losses, draws, and total games update when a '
                    'rated online game ends. Total kills update after every '
                    'rated move, including during active games. Local games '
                    'are unrated. '
                    'A kill is every opponent cell that dies, no matter who caused it.',
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('refresh-player-metrics'),
              tooltip: 'Refresh player stats',
              onPressed: state.status == PlayerStatsStatus.loading
                  ? null
                  : () => unawaited(
                      ref
                          .read(playerStatsControllerProvider.notifier)
                          .refresh(),
                    ),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (state.status == PlayerStatsStatus.loading && stats == null)
          const _MetricsLoadingCard()
        else if (state.status == PlayerStatsStatus.failed && stats == null)
          _MetricsErrorCard(
            message: state.error ?? 'Your player stats could not be loaded.',
            onRetry: () => unawaited(
              ref.read(playerStatsControllerProvider.notifier).refresh(),
            ),
          )
        else if (stats != null) ...[
          _MetricsGrid(stats: stats),
          if (stats.isEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Your Elo starts at 1200. Finish a rated online game to build your '
              'result record; kills update after every move.',
            ),
          ],
          if (state.status == PlayerStatsStatus.failed) ...[
            const SizedBox(height: 10),
            _InlineMetricsError(
              message: state.error ?? 'The latest stats could not be loaded.',
            ),
          ],
        ],
      ],
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.stats});

  final PlayerStats stats;

  @override
  Widget build(BuildContext context) {
    final values = [
      ('Elo', '${stats.elo}', Icons.trending_up),
      ('Win rate', _percent(stats.winRate), Icons.percent),
      ('Victories', '${stats.victories}', Icons.emoji_events_outlined),
      ('Total games', '${stats.totalGames}', Icons.sports_esports_outlined),
      ('Total kills', '${stats.kills}', Icons.flash_on_outlined),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 960
            ? 5
            : constraints.maxWidth >= 600
            ? 3
            : constraints.maxWidth >= 340
            ? 2
            : 1;
        const gap = 10.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final value in values)
              SizedBox(
                width: width,
                child: Semantics(
                  label: '${value.$1}: ${value.$2}',
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(value.$3, size: 21),
                          const SizedBox(height: 12),
                          Text(
                            value.$2,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(value.$1),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricsLoadingCard extends StatelessWidget {
  const _MetricsLoadingCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 14),
          Text('Loading your rated record…'),
        ],
      ),
    ),
  );
}

class _MetricsErrorCard extends StatelessWidget {
  const _MetricsErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Wrap(
        spacing: 14,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          Text(message),
          OutlinedButton.icon(
            key: const Key('retry-player-metrics'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

class _InlineMetricsError extends StatelessWidget {
  const _InlineMetricsError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    '$message Showing the last loaded record.',
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  );
}

String _percent(double value) {
  final percent = value * 100;
  return percent == percent.roundToDouble()
      ? '${percent.round()}%'
      : '${percent.toStringAsFixed(1)}%';
}
