import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';
import '../data/profile_avatar.dart';

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
    this.avatarBusy = false,
    this.avatarError,
    this.avatarNotice,
  });

  const AuthState.loading() : this(status: AuthStatus.loading);

  final AuthStatus status;
  final AppUser? user;
  final bool busy;
  final String? error;
  final String? notice;
  final RegistrationResult? registration;
  final String? resetCode;
  final bool avatarBusy;
  final String? avatarError;
  final String? avatarNotice;

  AuthState copyWith({
    AuthStatus? status,
    AppUser? user,
    bool? busy,
    String? error,
    String? notice,
    RegistrationResult? registration,
    String? resetCode,
    bool? avatarBusy,
    String? avatarError,
    String? avatarNotice,
    bool clearMessages = false,
    bool clearRegistration = false,
    bool clearAvatarMessages = false,
  }) => AuthState(
    status: status ?? this.status,
    user: user ?? this.user,
    busy: busy ?? this.busy,
    error: clearMessages ? null : error ?? this.error,
    notice: clearMessages ? null : notice ?? this.notice,
    registration: clearRegistration ? null : registration ?? this.registration,
    resetCode: resetCode ?? this.resetCode,
    avatarBusy: avatarBusy ?? this.avatarBusy,
    avatarError: avatarError ?? (clearAvatarMessages ? null : this.avatarError),
    avatarNotice:
        avatarNotice ?? (clearAvatarMessages ? null : this.avatarNotice),
  );
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repository, {this._beforeSessionEnd})
    : super(const AuthState.loading());

  final AuthRepository _repository;
  final Future<void> Function()? _beforeSessionEnd;
  var _sessionGeneration = 0;
  Future<void>? _avatarOperation;

  Future<void> restore() async {
    try {
      final user = await _repository.restore();
      _sessionGeneration++;
      state = AuthState(
        status: user == null ? AuthStatus.signedOut : AuthStatus.signedIn,
        user: user,
      );
    } catch (_) {
      _sessionGeneration++;
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
      state = state.copyWith(
        busy: false,
        avatarBusy: false,
        error: _message(error),
      );
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
      _sessionGeneration++;
      state = AuthState(status: AuthStatus.signedIn, user: user);
      return true;
    } catch (error) {
      state = state.copyWith(
        busy: false,
        avatarBusy: false,
        error: _message(error),
      );
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
      await _waitForAvatarOperation();
      _sessionGeneration++;
      await _runBeforeSessionEnd();
      await _repository.logout();
    } finally {
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  Future<bool> deleteAccount() async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      await _waitForAvatarOperation();
      await _repository.deleteAccount();
      _sessionGeneration++;
      await _runBeforeSessionEnd();
      state = const AuthState(
        status: AuthStatus.signedOut,
        notice: 'Your account was deleted.',
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        busy: false,
        avatarBusy: false,
        error: _message(error),
      );
      return false;
    }
  }

  void sessionExpired() {
    _sessionGeneration++;
    state = const AuthState(
      status: AuthStatus.signedOut,
      notice: 'Your session expired. Please sign in again.',
    );
  }

  void clearMessages() => state = state.copyWith(clearMessages: true);

  void reportAvatarError(String message) {
    if (state.status != AuthStatus.signedIn) return;
    state = state.copyWith(avatarError: message, clearAvatarMessages: true);
  }

  Future<bool> uploadAvatar(ProfileAvatarUpload upload) => _runAvatarUpdate(
    () => _repository.uploadAvatar(upload),
    successMessage: 'Profile picture updated.',
  );

  Future<bool> removeAvatar() => _runAvatarUpdate(
    _repository.removeAvatar,
    successMessage: 'Profile picture removed.',
  );

  Future<void> _runBeforeSessionEnd() async {
    try {
      await _beforeSessionEnd?.call();
    } catch (_) {
      // A notification cleanup failure must never trap a player in a session.
    }
  }

  Future<bool> _runAuth(Future<AppUser> Function() action) async {
    state = state.copyWith(busy: true, clearMessages: true);
    try {
      final user = await action();
      _sessionGeneration++;
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

  Future<bool> _runAvatarUpdate(
    Future<AvatarDocument> Function() action, {
    required String successMessage,
  }) async {
    final user = state.user;
    if (state.status != AuthStatus.signedIn ||
        user == null ||
        state.avatarBusy ||
        state.busy) {
      return false;
    }
    final generation = _sessionGeneration;
    state = state.copyWith(avatarBusy: true, clearAvatarMessages: true);
    final operation = _completeAvatarUpdate(
      action,
      user: user,
      generation: generation,
      successMessage: successMessage,
    );
    final tracked = operation.then<void>((_) {});
    _avatarOperation = tracked;
    try {
      return await operation;
    } finally {
      if (identical(_avatarOperation, tracked)) {
        _avatarOperation = null;
      }
    }
  }

  Future<bool> _completeAvatarUpdate(
    Future<AvatarDocument> Function() action, {
    required AppUser user,
    required int generation,
    required String successMessage,
  }) async {
    try {
      final avatar = await action();
      if (!_isCurrentUser(generation, user.id)) return false;
      if (avatar.version < user.avatarVersion) {
        state = state.copyWith(
          avatarBusy: false,
          avatarError: 'The profile picture changed elsewhere. Try again.',
        );
        return false;
      }
      final updated = user.copyWith(
        avatarUrl: avatar.url,
        clearAvatarUrl: avatar.url == null,
        avatarVersion: avatar.version,
      );
      try {
        await _repository.cacheUser(updated);
      } catch (_) {
        // The authoritative server result is still safe to show. A future
        // profile refresh will repair a failed local cache write.
      }
      if (!_isCurrentUser(generation, user.id)) return false;
      state = state.copyWith(
        user: updated,
        avatarBusy: false,
        avatarNotice: successMessage,
      );
      return true;
    } catch (error) {
      if (!_isCurrentUser(generation, user.id)) return false;
      state = state.copyWith(avatarBusy: false, avatarError: _message(error));
      return false;
    }
  }

  bool _isCurrentUser(int generation, String userId) =>
      generation == _sessionGeneration &&
      state.status == AuthStatus.signedIn &&
      state.user?.id == userId;

  Future<void> _waitForAvatarOperation() async {
    try {
      await _avatarOperation;
    } catch (_) {
      // The operation owns its error state and has already been invalidated.
    }
  }
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'Something went wrong. Check your connection and try again.';
}
