import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../providers.dart';
import '../../shared/async_message.dart';
import '../../shared/page_frame.dart';
import '../auth/presentation/auth_controller.dart';
import '../game/domain/game_session.dart';
import '../game/presentation/local_games_controller.dart';
import '../online/data/online_models.dart';
import '../online/presentation/lobby_controller.dart';
import '../online/presentation/lobby_screen.dart';
import '../stats/presentation/player_metrics_panel.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeHome());
  }

  void _resumeHome() {
    if (!mounted) return;
    final matchedId = ref.read(lobbyControllerProvider).matchedId;
    if (matchedId != null) {
      _openMatchedGame(matchedId);
      return;
    }
    _loadOnlineMatches();
  }

  void _openMatchedGame(String id) {
    ref.read(lobbyControllerProvider.notifier).acknowledgeMatch();
    context.go('/online/match/$id');
  }

  void _loadOnlineMatches() {
    if (!mounted ||
        ref.read(authControllerProvider).status != AuthStatus.signedIn) {
      return;
    }
    unawaited(ref.read(lobbyControllerProvider.notifier).loadMatches());
  }

  bool _requireSignedIn() {
    if (ref.read(authControllerProvider).status == AuthStatus.signedIn) {
      return true;
    }
    context.go('/login?returnTo=${Uri.encodeComponent('/')}');
    return false;
  }

  void _findOpponent() {
    if (!_requireSignedIn()) return;
    unawaited(
      ref
          .read(lobbyControllerProvider.notifier)
          .startQuickMatch(intent: MatchmakingIntent.findOpponent),
    );
  }

  Future<void> _createRoom() async {
    if (!_requireSignedIn()) return;
    final access = await showDialog<_RoomAccess>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create room'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('create-public-room'),
              leading: const Icon(Icons.public),
              title: const Text('Public room'),
              subtitle: const Text(
                'Wait for any available player. The match is rated.',
              ),
              onTap: () => Navigator.pop(context, _RoomAccess.public),
            ),
            ListTile(
              key: const Key('create-private-room'),
              leading: const Icon(Icons.lock_outline),
              title: const Text('Private room'),
              subtitle: const Text(
                'Invite someone with a join code. The match is rated.',
              ),
              onTap: () => Navigator.pop(context, _RoomAccess.private),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || access == null) return;
    final controller = ref.read(lobbyControllerProvider.notifier);
    if (access == _RoomAccess.public) {
      unawaited(
        controller.startQuickMatch(intent: MatchmakingIntent.publicRoom),
      );
    } else {
      unawaited(controller.createPrivateLobby());
    }
  }

  Future<void> _joinByCode() async {
    if (!_requireSignedIn()) return;
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join by code'),
        content: TextField(
          key: const Key('join-code'),
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
            LengthLimitingTextInputFormatter(10),
          ],
          decoration: const InputDecoration(
            labelText: 'Join code',
            hintText: 'ABCD12',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || !(code?.trim().isNotEmpty ?? false)) return;
    unawaited(ref.read(lobbyControllerProvider.notifier).join(code!));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final lobby = ref.watch(lobbyControllerProvider);
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (next.status == AuthStatus.signedIn &&
          previous?.status != AuthStatus.signedIn) {
        _loadOnlineMatches();
      } else if (next.status == AuthStatus.signedOut &&
          previous?.status == AuthStatus.signedIn) {
        ref.read(lobbyControllerProvider.notifier).sessionEnded();
      }
    });
    ref.listen<LobbyState>(lobbyControllerProvider, (previous, next) {
      final id = next.matchedId;
      if (id != null && id != previous?.matchedId) {
        _openMatchedGame(id);
      }
    });
    return PageFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'Home',
            title: 'Choose your next game',
            description:
                'Share one device, find someone now, or open a room for another player.',
          ),
          const SizedBox(height: 22),
          _HomeActions(
            busy:
                auth.status == AuthStatus.loading ||
                (auth.status == AuthStatus.signedIn &&
                    (lobby.loading ||
                        lobby.searching ||
                        lobby.hosting ||
                        lobby.hasOwnedWaitingRoom)),
            onPlayLocal: () => context.go('/local/setup'),
            onFindOpponent: _findOpponent,
            onCreateRoom: _createRoom,
            onJoinByCode: _joinByCode,
          ),
          if (auth.status == AuthStatus.signedIn && lobby.error != null) ...[
            const SizedBox(height: 18),
            AsyncMessage(error: lobby.error),
          ],
          if (auth.status == AuthStatus.signedIn && lobby.searching) ...[
            const SizedBox(height: 18),
            _MatchmakingStatusCard(
              publicRoom:
                  lobby.matchmakingIntent == MatchmakingIntent.publicRoom,
              onCancel: () =>
                  ref.read(lobbyControllerProvider.notifier).cancelQuickMatch(),
            ),
          ] else if (auth.status == AuthStatus.signedIn && lobby.hosting) ...[
            const SizedBox(height: 18),
            _PrivateRoomStatusCard(
              code: lobby.privateLobby!.joinCode ?? '—',
              onCancel: () => ref
                  .read(lobbyControllerProvider.notifier)
                  .closePrivateLobby(),
            ),
          ],
          if (auth.status == AuthStatus.signedIn) ...[
            const SizedBox(height: 36),
            const PlayerMetricsPanel(),
          ],
          const SizedBox(height: 48),
          _CurrentGamesSection(
            onlineMatches: auth.status == AuthStatus.signedIn
                ? lobby.matches
                : const [],
            onlineLoading:
                auth.status == AuthStatus.signedIn &&
                lobby.loading &&
                lobby.matches.isEmpty,
            signedIn: auth.status == AuthStatus.signedIn,
            onRefreshOnline: _loadOnlineMatches,
          ),
        ],
      ),
    );
  }
}

