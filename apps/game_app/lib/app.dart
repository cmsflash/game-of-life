import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/notifications/presentation/turn_notification_effects.dart';
import 'providers.dart';
import 'router.dart';

class GameOfLifeApp extends ConsumerStatefulWidget {
  const GameOfLifeApp({super.key});

  @override
  ConsumerState<GameOfLifeApp> createState() => _GameOfLifeAppState();
}

class _GameOfLifeAppState extends ConsumerState<GameOfLifeApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    ref.watch(authControllerProvider);
    final notifications = ref.read(turnNotificationControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentAuth = ref.read(authControllerProvider);
      final currentStatus = currentAuth.status;
      final social = ref.read(socialControllerProvider.notifier);
      final stats = ref.read(playerStatsControllerProvider.notifier);
      final accountId = currentAuth.user?.id;
      if (currentStatus == AuthStatus.signedIn && accountId != null) {
        social.connectAccount(accountId);
        stats.connectAccount(accountId);
      } else if (currentStatus != AuthStatus.loading) {
        social.disconnectAccount();
        stats.disconnectAccount();
      }
      unawaited(
        notifications.initialize().then((_) async {
          final latestAuth = ref.read(authControllerProvider);
          if (latestAuth.status == AuthStatus.loading) return;
          await notifications.setAccount(
            latestAuth.status == AuthStatus.signedIn
                ? latestAuth.user?.id
                : null,
          );
        }),
      );
    });
    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildLifeTheme(Brightness.light),
      darkTheme: buildLifeTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      scaffoldMessengerKey: _messengerKey,
      routerConfig: router,
      builder: (context, child) => TurnNotificationEffects(
        router: router,
        messengerKey: _messengerKey,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
