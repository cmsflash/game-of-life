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

    final strategies = options.blackStrategy == null
        ? _Strategy.values
        : [options.blackStrategy!];
    final whiteStrategies = options.whiteStrategy == null
        ? _Strategy.values
        : [options.whiteStrategy!];
    final specs = [
      for (final black in strategies)
        for (final white in whiteStrategies)
          for (var trial = 0; trial < options.gamesPerCell; trial++)
            _TrialSpec(black: black, white: white, trial: trial),
    ];
    final results = options.resume
        ? await _readCheckpoint(options: options, specs: specs)
        : <String, Map<String, Object?>>{};
    final pending = specs
        .where((spec) => !results.containsKey(spec.key))
        .toList(growable: false);
    final priorElapsedMilliseconds = await _priorElapsedMilliseconds(options);
    final stopwatch = Stopwatch()..start();
    var nextIndex = 0;
    Future<void> checkpointWrite = Future.value();

    Future<void> writeCheckpoint() {
      final outputPath = options.outputPath;
      if (outputPath == null) return Future.value();
      checkpointWrite = checkpointWrite.then(
        (_) => _writeDocument(
          outputPath: outputPath,
          options: options,
          specs: specs,
          results: results,
          elapsedMilliseconds:
              priorElapsedMilliseconds + stopwatch.elapsedMilliseconds,
        ),
      );
      return checkpointWrite;
    }

    Future<void> runWorker() async {
      while (nextIndex < pending.length) {
        final spec = pending[nextIndex++];
        final result = await Isolate.run(
          _TrialInvocation(
            spec: spec,
            baseSeed: options.baseSeed,
            safetyMaxPlies: options.safetyMaxPlies,
            progressEvery: options.progressEvery,
          ).call,
        );
        results[spec.key] = result;
        final truncated = result['truncated']! as bool;
        final winner = result['winner'] as String?;
        final outcome = truncated ? 'active' : (winner ?? 'draw');
        stderr.writeln(
          'Completed ${results.length}/${specs.length}: '
          '${spec.black.id} vs ${spec.white.id}, trial ${spec.trial}, '
          '$outcome at ${result['plies']} plies.',
        );
        await writeCheckpoint();
      }
    }

    await Future.wait(
      List.generate(
        math.min(options.concurrency, pending.length),
        (_) => runWorker(),
      ),
    );
    stopwatch.stop();
    await checkpointWrite;

    final document = _resultDocument(
      options: options,
      specs: specs,
      results: results,
      elapsedMilliseconds:
          priorElapsedMilliseconds + stopwatch.elapsedMilliseconds,
    );
    if (options.outputPath == null) {
      stdout.write('${_encode(document, pretty: options.pretty)}\n');
    } else {
      await _writeDocument(
        outputPath: options.outputPath!,
        options: options,
        specs: specs,
        results: results,
        elapsedMilliseconds:
            priorElapsedMilliseconds + stopwatch.elapsedMilliseconds,
      );
      stderr.writeln('Tournament data written to ${options.outputPath}');
    }
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    stderr.write(_usage);
    exitCode = 64;
  }
}

