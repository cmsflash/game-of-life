import '../domain/turn_notifications.dart';

abstract interface class TurnNotificationGateway {
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  );

  Future<TurnNotificationCapability> capability();

  Future<TurnNotificationEndpoint?> currentEndpoint();

  Future<TurnNotificationEndpoint?> requestEndpoint();

  Future<void> deactivate();

  Stream<TurnNotificationEndpoint> get endpointChanges;

  Stream<TurnNotificationMessage> get foregroundMessages;

  Stream<TurnNotificationMessage> get openedMessages;

  Future<void> dispose();
}
