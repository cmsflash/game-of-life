import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/ids.dart';

class StoredSession {
  const StoredSession({
    required this.accessToken,
    required this.refreshToken,
    this.expiresAt,
    this.userJson,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final Map<String, dynamic>? userJson;

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt?.toIso8601String(),
    'user': userJson,
  };

  factory StoredSession.fromJson(Map<String, dynamic> json) => StoredSession(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String?,
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    userJson: json['user'] as Map<String, dynamic>?,
  );
}

abstract interface class SessionStore {
  Future<StoredSession?> readSession();
  Future<void> writeSession(StoredSession session);
  Future<void> clearSession();
  Future<String> deviceId();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _sessionKey = 'game_of_life.session.v1';
  static const _deviceKey = 'game_of_life.device.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<StoredSession?> readSession() async {
    final value = await _storage.read(key: _sessionKey);
    if (value == null) return null;
    try {
      return StoredSession.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } catch (_) {
      await clearSession();
      return null;
    }
  }

  @override
  Future<void> writeSession(StoredSession session) =>
      _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));

  @override
  Future<void> clearSession() => _storage.delete(key: _sessionKey);

  @override
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _deviceKey);
    if (existing != null) return existing;
    final created = newRequestId();
    await _storage.write(key: _deviceKey, value: created);
    return created;
  }
}

class MemorySessionStore implements SessionStore {
  StoredSession? session;
  String id = 'test-device';

  @override
  Future<void> clearSession() async => session = null;

  @override
  Future<String> deviceId() async => id;

  @override
  Future<StoredSession?> readSession() async => session;

  @override
  Future<void> writeSession(StoredSession value) async => session = value;
}
