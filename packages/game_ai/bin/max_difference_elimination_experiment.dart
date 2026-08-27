import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }

    final stopwatch = Stopwatch()..start();
    final trials = List<Map<String, Object?>?>.filled(options.games, null);
    var nextTrial = 0;

    Future<void> runWorker() async {
      while (nextTrial < options.games) {
        final trial = nextTrial++;
        trials[trial] = await Isolate.run(
          () => _runTrial(
            trial: trial,
            baseSeed: options.baseSeed,
            safetyMaxPlies: options.safetyMaxPlies,
          ),
        );
      }
    }

    await Future.wait(
      List.generate(
        math.min(options.concurrency, options.games),
        (_) => runWorker(),
      ),
    );
    stopwatch.stop();

    final completedTrials = trials.cast<Map<String, Object?>>();
    final document = _resultDocument(
      options: options,
      trials: completedTrials,
      elapsedMilliseconds: stopwatch.elapsedMilliseconds,
    );
    final encoder = options.pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    final output = '${encoder.convert(document)}\n';
    final outputPath = options.outputPath;
    if (outputPath == null) {
      stdout.write(output);
    } else {
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(output, flush: true);
      stderr.writeln('Experiment data written to ${file.path}');
    }
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    stderr.write(_usage);
    exitCode = 64;
  }
}

Map<String, Object?> _runTrial({
  required int trial,
  required int baseSeed,
  required int safetyMaxPlies,
}) {
  final blackSeed = baseSeed + trial * 2;
  final whiteSeed = blackSeed + 1;
  final match =
      AiMatchRunner(
        black: OneStepMaxDifferenceAgent(tieBreakSeed: blackSeed),
        white: OneStepMaxDifferenceAgent(tieBreakSeed: whiteSeed),
      ).play(
        rules: GameRules.standard(victory: const EliminationVictory()),
        safetyMaxPlies: safetyMaxPlies,
      );
  final outcome = match.finalState.outcome;
  return {
    'trial': trial,
    'blackTieBreakSeed': blackSeed,
    'whiteTieBreakSeed': whiteSeed,
    'winner': outcome?.winner?.name,
    'outcomeReason': outcome?.reason.name,
    'plies': match.finalState.ply - match.initialState.ply,
    'truncated': match.truncated,
    'blackPopulation': match.finalState.blackPopulation,
    'whitePopulation': match.finalState.whitePopulation,
    'finalPositionHash': match.finalState.positionHash,
    'finalStateHash': match.finalState.stateHash,
  };
}

Map<String, Object?> _resultDocument({
  required _Options options,
  required List<Map<String, Object?>> trials,
  required int elapsedMilliseconds,
}) {
  final plies = trials.map((trial) => trial['plies']! as int).toList()..sort();
  final truncated = trials.where((trial) => trial['truncated']! as bool).length;
  final outcomeReasons = <String, int>{};
  for (final trial in trials) {
    final reason = trial['outcomeReason'] as String?;
    if (reason != null) {
      outcomeReasons.update(reason, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return {
    'experiment': 'oneStepMaxDifferenceSelfPlayElimination',
    'definition':
        'both players maximize own-minus-opponent population after one ply',
    'victoryRule': 'elimination',
    'games': options.games,
    'baseSeed': options.baseSeed,
    'tieBreakMethod': 'seededSha256AmongEqualBestSuccessors',
    'safetyMaxPlies': options.safetyMaxPlies,
    'parallelWorkers': math.min(options.concurrency, options.games),
    'elapsedMilliseconds': elapsedMilliseconds,
    'completedGames': options.games - truncated,
    'truncatedGames': truncated,
    'outcomeReasons': outcomeReasons,
    'blackWins': _winnerCount(trials, 'black'),
    'whiteWins': _winnerCount(trials, 'white'),
    'draws': trials
        .where(
          (trial) => !(trial['truncated']! as bool) && trial['winner'] == null,
        )
        .length,
    'plies': {
      'minimum': plies.first,
      'median': _median(plies),
      'mean': plies.reduce((left, right) => left + right) / plies.length,
      'p95': _nearestRank(plies, 0.95),
      'maximum': plies.last,
    },
    'trials': trials,
  };
}

int _winnerCount(List<Map<String, Object?>> trials, String player) =>
    trials.where((trial) => trial['winner'] == player).length;

double _median(List<int> sorted) {
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle].toDouble()
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

int _nearestRank(List<int> sorted, double percentile) =>
    sorted[(percentile * sorted.length).ceil() - 1];

final class _Options {
  const _Options({
    required this.games,
    required this.safetyMaxPlies,
    required this.baseSeed,
    required this.concurrency,
    required this.outputPath,
    required this.pretty,
    required this.help,
  });

  final int games;
  final int safetyMaxPlies;
  final int baseSeed;
  final int concurrency;
  final String? outputPath;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var games = 100;
    var safetyMaxPlies = 1000;
    var baseSeed = 0;
    var concurrency = Platform.numberOfProcessors;
    String? outputPath;
    var pretty = false;
    var help = false;
    for (final argument in arguments) {
      if (argument == '--pretty') {
        pretty = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument.startsWith('--games=')) {
        games = _integerValue(argument, '--games=');
      } else if (argument.startsWith('--safety-max-plies=')) {
        safetyMaxPlies = _integerValue(argument, '--safety-max-plies=');
      } else if (argument.startsWith('--base-seed=')) {
        baseSeed = _integerValue(argument, '--base-seed=');
      } else if (argument.startsWith('--concurrency=')) {
        concurrency = _integerValue(argument, '--concurrency=');
      } else if (argument.startsWith('--output=')) {
        outputPath = argument.substring('--output='.length);
        if (outputPath.isEmpty) {
          throw const FormatException('--output requires a path');
        }
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }
    if (games <= 0) {
      throw const FormatException('--games must be positive');
    }
    if (safetyMaxPlies <= 0) {
      throw const FormatException('--safety-max-plies must be positive');
    }
    if (baseSeed < 0) {
      throw const FormatException('--base-seed must be non-negative');
    }
    if (concurrency <= 0) {
      throw const FormatException('--concurrency must be positive');
    }
    return _Options(
      games: games,
      safetyMaxPlies: safetyMaxPlies,
      baseSeed: baseSeed,
      concurrency: concurrency,
      outputPath: outputPath,
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
}

const _usage = '''
Run one-step Max Difference self-play under elimination-only rules.

Usage:
  dart run bin/max_difference_elimination_experiment.dart [options]

Options:
  --games=N              Number of seeded trials (default: 100).
  --safety-max-plies=N   Report an active game as truncated here (default: 1000).
  --base-seed=N          First Black tie-break seed (default: 0).
  --concurrency=N        Parallel game workers (default: processor count).
  --output=PATH          Write complete JSON data to this path.
  --pretty               Pretty-print JSON output.
  -h, --help             Show this help.
''';
