import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const _googleSignInConfigured = bool.fromEnvironment(
    'GOOGLE_SIGN_IN_ENABLED',
    defaultValue: !kReleaseMode,
  );

  static const appName = 'The Game of Life';
  static const rulesetId = 'classic-elimination';
  static const rulesetVersion = 1;

  static String get apiBaseUrl => _configuredApiBaseUrl.isNotEmpty
      ? _configuredApiBaseUrl
      : 'http://localhost:8080';

  static bool get googleSignInAvailable {
    if (!_googleSignInConfigured) return false;
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static String get platform {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }

  static void ensureValidReleaseConfiguration() {
    if (!kReleaseMode) return;
    final uri = Uri.tryParse(_configuredApiBaseUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        _isLocalHost(uri.host)) {
      throw StateError(
        'Release builds require an HTTPS API_BASE_URL. '
        'Build with --dart-define=API_BASE_URL=https://api.example.com.',
      );
    }
  }

  static bool _isLocalHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized.endsWith('.localhost') ||
        normalized == '::1' ||
        normalized == '0.0.0.0' ||
        normalized.startsWith('127.');
  }
}
