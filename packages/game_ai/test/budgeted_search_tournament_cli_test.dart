import 'dart:convert';
import 'dart:io';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File config;
  late String output;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'budgeted-tournament-test.',
    );
    config = File('${directory.path}/input.json');
    output = '${directory.path}/study';
  });
  tearDown(() => directory.delete(recursive: true));

  Future<ProcessResult> run({bool resume = false, int concurrency = 2}) =>
      _runCli([
        '--config=${config.path}',
        '--output-dir=$output',
        '--concurrency=$concurrency',
        if (resume) '--resume',
      ]);

  test(
    'runs tiny-budget ordered games and censors without awarding draws',
    () async {
      await config.writeAsString(jsonEncode(_config(gamesPerCell: 2)));
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final summary = _read(File('$output/summary.json'));
      expect(summary['evaluationVersion'], 'terminalUtilityV1');
      expect(summary['victoryRule'], 'elimination');
      expect(summary['plannedGames'], 4);
      expect(summary['recordedGames'], 4);
      expect(summary['completedGames'], 0);
      expect(summary['truncatedGames'], 4);
      expect(summary['pendingGames'], 0);
      expect(summary['failedGames'], 0);
      expect(summary['draws'], 0);
      expect(summary['runComplete'], isTrue);
      for (final compact in (summary['games']! as List).cast<Map>()) {
        expect(compact['status'], 'truncated');
        expect(compact['winner'], isNull);
        expect(compact['outcomeReason'], isNull);
        final game = _read(
          File(
            '$output/games/${compact['blackProfile']}__${compact['whiteProfile']}__${compact['trial']}.json',
          ),
        );
        expect(game['plies'], 4);
        for (final move in (game['moves']! as List).cast<Map>()) {
          expect(move['successorEvaluations'], inInclusiveRange(1, 400));
          expect(move['completedDepth'], 1);
        }
      }
    },
  );

  test(
    'completed run resume is byte-preserving and does not duplicate games',
    () async {
      await config.writeAsString(jsonEncode(_config()));
      final first = await run();
      expect(first.exitCode, 0, reason: '${first.stderr}');
      final before = _snapshot(Directory(output));
      final resumed = await run(resume: true);
      expect(resumed.exitCode, 0, reason: '${resumed.stderr}');
      expect(_snapshot(Directory(output)), before);
      expect(resumed.stderr, isEmpty);
      final refused = await run();
      expect(refused.exitCode, 64);
      expect(refused.stderr, contains('not empty'));
      expect(_snapshot(Directory(output)), before);
    },
  );

  test(
    'continues an active or error checkpoint from its exact saved prefix',
    () async {
      await config.writeAsString(jsonEncode(_config(safetyMaxPlies: 8)));
      final first = await run(concurrency: 1);
      expect(first.exitCode, 0, reason: '${first.stderr}');
      final gameFile = File('$output/games/D1__D2__0.json');
      final original = _read(gameFile);
      for (final status in ['active', 'error']) {
        final prefix = _prefix(original, 3, status: status);
        await gameFile.writeAsString(jsonEncode(prefix));
        final resumed = await run(resume: true);
        expect(resumed.exitCode, 0, reason: '${resumed.stderr}');
        final actual = _read(gameFile);
        expect(actual['state'], original['state']);
        expect(actual['plies'], original['plies']);
        expect(actual['status'], original['status']);
        expect(actual.containsKey('error'), isFalse);
        expect(actual.containsKey('stackTrace'), isFalse);
        final actualMoves = (actual['moves']! as List).cast<Map>();
        final expectedMoves = (original['moves']! as List).cast<Map>();
        expect(actualMoves.take(3).toList(), expectedMoves.take(3).toList());
        for (var index = 0; index < expectedMoves.length; index++) {
          expect(
            _withoutTime(actualMoves[index]),
            _withoutTime(expectedMoves[index]),
          );
        }
        final summary = _read(File('$output/summary.json'));
        expect(summary['failedGames'], 0);
        expect(summary['pendingGames'], 0);
        expect(summary['recordedGames'], 2);
      }
    },
  );

  test(
    'rejects configuration and version mismatches without clobbering output',
    () async {
      final settings = _config();
      await config.writeAsString(jsonEncode(settings));
      final first = await run();
      expect(first.exitCode, 0, reason: '${first.stderr}');
      final before = _snapshot(Directory(output));
      for (final change in [
        {'baseSeed': 11},
        {'transitionBudget': 401},
        {'sourceRevision': 'different-code'},
        {'safetyMaxPlies': 5},
        {'evaluationVersion': 'old-score'},
      ]) {
        await config.writeAsString(jsonEncode({...settings, ...change}));
        final resumed = await run(resume: true);
        expect(resumed.exitCode, 64, reason: '${resumed.stderr}');
        expect(_snapshot(Directory(output)), before);
      }
    },
  );

  test(
    'rejects corrupt histories and telemetry before any output is changed',
    () async {
      await config.writeAsString(jsonEncode(_config()));
      final first = await run();
      expect(first.exitCode, 0, reason: '${first.stderr}');
      final gameFile = File('$output/games/D1__D2__0.json');
      final originalText = gameFile.readAsStringSync();
      for (final corrupt in <void Function(Map<String, Object?>)>[
        (game) => game['finalPositionHash'] = 'wrong',
        (game) => game['blackPopulation'] = 999,
        (game) => (game['moves']! as List).first['player'] = 'white',
        (game) => (game['moves']! as List).first['successorEvaluations'] = 401,
        (game) => (game['searchTotals']! as Map)['moves'] = 999,
        (game) => game['status'] = 'complete',
      ]) {
        final game = (jsonDecode(originalText) as Map).cast<String, Object?>();
        corrupt(game);
        await gameFile.writeAsString(jsonEncode(game));
        final before = _snapshot(Directory(output));
        final resumed = await run(resume: true);
        expect(resumed.exitCode, 64, reason: '${resumed.stderr}');
        expect(_snapshot(Directory(output)), before);
      }
    },
  );

  test('invalid inputs fail without creating output', () async {
    for (final invalid in [
      {..._config(), 'transitionBudget': 399},
      {..._config(), 'evaluationVersion': 'missing-fix'},
      {
        ..._config(),
        'pairings': [
          {'black': 'missing', 'white': 'D2'},
        ],
      },
    ]) {
      await config.writeAsString(jsonEncode(invalid));
      final result = await run();
      expect(result.exitCode, 64, reason: '${result.stderr}');
      expect(Directory(output).existsSync(), isFalse);
    }
    final missingFile = await _runCli([
      '--config=${directory.path}/absent.json',
      '--output-dir=$output',
    ]);
    expect(missingFile.exitCode, 1);
    expect(missingFile.stderr, contains('error:'));
    expect(Directory(output).existsSync(), isFalse);
  });
}

