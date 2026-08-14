import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:game_of_life/features/notifications/data/turn_notification_repository.dart';
import 'package:game_of_life/features/notifications/domain/turn_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('loads public provider configuration without authentication', () async {
    http.Request? recorded;
    final repository = _repository((request) async {
      recorded = request;
      return http.Response(
        jsonEncode({
          'providers': ['webPush', 'firebase'],
          'webPushVapidPublicKey': 'public-key',
        }),
        200,
      );
    });

    final configuration = await repository.configuration();

    expect(recorded?.url.path, '/v1/notifications/config');
    expect(recorded?.headers['authorization'], isNull);
    expect(configuration.supports('webPush'), isTrue);
    expect(configuration.supports('firebase'), isTrue);
    expect(configuration.webPushVapidPublicKey, 'public-key');
  });

  test(
    'registers a standard Web Push subscription without leaking it',
    () async {
      http.Request? recorded;
      final repository = _repository((request) async {
        recorded = request;
        return http.Response(
          jsonEncode({
            'installationId': 'browser-1',
            'platform': 'web',
            'provider': 'webPush',
            'locale': 'en-US',
            'timeZone': 'America/Los_Angeles',
            'createdAt': '2026-08-14T00:00:00Z',
            'updatedAt': '2026-08-14T00:00:00Z',
          }),
          200,
        );
      });

      final subscription = await repository.upsertSubscription(
        'browser-1',
        const TurnNotificationEndpoint.webPush(
          endpoint: 'https://push.example.test/subscription',
          p256dh: 'public-key',
          auth: 'auth-secret',
        ),
        locale: 'en-US',
        timeZone: 'America/Los_Angeles',
      );

      expect(recorded?.method, 'POST');
      expect(recorded?.url.path, '/v1/notifications/subscriptions');
      final body = jsonDecode(recorded!.body) as Map<String, dynamic>;
      expect(body, {
        'installationId': 'browser-1',
        'platform': 'web',
        'provider': 'webPush',
        'endpoint': 'https://push.example.test/subscription',
        'p256dh': 'public-key',
        'auth': 'auth-secret',
        'locale': 'en-US',
        'timeZone': 'America/Los_Angeles',
      });
      expect(subscription.installationId, 'browser-1');
    },
  );

  test(
    'lists token-free subscriptions and deletes the exact installation',
    () async {
      final requests = <http.Request>[];
      final repository = _repository((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'installationId': 'phone/one',
                  'platform': 'ios',
                  'provider': 'firebase',
                  'createdAt': '2026-08-14T00:00:00Z',
                  'updatedAt': '2026-08-14T00:00:00Z',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('', 204);
      });

      final subscriptions = await repository.listSubscriptions();
      await repository.deleteSubscription('phone/one');

      expect(subscriptions.single.provider, 'firebase');
      expect(requests.last.method, 'DELETE');
      expect(
        requests.last.url.path,
        '/v1/notifications/subscriptions/phone%2Fone',
      );
    },
  );
}

ApiTurnNotificationRepository _repository(
  Future<http.Response> Function(http.Request) handler,
) {
  final store = MemorySessionStore()
    ..session = const StoredSession(
      accessToken: 'access-token',
      refreshToken: null,
    );
  return ApiTurnNotificationRepository(
    ApiClient(
      sessionStore: store,
      httpClient: MockClient(handler),
      baseUrl: 'https://api.example.test',
    ),
  );
}
