import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
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
    final trialIds = options.trialIds;
    final trials = List<Map<String, Object?>?>.filled(trialIds.length, null);
    var nextIndex = 0;

    Future<void> runWorker() async {
      while (nextIndex < trialIds.length) {
        final index = nextIndex++;
        final trial = trialIds[index];
        trials[index] = await Isolate.run(
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
        math.min(options.concurrency, trialIds.length),
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
        black: _OneStepMaxSelfAgent(tieBreakSeed: blackSeed),
        white: _OneStepMaxSelfAgent(tieBreakSeed: whiteSeed),
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
    'experiment': 'oneStepMaxSelfSelfPlayElimination',
    'definition': 'both players maximize their own population after one ply',
    'victoryRule': 'elimination',
    'games': options.trialIds.length,
    'trialIds': options.trialIds,
    'baseSeed': options.baseSeed,
    'tieBreakMethod': 'seededSha256AmongEqualBestSuccessors',
    'safetyMaxPlies': options.safetyMaxPlies,
    'parallelWorkers': math.min(options.concurrency, options.trialIds.length),
    'elapsedMilliseconds': elapsedMilliseconds,
    'completedGames': options.trialIds.length - truncated,
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

final class _OneStepMaxSelfAgent implements GameAgent {
  _OneStepMaxSelfAgent({required this.tieBreakSeed})
    : _analyzer = OneStepMaxDifferenceAgent(tieBreakSeed: tieBreakSeed);

  @override
  String get name => 'one-step-max-self';

  final int tieBreakSeed;
  final OneStepMaxDifferenceAgent _analyzer;

  @override
  AgentDecision chooseMove(GameState state) {
    final candidates = _analyzer.analyze(state);
    final bestScore = candidates
        .map((candidate) => candidate.evaluation.selfCells)
        .reduce(math.max);
    final tiedBest = candidates
        .where((candidate) => candidate.evaluation.selfCells == bestScore)
        .toList(growable: false);
    final selected = tiedBest[_tieBreakIndex(state, tiedBest.length)];
    return _MaxSelfDecision(
      move: selected.representativeMove,
      selfCells: selected.evaluation.selfCells,
      opponentCells: selected.evaluation.opponentCells,
      tiedBestSuccessorCount: tiedBest.length,
      tieBreakSeed: tieBreakSeed,
    );
  }

  int _tieBreakIndex(GameState state, int candidateCount) {
    if (candidateCount == 1) return 0;
    final digest = sha256.convert(
      utf8.encode('$tieBreakSeed:${state.stateHash}:maxSelfCells'),
    );
    final prefix = digest.bytes
        .take(8)
        .fold<int>(0, (value, byte) => (value << 8) | byte);
    return prefix % candidateCount;
  }
}

final class _MaxSelfDecision implements AgentDecision {
  const _MaxSelfDecision({
    required this.move,
    required this.selfCells,
    required this.opponentCells,
    required this.tiedBestSuccessorCount,
    required this.tieBreakSeed,
  });

  @override
  final GameMove move;
  final int selfCells;
  final int opponentCells;
  final int tiedBestSuccessorCount;
  final int tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': 'maxSelfCells',
    'searchPlies': 1,
    'evaluation': {
      'selfCells': selfCells,
      'opponentCells': opponentCells,
      'cellAdvantage': selfCells - opponentCells,
    },
    'tiedBestSuccessorCount': tiedBestSuccessorCount,
    'tieBreakSeed': tieBreakSeed,
  };
}

final class _Options {
  const _Options({
    required this.trialIds,
    required this.safetyMaxPlies,
    required this.baseSeed,
    required this.concurrency,
    required this.outputPath,
    required this.pretty,
    required this.help,
  });

  final List<int> trialIds;
  final int safetyMaxPlies;
  final int baseSeed;
  final int concurrency;
  final String? outputPath;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var games = 100;
    var gamesProvided = false;
    List<int>? trialIds;
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
        gamesProvided = true;
      } else if (argument.startsWith('--trial-ids=')) {
        if (trialIds != null) {
          throw const FormatException('--trial-ids may be provided only once');
        }
        trialIds = _trialIdsValue(argument.substring('--trial-ids='.length));
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
    if (gamesProvided && trialIds != null) {
      throw const FormatException('--games and --trial-ids cannot be combined');
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
      trialIds: List<int>.unmodifiable(
        trialIds ?? List<int>.generate(games, (trial) => trial),
      ),
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

  static List<int> _trialIdsValue(String value) {
    if (value.isEmpty) {
      throw const FormatException('--trial-ids requires at least one ID');
    }
    final ids = <int>[];
    for (final part in value.split(',')) {
      final id = int.tryParse(part);
      if (id == null || id < 0) {
        throw FormatException('invalid --trial-ids value: $value');
      }
      if (ids.contains(id)) {
        throw FormatException('duplicate trial ID: $id');
      }
      ids.add(id);
    }
    return ids;
  }
}

const _usage = '''
Run one-step Max Self self-play under elimination-only rules.

Usage:
  dart run bin/max_self_elimination_experiment.dart [options]

Options:
  --games=N              Number of seeded trials (default: 100).
  --trial-ids=I,J,...    Run exact original trial IDs instead of --games.
  --safety-max-plies=N   Report an active game as truncated here (default: 1000).
  --base-seed=N          First Black tie-break seed (default: 0).
  --concurrency=N        Parallel game workers (default: processor count).
  --output=PATH          Write complete JSON data to this path.
  --pretty               Pretty-print JSON output.
  -h, --help             Show this help.
''';