Map<String, Object?> _runTrial({
  required _TrialSpec spec,
  required int baseSeed,
  required int safetyMaxPlies,
  required int? progressEvery,
}) {
  final blackSeed = baseSeed + spec.trial * 2;
  final whiteSeed = blackSeed + 1;
  final black = _agent(spec.black, blackSeed);
  final white = _agent(spec.white, whiteSeed);
  const engine = GameEngine();
  final initialState = engine.initialState(
    GameRules.standard(victory: const EliminationVictory()),
  );
  var state = initialState;
  while (state.isActive && state.ply < safetyMaxPlies) {
    final agent = state.toMove == Player.black ? black : white;
    final decision = agent.chooseMove(state);
    final validation = engine.validateMove(state, decision.move);
    if (!validation.isValid) {
      throw StateError(
        'agent ${agent.name} returned an illegal move: '
        '${validation.code?.name}: ${validation.message}',
      );
    }
    state = engine.applyMove(state, decision.move).state;
    if (progressEvery != null && state.ply % progressEvery == 0) {
      stderr.writeln(
        '${spec.black.id} vs ${spec.white.id}, trial ${spec.trial}: '
        '${state.ply} plies (Black ${state.blackPopulation}, '
        'White ${state.whitePopulation}).',
      );
    }
  }
  final outcome = state.outcome;
  return {
    'blackStrategy': spec.black.id,
    'whiteStrategy': spec.white.id,
    'trial': spec.trial,
    'blackTieBreakSeed': blackSeed,
    'whiteTieBreakSeed': whiteSeed,
    'winner': outcome?.winner?.name,
    'outcomeReason': outcome?.reason.name,
    'plies': state.ply - initialState.ply,
    'truncated': state.isActive,
    'blackPopulation': state.blackPopulation,
    'whitePopulation': state.whitePopulation,
    'finalPositionHash': state.positionHash,
    'finalStateHash': state.stateHash,
  };
}

final class _TrialInvocation {
  const _TrialInvocation({
    required this.spec,
    required this.baseSeed,
    required this.safetyMaxPlies,
    required this.progressEvery,
  });

  final _TrialSpec spec;
  final int baseSeed;
  final int safetyMaxPlies;
  final int? progressEvery;

  Map<String, Object?> call() => _runTrial(
    spec: spec,
    baseSeed: baseSeed,
    safetyMaxPlies: safetyMaxPlies,
    progressEvery: progressEvery,
  );
}

GameAgent _agent(_Strategy strategy, int tieBreakSeed) => switch (strategy) {
  _Strategy.maxSelf => _OneStepObjectiveAgent(
    objective: _OneStepObjective.maxSelf,
    tieBreakSeed: tieBreakSeed,
  ),
  _Strategy.minTheirs => _OneStepObjectiveAgent(
    objective: _OneStepObjective.minTheirs,
    tieBreakSeed: tieBreakSeed,
  ),
  _Strategy.oneStepDifference => OneStepMaxDifferenceAgent(
    tieBreakSeed: tieBreakSeed,
  ),
  _Strategy.twoStepDifference => TwoStepMaxDifferenceAgent(
    tieBreakSeed: tieBreakSeed,
  ),
};

Future<Map<String, Map<String, Object?>>> _readCheckpoint({
  required _Options options,
  required List<_TrialSpec> specs,
}) async {
  final outputPath = options.outputPath;
  if (outputPath == null) {
    throw const FormatException('--resume requires --output');
  }
  final file = File(outputPath);
  if (!await file.exists()) return {};
  final document = (jsonDecode(await file.readAsString()) as Map)
      .cast<String, Object?>();
  if (document['gamesPerCell'] != options.gamesPerCell ||
      document['safetyMaxPlies'] != options.safetyMaxPlies ||
      document['baseSeed'] != options.baseSeed) {
    throw const FormatException(
      'checkpoint configuration does not match requested tournament',
    );
  }
  final validKeys = specs.map((spec) => spec.key).toSet();
  final results = <String, Map<String, Object?>>{};
  for (final value in document['trials']! as List<Object?>) {
    final result = (value! as Map).cast<String, Object?>();
    final key = _resultKey(result);
    if (!validKeys.contains(key)) {
      throw const FormatException(
        'checkpoint contains a trial outside the requested tournament',
      );
    }
    results[key] = result;
  }
  return results;
}

Future<int> _priorElapsedMilliseconds(_Options options) async {
  if (!options.resume || options.outputPath == null) return 0;
  final file = File(options.outputPath!);
  if (!await file.exists()) return 0;
  final document = jsonDecode(await file.readAsString()) as Map;
  return document['elapsedMilliseconds']! as int;
}

