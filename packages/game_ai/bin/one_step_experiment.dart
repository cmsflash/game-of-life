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
    final blackProfile = options.blackProfile;
    final result = blackProfile == null
        ? runner.runMatrix(
            profiles: options.pureOnly
                ? OneStepExperimentProfile.pureProfiles
                : OneStepExperimentProfile.allProfiles,
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
                blackProfile: blackProfile,
                whiteProfile: options.whiteProfile!,
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
    required this.blackProfile,
    required this.whiteProfile,
    required this.pureOnly,
    required this.includeTrials,
    required this.pretty,
    required this.help,
  });

  final int gamesPerMatchup;
  final int maxPlies;
  final int baseSeed;
  final OneStepExperimentProfile? blackProfile;
  final OneStepExperimentProfile? whiteProfile;
  final bool pureOnly;
  final bool includeTrials;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var gamesPerMatchup = 20;
    var maxPlies = 100;
    var baseSeed = 0;
    OneStepExperimentProfile? blackProfile;
    OneStepExperimentProfile? whiteProfile;
    var pureOnly = false;
    var includeTrials = false;
    var pretty = false;
    var help = false;

    for (final argument in arguments) {
      if (argument == '--include-trials') {
        includeTrials = true;
      } else if (argument == '--pure-only') {
        pureOnly = true;
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
        blackProfile = _profileValue(argument, '--black-strategy=');
      } else if (argument.startsWith('--white-strategy=')) {
        whiteProfile = _profileValue(argument, '--white-strategy=');
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }

    if ((blackProfile == null) != (whiteProfile == null)) {
      throw const FormatException(
        '--black-strategy and --white-strategy must be provided together',
      );
    }
    if (pureOnly && blackProfile != null) {
      throw const FormatException(
        '--pure-only cannot be combined with a single pairing',
      );
    }
    return _Options(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      blackProfile: blackProfile,
      whiteProfile: whiteProfile,
      pureOnly: pureOnly,
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

  static OneStepExperimentProfile _profileValue(
    String argument,
    String prefix,
  ) {
    final value = argument.substring(prefix.length);
    return switch (value) {
      'max-self' || 'maxSelfCells' => OneStepExperimentProfile.maxSelf,
      'min-theirs' || 'minOpponentCells' => OneStepExperimentProfile.minTheirs,
      'max-difference' ||
      'maxCellAdvantage' => OneStepExperimentProfile.maxDifference,
      'mixed' || 'equalMix' => OneStepExperimentProfile.equalMix,
      _ => throw FormatException('invalid strategy profile: $value'),
    };
  }
}

const _usage = '''
Run reproducible one-step strategy experiments without Flutter.

Usage:
  dart run bin/one_step_experiment.dart [options]

Options:
  --games-per-matchup=N       Trials per ordered strategy pairing (default: 20).
  --max-plies=N               Positive even turn limit (default: 100).
  --base-seed=N               First non-negative tie-break seed (default: 0).
  --black-strategy=STRATEGY   Limit the experiment to one Black strategy.
  --white-strategy=STRATEGY   Limit the experiment to one White strategy.
  --pure-only                 Run only the original three pure strategies.
  --include-trials            Include seeds and outcomes for every game.
  --pretty                    Pretty-print the JSON output.
  -h, --help                  Show this help.

Strategies:
  max-self, min-theirs, max-difference, mixed (34/33/33)

Omit both strategy options to run all 16 ordered pairings. When selecting a
single pairing, provide both --black-strategy and --white-strategy. Use
--pure-only to reproduce the original nine-pairing pure-strategy matrix.
''';
