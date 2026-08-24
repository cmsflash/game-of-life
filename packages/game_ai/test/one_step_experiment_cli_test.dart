import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('default strategy selection runs all nine ordered pairings', () async {
    final result = await _runCli(['--games-per-matchup=1', '--max-plies=2']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['totalGames'], 9);
    expect(output['matchups'], hasLength(9));
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
    expect(matchup['blackStrategy'], 'maxSelfCells');
    expect(matchup['whiteStrategy'], 'minOpponentCells');
    expect(matchup['games'], 2);
    expect(matchup['trials'], hasLength(2));
  });

  test('one-sided and invalid strategy options fail with usage', () async {
    for (final arguments in [
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
  ['run', 'bin/one_step_experiment.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
