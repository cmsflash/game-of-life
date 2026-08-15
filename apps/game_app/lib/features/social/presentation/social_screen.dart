import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../../../shared/async_message.dart';
import '../../../shared/page_frame.dart';
import '../../../shared/player_avatar.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/social_models.dart';
import 'social_controller.dart';

class SocialScreen extends ConsumerStatefulWidget {
  const SocialScreen({super.key});

  @override
  ConsumerState<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends ConsumerState<SocialScreen> {
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String? _loadedAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _connectAndLoad(force: true),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _connectAndLoad({bool force = false}) {
    if (!mounted) return;
    final auth = ref.read(authControllerProvider);
    final controller = ref.read(socialControllerProvider.notifier);
    final user = auth.user;
    if (auth.status != AuthStatus.signedIn || user == null) {
      _loadedAccountId = null;
      controller.disconnectAccount();
      return;
    }
    final accountChanged = _loadedAccountId != user.id;
    _loadedAccountId = user.id;
    controller.connectAccount(user.id);
    unawaited(controller.load(force: force && accountChanged));
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    ref.read(socialControllerProvider.notifier).cancelSearch();
    final query = value.trim();
    if (query.isEmpty) return;
    if (query.length > 48) return;
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => ref.read(socialControllerProvider.notifier).search(query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (previous?.user?.id != next.user?.id ||
          previous?.status != next.status) {
        _connectAndLoad(force: true);
      }
    });
    ref.listen<SocialState>(socialControllerProvider, (previous, next) {
      final matchId = next.matchId;
      if (matchId != null && matchId != previous?.matchId) {
        ref.read(socialControllerProvider.notifier).acknowledgeMatch();
        context.go('/online/match/$matchId');
      }
    });
    if (auth.status != AuthStatus.signedIn || auth.user == null) {
      return const _SignedOutSocial();
    }
    final social = ref.watch(socialControllerProvider);
    return PageFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: SectionHeading(
                  eyebrow: 'Social',
                  title: 'Play with people you know',
                  description:
                      'Find players by public display name, become friends, and send rated challenges.',
                ),
              ),
              IconButton(
                key: const Key('refresh-social'),
                tooltip: 'Refresh Social',
                onPressed: social.status == SocialStatus.loading
                    ? null
                    : () => unawaited(
                        ref.read(socialControllerProvider.notifier).refresh(),
                      ),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (social.error != null || social.notice != null) ...[
            const SizedBox(height: 18),
            AsyncMessage(error: social.error, notice: social.notice),
          ],
          const SizedBox(height: 24),
          _PlayerSearch(
            controller: _searchController,
            state: social,
            onChanged: _searchChanged,
            onSubmitted: (query) => unawaited(
              ref.read(socialControllerProvider.notifier).search(query),
            ),
          ),
          if (social.status == SocialStatus.loading &&
              !social.hasOverviewData) ...[
            const SizedBox(height: 24),
            const _SocialLoading(),
          ] else if (social.status == SocialStatus.failed &&
              !social.hasOverviewData) ...[
            const SizedBox(height: 24),
            _SocialLoadFailure(
              onRetry: () => unawaited(
                ref.read(socialControllerProvider.notifier).refresh(),
              ),
            ),
          ] else ...[
            if (social.incomingChallenges.isNotEmpty ||
                social.outgoingChallenges.isNotEmpty) ...[
              const SizedBox(height: 34),
              _ChallengesSection(state: social),
            ],
            if (social.incomingFriendRequests.isNotEmpty ||
                social.outgoingFriendRequests.isNotEmpty) ...[
              const SizedBox(height: 34),
              _FriendRequestsSection(state: social),
            ],
            const SizedBox(height: 34),
            _FriendsSection(state: social),
          ],
        ],
      ),
    );
  }
}

class _SignedOutSocial extends StatelessWidget {
  const _SignedOutSocial();

  @override
  Widget build(BuildContext context) => PageFrame(
    maxWidth: 760,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          eyebrow: 'Social',
          title: 'Play with friends',
          description:
              'Sign in to find players by their public display name and send rated challenges.',
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Icon(Icons.people_outline, size: 50),
                const SizedBox(height: 14),
                Text(
                  'Your friends are one sign-in away',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Local games still work without an account.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const Key('social-sign-in'),
                  onPressed: () => context.go('/login?returnTo=/social'),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PlayerSearch extends ConsumerWidget {
  const _PlayerSearch({
    required this.controller,
    required this.state,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final SocialState state;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Find players', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 5),
          const Text(
            'Every signed-in player can be found by public display name. Usernames and email addresses are never shown.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('social-search'),
            controller: controller,
            maxLength: 48,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Public display name',
              hintText: 'Type a display name',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: state.searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Search',
                      onPressed: () => onSubmitted(controller.text),
                      icon: const Icon(Icons.arrow_forward),
                    ),
            ),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
          if (state.searchQuery.isNotEmpty && !state.searching) ...[
            const SizedBox(height: 16),
            if (state.searchResults.isEmpty)
              Text('No players found for “${state.searchQuery}”.')
            else
              _ResponsiveCards(
                children: [
                  for (final player in state.searchResults)
                    _SearchResultCard(player: player, state: state),
                ],
              ),
          ],
        ],
      ),
    ),
  );
}