Future<void> _writeDocument({
  required String outputPath,
  required _Options options,
  required List<_TrialSpec> specs,
  required Map<String, Map<String, Object?>> results,
  required int elapsedMilliseconds,
}) async {
  final file = File(outputPath);
  await file.parent.create(recursive: true);
  final temporary = File('$outputPath.tmp');
  final document = _resultDocument(
    options: options,
    specs: specs,
    results: results,
    elapsedMilliseconds: elapsedMilliseconds,
  );
  await temporary.writeAsString(
    '${_encode(document, pretty: options.pretty)}\n',
    flush: true,
  );
  await temporary.rename(outputPath);
}

Map<String, Object?> _resultDocument({
  required _Options options,
  required List<_TrialSpec> specs,
  required Map<String, Map<String, Object?>> results,
  required int elapsedMilliseconds,
}) {
  final orderedResults = [for (final spec in specs) ?results[spec.key]];
  final matchups = <Map<String, Object?>>[];
  final blackStrategies = specs.map((spec) => spec.black).toSet();
  final whiteStrategies = specs.map((spec) => spec.white).toSet();
  for (final black in _Strategy.values.where(blackStrategies.contains)) {
    for (final white in _Strategy.values.where(whiteStrategies.contains)) {
      final trials = orderedResults
          .where(
            (trial) =>
                trial['blackStrategy'] == black.id &&
                trial['whiteStrategy'] == white.id,
          )
          .toList(growable: false);
      final truncated = trials.where(_isTruncated).length;
      final terminated = trials.length - truncated;
      matchups.add({
        'blackStrategy': black.id,
        'whiteStrategy': white.id,
        'plannedGames': options.gamesPerCell,
        'recordedGames': trials.length,
        'terminatedGames': terminated,
        'truncatedGames': truncated,
        'blackWins': trials.where((trial) => trial['winner'] == 'black').length,
        'whiteWins': trials.where((trial) => trial['winner'] == 'white').length,
        'draws': trials
            .where((trial) => !_isTruncated(trial) && trial['winner'] == null)
            .length,
        'averagePlies': trials.isEmpty
            ? null
            : trials
                      .map((trial) => trial['plies']! as int)
                      .reduce((left, right) => left + right) /
                  trials.length,
      });
    }
  }
  final truncated = orderedResults.where(_isTruncated).length;
  return {
    'experiment': 'fourStrategyEliminationTournament',
    'definition':
        'ordered 4x4 tournament of one-step Max Self, one-step Min Theirs, '
        'one-step Max Difference, and two-step Max Difference',
    'victoryRule': 'elimination',
    'strategies': _Strategy.values
        .map((strategy) => strategy.toJson())
        .toList(growable: false),
    'gamesPerCell': options.gamesPerCell,
    'safetyMaxPlies': options.safetyMaxPlies,
    'baseSeed': options.baseSeed,
    'tieBreakMethod': 'seededSha256AmongEqualBestSuccessors',
    'parallelWorkers': math.min(options.concurrency, specs.length),
    'plannedGames': specs.length,
    'recordedGames': orderedResults.length,
    'terminatedGames': orderedResults.length - truncated,
    'truncatedGames': truncated,
    'pendingGames': specs.length - orderedResults.length,
    'runComplete': orderedResults.length == specs.length,
    'elapsedMilliseconds': elapsedMilliseconds,
    'matchups': matchups,
    'trials': orderedResults,
  };
}

bool _isTruncated(Map<String, Object?> trial) => trial['truncated']! as bool;

String _resultKey(Map<String, Object?> result) =>
    '${result['blackStrategy']}|${result['whiteStrategy']}|${result['trial']}';

String _encode(Map<String, Object?> document, {required bool pretty}) => pretty
    ? const JsonEncoder.withIndent('  ').convert(document)
    : jsonEncode(document);

