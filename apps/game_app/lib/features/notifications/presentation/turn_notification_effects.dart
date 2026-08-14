import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers.dart';
import '../domain/turn_notifications.dart';

class TurnNotificationEffects extends ConsumerStatefulWidget {
  const TurnNotificationEffects({
    super.key,
    required this.router,
    required this.messengerKey,
    required this.child,
  });

  final GoRouter router;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget child;

  @override
  ConsumerState<TurnNotificationEffects> createState() =>
      _TurnNotificationEffectsState();
}

class _TurnNotificationEffectsState
    extends ConsumerState<TurnNotificationEffects>
    with WidgetsBindingObserver {
  StreamSubscription<TurnNotificationMessage>? _foregroundSubscription;
  StreamSubscription<TurnNotificationMessage>? _openedSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final controller = ref.read(turnNotificationControllerProvider.notifier);
    _foregroundSubscription = controller.foregroundMessages.listen(
      _showForegroundMessage,
    );
    _openedSubscription = controller.openedMessages.listen(_openMessage);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(turnNotificationControllerProvider.notifier).refresh(),
      );
    }
  }

  void _showForegroundMessage(TurnNotificationMessage message) {
    final path = message.matchPath;
    final messenger = widget.messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message.body ?? message.title ?? 'It is your turn to play.',
          ),
          action: path == null
              ? null
              : SnackBarAction(
                  label: 'Open',
                  onPressed: () => widget.router.go(path),
                ),
        ),
      );
  }

  void _openMessage(TurnNotificationMessage message) {
    final path = message.matchPath;
    if (path != null) widget.router.go(path);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _foregroundSubscription?.cancel();
    _openedSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
