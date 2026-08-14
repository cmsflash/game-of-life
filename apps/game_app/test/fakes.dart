import 'dart:async';

import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/data/auth_repository.dart';
import 'package:game_of_life/features/notifications/data/turn_notification_repository.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:game_of_life/features/notifications/platform/turn_notification_gateway.dart';

class FakeAuthRepository implements AuthRepository {
  AppUser? current;
  Object? error;
  var loginCalls = 0;

  @override
  Future<AppUser?> restore() async => current;

  @override
  Future<AppUser> login({
    required String username,
    required String password,
  }) async {
    loginCalls++;
    if (error != null) throw error!;
    return current = AppUser(
      id: 'user-1',
      username: username,
      displayName: username,
    );
  }

  @override
  Future<RegistrationResult> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async =>
      RegistrationResult(username: username, confirmationRequired: true);

  @override
  Future<void> beginGoogleSignIn() async {}

  @override
  Future<AppUser> exchangeGoogleCode(String code) async =>
      current = const AppUser(
        id: 'google-1',
        username: 'google_player',
        displayName: 'Google Player',
      );

  @override
  Future<void> confirm({
    required String username,
    required String code,
  }) async {}

  @override
  Future<String?> forgotPassword(String username) async => null;

  @override
  Future<String?> resendConfirmation(String username) async => null;

  @override
  Future<void> logout() async => current = null;

  @override
  Future<void> deleteAccount() async {
    if (error != null) throw error!;
    current = null;
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String code,
    required String newPassword,
  }) async {}
}

class FakeTurnNotificationRepository implements TurnNotificationRepository {
  TurnNotificationConfiguration configurationValue =
      const TurnNotificationConfiguration(
        providers: {'webPush', 'firebase'},
        webPushVapidPublicKey: 'public-vapid-key',
      );
  final subscriptions = <TurnNotificationSubscription>[];
  final upserts = <TurnNotificationEndpoint>[];
  final deletedInstallationIds = <String>[];
  Object? error;

  @override
  Future<TurnNotificationConfiguration> configuration() async {
    if (error != null) throw error!;
    return configurationValue;
  }

  @override
  Future<List<TurnNotificationSubscription>> listSubscriptions() async {
    if (error != null) throw error!;
    return List.of(subscriptions);
  }

  @override
  Future<TurnNotificationSubscription> upsertSubscription(
    String installationId,
    TurnNotificationEndpoint endpoint, {
    String? locale,
    String? timeZone,
  }) async {
    if (error != null) throw error!;
    upserts.add(endpoint);
    subscriptions.removeWhere(
      (subscription) => subscription.installationId == installationId,
    );
    final subscription = TurnNotificationSubscription(
      installationId: installationId,
      platform: endpoint.platform,
      provider: endpoint.provider,
      locale: locale,
      timeZone: timeZone,
    );
    subscriptions.add(subscription);
    return subscription;
  }

  @override
  Future<void> deleteSubscription(String installationId) async {
    deletedInstallationIds.add(installationId);
    if (error != null) throw error!;
    subscriptions.removeWhere(
      (subscription) => subscription.installationId == installationId,
    );
  }
}

class FakeTurnNotificationGateway implements TurnNotificationGateway {
  TurnNotificationCapability capabilityValue =
      const TurnNotificationCapability.notConfigured();
  TurnNotificationEndpoint? endpoint;
  var initializeCalls = 0;
  var requestCalls = 0;
  var deactivateCalls = 0;

  final endpointController =
      StreamController<TurnNotificationEndpoint>.broadcast();
  final foregroundController =
      StreamController<TurnNotificationMessage>.broadcast();
  final openedController =
      StreamController<TurnNotificationMessage>.broadcast();

  @override
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  ) async {
    initializeCalls++;
    return capabilityValue;
  }

  @override
  Future<TurnNotificationCapability> capability() async => capabilityValue;

  @override
  Future<TurnNotificationEndpoint?> currentEndpoint() async => endpoint;

  @override
  Future<TurnNotificationEndpoint?> requestEndpoint() async {
    requestCalls++;
    return endpoint;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls++;
    endpoint = null;
  }

  @override
  Stream<TurnNotificationEndpoint> get endpointChanges =>
      endpointController.stream;

  @override
  Stream<TurnNotificationMessage> get foregroundMessages =>
      foregroundController.stream;

  @override
  Stream<TurnNotificationMessage> get openedMessages => openedController.stream;

  @override
  Future<void> dispose() async {
    await endpointController.close();
    await foregroundController.close();
    await openedController.close();
  }
}
