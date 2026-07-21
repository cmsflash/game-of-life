import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/auth_repository.dart';
import 'package:game_of_life/features/auth/data/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
}

class _FakeBrowser implements BrowserLauncher {
  Uri? opened;

  @override
  Future<bool> open(Uri uri) async {
    opened = uri;
    return true;
  }
}
