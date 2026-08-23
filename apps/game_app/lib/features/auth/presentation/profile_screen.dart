import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../../../shared/async_message.dart';
import '../../../shared/page_frame.dart';
import '../../../shared/player_avatar.dart';
import '../../notifications/presentation/turn_notification_preference_card.dart';
import '../../stats/presentation/player_metrics_panel.dart';
import '../data/profile_avatar.dart';
import 'auth_controller.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  var _pickingAvatar = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.status == AuthStatus.signedIn ? auth.user : null;
    return PageFrame(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            eyebrow: 'Settings',
            title: user == null
                ? 'Make it your own'
                : 'Your Game of Life account',
            description: user == null
                ? 'Sign in for online play, or learn more about the game and how your data is handled.'
                : 'Manage the account and preferences that travel with you between mobile, web, and desktop.',
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
                      onPressed: () => context.go('/login?returnTo=/settings'),
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
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            PlayerAvatar(
                              key: const Key('settings-avatar'),
                              displayName: user.displayName,
                              avatarUrl: user.avatarUrl,
                              avatarVersion: user.avatarVersion,
                              radius: 42,
                            ),
                            if (auth.avatarBusy)
                              const SizedBox.square(
                                dimension: 84,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              ),
                          ],
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
                              if (user.publicUsername != null) ...[
                                const SizedBox(height: 2),
                                Text('@${user.publicUsername}'),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            key: const Key('choose-profile-picture'),
                            onPressed:
                                _pickingAvatar || auth.avatarBusy || auth.busy
                                ? null
                                : _chooseAvatar,
                            icon: _pickingAvatar
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                            label: Text(
                              user.avatarUrl == null
                                  ? 'Choose picture'
                                  : 'Change picture',
                            ),
                          ),
                          if (user.avatarUrl != null)
                            OutlinedButton.icon(
                              key: const Key('remove-profile-picture'),
                              onPressed: auth.avatarBusy || auth.busy
                                  ? null
                                  : () => ref
                                        .read(authControllerProvider.notifier)
                                        .removeAvatar(),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Remove'),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('JPEG, PNG, or WebP · Maximum 3 MB'),
                    ),
                    const SizedBox(height: 4),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Display names and pictures are public in player search, Social, and online matches. A public username, when shown above, is also searchable and shown in Social.',
                      ),
                    ),
                    if (auth.avatarError != null ||
                        auth.avatarNotice != null) ...[
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AsyncMessage(
                          error: auth.avatarError,
                          notice: auth.avatarNotice,
                        ),
                      ),
                      if (auth.avatarError != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const Key('retry-profile-picture'),
                            onPressed:
                                _pickingAvatar || auth.avatarBusy || auth.busy
                                ? null
                                : _chooseAvatar,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Try another picture'),
                          ),
                        ),
                      ],
                    ],
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
                        title: const Text('Member since'),
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

  Future<void> _chooseAvatar() async {
    if (_pickingAvatar) return;
    final accountId = ref.read(authControllerProvider).user?.id;
    if (accountId == null) return;
    setState(() => _pickingAvatar = true);
    try {
      final upload = await ref.read(profileAvatarPickerProvider).pick();
      if (!mounted || upload == null) return;
      final auth = ref.read(authControllerProvider);
      if (auth.status != AuthStatus.signedIn || auth.user?.id != accountId) {
        return;
      }
      await ref.read(authControllerProvider.notifier).uploadAvatar(upload);
    } on ProfileAvatarPickException catch (error) {
      if (!mounted || ref.read(authControllerProvider).user?.id != accountId) {
        return;
      }
      ref
          .read(authControllerProvider.notifier)
          .reportAvatarError(error.message);
    } catch (_) {
      if (!mounted || ref.read(authControllerProvider).user?.id != accountId) {
        return;
      }
      ref
          .read(authControllerProvider.notifier)
          .reportAvatarError(
            'The picture could not be opened. Choose another and try again.',
          );
    } finally {
      if (mounted) setState(() => _pickingAvatar = false);
    }
  }
}

/// Kept for source compatibility while `/player` remains a legacy route.
@Deprecated('Use SettingsScreen instead.')
class PlayerScreen extends SettingsScreen {
  const PlayerScreen({super.key});
}

/// Kept for source compatibility while `/profile` remains a legacy route.
@Deprecated('Use SettingsScreen instead.')
class ProfileScreen extends SettingsScreen {
  const ProfileScreen({super.key});
}
