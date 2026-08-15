import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/data/profile_avatar.dart';
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

  test('avatar upload applies the authoritative URL and version', () async {
    final repository = FakeAuthRepository()
      ..current = const AppUser(
        id: 'user-1',
        username: 'alice',
        displayName: 'Alice',
      );
    final controller = AuthController(repository);
    await controller.restore();

    final success = await controller.uploadAvatar(_avatarUpload());

    expect(success, isTrue);
    expect(controller.state.user?.avatarVersion, 1);
    expect(controller.state.user?.avatarUrl, contains('avatar?v=1'));
    expect(controller.state.avatarNotice, 'Profile picture updated.');
    expect(repository.current?.avatarVersion, 1);
  });

  test('duplicate avatar operations are suppressed', () async {
    final gate = Completer<AvatarDocument>();
    final repository = FakeAuthRepository()
      ..current = const AppUser(
        id: 'user-1',
        username: 'alice',
        displayName: 'Alice',
      )
      ..avatarGate = gate;
    final controller = AuthController(repository);
    await controller.restore();

    final first = controller.uploadAvatar(_avatarUpload());
    final second = await controller.uploadAvatar(_avatarUpload());
    gate.complete(
      const AvatarDocument(
        url: 'https://api.example.test/v1/players/user-1/avatar?v=2',
        version: 2,
      ),
    );

    expect(second, isFalse);
    expect(await first, isTrue);
    expect(repository.uploadAvatarCalls, 1);
  });

  test(
    'sign out drains an in-flight avatar response before clearing',
    () async {
      final gate = Completer<AvatarDocument>();
      final repository = FakeAuthRepository()
        ..current = const AppUser(
          id: 'user-1',
          username: 'alice',
          displayName: 'Alice',
        )
        ..avatarGate = gate;
      final controller = AuthController(repository);
      await controller.restore();

      final upload = controller.uploadAvatar(_avatarUpload());
      final logout = controller.logout();
      gate.complete(
        const AvatarDocument(
          url: 'https://api.example.test/v1/players/user-1/avatar?v=3',
          version: 3,
        ),
      );

      expect(await upload, isTrue);
      await logout;
      expect(controller.state.status, AuthStatus.signedOut);
      expect(controller.state.user, isNull);
      expect(repository.current, isNull);
    },
  );

  test(
    'failed deletion preserves an avatar that completed while waiting',
    () async {
      final gate = Completer<AvatarDocument>();
      final repository = FakeAuthRepository()
        ..current = const AppUser(
          id: 'user-1',
          username: 'alice',
          displayName: 'Alice',
        )
        ..avatarGate = gate
        ..error = const ApiException(
          statusCode: 503,
          code: 'temporarilyUnavailable',
          message: 'Try later.',
        );
      final controller = AuthController(repository);
      await controller.restore();

      final upload = controller.uploadAvatar(_avatarUpload());
      final deletion = controller.deleteAccount();
      gate.complete(
        const AvatarDocument(
          url: 'https://api.example.test/v1/players/user-1/avatar?v=4',
          version: 4,
        ),
      );

      expect(await upload, isTrue);
      expect(await deletion, isFalse);
      expect(controller.state.status, AuthStatus.signedIn);
      expect(controller.state.user?.avatarVersion, 4);
      expect(controller.state.avatarBusy, isFalse);
    },
  );

  test('remove avatar keeps the old picture until success', () async {
    final gate = Completer<AvatarDocument>();
    final repository = FakeAuthRepository()
      ..current = const AppUser(
        id: 'user-1',
        username: 'alice',
        displayName: 'Alice',
        avatarUrl: 'https://api.example.test/avatar?v=4',
        avatarVersion: 4,
      )
      ..avatarGate = gate;
    final controller = AuthController(repository);
    await controller.restore();

    final removal = controller.removeAvatar();
    expect(controller.state.user?.avatarUrl, isNotNull);
    gate.complete(const AvatarDocument(url: null, version: 5));

    expect(await removal, isTrue);
    expect(controller.state.user?.avatarUrl, isNull);
    expect(controller.state.user?.avatarVersion, 5);
  });
}

ProfileAvatarUpload _avatarUpload() => ProfileAvatarUpload(
  bytes: Uint8List.fromList(const [0xff, 0xd8, 0xff]),
  filename: 'profile.jpg',
  contentType: 'image/jpeg',
);

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
