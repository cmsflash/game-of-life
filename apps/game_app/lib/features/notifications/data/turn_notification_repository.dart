import '../../../core/api_client.dart';
import '../domain/turn_notifications.dart';

abstract interface class TurnNotificationRepository {
  Future<TurnNotificationConfiguration> configuration();

  Future<List<TurnNotificationSubscription>> listSubscriptions();

  Future<TurnNotificationSubscription> upsertSubscription(
    String installationId,
    TurnNotificationEndpoint endpoint, {
    String? locale,
    String? timeZone,
  });

  Future<void> deleteSubscription(String installationId);
}

class ApiTurnNotificationRepository implements TurnNotificationRepository {
  const ApiTurnNotificationRepository(this._api);

  final ApiClient _api;

  @override
  Future<TurnNotificationConfiguration> configuration() async {
    final response = await _api.get(
      '/v1/notifications/config',
      authenticated: false,
    );
    return TurnNotificationConfiguration.fromJson(
      response.data as Map<String, dynamic>? ?? const {},
    );
  }

  @override
  Future<List<TurnNotificationSubscription>> listSubscriptions() async {
    final response = await _api.get('/v1/notifications/subscriptions');
    final json = response.data as Map<String, dynamic>? ?? const {};
    final items = json['items'] as List? ?? const [];
    return [
      for (final item in items)
        if (item is Map<String, dynamic>)
          TurnNotificationSubscription.fromJson(item),
    ];
  }

  @override
  Future<TurnNotificationSubscription> upsertSubscription(
    String installationId,
    TurnNotificationEndpoint endpoint, {
    String? locale,
    String? timeZone,
  }) async {
    final response = await _api.post(
      '/v1/notifications/subscriptions',
      idempotent: true,
      body: endpoint.toJson(
        installationId: installationId,
        locale: locale,
        timeZone: timeZone,
      ),
    );
    return TurnNotificationSubscription.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<void> deleteSubscription(String installationId) => _api.delete(
    '/v1/notifications/subscriptions/${Uri.encodeComponent(installationId)}',
  );
}
