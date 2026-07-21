import 'dart:convert';

import 'package:game_cli/game_cli.dart';
import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  late GameCli cli;

  setUp(() {
    cli = GameCli();
  });

  Map<String, Object?> resultOf(Map<String, Object?> response) =>
      Map<String, Object?>.from(response['result']! as Map);

  Map<String, Object?> initialStateJson() {
    final response = cli.handleRequest({'op': 'initial'});
    return Map<String, Object?>.from(resultOf(response)['state']! as Map);
  }

  test('initial uses the stable result envelope', () {
    final response = cli.handleRequest({'op': 'initial'});

    expect(response.keys, {'ok', 'result'});
    expect(response['ok'], isTrue);
    final state = GameState.fromJson(resultOf(response)['state']);
    expect(state, const GameEngine().initialState());
  });

  test('accepts operation and command aliases', () {
    expect(cli.handleRequest({'operation': 'initialState'})['ok'], isTrue);
    expect(cli.handleRequest({'command': 'initial'})['ok'], isTrue);
  });

  test('legalMoves returns every empty coordinate', () {
    final response = cli.handleRequest({
      'op': 'legalMoves',
      'state': initialStateJson(),
    });

    expect(response['ok'], isTrue);
    expect(resultOf(response)['count'], 396);
    expect(resultOf(response)['moves'], hasLength(396));
  });

  test('applyMove accepts the canonical move schema', () {
    final response = cli.handleRequest({
      'op': 'applyMove',
      'state': initialStateJson(),
      'move': {'player': 'black', 'row': 0, 'column': 0, 'expectedRevision': 0},
    });

    expect(response['ok'], isTrue);
    final result = resultOf(response);
    final state = GameState.fromJson(result['state']);
    expect(state.revision, 1);
    expect(state.toMove, Player.white);
    expect(result['delta'], isA<Map>());
  });

  test('applyMove supports top-level expectedRevision compatibility', () {
    final response = cli.handleRequest({
      'operation': 'applyMove',
      'state': initialStateJson(),
      'expectedRevision': 0,
      'move': {'player': 'black', 'row': 0, 'column': 0},
    });

    expect(response['ok'], isTrue);
  });

  test('rule violations use the stable error envelope', () {
    final response = cli.handleRequest({
      'op': 'applyMove',
      'state': initialStateJson(),
      'move': {'player': 'black', 'row': 9, 'column': 9, 'expectedRevision': 0},
    });

    expect(response.keys, {'ok', 'error'});
    expect(response['ok'], isFalse);
    final error = Map<String, Object?>.from(response['error']! as Map);
    expect(error.keys, {'code', 'message'});
    expect(error['code'], 'occupied');
  });

  test('passing is explicitly rejected', () {
    final response = cli.handleRequest({
      'op': 'applyMove',
      'state': initialStateJson(),
      'move': {'pass': true},
    });

    expect(response['ok'], isFalse);
    expect((response['error']! as Map)['code'], 'passNotAllowed');
  });

  test('evolve returns a board and simultaneous delta', () {
    final board = Board(
      rows: 3,
      columns: 3,
      cells: const [
        CellState.empty,
        CellState.empty,
        CellState.empty,
        CellState.black,
        CellState.black,
        CellState.black,
        CellState.empty,
        CellState.empty,
        CellState.empty,
      ],
    );
    final response = cli.handleRequest({
      'op': 'evolve',
      'board': board.toJson(),
    });

    expect(response['ok'], isTrue);
    final result = resultOf(response);
    final evolved = Board.fromJson(result['board']);
    expect(evolved.at(0, 1), CellState.black);
    expect(evolved.at(1, 1), CellState.black);
    expect(evolved.at(2, 1), CellState.black);
    expect(result['delta'], isA<Map>());
  });

  test('replay fills deterministic player and revision defaults', () {
    final response = cli.handleRequest({
      'op': 'replay',
      'moves': [
        {'row': 0, 'column': 0},
        {'row': 0, 'column': 0},
      ],
    });

    expect(response['ok'], isTrue);
    final result = resultOf(response);
    final state = GameState.fromJson(result['state']);
    expect(state.ply, 2);
    expect(state.toMove, Player.black);
    expect(result['turns'], hasLength(2));
  });

  test('malformed JSON does not throw or poison the stream', () {
    final response = jsonDecode(cli.handleLine('{not json')) as Map;

    expect(response['ok'], isFalse);
    expect((response['error'] as Map)['code'], 'invalidJson');

    final next = jsonDecode(cli.handleLine('{"op":"initial"}')) as Map;
    expect(next['ok'], isTrue);
  });

  test('unknown operations are typed errors', () {
    final response = cli.handleRequest({'op': 'explode'});

    expect(response['ok'], isFalse);
    expect((response['error']! as Map)['code'], 'unsupportedCommand');
  });
}
