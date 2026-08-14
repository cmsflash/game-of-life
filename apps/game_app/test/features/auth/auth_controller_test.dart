import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/presentation/auth_controller.dart';

import '../../fakes.dart';

void main() {
  test('restores signed-out state and signs in with password', () async {
    final repository = FakeAuthRepository();
    final controller = AuthController(repository);

    await controller.restore();
    expect(controller.state.status, AuthStatus.signedOut);

    final success = await controller.login('alice', 'correct-horse-1');
    expect(success, isTrue);
    expect(controller.state.status, AuthStatus.signedIn);
    expect(controller.state.user?.username, 'alice');
    expect(repository.loginCalls, 1);
  });

  test('surfaces API messages without signing in', () async {
    final repository = FakeAuthRepository()
      ..error = const ApiException(
        statusCode: 401,
        code: 'INVALID_CREDENTIALS',
        message: 'Username or password is incorrect.',
      );
    final controller = AuthController(repository);
    await controller.restore();

    final success = await controller.login('alice', 'wrong');
    expect(success, isFalse);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.error, 'Username or password is incorrect.');
  });

  test('deletes the account and returns to signed-out state', () async {
    final repository = FakeAuthRepository()
      ..current = const AppUser(
        id: 'user-1',
        username: 'alice',
        displayName: 'Alice',
      );
    final controller = AuthController(repository);
    await controller.restore();

    final success = await controller.deleteAccount();

    expect(success, isTrue);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.notice, 'Your account was deleted.');
    expect(repository.current, isNull);
  });

  test('cleans up client state only after account deletion succeeds', () async {
    final events = <String>[];
    final repository = _RecordingAuthRepository(events);
    final controller = AuthController(
      repository,
      beforeSessionEnd: () async => events.add('cleanup'),
    );

    await controller.restore();
    final success = await controller.deleteAccount();

    expect(success, isTrue);
    expect(events, ['delete', 'cleanup']);
  });

  test('failed account deletion preserves live client state', () async {
    var cleanupCalls = 0;
    final repository = FakeAuthRepository()
      ..current = const AppUser(
        id: 'user-1',
        username: 'alice',
        displayName: 'Alice',
      )
      ..error = const ApiException(
        statusCode: 503,
        code: 'metricsBusy',
        message: 'Ratings are being prepared. Try again shortly.',
      );
    final controller = AuthController(
      repository,
      beforeSessionEnd: () async => cleanupCalls++,
    );
    await controller.restore();

    final success = await controller.deleteAccount();

    expect(success, isFalse);
    expect(controller.state.status, AuthStatus.signedIn);
    expect(controller.state.user?.id, 'user-1');
    expect(cleanupCalls, 0);
  });
}

class _RecordingAuthRepository extends FakeAuthRepository {
  _RecordingAuthRepository(this.events) {
    current = const AppUser(
      id: 'user-1',
      username: 'alice',
      displayName: 'Alice',
    );
  }

  final List<String> events;

  @override
  Future<void> deleteAccount() async {
    events.add('delete');
    await super.deleteAccount();
  }
}
