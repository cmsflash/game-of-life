import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../../../shared/async_message.dart';
import '../../../shared/page_frame.dart';
import '../../notifications/presentation/turn_notification_preference_card.dart';
import '../../stats/presentation/player_metrics_panel.dart';
import 'auth_controller.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.status == AuthStatus.signedIn ? auth.user : null;
    return PageFrame(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            eyebrow: 'Player',
            title: user == null ? 'Make Life your own' : 'Your corner of Life',
            description: user == null
                ? 'Sign in for online play, or learn more about the game and how your data is handled.'
                : 'Your account travels with you between mobile, web, and desktop.',
          ),
          const SizedBox(height: 28),
          if (user == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    const Icon(Icons.person_outline, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      'Sign in to find other players',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your local games remain available without an account.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => context.go('/login?returnTo=/player'),
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 34,
                          child: Text(
                            (user.displayName.isEmpty
                                    ? 'P'
                                    : user.displayName.substring(0, 1))
                                .toUpperCase(),
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.displayName,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 2),
                              Text('@${user.username}'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    if (user.email != null)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.mail_outline),
                        title: const Text('Email'),
                        subtitle: Text(user.email!),
                      ),
                    if (user.createdAt != null)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.calendar_today_outlined),
                        title: const Text('Player since'),
                        subtitle: Text(
                          '${user.createdAt!.year}-${user.createdAt!.month.toString().padLeft(2, '0')}-${user.createdAt!.day.toString().padLeft(2, '0')}',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 26),
            const PlayerMetricsPanel(),
            const SizedBox(height: 18),
            const TurnNotificationPreferenceCard(),
          ],
          const SizedBox(height: 18),
          Card(
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  leading: const Icon(Icons.info_outline),
                  title: const Text('About'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/about'),
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/privacy'),
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Terms of Use'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/terms'),
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  leading: const Icon(Icons.person_remove_outlined),
                  title: const Text('Account deletion'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/account-deletion'),
                ),
              ],
            ),
          ),
          if (user != null) ...[
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                subtitle: const Text('Local games remain available offline.'),
                trailing: OutlinedButton(
                  onPressed: auth.busy
                      ? null
                      : () async {
                          await ref
                              .read(authControllerProvider.notifier)
                              .logout();
                          if (context.mounted) context.go('/');
                        },
                  child: const Text('Sign out'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            AsyncMessage(error: auth.error, notice: auth.notice),
            if (auth.error != null || auth.notice != null)
              const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delete account',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Permanently remove your sign-in and recovery information. '
                      'Waiting matches are cancelled, active matches are resigned, '
                      'your Social profile, relationships, challenges, and player '
                      'stats are removed, and retained match history is anonymized.',
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      key: const Key('delete-account'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: auth.busy
                          ? null
                          : () => _confirmAccountDeletion(context, ref),
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: const Text('Delete account'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmAccountDeletion(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(dialogContext).colorScheme.error,
        ),
        title: const Text('Delete this account permanently?'),
        content: const Text(
          'This cannot be undone. Your online sign-in will stop working and '
          'any active match will count as a resignation. Local games are not '
          'affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            key: const Key('confirm-delete-account'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    final deleted = await ref
        .read(authControllerProvider.notifier)
        .deleteAccount();
    if (deleted && context.mounted) context.go('/');
  }
}

/// Kept for source compatibility while `/profile` remains a legacy route.
@Deprecated('Use PlayerScreen instead.')
class ProfileScreen extends PlayerScreen {
  const ProfileScreen({super.key});
}
