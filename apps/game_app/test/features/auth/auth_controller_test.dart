import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/core/api_client.dart';
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
}
