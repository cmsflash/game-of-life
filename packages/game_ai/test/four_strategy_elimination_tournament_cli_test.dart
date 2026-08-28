import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('runs the complete ordered 4x4 matrix', () async {
    final result = await _runCli([
      '--games-per-cell=1',
      '--safety-max-plies=2',
      '--base-seed=0',
      '--concurrency=4',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['victoryRule'], 'elimination');
    expect(output['plannedGames'], 16);
    expect(output['recordedGames'], 16);
    expect(output['runComplete'], isTrue);
    expect(output['matchups'] as List<Object?>, hasLength(16));
    expect(output['trials'] as List<Object?>, hasLength(16));
  });

  test('Max Self reproduces the historical seeded trajectory', () async {
    final result = await _runCli([
      '--black-strategy=max-self',
      '--white-strategy=max-self',
      '--games-per-cell=1',
      '--safety-max-plies=10',
      '--base-seed=0',
      '--concurrency=1',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    final trial = (output['trials']! as List<Object?>).single!;
    expect(
      (trial as Map<String, Object?>)['finalStateHash'],
      'd45cf780dae45d230e90b32daa72611f9476c77ed1e0b098fff4c1f4c9084a13',
    );
  });

  test('resumes an atomic checkpoint without duplicating trials', () async {
    final directory = await Directory.systemTemp.createTemp(
      'four-strategy-tournament-test.',
    );
    final outputPath = '${directory.path}/checkpoint.json';
    try {
      final arguments = [
        '--black-strategy=min-theirs',
        '--white-strategy=min-theirs',
        '--games-per-cell=1',
        '--safety-max-plies=2',
        '--base-seed=0',
        '--concurrency=1',
        '--output=$outputPath',
        '--pretty',
      ];
      final first = await _runCli(arguments);
      expect(first.exitCode, 0, reason: first.stderr as String);

      final resumed = await _runCli([...arguments, '--resume']);
      expect(resumed.exitCode, 0, reason: resumed.stderr as String);
      final output = (jsonDecode(await File(outputPath).readAsString()) as Map)
          .cast<String, Object?>();
      expect(output['recordedGames'], 1);
      expect(output['pendingGames'], 0);
      expect(output['runComplete'], isTrue);
      expect(output['trials'] as List<Object?>, hasLength(1));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('invalid options fail with usage', () async {
    for (final arguments in [
      ['--games-per-cell=0'],
      ['--safety-max-plies=0'],
      ['--base-seed=-1'],
      ['--concurrency=0'],
      ['--progress-every=0'],
      ['--resume'],
      ['--black-strategy=max-self'],
      ['--black-strategy=nope', '--white-strategy=max-self'],
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
  ['run', 'bin/four_strategy_elimination_tournament.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
