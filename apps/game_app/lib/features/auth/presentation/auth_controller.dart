import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';

enum AuthStatus { loading, signedOut, signedIn }

class AuthState {
  const AuthState({
    required this.status,
    this.user,
    this.busy = false,
    this.error,
    this.notice,
    this.registration,
    this.resetCode,
  });

  const AuthState.loading() : this(status: AuthStatus.loading);

  final AuthStatus status;
  final AppUser? user;
  final bool busy;
  final String? error;
  final String? notice;
  final RegistrationResult? registration;
  final String? resetCode;

  AuthState copyWith({
    AuthStatus? status,
    AppUser? user,
    bool? busy,
    String? error,
    String? notice,
    RegistrationResult? registration,
    String? resetCode,
    bool clearMessages = false,
    bool clearRegistration = false,
  }) => AuthState(
    status: status ?? this.status,
    user: user ?? this.user,
    busy: busy ?? this.busy,
    error: clearMessages ? null : error ?? this.error,
    notice: clearMessages ? null : notice ?? this.notice,
    registration: clearRegistration ? null : registration ?? this.registration,
    resetCode: resetCode ?? this.resetCode,
  );
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repository) : super(const AuthState.loading());

  final AuthRepository _repository;

  Future<void> restore() async {
    try {
      final user = await _repository.restore();
      state = AuthState(
        status: user == null ? AuthStatus.signedOut : AuthStatus.signedIn,
        user: user,
      );
    } catch (_) {
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  Future<bool> login(String username, String password) =>
      _runAuth(() => _repository.login(username: username, password: password));

  Future<bool> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final registration = await _repository.register(
        username: username,
        email: email,
        password: password,
        displayName: displayName,
      );
      state = AuthState(
        status: AuthStatus.signedOut,
        notice: 'Check your email for a confirmation code.',
        registration: registration,
      );
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }

  Future<void> beginGoogleSignIn() async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      await _repository.beginGoogleSignIn();
      state = state.copyWith(
        busy: false,
        notice: 'Finish signing in in your browser.',
      );
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
    }
  }

  Future<bool> completeGoogleSignIn(String code) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final user = await _repository.exchangeGoogleCode(code);
      state = AuthState(status: AuthStatus.signedIn, user: user);
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }

  Future<bool> confirm(String username, String code) async {
    return _runAction(
      () => _repository.confirm(username: username, code: code),
      'Account confirmed. You can now sign in.',
    );
  }

  Future<bool> resendConfirmation(String username) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final code = await _repository.resendConfirmation(username);
      state = state.copyWith(
        busy: false,
        notice: 'A new confirmation code is on its way.',
        registration: RegistrationResult(
          username: username,
          confirmationRequired: true,
          debugConfirmationCode: code,
        ),
      );
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }

  Future<bool> forgotPassword(String username) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final code = await _repository.forgotPassword(username);
      state = state.copyWith(
        busy: false,
        notice: 'If that account exists, a reset code is on its way.',
        resetCode: code,
      );
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }

  Future<bool> resetPassword(
    String username,
    String code,
    String password,
  ) async {
    return _runAction(
      () => _repository.resetPassword(
        username: username,
        code: code,
        newPassword: password,
      ),
      'Password updated. Sign in with your new password.',
    );
  }

  Future<void> logout() async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      await _repository.logout();
    } finally {
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  void sessionExpired() {
    state = const AuthState(
      status: AuthStatus.signedOut,
      notice: 'Your session expired. Please sign in again.',
    );
  }

  void clearMessages() => state = state.copyWith(clearMessages: true);

  Future<bool> _runAuth(Future<AppUser> Function() action) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final user = await action();
      state = AuthState(status: AuthStatus.signedIn, user: user);
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }

  Future<bool> _runAction(Future<void> Function() action, String notice) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      await action();
      state = state.copyWith(busy: false, notice: notice);
      return true;
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
      return false;
    }
  }
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'Something went wrong. Check your connection and try again.';
}