enum _Strategy {
  maxSelf(
    id: 'one-step-max-self',
    label: '1-step Max Self',
    searchPlies: 1,
    objective: 'maximize own population',
  ),
  minTheirs(
    id: 'one-step-min-theirs',
    label: '1-step Min Theirs',
    searchPlies: 1,
    objective: 'minimize opponent population',
  ),
  oneStepDifference(
    id: 'one-step-max-difference',
    label: '1-step Max Difference',
    searchPlies: 1,
    objective: 'maximize own-minus-opponent population',
  ),
  twoStepDifference(
    id: 'two-step-max-difference',
    label: '2-step Max Difference',
    searchPlies: 2,
    objective: 'maximize worst-case own-minus-opponent population',
  );

  const _Strategy({
    required this.id,
    required this.label,
    required this.searchPlies,
    required this.objective,
  });

  final String id;
  final String label;
  final int searchPlies;
  final String objective;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'searchPlies': searchPlies,
    'objective': objective,
  };
}

final class _TrialSpec {
  const _TrialSpec({
    required this.black,
    required this.white,
    required this.trial,
  });

  final _Strategy black;
  final _Strategy white;
  final int trial;

  String get key => '${black.id}|${white.id}|$trial';
}

enum _OneStepObjective {
  maxSelf('maxSelfCells'),
  minTheirs('minOpponentCells');

  const _OneStepObjective(this.id);

  final String id;
}

final class _OneStepObjectiveAgent implements GameAgent {
  _OneStepObjectiveAgent({required this.objective, required this.tieBreakSeed})
    : _analyzer = OneStepMaxDifferenceAgent(tieBreakSeed: tieBreakSeed);

  final _OneStepObjective objective;
  final int tieBreakSeed;
  final OneStepMaxDifferenceAgent _analyzer;

  @override
  String get name => 'one-step-${objective.id}';

  @override
  AgentDecision chooseMove(GameState state) {
    final candidates = _analyzer.analyze(state);
    final scores = candidates.map(
      (candidate) => switch (objective) {
        _OneStepObjective.maxSelf => candidate.evaluation.selfCells,
        _OneStepObjective.minTheirs => -candidate.evaluation.opponentCells,
      },
    );
    final bestScore = scores.reduce(math.max);
    final tiedBest = candidates
        .where((candidate) {
          final score = switch (objective) {
            _OneStepObjective.maxSelf => candidate.evaluation.selfCells,
            _OneStepObjective.minTheirs => -candidate.evaluation.opponentCells,
          };
          return score == bestScore;
        })
        .toList(growable: false);
    return _ObjectiveDecision(
      move: tiedBest[_tieBreakIndex(state, tiedBest.length)].representativeMove,
      objective: objective,
      tieBreakSeed: tieBreakSeed,
    );
  }

  int _tieBreakIndex(GameState state, int candidateCount) {
    if (candidateCount == 1) return 0;
    final digest = sha256.convert(
      utf8.encode('$tieBreakSeed:${state.stateHash}:${objective.id}'),
    );
    final prefix = digest.bytes
        .take(8)
        .fold<int>(0, (value, byte) => (value << 8) | byte);
    return prefix % candidateCount;
  }
}

final class _ObjectiveDecision implements AgentDecision {
  const _ObjectiveDecision({
    required this.move,
    required this.objective,
    required this.tieBreakSeed,
  });

  @override
  final GameMove move;
  final _OneStepObjective objective;
  final int tieBreakSeed;

  @override
  Map<String, Object?> toJson() => {
    'move': move.toJson(),
    'strategy': objective.id,
    'searchPlies': 1,
    'tieBreakSeed': tieBreakSeed,
  };
}

final class _Options {
  const _Options({
    required this.gamesPerCell,
    required this.safetyMaxPlies,
    required this.baseSeed,
    required this.concurrency,
    required this.progressEvery,
    required this.blackStrategy,
    required this.whiteStrategy,
    required this.outputPath,
    required this.resume,
    required this.pretty,
    required this.help,
  });

