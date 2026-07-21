import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api_client.dart';
import 'auth_models.dart';
import 'session_store.dart';

abstract interface class BrowserLauncher {
  Future<bool> open(Uri uri);
}

class SystemBrowserLauncher implements BrowserLauncher {
  @override
  Future<bool> open(Uri uri) => launchUrl(
    uri,
    mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    webOnlyWindowName: '_self',
  );
}

abstract interface class AuthRepository {
  Future<AppUser?> restore();
  Future<AppUser> login({required String username, required String password});
  Future<RegistrationResult> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  });
  Future<void> confirm({required String username, required String code});
  Future<String?> resendConfirmation(String username);
  Future<String?> forgotPassword(String username);
  Future<void> resetPassword({
    required String username,
    required String code,
    required String newPassword,
  });
  Future<void> beginGoogleSignIn();
  Future<AppUser> exchangeGoogleCode(String code);
  Future<void> logout();
}

class ApiAuthRepository implements AuthRepository {
  factory ApiAuthRepository({
    required ApiClient api,
    required SessionStore sessionStore,
    required BrowserLauncher browserLauncher,
  }) => ApiAuthRepository._(api, sessionStore, browserLauncher);

  const ApiAuthRepository._(
    this._api,
    this._sessionStore,
    this._browserLauncher,
  );

  final ApiClient _api;
  final SessionStore _sessionStore;
  final BrowserLauncher _browserLauncher;

  @override
  Future<AppUser?> restore() async {
    final stored = await _sessionStore.readSession();
    if (stored == null) return null;
    if (stored.userJson != null) {
      try {
        return AppUser.fromJson(stored.userJson!);
      } catch (_) {
        // Fall through and ask the API for the canonical profile.
      }
    }
    try {
      final response = await _api.get('/v1/me');
      final user = AppUser.fromJson(response.data as Map<String, dynamic>);
      await _sessionStore.writeSession(
        StoredSession(
          accessToken: stored.accessToken,
          refreshToken: stored.refreshToken,
          expiresAt: stored.expiresAt,
          userJson: user.toJson(),
        ),
      );
      return user;
    } on ApiException catch (error) {
      if (error.statusCode == 401) await _sessionStore.clearSession();
      return null;
    }
  }

  @override
  Future<AppUser> login({
    required String username,
    required String password,
  }) async {
    final response = await _api.post(
      '/v1/auth/login',
      authenticated: false,
      body: {'username': username.trim(), 'password': password},
    );
    return _saveTokens(response.data as Map<String, dynamic>);
  }

  @override
  Future<RegistrationResult> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async {
    final response = await _api.post(
      '/v1/auth/register',
      authenticated: false,
      body: {
        'username': username.trim(),
        'email': email.trim(),
        'password': password,
        'displayName': displayName.trim(),
      },
    );
    return RegistrationResult.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> confirm({required String username, required String code}) async {
    await _api.post(
      '/v1/auth/confirm',
      authenticated: false,
      body: {'username': username.trim(), 'code': code.trim()},
    );
  }

  @override
  Future<String?> resendConfirmation(String username) async {
    final response = await _api.post(
      '/v1/auth/resend',
      authenticated: false,
      body: {'username': username.trim()},
    );
    final json = response.data as Map<String, dynamic>;
    return json['debugResetCode'] as String?;
  }

  @override
  Future<String?> forgotPassword(String username) async {
    final response = await _api.post(
      '/v1/auth/forgot',
      authenticated: false,
      body: {'username': username.trim()},
    );
    final json = response.data as Map<String, dynamic>;
    return json['debugResetCode'] as String?;
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String code,
    required String newPassword,
  }) async {
    await _api.post(
      '/v1/auth/reset',
      authenticated: false,
      body: {
        'username': username.trim(),
        'code': code.trim(),
        'newPassword': newPassword,
      },
    );
  }

  @override
  Future<void> beginGoogleSignIn() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      throw const ApiException(
        statusCode: 0,
        code: 'googleSignInUnsupported',
        message:
            'Google sign-in is not configured on this desktop platform yet. Use your username and password.',
      );
    }
    final uri = Uri.parse(
      '${_api.baseUrl}/v1/auth/google/start',
    ).replace(queryParameters: {'returnTo': _googleReturnUri().toString()});
    if (!await _browserLauncher.open(uri)) {
      throw const ApiException(
        statusCode: 0,
        code: 'browserUnavailable',
        message:
            'Google sign-in could not open a browser. Use your username and password instead.',
      );
    }
  }

  @override
  Future<AppUser> exchangeGoogleCode(String code) async {
    final response = await _api.post(
      '/v1/auth/exchange',
      authenticated: false,
      body: {'code': code},
    );
    return _saveTokens(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> logout() async {
    final session = await _sessionStore.readSession();
    try {
      await _api.post(
        '/v1/auth/logout',
        body: {'accessToken': session?.accessToken},
      );
    } finally {
      await _sessionStore.clearSession();
    }
  }

  Future<AppUser> _saveTokens(Map<String, dynamic> json) async {
    final userJson = json['user'] as Map<String, dynamic>?;
    if (userJson == null || json['accessToken'] is! String) {
      throw const ApiException(
        statusCode: 502,
        code: 'invalidSessionResponse',
        message: 'The server did not return a valid session.',
      );
    }
    final user = AppUser.fromJson(userJson);
    final expiresIn = (json['expiresIn'] as num?)?.round();
    await _sessionStore.writeSession(
      StoredSession(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String?,
        expiresAt: expiresIn == null
            ? null
            : DateTime.now().add(Duration(seconds: expiresIn)),
        userJson: user.toJson(),
      ),
    );
    return user;
  }
}

Uri _googleReturnUri() {
  const configured = String.fromEnvironment('GOOGLE_RETURN_URI');
  if (configured.isNotEmpty) return Uri.parse(configured);
  if (kIsWeb) {
    return Uri.base.replace(
      path: '/auth/callback',
      queryParameters: const {},
      fragment: '',
    );
  }
  return Uri.parse('com.cmsflash.gameoflife://auth');
}
