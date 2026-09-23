import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:game_ai/experimental_search.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

const positionBenchmarkVersion = 'budgetedPositionBenchmarkV1';
const benchmarkTieBreakSeed = 9000000;
const benchmarkBudgets = [10000, 100000, 1000000];
const benchmarkProfiles = [
  (id: 'D1', depth: 1, full: 64, beam: 8),
  (id: 'D2', depth: 2, full: 64, beam: 8),
  (id: 'D3', depth: 3, full: 64, beam: 8),
  (id: 'D4', depth: 4, full: 64, beam: 8),
  (id: 'D5', depth: 5, full: 64, beam: 8),
  (id: 'D8', depth: 8, full: 64, beam: 8),
  (id: 'F1B4', depth: 8, full: 1, beam: 4),
  (id: 'F1B8', depth: 8, full: 1, beam: 8),
  (id: 'F2B4', depth: 8, full: 2, beam: 4),
  (id: 'F2B8', depth: 8, full: 2, beam: 8),
];

void main(List<String> arguments) {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }
    final checkpoint = File(options.checkpoint!).absolute;
    final output = File(options.output!).absolute;
    if (output.existsSync()) {
      throw const FormatException('output already exists; choose a new path');
    }
    final checkpointBytes = checkpoint.readAsBytesSync();
    final document = _object(
      jsonDecode(utf8.decode(checkpointBytes)),
      'checkpoint',
    );
    final state = replayCheckpointPrefix(document, options.plies!);
    final results = <Map<String, Object?>>[];
    final startedAt = DateTime.now().toUtc().toIso8601String();
    final metadata = {
      'benchmarkVersion': positionBenchmarkVersion,
      ..._sourceMetadata(),
      'evaluationVersion': evaluationVersion,
      'budgetMetric': 'generatedUniqueSuccessors',
      'tieBreakSeed': benchmarkTieBreakSeed,
      'transitionBudgets': benchmarkBudgets,
      'execution': {
        'concurrency': 1,
        'runtime': const bool.fromEnvironment('dart.vm.product')
            ? 'AOT product'
            : 'Dart non-product (typically JIT)',
        'dartVersion': Platform.version,
        'operatingSystem': Platform.operatingSystem,
        'availableProcessors': Platform.numberOfProcessors,
        'timingConditions': 'under concurrent screen tournament load',
        'screenTournamentConcurrency': 18,
        'repetitionsPerComparison': 1,
        'warmup':
            'none; use transition counts for deterministic work comparisons',
      },
      'checkpoint': {
        'path': checkpoint.path,
        'sha256': sha256.convert(checkpointBytes).toString(),
        for (final key in [
          'runnerVersion',
          'studyId',
          'sourceRevision',
          'configHash',
          'blackProfile',
          'whiteProfile',
          'trial',
          'blackTieBreakSeed',
          'whiteTieBreakSeed',
          'plies',
          'finalStateHash',
        ])
          key: document[key],
      },
      'requestedPlies': options.plies,
      'position': state.toJson(),
      'prefixMoves': [
        for (final value in (document['moves']! as List).take(options.plies!))
          {
            for (final key in ['player', 'row', 'column'])
              key: (value as Map)[key],
          },
      ],
      'startedAtUtc': startedAt,
      'plannedComparisons': benchmarkBudgets.length * benchmarkProfiles.length,
      'notes': [
        'Every comparison searches the identical saved position; no move is applied between comparisons.',
        'Completed depth means completed requested horizon, not actual reach; terminal lines can stop earlier.',
        'Max visited ply includes work from an unfinished deeper iteration.',
        'Equal transition ceilings do not imply equal actual cost. Selective terminal scores are not full-width proofs.',
        'One position and one timing sample per setting are diagnostic, not strength or latency-distribution estimates.',
      ],
    };
    void save({bool complete = false}) => _atomicWrite(output, {
      ...metadata,
      'complete': complete,
      'completedComparisons': results.length,
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'results': results,
    });
    save();
    for (final result in benchmarkPosition(state)) {
      results.add(result);
      save();
      stderr.writeln(
        '${results.length}/${metadata['plannedComparisons']}: '
        '${result['name']} budget ${result['transitionBudget']}, '
        'completed horizon ${result['completedDepth']}, '
        'visited ply ${result['maxVisitedPly']}, '
        '${result['successorEvaluations']} successors, '
        '${(result['elapsedMicroseconds']! as int) / 1000} ms',
      );
    }
    save(complete: true);
    stdout.writeln('Benchmark: ${output.path}');
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
  } catch (error) {
    stderr.writeln('error: $error');
    exitCode = 1;
  }
}

