import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }
    final profiles = options.oneStepProfile == null
        ? OneStepExperimentProfile.allProfiles
        : [options.oneStepProfile!];
    final players = options.twoStepPlayer == null
        ? Player.values
        : [options.twoStepPlayer!];
    final specs = [
      for (final profile in profiles)
        for (final player in players)
          _MatchupSpec(
            twoStepPlayer: player,
            oneStepProfile: profile,
            games: options.gamesPerMatchup,
            maxPlies: options.maxPlies,
            baseSeed: options.baseSeed,
          ),
    ];
    final matchups = <TwoStepRepresentativeMatchupResult>[];
    for (var offset = 0; offset < specs.length; offset += options.concurrency) {
      final end = (offset + options.concurrency).clamp(0, specs.length);
      matchups.addAll(
        await Future.wait(
          specs
              .sublist(offset, end)
              .map((spec) => Isolate.run(() => _runMatchup(spec))),
        ),
      );
    }
    final result = TwoStepRepresentativeExperimentResult(
      gamesPerMatchup: options.gamesPerMatchup,
      maxPlies: options.maxPlies,
      baseSeed: options.baseSeed,
      matchups: matchups,
    );
    final encoder = options.pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    final document =
        '${encoder.convert(result.toJson(includeTrials: options.includeTrials))}\n';
    final outputPath = options.outputPath;
    if (outputPath == null) {
      stdout.write(document);
    } else {
      final output = File(outputPath);
      await output.parent.create(recursive: true);
      await output.writeAsString(document, flush: true);
      stderr.writeln('Experiment data written to ${output.path}');
    }
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

TwoStepRepresentativeMatchupResult _runMatchup(_MatchupSpec spec) =>
    const TwoStepRepresentativeExperimentRunner().runMatchup(
      twoStepPlayer: spec.twoStepPlayer,
      oneStepProfile: spec.oneStepProfile,
      games: spec.games,
      maxPlies: spec.maxPlies,
      baseSeed: spec.baseSeed,
    );

final class _MatchupSpec {
  const _MatchupSpec({
    required this.twoStepPlayer,
    required this.oneStepProfile,
    required this.games,
    required this.maxPlies,
    required this.baseSeed,
  });

  final Player twoStepPlayer;
  final OneStepExperimentProfile oneStepProfile;
  final int games;
  final int maxPlies;
  final int baseSeed;
}

final class _Options {
  const _Options({
    required this.gamesPerMatchup,
    required this.maxPlies,
    required this.baseSeed,
    required this.concurrency,
    required this.oneStepProfile,
    required this.twoStepPlayer,
    required this.outputPath,
    required this.includeTrials,
    required this.pretty,
    required this.help,
  });

  final int gamesPerMatchup;
  final int maxPlies;
  final int baseSeed;
  final int concurrency;
  final OneStepExperimentProfile? oneStepProfile;
  final Player? twoStepPlayer;
  final String? outputPath;
  final bool includeTrials;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var gamesPerMatchup = 20;
    var maxPlies = 100;
    var baseSeed = 2000000;
    var concurrency = Platform.numberOfProcessors.clamp(1, 8);
    OneStepExperimentProfile? oneStepProfile;
    Player? twoStepPlayer;
    String? outputPath;
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
      } else if (argument.startsWith('--concurrency=')) {
        concurrency = _integerValue(argument, '--concurrency=');
      } else if (argument.startsWith('--one-step-profile=')) {
        oneStepProfile = _profileValue(argument);
      } else if (argument.startsWith('--two-step-color=')) {
        twoStepPlayer = _playerValue(argument);
      } else if (argument.startsWith('--output=')) {
        outputPath = argument.substring('--output='.length);
        if (outputPath.isEmpty) {
          throw const FormatException('--output requires a path');
        }
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }
    if (gamesPerMatchup <= 0) {
      throw const FormatException('--games-per-matchup must be positive');
    }
    if (maxPlies <= 0 || maxPlies.isOdd) {
      throw const FormatException(
        '--max-plies must be a positive even integer',
      );
    }
    if (baseSeed < 0) {
      throw const FormatException('--base-seed must be non-negative');
    }
    if (concurrency <= 0) {
      throw const FormatException('--concurrency must be positive');
    }
    return _Options(
      gamesPerMatchup: gamesPerMatchup,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      concurrency: concurrency,
      oneStepProfile: oneStepProfile,
      twoStepPlayer: twoStepPlayer,
      outputPath: outputPath,
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

  static OneStepExperimentProfile _profileValue(String argument) {
    final value = argument.substring('--one-step-profile='.length);
    return switch (value) {
      'max-self' => OneStepExperimentProfile.maxSelf,
      'min-theirs' => OneStepExperimentProfile.minTheirs,
      'max-difference' => OneStepExperimentProfile.maxDifference,
      'mixed' => OneStepExperimentProfile.equalMix,
      _ => throw FormatException('invalid one-step profile: $value'),
    };
  }

  static Player _playerValue(String argument) {
    final value = argument.substring('--two-step-color='.length);
    return switch (value) {
      'black' => Player.black,
      'white' => Player.white,
      _ => throw FormatException('invalid two-step color: $value'),
    };
  }
}

const _usage = '''
Run the two-step max-difference AI against representative one-step profiles.

Usage:
  dart run bin/two_step_experiment.dart [options]

Options:
  --games-per-matchup=N       Trials per color/profile pairing (default: 20).
  --max-plies=N               Positive even turn limit (default: 100).
  --base-seed=N               First tie-break seed (default: 2000000).
  --concurrency=N             Parallel matchup workers (default: up to 8).
  --one-step-profile=PROFILE  Run only one representative profile.
  --two-step-color=COLOR      Run only Black or White for the two-step AI.
  --output=PATH               Write JSON data to this path.
  --include-trials            Include seeds and outcomes for every game.
  --pretty                    Pretty-print JSON output.
  -h, --help                  Show this help.

Profiles: max-self, min-theirs, max-difference, mixed
Colors: black, white
''';
