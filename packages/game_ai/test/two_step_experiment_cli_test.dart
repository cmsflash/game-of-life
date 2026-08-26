import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('default selection covers four profiles in both colors', () async {
    final result = await _runCli([
      '--games-per-matchup=1',
      '--max-plies=2',
      '--concurrency=2',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['totalGames'], 8);
    expect(output['matchups'], hasLength(8));
  });

  test('profile and color can select one pairing with trials', () async {
    final result = await _runCli([
      '--games-per-matchup=1',
      '--max-plies=2',
      '--one-step-profile=max-difference',
      '--two-step-color=white',
      '--include-trials',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    final matchup =
        (output['matchups'] as List<Object?>).single as Map<String, Object?>;
    expect(matchup['twoStepPlayer'], 'white');
    expect(
      (matchup['oneStepProfile'] as Map<String, Object?>)['id'],
      'maxDifference',
    );
    expect(matchup['trials'], hasLength(1));
  });

  test('invalid profile, color, and numeric options fail with usage', () async {
    for (final arguments in [
      ['--one-step-profile=nope'],
      ['--two-step-color=green'],
      ['--games-per-matchup=nope'],
      ['--concurrency=0'],
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
  ['run', 'bin/two_step_experiment.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