/// Verify the entire history and saved endpoint, then return the requested
/// active prefix. This does not trust a checkpoint's board without replaying it.
GameState replayCheckpointPrefix(Map<String, Object?> document, int plies) {
  if (document['runnerVersion'] != 'budgetedSearchTournamentV1' ||
      document['evaluationVersion'] != evaluationVersion) {
    throw const FormatException(
      'unsupported checkpoint runner/evaluation version',
    );
  }
  if (document['sourceRevision'] is! String ||
      (document['sourceRevision']! as String).trim().isEmpty) {
    throw const FormatException('checkpoint sourceRevision is missing');
  }
  final saved = GameState.fromJson(document['state']);
  if (saved.rules != GameRules.standard()) {
    throw const FormatException(
      'checkpoint must use standard elimination rules',
    );
  }
  final moves = document['moves'];
  if (moves is! List ||
      moves.length != saved.ply ||
      document['plies'] != saved.ply ||
      document['finalStateHash'] != saved.stateHash) {
    throw const FormatException('checkpoint state/history metadata mismatch');
  }
  if (plies < 0 || plies > moves.length) {
    throw FormatException(
      'requested prefix must be between 0 and ${moves.length} plies',
    );
  }
  const engine = GameEngine();
  var state = engine.initialState(GameRules.standard());
  GameState? prefix = plies == 0 ? state : null;
  for (final value in moves) {
    final json = _object(value, 'saved move');
    final row = json['row'];
    final column = json['column'];
    if (row is! int || column is! int) {
      throw const FormatException('move row/column must be integers');
    }
    final move = GameMove(
      player: Player.fromJson(json['player']),
      row: row,
      column: column,
      expectedRevision: state.revision,
    );
    final validation = engine.validateMove(state, move);
    if (!validation.isValid) {
      throw FormatException(
        'illegal history at ply ${state.ply}: ${validation.message}',
      );
    }
    state = engine.applyMove(state, move).state;
    if (state.ply == plies) prefix = state;
  }
  if (state != saved) {
    throw const FormatException('replayed history does not match saved state');
  }
  if (!prefix!.isActive) {
    throw const FormatException('requested prefix is already a completed game');
  }
  return prefix;
}

/// Serial generator; the optional budgets support tiny deterministic tests.
Iterable<Map<String, Object?>> benchmarkPosition(
  GameState state, {
  List<int> budgets = benchmarkBudgets,
}) sync* {
  if (!state.isActive || state.rules != GameRules.standard()) {
    throw const FormatException(
      'benchmark requires an active elimination position',
    );
  }
  for (final budget in budgets) {
    for (final profile in benchmarkProfiles) {
      final result = BudgetedSearchAgent(
        name: profile.id,
        maxDepth: profile.depth,
        fullWidthDepth: profile.full,
        beamWidth: profile.beam,
        transitionBudget: budget,
        tieBreakSeed: benchmarkTieBreakSeed,
      ).chooseMove(state);
      yield {
        'positionHash': state.positionHash,
        'stateHash': state.stateHash,
        ...result.toJson(),
      };
    }
  }
}

Map<String, Object?> _sourceMetadata() {
  String git(List<String> arguments) {
    final result = Process.runSync('git', arguments);
    if (result.exitCode != 0) {
      throw const FormatException('run this benchmark from its Git checkout');
    }
    return (result.stdout as String).trim();
  }

  final root = git(['rev-parse', '--show-toplevel']);
  const relativePath = 'packages/game_ai/bin/budgeted_position_benchmark.dart';
  return {
    'sourceRevision': git(['rev-parse', 'HEAD']),
    'searchSourceDirty': git([
      'status',
      '--porcelain',
      '--untracked-files=all',
      '--',
      '$root/packages/game_ai',
      '$root/packages/game_engine',
    ]).isNotEmpty,
    'benchmarkSourceSha256': sha256
        .convert(File('$root/$relativePath').readAsBytesSync())
        .toString(),
  };
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$name must be an object');
  }
  return value.cast<String, Object?>();
}

void _atomicWrite(File output, Map<String, Object?> document) {
  output.parent.createSync(recursive: true);
  final temporary = File('${output.path}.tmp');
  temporary.writeAsStringSync('${jsonEncode(document)}\n', flush: true);
  temporary.renameSync(output.path);
}

final class _Options {
  const _Options(this.checkpoint, this.plies, this.output, this.help);
  final String? checkpoint;
  final int? plies;
  final String? output;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    String? checkpoint;
    String? output;
    int? plies;
    var help = false;
    final seen = <String>{};
    for (final argument in arguments) {
      final key = argument.split('=').first;
      if (!seen.add(key)) throw FormatException('duplicate option: $key');
      if (argument.startsWith('--checkpoint=')) {
        checkpoint = argument.substring('--checkpoint='.length);
      } else if (argument.startsWith('--output=')) {
        output = argument.substring('--output='.length);
      } else if (argument.startsWith('--plies=')) {
        plies = int.tryParse(argument.substring('--plies='.length));
        if (plies == null || plies < 0) {
          throw const FormatException('--plies must be a non-negative integer');
        }
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else {
        throw FormatException('unsupported option: $argument');
      }
    }
    if (!help &&
        (checkpoint == null ||
            checkpoint.isEmpty ||
            output == null ||
            output.isEmpty ||
            plies == null)) {
      throw const FormatException(
        '--checkpoint, --plies, and --output are required',
      );
    }
    return _Options(checkpoint, plies, output, help);
  }
}

const _usage = '''
Compare ten search profiles at 10K, 100K, and 1M transition ceilings on one
replayed checkpoint position. Runs serially; never modifies the checkpoint.

Usage:
  dart run bin/budgeted_position_benchmark.dart --checkpoint=PATH --plies=N --output=PATH

Use dart compile exe for timing runs. Timing metadata assumes the screen
tournament is running concurrently. Output must not already exist.
''';
