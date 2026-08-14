import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/notifications/presentation/turn_notification_controller.dart';

import '../../fakes.dart';

void main() {
  test('automatically connects a granted installation on sign-in', () async {
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

    await controller.setAccount('player-a');

    expect(controller.state.enabled, isTrue);
    expect(repository.upserts.single.token, 'device-token');
    expect(gateway.requestCalls, 0);
  });

  test(
    'granted permission recreates a missing provider endpoint automatically',
    () async {
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway()
        ..capabilityValue = const TurnNotificationCapability(
          configured: true,
          supported: true,
          permission: TurnNotificationPermission.granted,
        )
        ..requestedEndpoint = const TurnNotificationEndpoint.firebase(
          platform: 'ios',
          token: 'recreated-token',
        );
      final controller = TurnNotificationController(
        repository: repository,
        gateway: gateway,
        sessionStore: MemorySessionStore(),
      );
      addTearDown(controller.dispose);

      await controller.setAccount('player-a');

      expect(gateway.requestCalls, 1);
      expect(repository.upserts.single.token, 'recreated-token');
      expect(controller.state.enabled, isTrue);
    },
  );

  test('a failed endpoint refresh is not shown as active', () async {
    final repository = FakeTurnNotificationRepository()
      ..subscriptions.add(
        const TurnNotificationSubscription(
          installationId: 'test-device',
          platform: 'web',
          provider: 'webPush',
        ),
      )
      ..upsertError = StateError('offline');
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.webPush(
        endpoint: 'https://push.example.test/subscription',
        p256dh: 'key',
        auth: 'secret',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setAccount('player-a');

    expect(controller.state.enabled, isFalse);
    expect(controller.state.error, contains('could not be updated'));
  });

  test('permission prompt waits for the explicit allow action', () async {
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.prompt,
      )
      ..capabilityAfterRequest = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'ios',
        token: 'phone-token',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setAccount('player-a');

    expect(controller.state.permission, TurnNotificationPermission.prompt);
    expect(controller.state.enabled, isFalse);
    expect(gateway.requestCalls, 0);
    expect(repository.upserts, isEmpty);

    await controller.allow();

    expect(gateway.requestCalls, 1);
    expect(repository.upserts, hasLength(1));
    expect(controller.state.enabled, isTrue);
    expect(controller.state.permission, TurnNotificationPermission.granted);
  });

  test(
    'sign-out removes the server row and deactivates the local endpoint',
    () async {
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway()
        ..capabilityValue = const TurnNotificationCapability(
          configured: true,
          supported: true,
          permission: TurnNotificationPermission.prompt,
        );
      final store = MemorySessionStore()..id = 'browser-1';
      final controller = TurnNotificationController(
        repository: repository,
        gateway: gateway,
        sessionStore: store,
      );
      addTearDown(controller.dispose);

      await controller.setAccount('player-a');
      await controller.disconnectAccount();

      expect(repository.deletedInstallationIds, ['browser-1']);
      expect(gateway.deactivateCalls, 1);
    },
  );

  test(
    'session expiry still deactivates locally when server cleanup fails',
    () async {
      final repository = FakeTurnNotificationRepository();
      final gateway = FakeTurnNotificationGateway()
        ..capabilityValue = const TurnNotificationCapability(
          configured: true,
          supported: true,
          permission: TurnNotificationPermission.prompt,
        );
      final controller = TurnNotificationController(
        repository: repository,
        gateway: gateway,
        sessionStore: MemorySessionStore(),
      );
      addTearDown(controller.dispose);

      await controller.setAccount('player-a');
      repository.error = StateError('offline');
      await controller.disconnectAccount();

      expect(gateway.deactivateCalls, 1);

      await controller.setAccount('player-a');
      await controller.setAccount(null);

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

    await controller.setAccount(null);
    await controller.setAccount(null);

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

    await controller.setAccount('player-a');

    expect(repository.deletedInstallationIds, ['test-device']);
    expect(controller.state.enabled, isFalse);
  });

  test('denied permission never reprompts and removes a stale row', () async {
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
        permission: TurnNotificationPermission.denied,
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setAccount('player-a');

    expect(gateway.requestCalls, 0);
    expect(repository.deletedInstallationIds, ['test-device']);
    expect(gateway.deactivateCalls, 1);
    expect(controller.state.enabled, isFalse);
    expect(controller.state.permission, TurnNotificationPermission.denied);
  });

  test('unsupported devices remove a stale server subscription', () async {
    final repository = FakeTurnNotificationRepository()
      ..subscriptions.add(
        const TurnNotificationSubscription(
          installationId: 'test-device',
          platform: 'web',
          provider: 'webPush',
        ),
      );
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability.unsupported();
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setAccount('player-a');

    expect(repository.deletedInstallationIds, ['test-device']);
    expect(gateway.deactivateCalls, 1);
    expect(controller.state.enabled, isFalse);
    expect(controller.state.supported, isFalse);
  });

  test('a rotated endpoint is maintained automatically', () async {
    final repository = FakeTurnNotificationRepository();
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'android',
        token: 'old-token',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    await controller.setAccount('player-a');
    gateway.endpointController.add(
      const TurnNotificationEndpoint.firebase(
        platform: 'android',
        token: 'rotated-token',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(repository.upserts.map((endpoint) => endpoint.token), [
      'old-token',
      'rotated-token',
    ]);
    expect(controller.state.enabled, isTrue);
  });

  test('logout invalidates a delayed reconcile before cleanup', () async {
    final gate = Completer<void>();
    final repository = FakeTurnNotificationRepository()
      ..listSubscriptionsGate = gate;
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'ios',
        token: 'late-token',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    final reconcile = controller.setAccount('player-a');
    while (repository.listSubscriptionsCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final cleanup = controller.disconnectAccount();
    gate.complete();
    await reconcile;
    await cleanup;

    expect(repository.upserts, isEmpty);
    expect(repository.deletedInstallationIds, ['test-device']);
    expect(gateway.deactivateCalls, 1);
    expect(controller.state.enabled, isFalse);
  });

  test('logout cleanup runs after an already-started upsert', () async {
    final gate = Completer<void>();
    final repository = FakeTurnNotificationRepository()..upsertGate = gate;
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'android',
        token: 'in-flight-token',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    final reconcile = controller.setAccount('player-a');
    while (repository.upsertCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final cleanup = controller.disconnectAccount();
    gate.complete();
    await reconcile;
    await cleanup;

    expect(repository.upserts, hasLength(1));
    expect(repository.subscriptions, isEmpty);
    expect(repository.deletedInstallationIds, ['test-device']);
    expect(controller.state.enabled, isFalse);
  });

  test('account switch ignores the previous account reconcile', () async {
    final gate = Completer<void>();
    final repository = FakeTurnNotificationRepository()
      ..listSubscriptionsGate = gate;
    final gateway = FakeTurnNotificationGateway()
      ..capabilityValue = const TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: TurnNotificationPermission.granted,
      )
      ..endpoint = const TurnNotificationEndpoint.firebase(
        platform: 'android',
        token: 'current-token',
      );
    final controller = TurnNotificationController(
      repository: repository,
      gateway: gateway,
      sessionStore: MemorySessionStore(),
    );
    addTearDown(controller.dispose);

    final first = controller.setAccount('player-a');
    while (repository.listSubscriptionsCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = controller.setAccount('player-b');
    gate.complete();
    await first;
    await second;

    expect(repository.listSubscriptionsCalls, 2);
    expect(repository.upserts, hasLength(1));
    expect(controller.state.enabled, isTrue);
  });

  test('accepts only online-match paths from notification data', () {
    expect(
      const TurnNotificationMessage(matchId: 'match/one').matchPath,
      '/online/match/match%2Fone',
    );
    expect(const TurnNotificationMessage(path: '/profile').matchPath, isNull);
  });
}
