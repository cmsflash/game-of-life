import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('runs seeded Max Self elimination self-play in parallel', () async {
    final result = await _runCli([
      '--games=2',
      '--safety-max-plies=2',
      '--base-seed=10',
      '--concurrency=2',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['experiment'], 'oneStepMaxSelfSelfPlayElimination');
    expect(output['victoryRule'], 'elimination');
    expect(output['games'], 2);
    expect(output['parallelWorkers'], 2);
    expect(output['truncatedGames'], 2);
    final trials = output['trials']! as List<Object?>;
    expect(trials, hasLength(2));
    expect((trials.first! as Map<String, Object?>)['blackTieBreakSeed'], 10);
    expect((trials.last! as Map<String, Object?>)['whiteTieBreakSeed'], 13);
  });

  test('replays exact trial IDs with their original seeds', () async {
    final result = await _runCli([
      '--trial-ids=3,8',
      '--safety-max-plies=2',
      '--base-seed=0',
      '--concurrency=2',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['games'], 2);
    expect(output['trialIds'], [3, 8]);
    final trials = output['trials']! as List<Object?>;
    expect((trials.first! as Map<String, Object?>)['trial'], 3);
    expect((trials.first! as Map<String, Object?>)['blackTieBreakSeed'], 6);
    expect((trials.last! as Map<String, Object?>)['trial'], 8);
    expect((trials.last! as Map<String, Object?>)['whiteTieBreakSeed'], 17);
  });

  test('invalid numeric options fail with usage', () async {
    for (final arguments in [
      ['--games=0'],
      ['--safety-max-plies=nope'],
      ['--base-seed=-1'],
      ['--concurrency=0'],
      ['--trial-ids='],
      ['--trial-ids=1,1'],
      ['--trial-ids=-1'],
      ['--games=2', '--trial-ids=1,2'],
    ]) {
      final result = await _runCli(arguments);

      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr as String, contains('error:'));
      expect(result.stderr as String, contains('Usage:'));
    }
  });
}

Future<ProcessResult> _runCli(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/max_self_elimination_experiment.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