enum _RoomAccess { public, private }

class _HomeActions extends ConsumerWidget {
  const _HomeActions({
    required this.busy,
    required this.onPlayLocal,
    required this.onFindOpponent,
    required this.onCreateRoom,
    required this.onJoinByCode,
  });

  final bool busy;
  final VoidCallback onPlayLocal;
  final VoidCallback onFindOpponent;
  final VoidCallback onCreateRoom;
  final VoidCallback onJoinByCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localUnavailable = ref.watch(
      localGamesProvider.select(
        (state) => state.status == LocalGamesLoadStatus.failed,
      ),
    );
    final actions = [
      _HomeAction(
        key: const Key('play-local'),
        icon: Icons.devices_outlined,
        title: 'Play locally',
        description: 'Share this device and keep the game available offline.',
        buttonLabel: 'New local game',
        onPressed: localUnavailable ? null : onPlayLocal,
        emphasized: true,
      ),
      _HomeAction(
        key: const Key('find-opponent'),
        icon: Icons.travel_explore,
        title: 'Find opponent',
        description: 'Search for an available player in a rated online game.',
        buttonLabel: 'Start search',
        onPressed: busy ? null : onFindOpponent,
        emphasized: true,
      ),
      _HomeAction(
        key: const Key('create-room'),
        icon: Icons.add_home_work_outlined,
        title: 'Create room',
        description:
            'Open a public room or share a private code for a rated match.',
        buttonLabel: 'Choose room',
        onPressed: busy ? null : onCreateRoom,
      ),
      _HomeAction(
        key: const Key('join-by-code'),
        icon: Icons.dialpad_outlined,
        title: 'Join by code',
        description: 'Enter a private-room code to join a rated match.',
        buttonLabel: 'Enter code',
        onPressed: busy ? null : onJoinByCode,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760 ? 2 : 1;
        final width = columns == 2
            ? (constraints.maxWidth - 14) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: _HomeActionCard(action: action),
              ),
          ],
        );
      },
    );
  }
}

class _HomeAction {
  const _HomeAction({
    required this.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.onPressed,
    this.emphasized = false,
  });

  final Key key;
  final IconData icon;
  final String title;
  final String description;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final bool emphasized;
}

class _HomeActionCard extends StatelessWidget {
  const _HomeActionCard({required this.action});

  final _HomeAction action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(child: Icon(action.icon)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(action.description),
                const SizedBox(height: 18),
                if (action.emphasized)
                  FilledButton(
                    key: action.key,
                    onPressed: action.onPressed,
                    child: Text(action.buttonLabel),
                  )
                else
                  OutlinedButton(
                    key: action.key,
                    onPressed: action.onPressed,
                    child: Text(action.buttonLabel),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MatchmakingStatusCard extends StatelessWidget {
  const _MatchmakingStatusCard({
    required this.publicRoom,
    required this.onCancel,
  });

  final bool publicRoom;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('matchmaking-status'),
    color: Theme.of(context).colorScheme.primaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 46,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(strokeWidth: 2),
                Icon(publicRoom ? Icons.public : Icons.travel_explore),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  publicRoom ? 'Public room open' : 'Finding an opponent',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  publicRoom
                      ? 'Waiting for any player to join this rated match…'
                      : 'Looking for the next player for a rated match…',
                ),
              ],
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    ),
  );
}

