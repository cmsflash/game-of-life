import 'dart:convert';
import 'dart:io';

import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

void main(List<String> arguments) {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }

    const agent = GreedyAgent();
    const runner = AiMatchRunner(black: agent, white: agent);
    final rules = GameRules.standard(
      victory: TurnLimitPopulationVictory(options.maxPlies),
    );
    final result = runner.play(rules: rules, safetyMaxPlies: options.maxPlies);
    final output = result.toJson(includeTurns: options.trace);
    stdout.writeln(
      options.pretty
          ? const JsonEncoder.withIndent('  ').convert(output)
          : jsonEncode(output),
    );
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    stderr.write(_usage);
    exitCode = 64;
  } on ArgumentError catch (error) {
    stderr.writeln('error: ${error.message ?? error}');
    stderr.write(_usage);
    exitCode = 64;
  }
}

final class _Options {
  const _Options({
    required this.maxPlies,
    required this.trace,
    required this.pretty,
    required this.help,
  });

  final int maxPlies;
  final bool trace;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var maxPlies = 100;
    var trace = false;
    var pretty = false;
    var help = false;
    for (final argument in arguments) {
      if (argument == '--trace') {
        trace = true;
      } else if (argument == '--pretty') {
        pretty = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument.startsWith('--max-plies=')) {
        final value = argument.substring('--max-plies='.length);
        maxPlies =
            int.tryParse(value) ??
            (throw FormatException('invalid --max-plies value: $value'));
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }
    if (maxPlies <= 0 || maxPlies.isOdd) {
      throw ArgumentError.value(
        maxPlies,
        '--max-plies',
        'must be a positive even integer',
      );
    }
    return _Options(
      maxPlies: maxPlies,
      trace: trace,
      pretty: pretty,
      help: help,
    );
  }
}

const _usage = '''
Run a deterministic greedy-vs-greedy Life Duel experiment.

Usage:
  dart run bin/greedy_match.dart [options]

Options:
  --max-plies=N  Turn-limit population victory bound (default: 100).
  --trace        Include every move and search diagnostics in the output.
  --pretty       Pretty-print the JSON output.
  -h, --help     Show this help.
''';
