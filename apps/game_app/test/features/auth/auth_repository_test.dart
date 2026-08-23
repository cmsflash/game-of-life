import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/auth_repository.dart';
import 'package:game_of_life/features/auth/data/profile_avatar.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('restore refreshes a cached user with the canonical avatar', () async {
    final store = MemorySessionStore()
      ..session = const StoredSession(
        accessToken: 'access-token',
        refreshToken: null,
        userJson: {
          'userId': 'user-1',
          'username': 'alice',
          'displayName': 'Alice',
        },
      );
    final repository = ApiAuthRepository(
      api: ApiClient(
        sessionStore: store,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'userId': 'user-1',
              'username': 'alice',
              'displayName': 'Alice',
              'publicUsername': 'alice',
              'avatarUrl':
                  'https://api.example.test/v1/players/user-1/avatar?v=5',
              'avatarVersion': 5,
            }),
            200,
          ),
        ),
        baseUrl: 'https://api.example.test',
      ),
      sessionStore: store,
      browserLauncher: _FakeBrowser(),
    );

    final user = await repository.restore();

    expect(user?.avatarVersion, 5);
    expect(user?.publicUsername, 'alice');
    expect((await store.readSession())?.userJson?['avatarVersion'], 5);
    expect((await store.readSession())?.userJson?['publicUsername'], 'alice');
  });

  test(
    'registration follows the confirmation-first backend contract',
    () async {
      final store = MemorySessionStore();
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/auth/register');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, {
          'username': 'alice',
          'email': 'alice@example.com',
          'password': 'correct-horse-1',
          'displayName': 'Alice',
        });
        return http.Response(
          jsonEncode({
            'userId': 'user-1',
            'username': 'alice',
            'confirmationRequired': true,
            'debugConfirmationCode': '123456',
          }),
          201,
        );
      });
      final repository = ApiAuthRepository(
        api: ApiClient(
          sessionStore: store,
          httpClient: client,
          baseUrl: 'https://api.example.test',
        ),
        sessionStore: store,
        browserLauncher: _FakeBrowser(),
      );

      final result = await repository.register(
        username: 'alice',
        email: 'alice@example.com',
        password: 'correct-horse-1',
        displayName: 'Alice',
      );

      expect(result.confirmationRequired, isTrue);
      expect(result.debugConfirmationCode, '123456');
      expect(await store.readSession(), isNull);
    },
  );

  test(
    'Google login opens the backend redirect without contacting Google',
    () async {
      final browser = _FakeBrowser();
      final store = MemorySessionStore();
      final repository = ApiAuthRepository(
        api: ApiClient(
          sessionStore: store,
          httpClient: MockClient((_) async => http.Response('', 500)),
          baseUrl: 'https://api.example.test',
        ),
        sessionStore: store,
        browserLauncher: browser,
      );

      await repository.beginGoogleSignIn();

      expect(browser.opened?.path, '/v1/auth/google/start');
      expect(browser.opened?.queryParameters['returnTo'], isNotEmpty);
    },
  );

  test(
    'account deletion clears the local session after the API confirms',
    () async {
      final store = MemorySessionStore()
        ..session = const StoredSession(
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
        );
      final repository = ApiAuthRepository(
        api: ApiClient(
          sessionStore: store,
          httpClient: MockClient((request) async {
            expect(request.method, 'DELETE');
            expect(request.url.path, '/v1/me');
            expect(request.headers['authorization'], 'Bearer access-token');
            return http.Response(
              jsonEncode({'message': 'Account deleted.'}),
              200,
            );
          }),
          baseUrl: 'https://api.example.test',
        ),
        sessionStore: store,
        browserLauncher: _FakeBrowser(),
      );

      await repository.deleteAccount();

      expect(await store.readSession(), isNull);
    },
  );

  test(
    'failed account deletion keeps the session so the player can retry',
    () async {
      final store = MemorySessionStore()
        ..session = const StoredSession(
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
        );
      final repository = ApiAuthRepository(
        api: ApiClient(
          sessionStore: store,
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {
                  'code': 'temporarilyUnavailable',
                  'message': 'Try again shortly.',
                },
              }),
              503,
            ),
          ),
          baseUrl: 'https://api.example.test',
        ),
        sessionStore: store,
        browserLauncher: _FakeBrowser(),
      );

      await expectLater(
        repository.deleteAccount(),
        throwsA(isA<ApiException>()),
      );

      expect(await store.readSession(), isNotNull);
    },
  );

  test(
    'avatar upload uses authenticated multipart and parses version',
    () async {
      final store = MemorySessionStore()
        ..session = const StoredSession(
          accessToken: 'access-token',
          refreshToken: null,
          userJson: {
            'userId': 'user-1',
            'username': 'alice',
            'displayName': 'Alice',
          },
        );
      final repository = ApiAuthRepository(
        api: ApiClient(
          sessionStore: store,
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/v1/me/avatar');
            expect(request.headers['authorization'], 'Bearer access-token');
            expect(
              request.headers['content-type'],
              startsWith('multipart/form-data'),
            );
            expect(request.body, contains('name="file"'));
            expect(request.body, contains('filename="profile.jpg"'));
            expect(request.body, contains('content-type: image/jpeg'));
            return http.Response(
              jsonEncode({
                'avatarUrl':
                    'https://api.example.test/v1/players/user-1/avatar?v=6',
                'avatarVersion': 6,
              }),
              200,
            );
          }),
          baseUrl: 'https://api.example.test',
        ),
        sessionStore: store,
        browserLauncher: _FakeBrowser(),
      );

      final result = await repository.uploadAvatar(
        ProfileAvatarUpload(
          bytes: utf8.encode('avatar'),
          filename: 'profile.jpg',
          contentType: 'image/jpeg',
        ),
      );

      expect(result.version, 6);
      expect(result.url, endsWith('avatar?v=6'));
    },
  );

  test('avatar removal parses the authoritative null document', () async {
    final store = MemorySessionStore()
      ..session = const StoredSession(
        accessToken: 'access-token',
        refreshToken: null,
      );
    final repository = ApiAuthRepository(
      api: ApiClient(
        sessionStore: store,
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/v1/me/avatar');
          return http.Response(
            jsonEncode({'avatarUrl': null, 'avatarVersion': 7}),
            200,
          );
        }),
        baseUrl: 'https://api.example.test',
      ),
      sessionStore: store,
      browserLauncher: _FakeBrowser(),
    );

    final result = await repository.removeAvatar();

    expect(result.url, isNull);
    expect(result.version, 7);
  });
}

class _FakeBrowser implements BrowserLauncher {
  Uri? opened;

  @override
  Future<bool> open(Uri uri) async {
    opened = uri;
    return true;
  }
}