class _PrivateRoomStatusCard extends StatelessWidget {
  const _PrivateRoomStatusCard({required this.code, required this.onCancel});

  final String code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('private-room-status'),
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Private room open',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text('Rated match · Share this join code:'),
            ],
          ),
          SelectionArea(
            child: Text(
              code,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                letterSpacing: 4,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Copy code',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Join code copied.')),
              );
            },
            icon: const Icon(Icons.copy),
          ),
          TextButton(onPressed: onCancel, child: const Text('Close room')),
        ],
      ),
    ),
  );
}

class _CurrentGamesSection extends ConsumerWidget {
  const _CurrentGamesSection({
    required this.onlineMatches,
    required this.onlineLoading,
    required this.signedIn,
    required this.onRefreshOnline,
  });

  final List<OnlineMatchSummary> onlineMatches;
  final bool onlineLoading;
  final bool signedIn;
  final VoidCallback onRefreshOnline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localGamesProvider);
    final currentItems = <_CurrentGameItem>[
      for (final summary in local.summaries)
        if (summary.isActive) _CurrentGameItem.local(summary),
      for (final match in onlineMatches)
        if (match.status == 'active' || match.status == 'waiting')
          _CurrentGameItem.online(match),
    ]..sort(_CurrentGameItem.compare);
    final finishedItems = <_CurrentGameItem>[
      for (final summary in local.summaries)
        if (!summary.isActive) _CurrentGameItem.local(summary),
      for (final match in onlineMatches)
        if (match.status == 'completed') _CurrentGameItem.online(match),
    ]..sort(_CurrentGameItem.compare);
    final localLoading = local.status == LocalGamesLoadStatus.loading;
    final loading = localLoading || onlineLoading;
    return Column(
      key: const Key('current-games'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Current games',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            if (onlineLoading)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (signedIn)
              IconButton(
                tooltip: 'Refresh online games',
                onPressed: onlineLoading ? null : onRefreshOnline,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (local.status == LocalGamesLoadStatus.failed)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AsyncMessage(
                  error: local.error ?? 'Local games could not be loaded.',
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('retry-local-games'),
                  onPressed: () => unawaited(
                    ref.read(localGamesProvider.notifier).retryLoad(),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry local games'),
                ),
              ],
            ),
          ),
        if (currentItems.isEmpty && loading)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(34),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (currentItems.isEmpty)
          _EmptyCurrentGames(signedIn: signedIn)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth >= 760
                  ? (constraints.maxWidth - 14) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final item in currentItems)
                    SizedBox(
                      width: width,
                      child: _CurrentGameCard(item: item),
                    ),
                ],
              );
            },
          ),
        if (finishedItems.isNotEmpty) ...[
          const SizedBox(height: 18),
          Card(
            child: ExpansionTile(
              key: const Key('finished-games'),
              leading: const Icon(Icons.history),
              title: const Text('Finished games'),
              subtitle: Text(
                '${finishedItems.length} saved ${finishedItems.length == 1 ? 'game' : 'games'}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                for (var index = 0; index < finishedItems.length; index++) ...[
                  if (index > 0) const SizedBox(height: 10),
                  _CurrentGameCard(item: finishedItems[index]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CurrentGameItem {
  const _CurrentGameItem({
    required this.id,
    required this.title,
    required this.status,
    required this.route,
    required this.updatedAt,
    required this.icon,
    required this.priority,
    required this.emphasized,
    required this.completed,
    this.localGameId,
    this.joinCode,
    this.waitingRoomId,
  });

  factory _CurrentGameItem.local(LocalGameSummary summary) {
    final status = summary.isActive
        ? summary.toMove == engine.Player.black
              ? 'Black to move'
              : 'White to move'
        : summary.isDraw
        ? 'Draw'
        : summary.winner == engine.Player.black
        ? 'Black won'
        : 'White won';
    return _CurrentGameItem(
      id: 'local-${summary.id}',
      title: summary.title,
      status: 'Local · Unrated · $status',
      route: '/local/game/${summary.id}',
      updatedAt: summary.updatedAt,
      icon: Icons.devices_outlined,
      priority: summary.isActive ? 1 : 3,
      emphasized: false,
      completed: !summary.isActive,
      localGameId: summary.id,
    );
  }

  factory _CurrentGameItem.online(OnlineMatchSummary match) => _CurrentGameItem(
    id: 'online-${match.id}',
    title: match.status == 'waiting' && match.joinCode != null
        ? 'Private room'
        : 'vs ${match.opponentName}',
    status: match.status == 'waiting' && match.joinCode != null
        ? 'Online · Rated · Private room waiting'
        : 'Online · Rated · ${onlineMatchStatus(match)}',
    route: '/online/match/${match.id}',
    updatedAt:
        match.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    icon: Icons.public,
    priority: match.status == 'completed'
        ? 3
        : match.yourTurn && match.status == 'active'
        ? 0
        : 2,
    emphasized: match.yourTurn && match.status == 'active',
    completed: match.status == 'completed',
    joinCode: match.status == 'waiting' ? match.joinCode : null,
    waitingRoomId: match.status == 'waiting' && match.joinCode != null
        ? match.id
        : null,
  );

  final String id;
  final String title;
  final String status;
  final String route;
  final DateTime updatedAt;
  final IconData icon;
  final int priority;
  final bool emphasized;
  final bool completed;
  final String? localGameId;
  final String? joinCode;
  final String? waitingRoomId;

  static int compare(_CurrentGameItem a, _CurrentGameItem b) {
    final priority = a.priority.compareTo(b.priority);
    if (priority != 0) return priority;
    final updated = b.updatedAt.compareTo(a.updatedAt);
    return updated != 0 ? updated : a.id.compareTo(b.id);
  }
}

class _CurrentGameCard extends ConsumerWidget {
  const _CurrentGameCard({required this.item});

  final _CurrentGameItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: Key(item.id),
      color: item.emphasized
          ? scheme.tertiaryContainer
          : item.completed
          ? scheme.surfaceContainerLow
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => context.go(item.route),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: item.emphasized
                    ? scheme.tertiary
                    : scheme.secondaryContainer,
                foregroundColor: item.emphasized
                    ? scheme.onTertiary
                    : scheme.onSecondaryContainer,
                child: Icon(item.icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: item.completed ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.status,
                      style: TextStyle(
                        color: item.emphasized
                            ? scheme.onTertiaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: item.emphasized
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              if (item.emphasized)
                const Badge(child: Icon(Icons.priority_high_rounded, size: 16)),
              if (item.joinCode != null)
                IconButton(
                  tooltip: 'Copy join code',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: item.joinCode!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Join code copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
              if (item.waitingRoomId != null)
                PopupMenuButton<_OnlineRoomAction>(
                  tooltip: 'Private room actions',
                  onSelected: (action) {
                    if (action == _OnlineRoomAction.close) {
                      unawaited(
                        _confirmCloseRoom(context, ref, item.waitingRoomId!),
                      );
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _OnlineRoomAction.close,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.close),
                        title: Text('Close private room'),
                      ),
                    ),
                  ],
                ),
              if (item.localGameId != null)
                PopupMenuButton<_LocalGameAction>(
                  tooltip: 'Local game actions',
                  onSelected: (action) {
                    if (action == _LocalGameAction.delete) {
                      _confirmDeleteLocalGame(
                        context,
                        ref,
                        item.localGameId!,
                        item.title,
                      );
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _LocalGameAction.delete,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete local game'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteLocalGame(
    BuildContext context,
    WidgetRef ref,
    String id,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete local game?'),
        content: Text('“$title” will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep game'),
          ),
          FilledButton(
            key: const Key('confirm-delete-local-game'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete local game'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    try {
      await ref.read(localGamesProvider.notifier).delete(id);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The local game could not be deleted.')),
      );
    }
  }

  Future<void> _confirmCloseRoom(
    BuildContext context,
    WidgetRef ref,
    String id,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close private room?'),
        content: const Text(
          'The join code will stop working and the waiting room will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep room open'),
          ),
          FilledButton(
            key: const Key('confirm-close-private-room'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close room'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    await ref.read(lobbyControllerProvider.notifier).closeWaitingRoom(id);
  }
}

enum _LocalGameAction { delete }

enum _OnlineRoomAction { close }

class _EmptyCurrentGames extends StatelessWidget {
  const _EmptyCurrentGames({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(34),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.hourglass_empty,
              size: 42,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No current games',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 5),
            Text(
              signedIn
                  ? 'Start locally, find an opponent, or create a room.'
                  : 'Start a local game, or sign in for online play.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}
