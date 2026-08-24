import 'dart:convert';
import 'dart:io';

import 'package:game_ai/game_ai.dart';

void main(List<String> arguments) {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }

    const runner = OneStepExperimentRunner();
    final blackStrategy = options.blackStrategy;
    final result = blackStrategy == null
        ? runner.runMatrix(
            gamesPerMatchup: options.gamesPerMatchup,
            maxPlies: options.maxPlies,
            baseSeed: options.baseSeed,
          )
        : OneStepExperimentResult(
            gamesPerMatchup: options.gamesPerMatchup,
            maxPlies: options.maxPlies,
            baseSeed: options.baseSeed,
            matchups: [
              runner.runMatchup(
                blackStrategy: blackStrategy,
                whiteStrategy: options.whiteStrategy!,
                games: options.gamesPerMatchup,
                maxPlies: options.maxPlies,
                baseSeed: options.baseSeed,
              ),
            ],
          );
    final output = result.toJson(includeTrials: options.includeTrials);
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
    required this.gamesPerMatchup,
    required this.maxPlies,
    required this.baseSeed,
    required this.blackStrategy,
    required this.whiteStrategy,
    required this.includeTrials,
    required this.pretty,
    required this.help,
  });

  final int gamesPerMatchup;
  final int maxPlies;
  final int baseSeed;
  final OneStepGreedyStrategy? blackStrategy;
  final OneStepGreedyStrategy? whiteStrategy;
  final bool includeTrials;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var gamesPerMatchup = 20;
    var maxPlies = 100;
    var baseSeed = 0;
    OneStepGreedyStrategy? blackStrategy;
    OneStepGreedyStrategy? whiteStrategy;
    var includeTrials = false;
    var pretty = false;
    var help = false;

    for (final argument in arguments) {
      if (argument == '--include-trials') {
        includeTrials = true;
      } else if (argument == '--pretty') {
        pretty = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument.startsWith('--games-per-matchup=')) {
        gamesPerMatchup = _integerValue(argument, '--games-per-matchup=');
      } else if (argument.startsWith('--max-plies=')) {
        maxPlies = _integerValue(argument, '--max-plies=');
      } else if (argument.startsWith('--base-seed=')) {
        baseSeed = _integerValue(argument, '--base-seed=');
      } else if (argument.startsWith('--black-strategy=')) {
        blackStrategy = _strategyValue(argument, '--black-strategy=');
      } else if (argument.startsWith('--white-strategy=')) {
        whiteStrategy = _strategyValue(argument, '--white-strategy=');
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }

    if ((blackStrategy == null) != (whiteStrategy == null)) {
      throw const FormatException(
        '--black-strategy and --white-strategy must be provided together',
      );
    }
    return _Options(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      blackStrategy: blackStrategy,
      whiteStrategy: whiteStrategy,
      includeTrials: includeTrials,
      pretty: pretty,
      help: help,
    );
  }

  static int _integerValue(String argument, String prefix) {
    final value = argument.substring(prefix.length);
    return int.tryParse(value) ??
        (throw FormatException(
          'invalid ${prefix.substring(0, prefix.length - 1)} value: $value',
        ));
  }

  static OneStepGreedyStrategy _strategyValue(String argument, String prefix) {
    final value = argument.substring(prefix.length);
    return switch (value) {
      'max-self' || 'maxSelfCells' => OneStepGreedyStrategy.maxSelfCells,
      'min-theirs' ||
      'minOpponentCells' => OneStepGreedyStrategy.minOpponentCells,
      'max-difference' ||
      'maxCellAdvantage' => OneStepGreedyStrategy.maxCellAdvantage,
      _ => throw FormatException('invalid strategy: $value'),
    };
  }
}

const _usage = '''
Run reproducible pure one-step strategy experiments without Flutter.

Usage:
  dart run bin/one_step_experiment.dart [options]

Options:
  --games-per-matchup=N       Trials per ordered strategy pairing (default: 20).
  --max-plies=N               Positive even turn limit (default: 100).
  --base-seed=N               First non-negative tie-break seed (default: 0).
  --black-strategy=STRATEGY   Limit the experiment to one Black strategy.
  --white-strategy=STRATEGY   Limit the experiment to one White strategy.
  --include-trials            Include seeds and outcomes for every game.
  --pretty                    Pretty-print the JSON output.
  -h, --help                  Show this help.

Strategies:
  max-self, min-theirs, max-difference

Omit both strategy options to run all nine ordered pairings. When selecting a
single pairing, provide both --black-strategy and --white-strategy.
''';
