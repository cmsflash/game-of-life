import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../../../shared/page_frame.dart';
import 'auth_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.user;
    if (auth.status != AuthStatus.signedIn || user == null) {
      return PageFrame(
        maxWidth: 620,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Icon(Icons.person_outline, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Sign in to view your profile',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => context.go('/login?returnTo=/profile'),
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PageFrame(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'Player profile',
            title: 'Your corner of Life',
            description:
                'Your account travels with you between mobile, web, and desktop.',
          ),
          const SizedBox(height: 28),
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
                          user.displayName.substring(0, 1).toUpperCase(),
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
                      if (user.rating != null)
                        Chip(
                          avatar: const Icon(Icons.trending_up, size: 18),
                          label: Text('${user.rating} rating'),
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
        ],
      ),
    );
  }
}
