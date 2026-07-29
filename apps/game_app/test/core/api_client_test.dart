import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('sends bearer token and decodes successful JSON', () async {
    final store = MemorySessionStore()
      ..session = const StoredSession(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      );
    final httpClient = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.url.path, '/v1/me');
      return http.Response(
        jsonEncode({'userId': 'u1', 'username': 'alice'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = ApiClient(
      sessionStore: store,
      httpClient: httpClient,
      baseUrl: 'https://api.example.test',
    );

    final response = await api.get('/v1/me');
    expect(response.data['username'], 'alice');
  });

  test('turns the standard error envelope into ApiException', () async {
    final api = ApiClient(
      sessionStore: MemorySessionStore(),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'CELL_OCCUPIED',
              'message': 'Choose an empty cell.',
              'requestId': 'request-1',
            },
          }),
          422,
        ),
      ),
      baseUrl: 'https://api.example.test',
    );

    expect(
      () => api.post('/v1/matches/m1/moves', body: {}),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'CELL_OCCUPIED')
            .having((error) => error.requestId, 'requestId', 'request-1'),
      ),
    );
  });

  test('clears and announces an expired session that cannot refresh', () async {
    final store = MemorySessionStore()
      ..session = const StoredSession(
        accessToken: 'expired',
        refreshToken: null,
      );
    final api = ApiClient(
      sessionStore: store,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'unauthorized', 'message': 'Sign in again.'},
          }),
          401,
        ),
      ),
      baseUrl: 'https://api.example.test',
    );
    final expired = expectLater(api.sessionExpired, emits(null));

    await expectLater(api.get('/v1/me'), throwsA(isA<ApiException>()));
    await expired;
    expect(await store.readSession(), isNull);
  });

  test('maps request timeouts to a stable user-facing API error', () async {
    final api = ApiClient(
      sessionStore: MemorySessionStore(),
      httpClient: MockClient(
        (_) => Future<http.Response>.delayed(
          const Duration(milliseconds: 20),
          () => http.Response('{}', 200),
        ),
      ),
      baseUrl: 'https://api.example.test',
      requestTimeout: Duration.zero,
    );

    await expectLater(
      api.get('/v1/health', authenticated: false),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'requestTimeout')
            .having((error) => error.statusCode, 'statusCode', 0),
      ),
    );
  });

  test(
    'maps client transport failures to a stable user-facing API error',
    () async {
      final api = ApiClient(
        sessionStore: MemorySessionStore(),
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection failed'),
        ),
        baseUrl: 'https://api.example.test',
      );

      await expectLater(
        api.get('/v1/health', authenticated: false),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'networkUnavailable',
          ),
        ),
      );
    },
  );
}