class _SearchResultCard extends ConsumerWidget {
  const _SearchResultCard({required this.player, required this.state});

  final PublicPlayer player;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFriend = state.friends.any((item) => item.id == player.id);
    final outgoing = state.outgoingFriendRequests.any(
      (request) => request.player.id == player.id,
    );
    final incoming = state.incomingFriendRequests.any(
      (request) => request.player.id == player.id,
    );
    final busy = state.actionId != null;
    return _PlayerCard(
      key: Key('search-player-${player.id}'),
      player: player,
      trailing: isFriend
          ? const Chip(label: Text('Friends'))
          : outgoing
          ? const Chip(label: Text('Request sent'))
          : incoming
          ? const Chip(label: Text('Respond below'))
          : FilledButton.icon(
              key: Key('add-friend-${player.id}'),
              onPressed: busy
                  ? null
                  : () => unawaited(
                      ref
                          .read(socialControllerProvider.notifier)
                          .sendFriendRequest(player),
                    ),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add friend'),
            ),
    );
  }
}

class _ChallengesSection extends StatelessWidget {
  const _ChallengesSection({required this.state});

  final SocialState state;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Challenges', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 5),
      const Text('Every friend challenge uses the default rules and is rated.'),
      const SizedBox(height: 14),
      _ResponsiveCards(
        children: [
          for (final challenge in state.incomingChallenges)
            _IncomingChallengeCard(challenge: challenge, state: state),
          for (final challenge in state.outgoingChallenges)
            _OutgoingChallengeCard(challenge: challenge, state: state),
        ],
      ),
    ],
  );
}

class _IncomingChallengeCard extends ConsumerWidget {
  const _IncomingChallengeCard({required this.challenge, required this.state});

  final PlayerChallenge challenge;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SocialActionCard(
    key: Key('incoming-challenge-${challenge.id}'),
    player: challenge.player,
    title: 'Challenge from ${challenge.player.displayName}',
    subtitle: _challengeDetails(challenge),
    actions: [
      FilledButton(
        key: Key('accept-challenge-${challenge.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .acceptChallenge(challenge),
              )
            : null,
        child: const Text('Accept'),
      ),
      TextButton(
        key: Key('decline-challenge-${challenge.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .declineChallenge(challenge),
              )
            : null,
        child: const Text('Decline'),
      ),
    ],
  );
}

class _OutgoingChallengeCard extends ConsumerWidget {
  const _OutgoingChallengeCard({required this.challenge, required this.state});

  final PlayerChallenge challenge;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SocialActionCard(
    key: Key('outgoing-challenge-${challenge.id}'),
    player: challenge.player,
    title: 'Challenge sent to ${challenge.player.displayName}',
    subtitle: _challengeDetails(challenge),
    actions: [
      OutlinedButton(
        key: Key('cancel-challenge-${challenge.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .cancelChallenge(challenge),
              )
            : null,
        child: const Text('Cancel challenge'),
      ),
    ],
  );
}

class _FriendRequestsSection extends StatelessWidget {
  const _FriendRequestsSection({required this.state});

  final SocialState state;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Friend requests',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 14),
      _ResponsiveCards(
        children: [
          for (final request in state.incomingFriendRequests)
            _IncomingFriendRequestCard(request: request, state: state),
          for (final request in state.outgoingFriendRequests)
            _OutgoingFriendRequestCard(request: request, state: state),
        ],
      ),
    ],
  );
}

class _IncomingFriendRequestCard extends ConsumerWidget {
  const _IncomingFriendRequestCard({
    required this.request,
    required this.state,
  });

  final FriendRequest request;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SocialActionCard(
    key: Key('incoming-friend-request-${request.id}'),
    player: request.player,
    title: request.player.displayName,
    subtitle: 'Wants to be friends · Elo ${request.player.elo}',
    actions: [
      FilledButton(
        key: Key('accept-friend-request-${request.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .acceptFriendRequest(request),
              )
            : null,
        child: const Text('Accept'),
      ),
      TextButton(
        key: Key('decline-friend-request-${request.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .declineFriendRequest(request),
              )
            : null,
        child: const Text('Decline'),
      ),
    ],
  );
}

