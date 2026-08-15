import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/online/data/online_models.dart';

void main() {
  test('match summaries retain a private-room join code', () {
    final summary = OnlineMatchSummary.fromJson({
      'matchId': 'waiting-room',
      'status': 'waiting',
      'joinCode': 'LIFE42',
      'opponentName': 'Opponent',
    });

    expect(summary.joinCode, 'LIFE42');
  });

  test('match summaries expose the opponent avatar snapshot', () {
    final summary = OnlineMatchSummary.fromJson({
      'matchId': 'match-avatar',
      'status': 'active',
      'yourColor': 'black',
      'players': [
        {'userId': 'alice', 'displayName': 'Alice', 'color': 'black'},
        {
          'userId': 'bob',
          'displayName': 'Bob',
          'color': 'white',
          'avatarUrl': 'https://api.example.test/v1/players/bob/avatar?v=9',
          'avatarVersion': 9,
        },
      ],
    });

    expect(summary.opponentName, 'Bob');
    expect(summary.opponentAvatarVersion, 9);
    expect(summary.opponentAvatarUrl, endsWith('avatar?v=9'));
  });

  test('decodes packed two-bit server boards', () {
    final values = List<int>.filled(400, 0)
      ..[0] = 1
      ..[1] = 2
      ..[399] = 1;
    final bytes = List<int>.filled(100, 0);
    for (var i = 0; i < values.length; i++) {
      bytes[i ~/ 4] |= values[i] << ((i % 4) * 2);
    }

    final match = OnlineMatch.fromJson({
      'matchId': 'match-1',
      'status': 'active',
      'revision': 4,
      'yourColor': 'black',
      'nextPlayerColor': 'black',
      'players': [
        {
          'userId': 'a',
          'username': 'alice',
          'displayName': 'Alice',
          'color': 'black',
        },
        {
          'userId': 'b',
          'username': 'bob',
          'displayName': 'Bob',
          'color': 'white',
          'avatarUrl': 'https://api.example.test/v1/players/b/avatar?v=2',
          'avatarVersion': 2,
        },
      ],
      'board': {
        'encoding': 'u2-base64-v1',
        'width': 20,
        'height': 20,
        'cells': base64Encode(bytes),
      },
    });

    expect(match.board.at(0, 0), engine.CellState.black);
    expect(match.board.at(0, 1), engine.CellState.white);
    expect(match.board.at(19, 19), engine.CellState.black);
    expect(match.blackPopulation, 2);
    expect(match.whitePopulation, 1);
    expect(match.isYourTurn, isTrue);
    expect(match.playerFor(engine.Player.white)?.avatarVersion, 2);
  });

  test('accepts the alternate nested state document shape', () {
    final cells = List<int>.filled(400, 0)..[210] = 2;
    final match = OnlineMatch.fromJson({
      'id': 'alternate',
      'state': {
        'status': 'active',
        'revision': 7,
        'toMove': 'white',
        'cells': cells,
      },
      'yourColor': 'white',
      'blackPlayer': {'id': 'a', 'username': 'alice'},
      'whitePlayer': {'id': 'b', 'username': 'bob'},
    });

    expect(match.id, 'alternate');
    expect(match.revision, 7);
    expect(match.board.at(10, 10), engine.CellState.white);
    expect(match.players, hasLength(2));
  });

  test('parses authoritative rules and an optional persisted last move', () {
    final rules = engine.GameRules.standard(
      victory: engine.TurnLimitPopulationVictory(20),
    );
    final state = const engine.GameEngine().initialState(rules);
    final match = OnlineMatch.fromJson({
      'id': 'with-preview-data',
      'status': 'active',
      'rules': rules.toJson(),
      'state': state.toJson(),
      'yourColor': 'black',
      'lastMove': {'revision': 3, 'player': 'black', 'row': 4, 'column': 7},
    });

    expect(match.rules, rules);
    expect(match.lastMove, const engine.Coordinate(4, 7));

    final legacy = OnlineMatch.fromJson({
      'id': 'legacy',
      'status': 'active',
      'state': state.toJson(),
    });
    expect(legacy.lastMove, isNull);
  });
}
