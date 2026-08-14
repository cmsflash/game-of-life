import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('default command completes with an official bounded outcome', () async {
    final result = await _runCli();

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['initialPly'], 0);
    expect(output['finalPly'], 100);
    expect(output['safetyMaxPlies'], 100);
    expect(output['truncated'], isFalse);
    expect(output['outcome'], isA<Map<String, Object?>>());
    final outcome = output['outcome'] as Map<String, Object?>;
    expect(outcome['reason'], 'turnLimitPopulation');
  });

  test('--trace includes every decision and evolution delta', () async {
    final result = await _runCli(['--max-plies=2', '--trace']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    final turns = output['turns'] as List<Object?>;
    expect(turns, hasLength(2));
    final firstTurn = turns.first as Map<String, Object?>;
    expect(firstTurn['decision'], isA<Map<String, Object?>>());
    expect(firstTurn['delta'], isA<Map<String, Object?>>());
  });

  test('invalid and odd max plies fail with usage exit code', () async {
    for (final argument in ['--max-plies=nope', '--max-plies=3']) {
      final result = await _runCli([argument]);

      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr as String, contains('error:'));
      expect(result.stderr as String, contains('Usage:'));
    }
  });

  test('--help prints usage and exits successfully', () async {
    final result = await _runCli(['--help']);

    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('Usage:'));
    expect(result.stderr, isEmpty);
  });
}

Future<ProcessResult> _runCli([List<String> arguments = const []]) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/greedy_match.dart',
      ...arguments,
    ], workingDirectory: Directory.current.path);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
