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
    final canAct = !state.loading && !state.busy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('turn-notifications-status'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                state.enabled
                    ? Icons.notifications_active
                    : Icons.notifications_outlined,
              ),
              title: const Text('Turn alerts'),
              subtitle: Text(_subtitle(state)),
            ),
            if (state.busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: LinearProgressIndicator(),
              ),
            if (state.permission == TurnNotificationPermission.prompt &&
                state.configured &&
                state.supported)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('allow-turn-notifications'),
                    onPressed: canAct ? controller.allow : null,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Allow notifications'),
                  ),
                ),
              ),
            if (state.permission == TurnNotificationPermission.denied &&
                state.configured &&
                state.supported)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('notification-settings-help'),
                    onPressed: canAct
                        ? () => _showSettingsHelp(context, controller)
                        : null,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Notification settings'),
                  ),
                ),
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
      return 'Blocked by your browser or device settings.';
    }
    if (state.permission == TurnNotificationPermission.prompt) {
      return 'Allow this browser or device to receive turn alerts.';
    }
    return state.enabled
        ? 'Active for this browser or device.'
        : 'Permission is allowed; reconnecting this device.';
  }

  Future<void> _showSettingsHelp(
    BuildContext context,
    TurnNotificationController controller,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow notifications in settings'),
        content: const Text(
          'Open this app or site in your browser or device notification '
          'settings, choose Allow, then return here. Turn alerts connect '
          'automatically after permission is granted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const Key('check-notification-permission'),
            onPressed: () {
              Navigator.pop(dialogContext);
              controller.refresh();
            },
            child: const Text('Check again'),
          ),
        ],
      ),
    );
  }
}