class _OutgoingFriendRequestCard extends ConsumerWidget {
  const _OutgoingFriendRequestCard({
    required this.request,
    required this.state,
  });

  final FriendRequest request;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SocialActionCard(
    key: Key('outgoing-friend-request-${request.id}'),
    player: request.player,
    title: request.player.displayName,
    subtitle: 'Friend request pending · Elo ${request.player.elo}',
    actions: [
      OutlinedButton(
        key: Key('cancel-friend-request-${request.id}'),
        onPressed: state.actionId == null
            ? () => unawaited(
                ref
                    .read(socialControllerProvider.notifier)
                    .cancelFriendRequest(request),
              )
            : null,
        child: const Text('Cancel request'),
      ),
    ],
  );
}

class _FriendsSection extends StatelessWidget {
  const _FriendsSection({required this.state});

  final SocialState state;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('friends-list'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Friends', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 5),
      const Text('Play sends a rated default-rules challenge.'),
      const SizedBox(height: 14),
      if (state.friends.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(26),
            child: Center(
              child: Text('No friends yet. Search by public display name.'),
            ),
          ),
        )
      else
        _ResponsiveCards(
          children: [
            for (final friend in state.friends)
              _FriendCard(friend: friend, state: state),
          ],
        ),
    ],
  );
}

class _FriendCard extends ConsumerWidget {
  const _FriendCard({required this.friend, required this.state});

  final PublicPlayer friend;
  final SocialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outgoingChallenge = state.outgoingChallenges.any(
      (challenge) => challenge.player.id == friend.id,
    );
    final incomingChallenge = state.incomingChallenges.any(
      (challenge) => challenge.player.id == friend.id,
    );
    return _PlayerCard(
      key: Key('friend-${friend.id}'),
      player: friend,
      trailing: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: Key('play-friend-${friend.id}'),
            onPressed:
                state.actionId == null &&
                    !outgoingChallenge &&
                    !incomingChallenge
                ? () => unawaited(
                    ref
                        .read(socialControllerProvider.notifier)
                        .createChallenge(friend),
                  )
                : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              outgoingChallenge
                  ? 'Sent'
                  : incomingChallenge
                  ? 'Respond above'
                  : 'Play',
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Friend actions for ${friend.displayName}',
            onSelected: (value) {
              if (value == 'unfriend') {
                unawaited(_confirmUnfriend(context, ref, friend));
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'unfriend',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.person_remove_outlined),
                  title: Text('Remove friend'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUnfriend(
    BuildContext context,
    WidgetRef ref,
    PublicPlayer player,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove friend?'),
        content: Text(
          'You and ${player.displayName} will no longer be able to send direct challenges.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep friend'),
          ),
          FilledButton(
            key: Key('confirm-unfriend-${player.id}'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove friend'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await ref.read(socialControllerProvider.notifier).unfriend(player);
  }
}

class _PlayerCard extends StatelessWidget {
  const _PlayerCard({super.key, required this.player, required this.trailing});

  final PublicPlayer player;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PlayerAvatar(
                displayName: player.displayName,
                avatarUrl: player.avatarUrl,
                avatarVersion: player.avatarVersion,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    player.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              Chip(label: Text('Elo ${player.elo}')),
            ],
          ),
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: trailing),
        ],
      ),
    ),
  );
}

class _SocialActionCard extends StatelessWidget {
  const _SocialActionCard({
    super.key,
    required this.player,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final PublicPlayer player;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlayerAvatar(
            displayName: player.displayName,
            avatarUrl: player.avatarUrl,
            avatarVersion: player.avatarVersion,
          ),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(subtitle),
          const Spacer(),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    ),
  );
}

class _ResponsiveCards extends StatelessWidget {
  const _ResponsiveCards({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth >= 760
          ? (constraints.maxWidth - 12) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final child in children)
            SizedBox(
              width: width,
              child: IntrinsicHeight(child: child),
            ),
        ],
      );
    },
  );
}

class _SocialLoading extends StatelessWidget {
  const _SocialLoading();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(30),
      child: Center(child: CircularProgressIndicator()),
    ),
  );
}

class _SocialLoadFailure extends StatelessWidget {
  const _SocialLoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Center(
        child: FilledButton.icon(
          key: const Key('retry-social'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry Social'),
        ),
      ),
    ),
  );
}

String _challengeDetails(PlayerChallenge challenge) {
  final expiry = challenge.expiresAt.toLocal();
  return 'Rated · Default rules · Expires ${expiry.month}/${expiry.day}';
}
