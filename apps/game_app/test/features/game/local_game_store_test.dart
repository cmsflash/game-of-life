import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/local_games_controller.dart';

void main() {
  const storageKey = 'game_of_life.local_games.v1';

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('secure store round trips multiple complete local games', () async {
    final store = SecureLocalGameStore();
    final games = [
      _session('one', DateTime.utc(2026, 8, 14)),
      _session('two', DateTime.utc(2026, 8, 15)),
    ];

    await store.writeGames(games);
    final restored = await store.readGames();

    expect(restored.map((game) => game.id), ['one', 'two']);
    expect(restored[0].game.stateHash, games[0].game.stateHash);
    expect(restored[1].createdAt, DateTime.utc(2026, 8, 15));
  });

  test('one damaged game does not hide other saved games', () async {
    final valid = _session('valid', DateTime.utc(2026, 8, 14)).toJson();
    final damaged = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
    damaged['id'] = 'damaged';
    (damaged['game'] as Map<String, dynamic>)['stateHash'] = 'bad-hash';
    FlutterSecureStorage.setMockInitialValues({
      storageKey: jsonEncode({
        'schemaVersion': 1,
        'games': [damaged, valid],
      }),
    });

    final restored = await SecureLocalGameStore().readGames();

    expect(restored, hasLength(1));
    expect(restored.single.id, 'valid');
  });

  test(
    'malformed collection surfaces failure without deleting raw data',
    () async {
      const raw = 'not-json';
      FlutterSecureStorage.setMockInitialValues({storageKey: raw});
      const storage = FlutterSecureStorage();

      await expectLater(
        SecureLocalGameStore(storage: storage).readGames(),
        throwsFormatException,
      );
      expect(await storage.read(key: storageKey), raw);
    },
  );

  test('future schema remains intact across failed load and retry', () async {
    final raw = jsonEncode({
      'schemaVersion': 2,
      'games': [
        {'future': 'data'},
      ],
    });
    FlutterSecureStorage.setMockInitialValues({storageKey: raw});
    const storage = FlutterSecureStorage();
    final controller = LocalGamesController(
      SecureLocalGameStore(storage: storage),
    );

    await controller.load();
    expect(controller.state.status, LocalGamesLoadStatus.failed);
    expect(controller.state.error, contains('schema version: 2'));
    expect(await storage.read(key: storageKey), raw);

    await controller.retryLoad();
    expect(controller.state.status, LocalGamesLoadStatus.failed);
    expect(await storage.read(key: storageKey), raw);
  });
}

LocalGameSession _session(String id, DateTime timestamp) => LocalGameSession(
  id: id,
  title: 'Game $id',
  opponentLabel: 'White',
  createdAt: timestamp,
  updatedAt: timestamp,
  config: const LocalGameConfig(),
  game: const engine.GameEngine().initialState(),
);
