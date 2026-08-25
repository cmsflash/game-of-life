import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
    final config = options.quick
        ? OneStepOptimizationConfig(
            searchSteps: const [50],
            discoveryGames: 1,
            survivorGames: 2,
            finalistGames: 3,
            survivorCount: 2,
            finalistCount: 1,
            refineParentCount: 1,
            globalExplorationCount: 0,
            oracleIterations: 1,
            metaGames: 1,
            metaSolverIterations: 1000,
            validationGames: 2,
            validationBootstrapSamples: 100,
            maxPlies: options.maxPlies ?? 2,
            baseSeed: options.baseSeed,
            validationBaseSeed: options.baseSeed + 1000000,
            maxParallelEvaluations: options.concurrency,
          )
        : OneStepOptimizationConfig(
            oracleIterations: options.oracleIterations,
            validationGames: options.validationGames,
            maxPlies: options.maxPlies ?? 100,
            baseSeed: options.baseSeed,
            validationBaseSeed: options.baseSeed + 1000000,
            maxParallelEvaluations: options.concurrency,
          );
    final optimizer = OneStepAdaptiveOptimizer(
      evaluate: _evaluate,
      config: config,
      onProgress: stderr.writeln,
    );
    final result = await optimizer.run();
    final encoder = options.pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    final document = '${encoder.convert(result.toJson())}\n';
    final outputPath = options.outputPath;
    if (outputPath == null) {
      stdout.write(document);
    } else {
      final output = File(outputPath);
      await output.parent.create(recursive: true);
      await output.writeAsString(document, flush: true);
      stderr.writeln('Optimization data written to ${output.path}');
    }
    stderr.writeln(
      'Recommended Black: ${result.recommendedBlack.label}; '
      'White: ${result.recommendedWhite.label}; '
      'estimated exploitability: '
      '${result.estimatedExploitability.toStringAsFixed(4)}',
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

Future<OneStepPayoffEstimate> _evaluate(OneStepEvaluationRequest request) =>
    Isolate.run(() => _evaluateSynchronously(request));

OneStepPayoffEstimate _evaluateSynchronously(OneStepEvaluationRequest request) {
  const runner = OneStepExperimentRunner();
  final utilities = <int>[];
  for (var trial = 0; trial < request.games; trial++) {
    final opponent = request
        .opponents[_opponentIndex(
          request.opponents,
          request.scheduleSeed,
          trial,
        )]
        .profile;
    final black = request.role == OneStepOptimizationRole.black
        ? request.candidate
        : opponent;
    final white = request.role == OneStepOptimizationRole.white
        ? request.candidate
        : opponent;
    final matchup = runner.runMatchup(
      blackProfile: black,
      whiteProfile: white,
      games: 1,
      maxPlies: request.maxPlies,
      baseSeed: request.baseSeed + trial * 2,
    );
    final winner = matchup.trials.single.match.finalState.outcome?.winner;
    utilities.add(switch (winner) {
      Player.black => 1,
      Player.white => -1,
      null => 0,
    });
  }
  return OneStepPayoffEstimate(utilities);
}

int _opponentIndex(
  List<OneStepWeightedProfile> opponents,
  int scheduleSeed,
  int trial,
) {
  final totalWeight = opponents.fold<double>(
    0,
    (total, opponent) => total + opponent.weight,
  );
  if (totalWeight <= 0 || opponents.any((opponent) => opponent.weight < 0)) {
    throw ArgumentError.value(
      opponents.map((opponent) => opponent.weight).toList(),
      'opponents',
      'weights must be non-negative and have a positive total',
    );
  }
  final digest = sha256.convert(utf8.encode('$scheduleSeed:$trial'));
  final prefix = digest.bytes
      .take(4)
      .fold<int>(0, (value, byte) => (value << 8) | byte);
  final target = prefix / 0x100000000 * totalWeight;
  var cumulative = 0.0;
  for (var index = 0; index < opponents.length; index++) {
    cumulative += opponents[index].weight;
    if (target < cumulative) return index;
  }
  return opponents.length - 1;
}

final class _Options {
  const _Options({
    required this.oracleIterations,
    required this.validationGames,
    required this.maxPlies,
    required this.baseSeed,
    required this.concurrency,
    required this.outputPath,
    required this.pretty,
    required this.quick,
    required this.help,
  });

  final int oracleIterations;
  final int validationGames;
  final int? maxPlies;
  final int baseSeed;
  final int concurrency;
  final String? outputPath;
  final bool pretty;
  final bool quick;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    var oracleIterations = 2;
    var validationGames = 500;
    int? maxPlies;
    var baseSeed = 10000;
    var concurrency = Platform.numberOfProcessors.clamp(1, 12);
    String? outputPath;
    var pretty = false;
    var quick = false;
    var help = false;
    for (final argument in arguments) {
      if (argument == '--pretty') {
        pretty = true;
      } else if (argument == '--quick') {
        quick = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument.startsWith('--oracle-iterations=')) {
        oracleIterations = _integerValue(argument, '--oracle-iterations=');
      } else if (argument.startsWith('--validation-games=')) {
        validationGames = _integerValue(argument, '--validation-games=');
      } else if (argument.startsWith('--max-plies=')) {
        maxPlies = _integerValue(argument, '--max-plies=');
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
    return _Options(
      oracleIterations: oracleIterations,
      validationGames: validationGames,
      maxPlies: maxPlies,
      baseSeed: baseSeed,
      concurrency: concurrency,
      outputPath: outputPath,
      pretty: pretty,
      quick: quick,
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
Run reproducible adaptive optimization of one-step strategy mixtures.

Usage:
  dart run bin/one_step_optimize.dart [options]

Options:
  --oracle-iterations=N  Restricted-game expansion rounds (default: 2).
  --validation-games=N   Unseen-seed games per reported pairing (default: 500).
  --max-plies=N          Positive even turn limit (default: 100).
  --base-seed=N          First optimization tie-break seed (default: 10000).
  --concurrency=N        Parallel candidate evaluations (default: up to 12).
  --output=PATH          Write complete JSON data to this path.
  --pretty               Pretty-print JSON output.
  --quick                Run a tiny smoke configuration for development only.
  -h, --help             Show this help.
''';
