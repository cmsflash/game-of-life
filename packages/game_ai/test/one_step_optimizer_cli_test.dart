import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('quick command runs the complete optimization pipeline', () async {
    final result = await _runCli(['--quick']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = _decodeOutput(result);
    expect(output['experiment'], 'oneStepAdaptiveMixtureOptimization');
    expect(output['iterations'], hasLength(1));
    expect(output['recommendedBlack'], isA<Map<String, Object?>>());
    expect(output['recommendedWhite'], isA<Map<String, Object?>>());
    expect(output['validations'], isNotEmpty);
  });

  test('invalid concurrency fails with usage', () async {
    final result = await _runCli(['--quick', '--concurrency=0']);

    expect(result.exitCode, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr as String, contains('error:'));
    expect(result.stderr as String, contains('Usage:'));
  });

  test('--help describes the adaptive optimizer', () async {
    final result = await _runCli(['--help']);

    expect(result.exitCode, 0);
    expect(result.stdout as String, contains('adaptive optimization'));
    expect(result.stderr, isEmpty);
  });
}

Future<ProcessResult> _runCli(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/one_step_optimize.dart', ...arguments],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _decodeOutput(ProcessResult result) =>
    (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