  final int gamesPerCell;
  final int safetyMaxPlies;
  final int baseSeed;
  final int concurrency;
  final int? progressEvery;
  final _Strategy? blackStrategy;
  final _Strategy? whiteStrategy;
  final String? outputPath;
  final bool resume;
  final bool pretty;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var gamesPerCell = 10;
    var safetyMaxPlies = 1000000;
    var baseSeed = 0;
    var concurrency = Platform.numberOfProcessors.clamp(1, 8);
    int? progressEvery;
    _Strategy? blackStrategy;
    _Strategy? whiteStrategy;
    String? outputPath;
    var resume = false;
    var pretty = false;
    var help = false;
    for (final argument in arguments) {
      if (argument == '--resume') {
        resume = true;
      } else if (argument == '--pretty') {
        pretty = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument.startsWith('--games-per-cell=')) {
        gamesPerCell = _integerValue(argument, '--games-per-cell=');
      } else if (argument.startsWith('--safety-max-plies=')) {
        safetyMaxPlies = _integerValue(argument, '--safety-max-plies=');
      } else if (argument.startsWith('--base-seed=')) {
        baseSeed = _integerValue(argument, '--base-seed=');
      } else if (argument.startsWith('--concurrency=')) {
        concurrency = _integerValue(argument, '--concurrency=');
      } else if (argument.startsWith('--progress-every=')) {
        progressEvery = _integerValue(argument, '--progress-every=');
      } else if (argument.startsWith('--black-strategy=')) {
        blackStrategy = _strategyValue(argument, '--black-strategy=');
      } else if (argument.startsWith('--white-strategy=')) {
        whiteStrategy = _strategyValue(argument, '--white-strategy=');
      } else if (argument.startsWith('--output=')) {
        outputPath = argument.substring('--output='.length);
        if (outputPath.isEmpty) {
          throw const FormatException('--output requires a path');
        }
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }
    if ((blackStrategy == null) != (whiteStrategy == null)) {
      throw const FormatException(
        '--black-strategy and --white-strategy must be provided together',
      );
    }
    if (gamesPerCell <= 0) {
      throw const FormatException('--games-per-cell must be positive');
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
    if (progressEvery != null && progressEvery <= 0) {
      throw const FormatException('--progress-every must be positive');
    }
    if (resume && outputPath == null) {
      throw const FormatException('--resume requires --output');
    }
    return _Options(
      gamesPerCell: gamesPerCell,
      safetyMaxPlies: safetyMaxPlies,
      baseSeed: baseSeed,
      concurrency: concurrency,
      progressEvery: progressEvery,
      blackStrategy: blackStrategy,
      whiteStrategy: whiteStrategy,
      outputPath: outputPath,
      resume: resume,
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

  static _Strategy _strategyValue(String argument, String prefix) {
    final value = argument.substring(prefix.length);
    return switch (value) {
      'max-self' || 'one-step-max-self' => _Strategy.maxSelf,
      'min-theirs' || 'one-step-min-theirs' => _Strategy.minTheirs,
      'one-step-diff' ||
      'one-step-max-difference' => _Strategy.oneStepDifference,
      'two-step-diff' ||
      'two-step-max-difference' => _Strategy.twoStepDifference,
      _ => throw FormatException('invalid strategy: $value'),
    };
  }
}

const _usage = '''
Run the four-strategy ordered tournament under elimination-only rules.

Usage:
  dart run bin/four_strategy_elimination_tournament.dart [options]

Options:
  --games-per-cell=N         Trials per ordered matrix cell (default: 10).
  --safety-max-plies=N       Report active games as truncated (default: 1000000).
  --base-seed=N              First Black tie-break seed (default: 0).
  --concurrency=N            Parallel game workers (default: up to 8).
  --progress-every=N         Report active trials every N plies to stderr.
  --black-strategy=STRATEGY  Run one ordered cell; requires White strategy.
  --white-strategy=STRATEGY  Run one ordered cell; requires Black strategy.
  --output=PATH              Atomically checkpoint JSON data to this path.
  --resume                   Resume a matching output checkpoint.
  --pretty                   Pretty-print JSON output.
  -h, --help                 Show this help.

Strategies: max-self, min-theirs, one-step-diff, two-step-diff
''';
