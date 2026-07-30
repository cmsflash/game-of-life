import 'dart:convert';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const engine = GameEngine();

  group('serialization and hashes', () {
    test('all victory rule documents round trip', () {
      final rulesets = [
        GameRules.standard(),
        GameRules.standard(victory: TurnLimitPopulationVictory(20)),
        GameRules.standard(victory: PopulationTargetVictory(100)),
        GameRules.legacyV1(),
        GameRules.legacyV1(victory: TurnLimitPopulationVictory(20)),
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
      expect(initial.rules.version, 2);
      expect(initial.rules.birthOwnership, BirthOwnership.movingPlayer);
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

    test('legacy v1 state retains its exact rules and hashes', () {
      final initial = engine.initialState(GameRules.legacyV1());
      final restored = GameState.fromJson(
        jsonDecode(jsonEncode(initial.toJson())),
      );

      expect(restored, initial);
      expect(initial.rules.version, 1);
      expect(
        initial.rules.birthOwnership,
        BirthOwnership.strictNeighborMajority,
      );
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
      unsupportedRules['rulesVersion'] = 3;
      expect(() => GameRules.fromJson(unsupportedRules), throwsFormatException);

      final mismatchedV1 = GameRules.legacyV1().toJson();
      (mismatchedV1['evolution']! as Map<String, Object?>)['birthOwner'] =
          BirthOwnership.movingPlayer.wireValue;
      expect(() => GameRules.fromJson(mismatchedV1), throwsFormatException);

      final mismatchedV2 = GameRules.standard().toJson();
      (mismatchedV2['evolution']! as Map<String, Object?>)['birthOwner'] =
          BirthOwnership.strictNeighborMajority.wireValue;
      expect(() => GameRules.fromJson(mismatchedV2), throwsFormatException);
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

    test('replaying stored v1 moves preserves legacy birth ownership', () {
      final rules = GameRules.legacyV1();
      final initial = activeState(
        boardWith({
          const Coordinate(4, 4): CellState.black,
          const Coordinate(4, 5): CellState.black,
        }),
        toMove: Player.white,
        rules: rules,
        ply: 1,
      );
      const move = GameMove(
        player: Player.white,
        row: 5,
        column: 4,
        expectedRevision: 1,
      );

      final expected = engine.applyMove(initial, move).state;
      final replayed = engine.replay([move], initial: initial);

      expect(replayed, expected);
      expect(replayed.rules.version, 1);
      expect(replayed.board.at(5, 5), CellState.black);
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
