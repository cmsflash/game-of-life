import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../providers.dart';
import '../../../shared/async_message.dart';
import '../../../shared/page_frame.dart';
import '../../../shared/player_avatar.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/online_models.dart';
import 'lobby_controller.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key});

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(authControllerProvider).status == AuthStatus.signedIn) {
        ref.read(lobbyControllerProvider.notifier).loadMatches();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth.status != AuthStatus.signedIn) {
      return PageFrame(
        maxWidth: 660,
        child: _SignedOutOnlineCard(
          onSignIn: () => context.go('/login?returnTo=/online'),
        ),
      );
    }
    ref.listen<LobbyState>(lobbyControllerProvider, (previous, next) {
      final id = next.matchedId;
      if (id != null && id != previous?.matchedId) {
        ref.read(lobbyControllerProvider.notifier).acknowledgeMatch();
        context.go('/online/match/$id');
      }
    });
    final lobby = ref.watch(lobbyControllerProvider);
    return PageFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            eyebrow: 'Online play',
            title: 'Hello, ${auth.user!.displayName}',
            description:
                'Find a new opponent or jump back into an active match. The server validates every move.',
          ),
          const SizedBox(height: 28),
          AsyncMessage(error: lobby.error),
          if (lobby.error != null) const SizedBox(height: 16),
          if (lobby.searching)
            _WaitingCard(
              icon: Icons.radar,
              title: lobby.matchmakingIntent == MatchmakingIntent.publicRoom
                  ? 'Public room open'
                  : 'Finding an opponent',
              description:
                  lobby.matchmakingIntent == MatchmakingIntent.publicRoom
                  ? 'Waiting for any player to join…'
                  : 'Looking for the next available player…',
              onCancel: () =>
                  ref.read(lobbyControllerProvider.notifier).cancelQuickMatch(),
            )
          else if (lobby.hosting)
            _PrivateWaitingCard(
              code: lobby.privateLobby!.joinCode ?? '—',
              onCancel: () => ref
                  .read(lobbyControllerProvider.notifier)
                  .closePrivateLobby(),
            )
          else
            _MatchActions(
              busy: lobby.loading || lobby.hasOwnedWaitingRoom,
              onQuickMatch: () =>
                  ref.read(lobbyControllerProvider.notifier).startQuickMatch(),
              onCreate: () => _showCreateRoomDialog(context),
              onJoin: () => _showJoinDialog(context),
            ),
          const SizedBox(height: 42),
          Row(
            children: [
              Text(
                'Your matches',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh matches',
                onPressed: lobby.loading
                    ? null
                    : () => ref
                          .read(lobbyControllerProvider.notifier)
                          .loadMatches(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (lobby.loading && lobby.matches.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            )
          else if (lobby.matches.isEmpty)
            const _EmptyMatches()
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final match in lobby.matches)
                      SizedBox(
                        width: width >= 800 ? (width - 14) / 2 : width,
                        child: OnlineMatchCard(
                          match: match,
                          onTap: () => context.go('/online/match/${match.id}'),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _showJoinDialog(BuildContext context) async {
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
    if (code?.trim().isNotEmpty ?? false) {
      await ref.read(lobbyControllerProvider.notifier).join(code!);
    }
  }

  Future<void> _showCreateRoomDialog(BuildContext context) async {
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
              subtitle: const Text('Wait for any available player.'),
              onTap: () => Navigator.pop(context, _RoomAccess.public),
            ),
            ListTile(
              key: const Key('create-private-room'),
              leading: const Icon(Icons.lock_outline),
              title: const Text('Private room'),
              subtitle: const Text('Invite someone with a join code.'),
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
      await controller.startQuickMatch(intent: MatchmakingIntent.publicRoom);
    } else {
      await controller.createPrivateLobby();
    }
  }
}

enum _RoomAccess { public, private }

class _SignedOutOnlineCard extends StatelessWidget {
  const _SignedOutOnlineCard({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.public, size: 34),
          ),
          const SizedBox(height: 20),
          Text(
            'The world is waiting',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          const Text(
            'Sign in with a username and password anywhere, or use Google where available.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: onSignIn,
            child: const Text('Sign in to play'),
          ),
        ],
      ),
    ),
  );
}

class _MatchActions extends StatelessWidget {
  const _MatchActions({
    required this.busy,
    required this.onQuickMatch,
    required this.onCreate,
    required this.onJoin,
  });

  final bool busy;
  final VoidCallback onQuickMatch;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (
        Icons.bolt,
        'Find opponent',
        'Search for the next available player now.',
        'Find opponent',
        onQuickMatch,
        true,
      ),
      (
        Icons.add_link,
        'Create room',
        'Open a public room or invite someone privately.',
        'Choose room',
        onCreate,
        false,
      ),
      (
        Icons.keyboard,
        'Join by code',
        'Enter a private lobby code.',
        'Enter code',
        onJoin,
        false,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final action in actions)
              SizedBox(
                width: constraints.maxWidth >= 850
                    ? (constraints.maxWidth - 28) / 3
                    : constraints.maxWidth,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(child: Icon(action.$1)),
                        const SizedBox(height: 20),
                        Text(
                          action.$2,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(action.$3),
                        const SizedBox(height: 20),
                        action.$6
                            ? FilledButton(
                                onPressed: busy ? null : action.$5,
                                child: Text(action.$4),
                              )
                            : OutlinedButton(
                                onPressed: busy ? null : action.$5,
                                child: Text(action.$4),
                              ),
                      ],
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

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onCancel,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(strokeWidth: 2),
                Icon(icon),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                Text(description),
              ],
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    ),
  );
}

class _PrivateWaitingCard extends StatelessWidget {
  const _PrivateWaitingCard({required this.code, required this.onCancel});

  final String code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 18,
        runSpacing: 14,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Waiting for a friend',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text('Share this private join code:'),
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
          TextButton(onPressed: onCancel, child: const Text('Cancel lobby')),
        ],
      ),
    ),
  );
}

class OnlineMatchCard extends StatelessWidget {
  const OnlineMatchCard({super.key, required this.match, required this.onTap});

  final OnlineMatchSummary match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            if (match.status == 'waiting')
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: const Icon(Icons.public),
              )
            else
              PlayerAvatar(
                displayName: match.opponentName,
                avatarUrl: match.opponentAvatarUrl,
                avatarVersion: match.opponentAvatarVersion,
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'vs ${match.opponentName}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 3),
                  Text('Online · ${onlineMatchStatus(match)}'),
                ],
              ),
            ),
            if (match.yourTurn && match.status == 'active')
              const Badge(
                backgroundColor: LifeColors.coral,
                child: Icon(Icons.priority_high, size: 16),
              ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}

String onlineMatchStatus(OnlineMatchSummary match) {
  if (match.status == 'completed') return 'Completed';
  if (match.status == 'waiting') return 'Waiting for a player';
  if (match.yourTurn) return 'Your turn';
  return 'Waiting for opponent';
}

class _EmptyMatches extends StatelessWidget {
  const _EmptyMatches();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(36),
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
              'No active matches yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 5),
            const Text('Start a quick match or invite a friend.'),
          ],
        ),
      ),
    ),
  );
}
