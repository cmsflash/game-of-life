import 'package:game_of_life/features/auth/data/auth_models.dart';
import 'package:game_of_life/features/auth/data/auth_repository.dart';

class FakeAuthRepository implements AuthRepository {
  AppUser? current;
  Object? error;
  var loginCalls = 0;

  @override
  Future<AppUser?> restore() async => current;

  @override
  Future<AppUser> login({
    required String username,
    required String password,
  }) async {
    loginCalls++;
    if (error != null) throw error!;
    return current = AppUser(
      id: 'user-1',
      username: username,
      displayName: username,
    );
  }

  @override
  Future<RegistrationResult> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async =>
      RegistrationResult(username: username, confirmationRequired: true);

  @override
  Future<void> beginGoogleSignIn() async {}

  @override
  Future<AppUser> exchangeGoogleCode(String code) async =>
      current = const AppUser(
        id: 'google-1',
        username: 'google_player',
        displayName: 'Google Player',
      );

  @override
  Future<void> confirm({
    required String username,
    required String code,
  }) async {}

  @override
  Future<String?> forgotPassword(String username) async => null;

  @override
  Future<String?> resendConfirmation(String username) async => null;

  @override
  Future<void> logout() async => current = null;

  @override
  Future<void> deleteAccount() async {
    if (error != null) throw error!;
    current = null;
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String code,
    required String newPassword,
  }) async {}
}
