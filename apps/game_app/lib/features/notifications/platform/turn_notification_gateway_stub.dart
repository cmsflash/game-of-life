import '../domain/turn_notifications.dart';
import 'turn_notification_gateway.dart';

TurnNotificationGateway createTurnNotificationGateway() =>
    _UnsupportedTurnNotificationGateway();

class _UnsupportedTurnNotificationGateway implements TurnNotificationGateway {
  @override
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  ) async => const TurnNotificationCapability.unsupported();

  @override
  Future<TurnNotificationCapability> capability() async =>
      const TurnNotificationCapability.unsupported();

  @override
  Future<TurnNotificationEndpoint?> currentEndpoint() async => null;

  @override
  Future<TurnNotificationEndpoint?> requestEndpoint() async => null;

  @override
  Future<void> deactivate() async {}

  @override
  Stream<TurnNotificationEndpoint> get endpointChanges => const Stream.empty();

  @override
  Stream<TurnNotificationMessage> get foregroundMessages =>
      const Stream.empty();

  @override
  Stream<TurnNotificationMessage> get openedMessages => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