Map<String, Object?> _config({int gamesPerCell = 1, int safetyMaxPlies = 4}) =>
    {
      'studyId': 'budgeted-cli-test',
      'sourceRevision': 'integration-test',
      'evaluationVersion': 'terminalUtilityV1',
      'baseSeed': 0,
      'gamesPerCell': gamesPerCell,
      'safetyMaxPlies': safetyMaxPlies,
      'transitionBudget': 400,
      'profiles': [
        for (var depth = 1; depth <= 2; depth++)
          {
            'id': 'D$depth',
            'maxDepth': depth,
            'fullWidthDepth': 64,
            'beamWidth': 8,
          },
      ],
      'pairings': [
        {'black': 'D1', 'white': 'D2'},
        {'black': 'D2', 'white': 'D1'},
      ],
    };

Future<ProcessResult> _runCli(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/budgeted_search_tournament.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _read(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();

Map<String, String> _snapshot(Directory directory) => {
  for (final file in directory.listSync(recursive: true).whereType<File>())
    file.path: file.readAsStringSync(),
};

Map<Object?, Object?> _withoutTime(Map move) => {
  for (final entry in move.entries)
    if (entry.key != 'elapsedMicroseconds') entry.key: entry.value,
};

Map<String, Object?> _prefix(
  Map<String, Object?> source,
  int plies, {
  required String status,
}) {
  const engine = GameEngine();
  var state = engine.initialState(GameRules.standard());
  final moves = (source['moves']! as List).take(plies).cast<Map>().toList();
  for (final move in moves) {
    state = engine
        .applyMove(
          state,
          GameMove(
            player: Player.fromJson(move['player']),
            row: move['row'] as int,
            column: move['column'] as int,
            expectedRevision: state.revision,
          ),
        )
        .state;
  }
  final depths = <String, int>{};
  for (final move in moves) {
    depths.update(
      '${move['completedDepth']}',
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }
  return {
    ...source,
    'status': status,
    'complete': false,
    'truncated': false,
    'plies': plies,
    'winner': null,
    'outcomeReason': null,
    'blackPopulation': state.blackPopulation,
    'whitePopulation': state.whitePopulation,
    'finalPositionHash': state.positionHash,
    'finalStateHash': state.stateHash,
    'elapsedMicroseconds': 1000000,
    'searchTotals': {
      'moves': plies,
      'maxVisitedPly': moves.fold<int>(
        0,
        (maximum, move) => (move['maxVisitedPly'] as int) > maximum
            ? move['maxVisitedPly'] as int
            : maximum,
      ),
      for (final field in [
        'successorEvaluations',
        'nodesVisited',
        'cacheHits',
        'cutoffs',
        'elapsedMicroseconds',
      ])
        field: moves.fold<int>(0, (sum, move) => sum + (move[field] as int)),
      'budgetExhaustedMoves': moves
          .where((move) => move['budgetExhausted'] == true)
          .length,
      'completedDepthHistogram': depths,
    },
    if (status == 'error') 'error': 'simulated interruption after a saved move',
    if (status == 'error') 'stackTrace': 'test fixture',
    'state': state.toJson(),
    'moves': moves,
  };
}
