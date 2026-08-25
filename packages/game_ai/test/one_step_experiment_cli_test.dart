import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('default selection runs all 16 ordered profile pairings', () async {
    final result = await _runCli(['--games-per-matchup=1', '--max-plies=2']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['totalGames'], 16);
    expect(output['matchups'], hasLength(16));
  });

  test('Black and White strategies can be selected independently', () async {
    final result = await _runCli([
      '--games-per-matchup=2',
      '--max-plies=2',
      '--base-seed=5',
      '--black-strategy=max-self',
      '--white-strategy=min-theirs',
      '--include-trials',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    final matchups = output['matchups'] as List<Object?>;
    expect(matchups, hasLength(1));
    final matchup = matchups.single as Map<String, Object?>;
    final blackProfile = matchup['blackProfile'] as Map<String, Object?>;
    final whiteProfile = matchup['whiteProfile'] as Map<String, Object?>;
    expect(blackProfile['id'], 'maxSelf');
    expect(whiteProfile['id'], 'minTheirs');
    expect(matchup['games'], 2);
    expect(matchup['trials'], hasLength(2));
  });

  test('mixed profile and pure-only matrix are available', () async {
    final mixedResult = await _runCli([
      '--games-per-matchup=1',
      '--max-plies=2',
      '--black-strategy=mixed',
      '--white-strategy=max-difference',
    ]);
    expect(mixedResult.exitCode, 0, reason: mixedResult.stderr as String);
    final mixedOutput = _decodeOutput(mixedResult);
    final mixedMatchup =
        (mixedOutput['matchups'] as List<Object?>).single
            as Map<String, Object?>;
    expect(
      (mixedMatchup['blackProfile'] as Map<String, Object?>)['id'],
      'equalMix',
    );

    final pureResult = await _runCli([
      '--games-per-matchup=1',
      '--max-plies=2',
      '--pure-only',
    ]);
    expect(pureResult.exitCode, 0, reason: pureResult.stderr as String);
    final pureOutput = _decodeOutput(pureResult);
    expect(pureOutput['totalGames'], 9);
    expect(pureOutput['matchups'], hasLength(9));
  });

  test('one-sided and invalid strategy options fail with usage', () async {
    for (final arguments in [
      ['--black-strategy=max-self'],
      ['--black-strategy=nope', '--white-strategy=max-self'],
      [
        '--pure-only',
        '--black-strategy=max-self',
        '--white-strategy=min-theirs',
      ],
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
  ['run', 'bin/one_step_experiment.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
