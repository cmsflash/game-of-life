import 'dart:convert';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = GameEngine();

  group('serialization and hashes', () {
    test('all victory rule documents round trip', () {
      final rulesets = [
        GameRules.standard(),
        GameRules.standard(victory: TurnLimitPopulationVictory(20)),
        GameRules.standard(victory: PopulationTargetVictory(100)),
      ];

      for (final rules in rulesets) {
        final decoded = jsonDecode(jsonEncode(rules.toJson()));
        final restored = GameRules.fromJson(decoded);
        expect(restored, rules);
        expect(restored.rulesHash, rules.rulesHash);
      }
    });

    test('state round trips with verified hashes', () {
      final initial = engine.initialState();
      final restored = GameState.fromJson(
        jsonDecode(jsonEncode(initial.toJson())),
      );

      expect(restored, initial);
      expect(restored.positionHash, initial.positionHash);
      expect(restored.stateHash, initial.stateHash);
      expect(initial.rules.rulesHash, hasLength(64));
      expect(initial.positionHash, hasLength(64));
      expect(initial.stateHash, hasLength(64));
      expect(
        initial.rules.rulesHash,
        'cd7c375a1830a2e6a7b381fe0fe010055b686e603c51e1b3a519f48f3f7090a7',
      );
      expect(
        initial.positionHash,
        '2dd5f2bd59cf2672b834b531fd5ea615e4e6d1626339f052d769d1dac156eb91',
      );
      expect(
        initial.stateHash,
        '3befc64952e1ce83fa494176402f93e224df398c62105c09db611cac1bf4773e',
      );
    });

    test('rejects tampered state and unsupported versions', () {
      final json = engine.initialState().toJson();
      final tampered = Map<String, Object?>.from(json);
      tampered['stateHash'] = List.filled(64, '0').join();
      expect(() => GameState.fromJson(tampered), throwsFormatException);

      final unsupportedRules = Map<String, Object?>.from(
        engine.initialState().rules.toJson(),
      );
      unsupportedRules['rulesVersion'] = 2;
      expect(() => GameRules.fromJson(unsupportedRules), throwsFormatException);
    });

    test('canonical JSON ignores insertion order', () {
      expect(
        canonicalJson({'z': 1, 'a': true}),
        canonicalJson({'a': true, 'z': 1}),
      );
    });

    test('replaying move events reproduces final state', () {
      final initial = engine.initialState();
      const moves = [
        GameMove(player: Player.black, row: 0, column: 0, expectedRevision: 0),
        GameMove(player: Player.white, row: 0, column: 0, expectedRevision: 1),
      ];
      var expected = initial;
      for (final move in moves) {
        expected = engine.applyMove(expected, move).state;
      }

      final replayed = engine.replay(moves);

      expect(replayed, expected);
      expect(replayed.stateHash, expected.stateHash);
    });
  });

  test('Board defensively copies its cells', () {
    final source = List<CellState>.filled(4, CellState.empty);
    final board = Board(rows: 2, columns: 2, cells: source);
    source[0] = CellState.black;

    expect(board.at(0, 0), CellState.empty);
    expect(() => board.cells[0] = CellState.black, throwsUnsupportedError);
  });
}
