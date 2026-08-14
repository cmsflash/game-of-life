import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/game_session.dart';

abstract interface class LocalGameStore {
  Future<List<LocalGameSession>> readGames();
  Future<void> writeGames(List<LocalGameSession> games);
}

class SecureLocalGameStore implements LocalGameStore {
  SecureLocalGameStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _gamesKey = 'game_of_life.local_games.v1';
  static const _schemaVersion = 1;

  final FlutterSecureStorage _storage;

  @override
  Future<List<LocalGameSession>> readGames() async {
    final stored = await _storage.read(key: _gamesKey);
    if (stored == null) return const [];
    final document = jsonDecode(stored);
    if (document is! Map) {
      throw const FormatException('Local games document must be an object');
    }
    final schemaVersion = document['schemaVersion'];
    if (schemaVersion != _schemaVersion) {
      throw FormatException(
        'Unsupported local games schema version: $schemaVersion',
      );
    }
    final encodedGames = document['games'];
    if (encodedGames is! List) {
      throw const FormatException('local games must be a list');
    }
    final games = <LocalGameSession>[];
    final seenIds = <String>{};
    for (final encodedGame in encodedGames) {
      try {
        final game = LocalGameSession.fromJson(encodedGame);
        if (seenIds.add(game.id)) games.add(game);
      } on FormatException {
        // One damaged match is isolated without modifying the source document.
      } on ArgumentError {
        // Invalid engine values are isolated to their containing match.
      }
    }
    return List.unmodifiable(games);
  }

  @override
  Future<void> writeGames(List<LocalGameSession> games) {
    final value = jsonEncode({
      'schemaVersion': _schemaVersion,
      'games': games.map((game) => game.toJson()).toList(growable: false),
    });
    return _storage.write(key: _gamesKey, value: value);
  }
}

class MemoryLocalGameStore implements LocalGameStore {
  MemoryLocalGameStore({Iterable<LocalGameSession> games = const []})
    : _games = _persistedCopy(games);

  List<LocalGameSession> _games;
  Object? readError;
  Object? writeError;
  var writeCount = 0;

  List<LocalGameSession> get games => List.unmodifiable(_games);

  @override
  Future<List<LocalGameSession>> readGames() async {
    if (readError != null) throw readError!;
    return _persistedCopy(_games);
  }

  @override
  Future<void> writeGames(List<LocalGameSession> games) async {
    if (writeError != null) throw writeError!;
    writeCount++;
    _games = _persistedCopy(games);
  }

  static List<LocalGameSession> _persistedCopy(
    Iterable<LocalGameSession> games,
  ) => games
      .map((game) => LocalGameSession.fromJson(game.toJson()))
      .toList(growable: false);
}
