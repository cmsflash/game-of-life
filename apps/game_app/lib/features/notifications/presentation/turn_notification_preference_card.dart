import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers.dart';
import '../domain/turn_notifications.dart';
import 'turn_notification_controller.dart';

class TurnNotificationPreferenceCard extends ConsumerWidget {
  const TurnNotificationPreferenceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(turnNotificationControllerProvider);
    final controller = ref.read(turnNotificationControllerProvider.notifier);
    final canChange =
        !state.loading &&
        !state.busy &&
        state.configured &&
        state.supported &&
        (state.enabled ||
            state.permission != TurnNotificationPermission.denied);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('turn-notifications-toggle'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Turn notifications'),
              subtitle: Text(_subtitle(state)),
              value: state.enabled,
              onChanged: canChange
                  ? (enabled) =>
                        enabled ? controller.enable() : controller.disable()
                  : null,
            ),
            if (state.busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: LinearProgressIndicator(),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        state.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: state.busy ? null : controller.refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            if (!state.loading && state.configured && state.supported)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  'Alerts are sent when your turn begins, then after 8 hours, '
                  '24 hours, and 72 hours if you still have not moved.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _subtitle(TurnNotificationState state) {
    if (state.loading) return 'Checking this device…';
    if (!state.configured) {
      return 'Notifications are not configured for this app build.';
    }
    if (!state.supported) {
      return 'Notifications are not supported on this browser or device.';
    }
    if (state.permission == TurnNotificationPermission.denied) {
      return state.enabled
          ? 'Blocked by your browser or device. Turn this off or allow notifications in system settings.'
          : 'Blocked by your browser or device settings.';
    }
    return state.enabled
        ? 'On for this browser or device.'
        : 'Know when an online match is waiting for you.';
  }
}
