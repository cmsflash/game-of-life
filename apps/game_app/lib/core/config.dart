import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  static const appName = 'The Game of Life';
  static const rulesetId = 'classic-elimination';
  static const rulesetVersion = 1;

  static String get platform {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }
}
