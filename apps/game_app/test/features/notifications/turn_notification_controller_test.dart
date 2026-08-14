import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/notifications/presentation/turn_notification_controller.dart';

import '../../fakes.dart';

void main() {
  test('enables and disables the current installation', () async {
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'android',
        token: 'device-token',
      );
    final store = MemorySessionStore()..id = 'phone-1';
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: store,
    );
    addTearDown(controller.dispose);

    await controller.setSignedIn(true);
    await controller.enable();

    expect(controller.state.enabled, isTrue);
    expect(repository.upserts.single.token, 'device-token');
    expect(gateway.requestCalls, 1);

    await controller.disable();

    expect(controller.state.enabled, isFalse);
    expect(repository.deletedInstallationIds, ['phone-1']);
    expect(gateway.deactivateCalls, 1);
  });

  test(
    'sign-out removes the server row and deactivates the local endpoint',
    () async {
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway();
      final store = MemorySessionStore()..id = 'browser-1';
      final controller = TurnNotificationController(
        repository: repository,
        gateway: gateway,
        sessionStore: store,
      );
      addTearDown(controller.dispose);

      await controller.setSignedIn(true);
      await controller.disconnectAccount();

      expect(repository.deletedInstallationIds, ['browser-1']);
      expect(gateway.deactivateCalls, 1);
    },
  );

  test(
    'session expiry still deactivates locally when server cleanup fails',
    () async {
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway();
      final controller = TurnNotificationController(
        repository: repository,
        gateway: gateway,
        sessionStore: MemorySessionStore(),
      );
      addTearDown(controller.dispose);

      await controller.setSignedIn(true);
      repository.error = StateError('offline');
      await controller.disconnectAccount();

      expect(gateway.deactivateCalls, 1);

      await controller.setSignedIn(true);
      await controller.setSignedIn(false);

      expect(gateway.deactivateCalls, 2);
      expect(controller.state.enabled, isFalse);
    },
  );

  test('signed-out startup removes a leftover local endpoint once', () async {
    final gateway = FakeTurnNotificationGateway();
    final controller = TurnNotificationController(
      repository: FakeTurnNotificationRepository(),
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setSignedIn(false);
    await controller.setSignedIn(false);

    expect(gateway.deactivateCalls, 1);
    expect(controller.state.enabled, isFalse);
  });

  test('logout cleanup runs even before auth-state synchronization', () async {
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway();
    final store = MemorySessionStore()..id = 'quick-logout';
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: store,
    );
    addTearDown(controller.dispose);

    await controller.disconnectAccount();

    expect(repository.deletedInstallationIds, ['quick-logout']);
    expect(gateway.deactivateCalls, 1);
  });

  test('removes a stale server row when the local endpoint is gone', () async {
    final repository = FakeTurnNotificationRepository()
      ..subscriptions.add(
        const TurnNotificationSubscription(
          installationId: 'test-device',
          platform: 'web',
          provider: 'webPush',
        ),
      );
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setSignedIn(true);

    expect(repository.deletedInstallationIds, ['test-device']);
    expect(controller.state.enabled, isFalse);
  });

  test('accepts only online-match paths from notification data', () {
    expect(
      const TurnNotificationMessage(matchId: 'match/one').matchPath,
      '/online/match/match%2Fone',
    );
    expect(const TurnNotificationMessage(path: '/profile').matchPath, isNull);
  });
}
