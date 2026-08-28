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

  test('memory-efficient replay preserves the recorded trajectory', () async {
    final result = await _runCli([
      '--trial-ids=48',
      '--safety-max-plies=10',
      '--base-seed=0',
      '--concurrency=1',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    final trial = (output['trials']! as List<Object?>).single!;
    expect(
      (trial as Map<String, Object?>)['finalStateHash'],
      'b07a24bf2de87e7aef6844968b051b6cd8a65836e9f26297b8b8d20df7128ba5',
    );
  });

  test('reports exact progress without contaminating JSON output', () async {
    final result = await _runCli([
      '--trial-ids=52',
      '--safety-max-plies=10',
      '--base-seed=0',
      '--concurrency=1',
      '--progress-every=5',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['trialIds'], [52]);
    expect(
      result.stderr as String,
      contains('Trial 52 reached 5 plies (Black 10, White 4).'),
    );
    expect(
      result.stderr as String,
      contains('Trial 52 reached 10 plies (Black 17, White 5).'),
    );
  });

  test('invalid numeric options fail with usage', () async {
    for (final arguments in [
      ['--games=0'],
      ['--safety-max-plies=nope'],
      ['--base-seed=-1'],
      ['--concurrency=0'],
      ['--progress-every=0'],
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
