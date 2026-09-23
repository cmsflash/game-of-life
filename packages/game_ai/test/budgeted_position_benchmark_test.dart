import 'dart:convert';
import 'dart:io';

import 'package:game_engine/game_engine.dart';
import 'package:test/test.dart';

import '../bin/budgeted_position_benchmark.dart' as benchmark;

void main() {
  test('replays a requested prefix and validates the later endpoint', () {
    final checkpoint = _checkpoint(4);
    final prefix = benchmark.replayCheckpointPrefix(checkpoint, 2);
    expect(prefix.ply, 2);
    expect(prefix.isActive, isTrue);
    expect(prefix.toJson(), _checkpoint(2)['state']);
    expect(benchmark.replayCheckpointPrefix(checkpoint, 0).ply, 0);
    final altered = _checkpoint(4);
    (altered['moves']! as List).last['player'] = 'black';
    expect(
      () => benchmark.replayCheckpointPrefix(altered, 2),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('illegal history'),
        ),
      ),
    );
  });

  test(
    'rejects unavailable prefix, non-elimination, state and history corruption',
    () {
      for (final invalid in [-1, 5]) {
        expect(
          () => benchmark.replayCheckpointPrefix(_checkpoint(4), invalid),
          throwsFormatException,
        );
      }
      for (final corrupt in <void Function(Map<String, Object?>)>[
        (value) => value['evaluationVersion'] = 'old',
        (value) => value['runnerVersion'] = 'old',
        (value) => value['sourceRevision'] = '',
        (value) => value['finalStateHash'] = 'wrong',
        (value) => value['plies'] = 9,
        (value) => (value['moves']! as List).first['row'] = 100,
        (value) => (value['moves']! as List).first['row'] = '0',
        (value) {
          (value['moves']! as List).first['row'] = 9;
          (value['moves']! as List).first['column'] = 9;
        },
      ]) {
        final checkpoint = _checkpoint(4);
        corrupt(checkpoint);
        expect(
          () => benchmark.replayCheckpointPrefix(checkpoint, 2),
          throwsFormatException,
        );
      }
      final nonElimination = _checkpoint(
        0,
        rules: GameRules.standard(victory: TurnLimitPopulationVictory(10)),
      );
      expect(
        () => benchmark.replayCheckpointPrefix(nonElimination, 0),
        throwsFormatException,
      );
    },
  );

  test(
    'all 30 comparisons reuse identical state, fixed seed and strict ceilings',
    () {
      final state = benchmark.replayCheckpointPrefix(_checkpoint(2), 2);
      final before = state.toJson();
      final results = benchmark
          .benchmarkPosition(state, budgets: [400, 401, 500])
          .toList();
      expect(results, hasLength(30));
      expect(state.toJson(), before);
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        expect(result['name'], benchmark.benchmarkProfiles[index % 10].id);
        expect(result['transitionBudget'], [400, 401, 500][index ~/ 10]);
        expect(result['stateHash'], state.stateHash);
        expect(result['positionHash'], state.positionHash);
        expect(result['tieBreakSeed'], 9000000);
        expect(result['evaluationVersion'], 'terminalUtilityV1');
        expect(
          result['successorEvaluations'],
          inInclusiveRange(1, result['transitionBudget']! as int),
        );
        final move = GameMove.fromJson(result['move']);
        expect(const GameEngine().validateMove(state, move).isValid, isTrue);
      }
      final repeated = benchmark
          .benchmarkPosition(state, budgets: [400])
          .toList();
      for (var index = 0; index < 10; index++) {
        expect(_withoutTime(repeated[index]), _withoutTime(results[index]));
      }
    },
  );

  test(
    'CLI help and invalid prefix do not produce or overwrite artifacts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'position-benchmark-test.',
      );
      addTearDown(() => directory.delete(recursive: true));
      final checkpoint = File('${directory.path}/checkpoint.json');
      await checkpoint.writeAsString(jsonEncode(_checkpoint(2)));
      final original = await checkpoint.readAsString();
      final output = File('${directory.path}/output.json');
      Future<ProcessResult> run(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/budgeted_position_benchmark.dart', ...args],
      );
      final help = await run(['--help']);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('Runs serially'));
      final invalid = await run([
        '--checkpoint=${checkpoint.path}',
        '--plies=3',
        '--output=${output.path}',
      ]);
      expect(invalid.exitCode, 64, reason: '${invalid.stderr}');
      expect(invalid.stderr, contains('requested prefix'));
      expect(output.existsSync(), isFalse);
      final overwrite = await run([
        '--checkpoint=${checkpoint.path}',
        '--plies=1',
        '--output=${checkpoint.path}',
      ]);
      expect(overwrite.exitCode, 64);
      expect(overwrite.stderr, contains('already exists'));
      expect(await checkpoint.readAsString(), original);
    },
  );
}

Map<String, Object?> _withoutTime(Map<String, Object?> value) => {
  for (final entry in value.entries)
    if (entry.key != 'elapsedMicroseconds') entry.key: entry.value,
};

Map<String, Object?> _checkpoint(int plies, {GameRules? rules}) {
  const engine = GameEngine();
  var state = engine.initialState(rules ?? GameRules.standard());
  final moves = <Map<String, Object?>>[];
  for (var index = 0; index < plies; index++) {
    // A remote placement dies immediately, leaving the stable opening intact.
    final move = GameMove(
      player: state.toMove!,
      row: 0,
      column: 0,
      expectedRevision: state.revision,
    );
    moves.add({
      'player': move.player.name,
      'row': move.row,
      'column': move.column,
    });
    state = engine.applyMove(state, move).state;
  }
  return {
    'runnerVersion': 'budgetedSearchTournamentV1',
    'evaluationVersion': 'terminalUtilityV1',
    'sourceRevision': 'test-source',
    'plies': plies,
    'finalStateHash': state.stateHash,
    'state': state.toJson(),
    'moves': moves,
  };
}
