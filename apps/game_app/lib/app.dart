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
    final authStatus = ref.watch(
      authControllerProvider.select((state) => state.status),
    );
    final notifications = ref.read(turnNotificationControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        notifications.initialize().then((_) async {
          if (authStatus == AuthStatus.loading) return;
          await notifications.setSignedIn(authStatus == AuthStatus.signedIn);
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
