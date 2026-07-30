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
      expect(initial.rules.toJson()['rulesVersion'], GameRules.rulesVersion);
      expect(
        (initial.rules.toJson()['evolution']! as Map)['birthOwner'],
        'movingPlayer',
      );
      expect(
        initial.rules.rulesHash,
        '725f21234c95ee15f2c611aac441c299ae41cb828243a0ee6249ab9b751409cf',
      );
      expect(
        initial.positionHash,
        '34378b0e7fc88fa83ccc59631cd35c901b26f29bad0f0dc088819e388ff170d2',
      );
      expect(
        initial.stateHash,
        'beb279996681f206854970ae53ee14d59aaec4a3718b553f251b55f209e91f2a',
      );
    });

    test('rejects tampered state and every non-current ruleset', () {
      final json = engine.initialState().toJson();
      final tampered = Map<String, Object?>.from(json);
      tampered['stateHash'] = List.filled(64, '0').join();
      expect(() => GameState.fromJson(tampered), throwsFormatException);

      for (final unsupportedVersion in [1, 3]) {
        final unsupportedRules = Map<String, Object?>.from(
          engine.initialState().rules.toJson(),
        );
        unsupportedRules['rulesVersion'] = unsupportedVersion;
        expect(
          () => GameRules.fromJson(unsupportedRules),
          throwsFormatException,
        );
      }

      final wrongBirthOwner = GameRules.standard().toJson();
      (wrongBirthOwner['evolution']! as Map<String, Object?>)['birthOwner'] =
          'strictNeighborMajority';
      expect(() => GameRules.fromJson(wrongBirthOwner), throwsFormatException);
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
